import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Form {
            Section("Sharing") {
                Toggle("Control keyboard & mouse across Macs", isOn: $app.settings.inputSharing)
                Toggle("Share clipboard (text, links, images)", isOn: $app.settings.clipboardSharing)
                Toggle("Copy files, folders and apps between Macs (⌘C here, ⌘V there; up to 250 MB)", isOn: $app.settings.fileClipboard)
                Toggle("Drag files, links and apps across the screen edge (experimental)", isOn: $app.settings.dragAcrossEdge)
                Toggle("Accept files into Downloads/MacLinker", isOn: $app.settings.fileSharing)
                Toggle("Let paired Macs adjust this Mac's brightness and volume", isOn: $app.settings.remoteSystemControl)
                Toggle("Let paired Macs lock this Mac's screen", isOn: $app.settings.allowRemoteLock)
                Toggle("Open at login", isOn: $app.settings.launchAtLogin)
                HStack {
                    Text("Pointer hiding while controlling another Mac")
                    Spacer()
                    Button("Test (5 s)") { CursorHider.test() }
                }
                HStack {
                    Text("Edge push")
                    Slider(value: $app.settings.edgePush, in: 0...60)
                    Text("\(Int(app.settings.edgePush)) pt").monospacedDigit().frame(width: 50)
                }
            }

            Section("Network") {
                Toggle("Keep Mac-to-Mac traffic on the local network (bypass VPN)", isOn: $app.settings.pinToLAN)
                LabeledContent("Local interface", value: app.paths.lanInterface?.name ?? "none")
                LabeledContent("VPN") {
                    Text(app.paths.vpnActive ? "Detected (\(app.paths.vpnInterfaces.joined(separator: ", ")))" : "Not detected")
                }
                Text("Outline routes traffic through a system tunnel. With this on, MacLinker binds its LAN connections to \(app.paths.lanInterface?.name ?? "Wi-Fi/Ethernet") so they never enter the tunnel. Both Macs must be on the same LAN; Outline cannot link two Macs by itself.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Permissions") {
                permissionRow("Accessibility", granted: app.permissions.accessibility,
                              request: app.permissions.requestAccessibility, pane: "Privacy_Accessibility")
                permissionRow("Input Monitoring", granted: app.permissions.inputMonitoring,
                              request: app.permissions.requestInputMonitoring, pane: "Privacy_ListenEvent")
            }

            Section("Trusted devices") {
                if app.trusted.devices.isEmpty { Text("None yet").foregroundStyle(.secondary) }
                ForEach(app.trusted.devices) { t in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("✓ \(t.name)")
                            Text(t.lastConnected.map { "Last connected \($0.formatted(.relative(presentation: .named)))" } ?? "Never connected")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { app.forget(t.id) }
                    }
                }
            }

            Section("Updates") {
                LabeledContent("Version", value: app.updater.currentVersion)
                HStack {
                    Text(updateText)
                    Spacer()
                    if case .ready = app.updater.status {
                        Button("Restart & Update") { app.updater.installAndRelaunch() }
                    } else {
                        Button("Check Now") { app.updater.check() }
                    }
                }
            }

            Section("About") {
                LabeledContent("MacLinker", value: "Built by Kaung Khant Ko")
                Link("github.com/kaungkhantko26/MacLinker", destination: URL(string: "https://github.com/kaungkhantko26/MacLinker")!)
            }

            Section("This Mac") {
                LabeledContent("Name", value: app.identity.deviceName)
                LabeledContent("Device ID", value: app.identity.deviceID).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    private var updateText: String {
        switch app.updater.status {
        case .idle: return "Checks automatically at launch and every few hours."
        case .checking: return "Checking…"
        case .upToDate: return "MacLinker is up to date."
        case .downloading(let v): return "Downloading \(v)…"
        case .ready(let v): return "\(v) is ready to install."
        case .failed(let why): return why
        }
    }

    private func permissionRow(_ name: String, granted: Bool, request: @escaping () -> Void, pane: String) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
            Text(name)
            Spacer()
            if !granted {
                Button("Request") { request() }
                Button("Open Settings") { app.permissions.openPrivacySettings(pane) }
            }
        }
    }
}

struct ActivityView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        if app.files.transfers.isEmpty {
            Text("No file transfers yet").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(app.files.transfers) { t in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: t.direction == .sending ? "arrow.up.circle" : "arrow.down.circle")
                        Text(t.name)
                        Spacer()
                        statusText(t)
                    }
                    ProgressView(value: Double(t.transferred), total: Double(max(t.size, 1)))
                    HStack {
                        Text(t.direction == .sending ? "To \(t.peerName)" : "From \(t.peerName)")
                        if t.status == .done, let url = t.url {
                            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.link)
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private func statusText(_ t: TransferItem) -> some View {
        switch t.status {
        case .active: Text("\(ByteCountFormatter.string(fromByteCount: Int64(t.transferred), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(t.size), countStyle: .file))").font(.caption)
        case .done: Label("Done", systemImage: "checkmark").font(.caption).foregroundStyle(.green)
        case .failed(let why): Text(why).font(.caption).foregroundStyle(.red)
        }
    }
}
