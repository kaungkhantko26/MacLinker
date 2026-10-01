import SwiftUI

struct PairingView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 16) {
            if let req = app.pairing.pending {
                Text("Pair with “\(req.deviceName)”").font(.title3.bold())
                Text("Make sure this code is identical on both Macs, then confirm on both.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Text(req.formattedCode)
                    .font(.system(size: 44, weight: .semibold, design: .monospaced))
                    .padding(.vertical, 8)
                HStack {
                    Button("Cancel", role: .cancel) { app.pairing.reject() }.keyboardShortcut(.cancelAction)
                    Button("Codes Match") { app.pairing.confirm() }.keyboardShortcut(.defaultAction)
                }
                Text("If the codes differ, press Cancel: someone may be intercepting the connection.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                Text("No pairing in progress")
            }
        }
        .padding(24)
        .frame(width: 380)
        .onChange(of: app.pairing.pending) { if $0 == nil { WindowManager.shared.hidePairing() } }
    }
}
