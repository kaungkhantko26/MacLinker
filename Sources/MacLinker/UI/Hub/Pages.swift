import SwiftUI
import UniformTypeIdentifiers

// MARK: Devices

struct DevicesPage: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Devices", subtitle: "Pair Macs, set where each one sits, and connect by address.") {
                RefreshButton(isRefreshing: app.isRefreshing, action: app.refresh)
            }
            DeviceListView()
        }
        .padding(24)
    }
}

// MARK: Transfer

struct TransferPage: View {
    @EnvironmentObject var app: AppState
    @State private var targeted = false

    private var targets: [DeviceActionButton.Target] {
        app.devices.filter { $0.status == .connected }.map { .init(id: $0.id, name: $0.name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Transfer", subtitle: "Files you send and receive. Received files go to Downloads/MacLinker.") {
                HStack {
                    DeviceActionButton(title: "Send File…", symbol: "paperplane", targets: targets, action: app.pickAndSendFiles)
                        .frame(width: 150)
                    Button { NSWorkspace.shared.open(K.downloadsDirectory) } label: { Image(systemName: "folder") }
                        .help("Open the received files folder")
                }
            }
            if app.files.transfers.isEmpty {
                EmptyStateCard(symbol: "arrow.left.arrow.right", title: "No transfers yet",
                               message: targets.isEmpty ? "Connect a Mac to send files."
                                                        : "Drop files here, or use Send File.")
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(app.files.transfers) { TransferRow(item: $0) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
            .padding(10).opacity(targeted ? 1 : 0))
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            guard let target = targets.first else { return false }
            for p in providers { _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { app.sendFiles([url], to: target.id) } } } }
            return true
        }
    }
}

struct TransferRow: View {
    let item: TransferItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: item.direction == .sending ? "arrow.up.circle" : "arrow.down.circle").foregroundStyle(Color.accentColor)
                Text(item.name).lineLimit(1)
                Spacer()
                status
            }
            ProgressView(value: Double(item.transferred), total: Double(max(item.size, 1)))
            HStack {
                Text(item.direction == .sending ? "To \(item.peerName)" : "From \(item.peerName)")
                if item.status == .done, let url = item.url {
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.link)
                }
            }.font(.caption).foregroundStyle(.secondary)
        }
        .hubCard(padding: 12, radius: 12)
    }

    private func bytes(_ n: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }

    @ViewBuilder private var status: some View {
        switch item.status {
        case .active: Text("\(bytes(item.transferred)) / \(bytes(item.size))").font(.caption)
        case .done: Label("Done", systemImage: "checkmark").font(.caption).foregroundStyle(.green)
        case .failed(let why): Text(why).font(.caption).foregroundStyle(.red)
        }
    }
}

// MARK: Drop Shelf

struct ShelfPage: View {
    @EnvironmentObject var app: AppState
    @State private var targeted = false

    private var targets: [DeviceActionButton.Target] {
        app.devices.filter { $0.status == .connected }.map { .init(id: $0.id, name: $0.name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Drop Shelf", subtitle: "Park files here, then send them when you're ready. Files stay where they are; nothing is copied.") {
                HStack {
                    DeviceActionButton(title: "Send All", symbol: "paperplane", targets: app.shelf.items.isEmpty ? [] : targets) { id in
                        app.sendFiles(app.shelf.items.map(\.url), to: id)
                    }.frame(width: 130)
                    Button("Clear") { app.shelf.clear() }.disabled(app.shelf.items.isEmpty)
                }
            }
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .background(RoundedRectangle(cornerRadius: 16).fill(targeted ? Color.accentColor.opacity(0.08) : Color.clear))
                .overlay(VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 26)).foregroundStyle(.secondary)
                    Text("Drop files here").font(.headline)
                }.foregroundStyle(.secondary))
                .frame(height: 130)
                .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                    for p in providers { _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url { DispatchQueue.main.async { app.shelf.add([url]) } } } }
                    return true
                }
            if app.shelf.items.isEmpty {
                Text("The shelf is empty.").font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 8) { ForEach(app.shelf.items) { ShelfRow(item: $0, targets: targets) } }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
    }
}

struct ShelfRow: View {
    @EnvironmentObject var app: AppState
    let item: ShelfItem
    let targets: [DeviceActionButton.Target]

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu("Send") {
                if targets.isEmpty { Text("No connected Macs") }
                ForEach(targets) { t in Button(t.name) { app.sendFiles([item.url], to: t.id) } }
            }.menuStyle(.borderlessButton).fixedSize().disabled(targets.isEmpty)
            Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.plain).help("Show in Finder")
            Button { app.shelf.remove(item) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove from shelf")
        }
        .hubCard(padding: 10, radius: 12)
    }
}

// MARK: Clipboard

struct ClipboardPage: View {
    @EnvironmentObject var app: AppState

