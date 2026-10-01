import SwiftUI

struct DeviceListView: View {
    @EnvironmentObject var app: AppState
    @State private var address = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let devices = app.devices
            if devices.isEmpty {
                Text("No Macs found yet. Install and open MacLinker on your other Mac, on the same network.")
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(devices) { device in
                        if device.status == .connected { ConnectedDeviceView(device: device) }
                        else { GroupBox { DeviceRow(device: device).padding(4) } }
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Add a Mac by address").font(.subheadline.bold())
                HStack {
                    TextField("192.168.1.6 or mac-mini.local[:port]", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("Connect", action: add).disabled(address.isEmpty)
                }
                Text(app.lastError ?? "Use this if automatic discovery is blocked, for example by a VPN.")
                    .font(.caption).foregroundStyle(app.lastError == nil ? Color.secondary : Color.red)
            }
        }
    }

    private func add() { app.connect(address: address); address = "" }
}
