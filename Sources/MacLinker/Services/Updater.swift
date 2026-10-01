import Foundation
import AppKit
import Security

/// Checks GitHub Releases for a newer MacLinker.zip, downloads it, and installs it on request.
///
/// Authenticity: the downloaded app must satisfy *this* app's designated code requirement, i.e. be
/// signed by the same certificate. A tampered or foreign build is refused.
final class Updater: ObservableObject {
    enum Status: Equatable {
        case idle, checking, upToDate, downloading(String), ready(String), failed(String)
    }

    @Published private(set) var status: Status = .idle
    private var staged: URL?
    private var timer: Timer?

    var repo: String? {
        let r = (Bundle.main.object(forInfoDictionaryKey: "MacLinkerUpdateRepo") as? String) ?? ""
        return r.contains("/") ? r : nil
    }
    var currentVersion: String { (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0" }

    func start() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.check() }
    }

    func check() {
        guard let repo else { status = .failed("Updates aren't configured in this build."); return }
        if case .downloading = status { return }
        if case .ready = status { return }
        status = .checking
        Task {
            do {
                let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
                var req = URLRequest(url: url)
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, _) = try await URLSession.shared.data(for: req)
                let release = try JSONDecoder().decode(Release.self, from: data)
                guard Self.isNewer(release.tag_name, than: currentVersion) else {
                    await MainActor.run { self.status = .upToDate }; return
                }
                guard let asset = release.assets.first(where: { $0.name == "MacLinker.zip" }) else {
                    throw UpdateError.message("Release has no MacLinker.zip")
                }
                await MainActor.run { self.status = .downloading(release.tag_name) }
                try await stage(from: asset.browser_download_url, tag: release.tag_name)
            } catch {
                await MainActor.run { self.status = .failed("\(error.localizedDescription)") }
            }
        }
    }

    private func stage(from url: URL, tag: String) async throws {
        let (tmp, _) = try await URLSession.shared.download(from: url)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maclinker-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent("MacLinker.zip")
        try FileManager.default.moveItem(at: tmp, to: zip)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
        let app = dir.appendingPathComponent("MacLinker.app")
        guard Self.isSignedBySameCertificate(app) else {
            try? FileManager.default.removeItem(at: dir)
            throw UpdateError.message("Update rejected: it isn't signed by the same certificate as this app.")
        }
        staged = app
        await MainActor.run { self.status = .ready(tag) }
    }

    /// Where the updated app should live. If this copy can't be replaced (macOS runs quarantined apps
    /// from a read-only "translocated" path, or the folder isn't writable) install to Applications.
    static func installDestination(current: URL = Bundle.main.bundleURL) -> URL {
        let fm = FileManager.default
        let translocated = current.path.contains("/AppTranslocation/")
        if !translocated, fm.isWritableFile(atPath: current.deletingLastPathComponent().path) { return current }
        let system = URL(fileURLWithPath: "/Applications")
        if fm.isWritableFile(atPath: system.path) { return system.appendingPathComponent(current.lastPathComponent) }
        let home = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        try? fm.createDirectory(at: home, withIntermediateDirectories: true)
        return home.appendingPathComponent(current.lastPathComponent)
    }

    static func installScript(pid: Int32, staged: String, dest: String) -> String {
        """
        #!/bin/bash
        LOG="$HOME/Library/Logs/MacLinker-update.log"
        mkdir -p "$HOME/Library/Logs"
        exec >>"$LOG" 2>&1
        STAGED="\(staged)"; DEST="\(dest)"
        echo "--- $(date) updating to $DEST"
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        [ -e "$DEST" ] && mv "$DEST" "$DEST.old"
        if /usr/bin/ditto "$STAGED" "$DEST"; then
            /usr/bin/xattr -dr com.apple.quarantine "$DEST"
            rm -rf "$DEST.old" "$STAGED"
            echo "installed"
        else
            echo "install failed, restoring"
            rm -rf "$DEST"; [ -e "$DEST.old" ] && mv "$DEST.old" "$DEST"
        fi
        /usr/bin/open "$DEST"
        """
    }

    /// Replaces the app with the staged one after we quit, then relaunches it.
    func installAndRelaunch() {
        guard let staged else { return }
        let dest = Self.installDestination().path
        let script = Self.installScript(pid: ProcessInfo.processInfo.processIdentifier,
                                        staged: staged.path, dest: dest)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("maclinker-install.sh")
        do {
            try script.write(to: path, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
            p.arguments = ["/bin/bash", path.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            // Give the installer a moment to start waiting before we exit.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
        } catch {
            status = .failed("Couldn't start installer: \(error.localizedDescription)")
        }
    }

    // MARK: Helpers

    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        let tag_name: String
        let assets: [Asset]
    }
    private enum UpdateError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m } else { return nil } }
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 { throw UpdateError.message("\(tool) failed") }
    }

    static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 } }
        let a = parts(remote), b = parts(local)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func isSignedBySameCertificate(_ app: URL) -> Bool {
        var me: SecCode?, meStatic: SecStaticCode?, requirement: SecRequirement?, other: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &meStatic) == errSecSuccess, let meStatic,
              SecCodeCopyDesignatedRequirement(meStatic, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &other) == errSecSuccess, let other else { return false }
        // An ad-hoc signed app has a cdhash-only requirement, which no update can ever satisfy; refuse it.
        var info: CFDictionary?
        SecCodeCopySigningInformation(meStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        guard let certs = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [Any], !certs.isEmpty else { return false }
        return SecStaticCodeCheckValidity(other, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess
    }
}