    private var targets: [DeviceActionButton.Target] {
        app.devices.filter { $0.status == .connected }.map { .init(id: $0.id, name: $0.name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Clipboard", subtitle: "Recent items from this Mac and your other Macs. Kept in memory only, never saved to disk.") {
                HStack {
                    DeviceActionButton(title: "Send Current", symbol: "doc.on.clipboard", targets: targets, action: app.sendClipboard)
                        .frame(width: 150)
                    Button("Clear") { app.clipboard.history.clear() }.disabled(app.clipboard.history.entries.isEmpty)
                }
            }
            if app.clipboard.history.entries.isEmpty {
                EmptyStateCard(symbol: "doc.on.clipboard", title: "Nothing copied yet", message: "Copy something on any connected Mac and it shows up here.")
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(app.clipboard.history.entries) { ClipboardRow(entry: $0, targets: targets) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
    }
}

struct ClipboardRow: View {
    @EnvironmentObject var app: AppState
    let entry: ClipboardEntry
    let targets: [DeviceActionButton.Target]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.kind == .image ? "photo" : "text.alignleft").foregroundStyle(Color.accentColor).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.kind == .image ? "Image (\(ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .file)))" : entry.preview)
                    .lineLimit(3).font(.callout)
                Text("\(entry.source) · \(entry.date.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let message = entry.message {
                Button("Copy") { app.clipboard.copy(message) }.controlSize(.small)
                Menu("Send") {
                    if targets.isEmpty { Text("No connected Macs") }
                    ForEach(targets) { t in Button(t.name) { app.send(entry, to: t.id) } }
                }.menuStyle(.borderlessButton).fixedSize().disabled(targets.isEmpty)
            } else {
                Text("Too large to keep").font(.caption).foregroundStyle(.secondary)
            }
        }
        .hubCard(padding: 12, radius: 12)
    }
}

// MARK: Actions

struct ActionsPage: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        let connected = app.devices.filter { $0.status == .connected }
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Actions", subtitle: "Do something on a connected Mac.") {
                RefreshButton(isRefreshing: app.isRefreshing, action: app.refresh)
            }
            if connected.isEmpty {
                EmptyStateCard(symbol: "bolt", title: "No connected Macs", message: "Connect a Mac to see what you can do with it.")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(connected) { device in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(device.name).font(.headline)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                                QuickActionButton(title: "Send File", symbol: "paperplane") { app.pickAndSendFiles(to: device.id) }
                                QuickActionButton(title: "Send Clipboard", symbol: "doc.on.clipboard") { app.sendClipboard(to: device.id) }
                                QuickActionButton(title: "Lock Screen", symbol: "lock", enabled: app.peerSupportsHub(device.id)) { app.lock(device.id) }
                                QuickActionButton(title: "Disconnect", symbol: "xmark.circle") { app.disconnect(device.id) }
                            }
                            if !app.peerSupportsHub(device.id) {
                                Text("Lock Screen needs MacLinker \(K.hubMinVersion) or newer on \(device.name).").font(.caption).foregroundStyle(.secondary)
                            }
                            RemoteControlsView(device: device)
                        }
                        .hubCard()
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
    }
}

// MARK: Network

struct NetworkPage: View {
    @EnvironmentObject var app: AppState
    @State private var address = ""

    var body: some View {
        let addresses = NetworkPathWatcher.localAddresses()
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Network", subtitle: "How your Macs reach each other.") {
                RefreshButton(isRefreshing: app.isRefreshing, action: app.refresh)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("This Mac").font(.headline)
                        info("Link used", app.paths.lanInterface.map { "\(DeviceInfoProvider.linkName($0) ?? "Other") (\($0.name))" } ?? "None")
                        info("VPN", app.paths.vpnActive ? "Detected (\(app.paths.vpnInterfaces.joined(separator: ", "))): LAN traffic stays on \(app.paths.lanInterface?.name ?? "the LAN")" : "Not detected")
                        info("Listening on port", "\(app.server.port)")
                        ForEach(addresses.indices, id: \.self) { i in info(i == 0 ? "Addresses" : "", "\(addresses[i].address)  (\(addresses[i].interface))") }
                    }.frame(maxWidth: .infinity, alignment: .leading).hubCard()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Other Macs").font(.headline)
                        if app.devices.isEmpty { Text("None found yet.").font(.callout).foregroundStyle(.secondary) }
                        ForEach(app.devices) { d in
                            HStack {
                                Circle().fill(d.status.color).frame(width: 8, height: 8)
                                Text(d.name)
                                Spacer()
                                Text(d.statusText + (app.connections.peers[d.id]?.link.map { " · \($0)" } ?? "")).font(.caption).foregroundStyle(.secondary)
                                if let v = app.connections.peers[d.id]?.appVersion, v != "0" { Text("v\(v)").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).hubCard()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Add a Mac by address").font(.headline)
                        HStack {
                            TextField("192.168.1.6 or mac-mini.local[:port]", text: $address).textFieldStyle(.roundedBorder).onSubmit(add)
                            Button("Connect", action: add).disabled(address.isEmpty)
                        }
                        Text(app.lastError ?? "Use this if automatic discovery is blocked, for example by a VPN.")
                            .font(.caption).foregroundStyle(app.lastError == nil ? Color.secondary : Color.red)
                    }.frame(maxWidth: .infinity, alignment: .leading).hubCard()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
    }

    private func info(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(value).textSelection(.enabled)
            Spacer()
        }.font(.callout)
    }

    private func add() { app.connect(address: address); address = "" }
}

// MARK: Settings

struct SettingsPage: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Settings").padding([.horizontal, .top], 24)
            SettingsView()
        }
    }
}
