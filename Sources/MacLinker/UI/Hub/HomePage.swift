import SwiftUI

struct HomeModel: Equatable {
    var greeting: String
    var subtitle: String
    var thisDevice: DeviceCardModel
    var others: [DeviceCardModel]
    var targets: [DeviceActionButton.Target]   // connected Macs
}

struct HomeActions {
    var refresh: () -> Void = {}
    var connect: (String) -> Void = { _ in }
    var disconnect: (String) -> Void = { _ in }
    var sendFile: (String) -> Void = { _ in }
    var sendClipboard: (String) -> Void = { _ in }
    var lock: (String) -> Void = { _ in }
    var openShelf: () -> Void = {}
}

func greeting(for date: Date = Date(), calendar: Calendar = .current) -> String {
    switch calendar.component(.hour, from: date) {
    case 5..<12: return "Good morning"
    case 12..<18: return "Good afternoon"
    default: return "Good evening"
    }
}

/// The pure layout of Home. `HomePage` feeds it live data.
struct HomeContent: View {
    let model: HomeModel
    var isRefreshing = false
    var actions = HomeActions()
    /// Off only when rendering to an image (a scroll view can't be drawn offscreen).
    var scrollable = true

    var body: some View {
        if scrollable { ScrollView { content } } else { content }
    }

    private var content: some View {
        Group {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: model.greeting, subtitle: model.subtitle) {
                    RefreshButton(isRefreshing: isRefreshing, action: actions.refresh)
                }

                Text("Your Devices").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                    DeviceCard(model: model.thisDevice)
                    ForEach(model.others) { device in
                        DeviceCard(model: device, actions: cardActions(for: device))
                    }
                }
                if model.others.isEmpty {
                    EmptyStateCard(symbol: "wifi", title: "No other MacLinker devices found",
                                   message: "Open MacLinker on your other Mac. Both Macs must be on the same network or connected by a cable.")
                }

                Text("Quick Actions").font(.headline)
                HStack(spacing: 12) {
                    DeviceActionButton(title: "Send File", symbol: "paperplane", targets: model.targets, action: actions.sendFile)
                    DeviceActionButton(title: "Send Clipboard", symbol: "doc.on.clipboard", targets: model.targets, action: actions.sendClipboard)
                    DeviceActionButton(title: "Lock", symbol: "lock", targets: model.targets, action: actions.lock)
                    QuickActionButton(title: "Drop Shelf", symbol: "tray.and.arrow.down", prominent: true, action: actions.openShelf)
                }
            }
            .padding(24)
        }
    }

    private func cardActions(for device: DeviceCardModel) -> [DeviceCard.CardAction] {
        switch device.status {
        case .connected:
            return [.init(id: "send", title: "Send File") { actions.sendFile(device.id) },
                    .init(id: "disc", title: "Disconnect") { actions.disconnect(device.id) }]
        case .nearby, .offline:
            return [.init(id: "conn", title: device.isTrusted ? "Connect" : "Pair", prominent: true) { actions.connect(device.id) }]
        default: return []
        }
    }
}

struct HomePage: View {
    @EnvironmentObject var app: AppState
    var openShelf: () -> Void

    var body: some View {
        HomeContent(model: app.homeModel(), isRefreshing: app.isRefreshing, actions: HomeActions(
            refresh: app.refresh,
            connect: { id in if let d = app.devices.first(where: { $0.id == id }) { app.connect(d) } },
            disconnect: app.disconnect,
            sendFile: app.pickAndSendFiles,
            sendClipboard: app.sendClipboard,
            lock: app.lock,
            openShelf: openShelf))
    }
}

extension AppState {
    func homeModel() -> HomeModel {
        let info = deviceInfo.local
        let this = DeviceCardModel(id: identity.deviceID, name: identity.deviceName, subtitle: DeviceCardModel.subtitle(for: info),
                                   symbol: DeviceCardModel.symbol(for: info), status: .thisDevice, detail: nil,
                                   rows: DeviceCardModel.rows(for: info))
        let others = devices.map { d -> DeviceCardModel in
            let remote = deviceInfo.remote[d.id]
            var detail: [String] = []
            if d.status == .connected {
                if let ms = d.latency { detail.append(String(format: "%.0f ms", ms)) }
                if let link = connections.peers[d.id]?.link { detail.append(link.hasPrefix("bridge") ? "USB-C cable" : link) }
            }
            let status: DeviceCardModel.Status
            switch d.status {
            case .connected: status = .connected
            case .pairing: status = .pairing
            case .connecting: status = .connecting
            case .nearby: status = .nearby
            case .offline: status = .offline
            }
            return DeviceCardModel(id: d.id, name: d.name, subtitle: DeviceCardModel.subtitle(for: remote),
                                   symbol: DeviceCardModel.symbol(for: remote), status: status,
                                   detail: detail.isEmpty ? nil : detail.joined(separator: " · "),
                                   rows: DeviceCardModel.rows(for: remote), isTrusted: d.isTrusted)
        }
        let connected = devices.filter { $0.status == .connected }
        let subtitle: String
        switch connected.count {
        case 0: subtitle = others.contains { $0.status == .nearby } ? "Devices found on your network." : "Looking for your devices on the local network…"
        case 1: subtitle = "Connected to \(connected[0].name)."
        default: subtitle = "\(connected.count) devices connected."
        }
        return HomeModel(greeting: greeting(), subtitle: subtitle, thisDevice: this, others: others,
                         targets: connected.map { .init(id: $0.id, name: $0.name) })
    }
}
