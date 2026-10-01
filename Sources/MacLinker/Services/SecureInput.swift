import Foundation
import AppKit
import Carbon.HIToolbox

struct SecureInputStatus: Equatable {
    var enabled = false
    /// The app that turned it on, when macOS says which one.
    var appName: String?
}

/// "Secure Event Input" is a macOS protection: while any app has it on (a password field, Terminal's
/// Secure Keyboard Entry, a security tool), no other app can see keystrokes. That includes MacLinker on the Mac you
/// type on, so the keyboard stops reaching the other Mac while the mouse still works.
enum SecureInput {
    static func status() -> SecureInputStatus {
        guard IsSecureEventInputEnabled() else { return SecureInputStatus() }
        var name: String?
        if let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
           let pid = (dict["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value {
            name = NSRunningApplication(processIdentifier: pid)?.localizedName
        }
        return SecureInputStatus(enabled: true, appName: name)
    }

    static func message(for status: SecureInputStatus) -> String? {
        guard status.enabled else { return nil }
        let who = status.appName.map { "“\($0)”" } ?? "An app"
        return "Keyboard sharing is blocked. \(who) has Secure Input on, so macOS hides your typing from MacLinker. "
            + "Quit it, leave its password field, or turn off “Secure Keyboard Entry” (Terminal menu). The mouse still works."
    }
}
