import SwiftUI
import UniformTypeIdentifiers

struct ConnectedDeviceView: View {
    @EnvironmentObject var app: AppState
    let device: Device
    @State private var dropTargeted = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Circle().fill(.green).frame(width: 9, height: 9)
                    VStack(alignment: .leading) {
                        Text(device.name).font(.headline)
                        Text(device.statusText).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Send File…") { app.pickAndSendFiles(to: device.id) }
                    Button("Disconnect") { app.disconnect(device.id) }
                }
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading) {
                        Text("Where is \(device.name) relative to this Mac?").font(.caption).foregroundStyle(.secondary)
                        PositionPicker(position: device.position) { app.setPosition($0, for: device.id) }
                    }
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                        .foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
                        .overlay(Text("Drop files here to send").font(.caption).foregroundStyle(.secondary))
                        .frame(height: 90)
                        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                            for p in providers {
                                _ = p.loadObject(ofClass: URL.self) { url, _ in
                                    if let url { DispatchQueue.main.async { app.sendFiles([url], to: device.id) } }
                                }
                            }
                            return true
                        }
                }
                RemoteControlsView(device: device)
                DisplayShareRow(device: device)
                if device.position == nil {
                    Text("Pick a side to share one keyboard and mouse between the Macs.")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    Text("Push the pointer against that screen edge to cross over. Emergency exit: ⌃⌥⌘⎋")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(6)
        }
    }
}

struct PositionPicker: View {
    let position: Edge?
    let onChange: (Edge?) -> Void

    private func cell(_ edge: Edge) -> some View {
        Button { onChange(position == edge ? nil : edge) } label: {
            Text(edge.title).frame(width: 64, height: 26)
        }
        .buttonStyle(.borderedProminent)
        .tint(position == edge ? .accentColor : .gray.opacity(0.4))
    }

    var body: some View {
        VStack(spacing: 4) {
            cell(.top)
            HStack(spacing: 4) {
                cell(.left)
                Text("This Mac").font(.caption).frame(width: 64, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).stroke(.secondary))
                cell(.right)
            }
            cell(.bottom)
        }
    }
}

/// Brightness and volume of the *other* Mac. Only the controls that Mac reports as working are shown.
struct RemoteControlsView: View {
    @EnvironmentObject var app: AppState
    let device: Device

    private func binding(_ kind: SystemControlPayload.Kind) -> Binding<Double> {
        Binding(get: {
            guard let s = app.system.states[device.id] else { return 0.5 }
            let v = kind == .brightness ? s.brightness : s.volume
            return Double(v < 0 ? 0.5 : v)
        }, set: { app.system.set(kind, Float($0), on: device.id) })
    }

    var body: some View {
        if let s = app.system.states[device.id], s.hasBrightness || s.hasVolume {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(device.name) controls").font(.caption).foregroundStyle(.secondary)
                if s.hasBrightness {
                    HStack {
                        Image(systemName: "sun.max").frame(width: 20)
                        Slider(value: binding(.brightness), in: 0...1)
                    }
                }
                if s.hasVolume {
                    HStack {
                        Button { app.system.set(.mute, s.muted ? 0 : 1, on: device.id) } label: {
                            Image(systemName: s.muted ? "speaker.slash" : "speaker.wave.2").frame(width: 20)
                        }.buttonStyle(.plain)
                        Slider(value: binding(.volume), in: 0...1).disabled(s.muted)
                    }
                }
            }
        }
    }
}

/// Use the other Mac as a second display for this one.
struct DisplayShareRow: View {
    @EnvironmentObject var app: AppState
    let device: Device

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch app.display.state {
            case .offering(let p) where p == device.id:
                row("Waiting for \(device.name) to accept…", button: "Cancel") { app.display.stop() }
            case .starting(let p) where p == device.id:
                row("Starting the display…", button: "Cancel") { app.display.stop() }
            case .hosting(let p) where p == device.id:
                row("\(device.name) is now a second display for this Mac.", button: "Stop") { app.display.stop() }
                Text("Drag windows onto it, or arrange it in System Settings > Displays. Stop with Control+Option+Command+Esc on \(device.name).")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Arrange Displays…") { openDisplaySettings() }.buttonStyle(.link).font(.caption)
            case .asking(let p) where p == device.id, .viewing(let p) where p == device.id:
                Text("This Mac is showing \(device.name)'s desktop.").font(.callout)
            case .failed(let reason):
                row(reason, button: "Dismiss") { app.display.clearFailure() }.foregroundStyle(.red)
            default:
                HStack {
                    Image(systemName: "display.2").frame(width: 20)
                    Text("Use \(device.name) as a second display").font(.callout)
                    Spacer()
                    Button("Start") { app.display.startHosting(to: device.id) }
                        .disabled(app.display.isBusy || !app.supportsDisplay(device.id))
                }
                if !app.supportsDisplay(device.id) {
                    Text("\(device.name) needs MacLinker \(K.displayMinVersion) or newer for this.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: "display.2").frame(width: 20)
            Text(text).font(.callout)
            Spacer()
            Button(button, action: action)
        }
    }

    private func openDisplaySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}
