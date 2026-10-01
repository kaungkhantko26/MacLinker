import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("MacLinker").font(.headline)
                Spacer()
                if app.paths.vpnActive {
                    Label("VPN", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                        .help("VPN detected (\(app.paths.vpnInterfaces.joined(separator: ", "))). LAN links are pinned to \(app.paths.lanInterface?.name ?? "the LAN").")
                }
                Circle().fill(app.connectedCount > 0 ? Color.green : Color.secondary).frame(width: 9, height: 9)
            }

            if !app.permissions.allGranted {
                Button { WindowManager.shared.showMain() } label: {
                    Label("Permissions needed for keyboard & mouse", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }.buttonStyle(.plain)
            }

            Divider()

            let devices = app.devices
            if devices.isEmpty {
                Text("Looking for Macs running MacLinker…").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(devices) { DeviceRow(device: $0) }

            Divider()
            Toggle("Control Keyboard & Mouse", isOn: $app.settings.inputSharing)
            Toggle("Clipboard Sharing", isOn: $app.settings.clipboardSharing)
            Toggle("File Sharing", isOn: $app.settings.fileSharing)
            Divider()

            if case .ready(let v) = app.updater.status {
                Button("Update to \(v) and Restart") { app.updater.installAndRelaunch() }
            }
            if app.connectedCount > 0 {
                Button("Disconnect All") { app.connections.disconnectAll() }
            }
            Button("Open MacLinker…") { WindowManager.shared.showMain() }
            Button("Quit MacLinker") { NSApp.terminate(nil) }
        }
        .toggleStyle(.checkbox)
        .padding(14)
        .frame(width: 320)
    }
}

struct DeviceRow: View {
    @EnvironmentObject var app: AppState
    let device: Device

    var body: some View {
        HStack {
            Circle().fill(device.status.color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(device.name)
                Text(device.statusText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch device.status {
            case .connected:
                Button("Send File…") { app.pickAndSendFiles(to: device.id) }.controlSize(.small)
                Button("Disconnect") { app.disconnect(device.id) }.controlSize(.small)
            case .nearby, .offline:
                Button(device.isTrusted ? "Connect" : "Pair") { app.connect(device) }.controlSize(.small)
            default: ProgressView().controlSize(.small)
            }
        }
    }
}

extension Device.Status {
    var color: Color {
        switch self {
        case .connected: return .green
        case .pairing, .connecting: return .orange
        case .nearby: return .blue
        case .offline: return .secondary
        }
    }
}

extension Device {
    var statusText: String {
        switch status {
        case .connected: return latency.map { String(format: "Connected · %.0f ms", $0) } ?? "Connected"
        case .pairing: return "Waiting for pairing"
        case .connecting: return "Connecting…"
        case .nearby: return isTrusted ? "Nearby" : "Nearby · not paired"
        case .offline: return "Offline"
        }
    }
}
