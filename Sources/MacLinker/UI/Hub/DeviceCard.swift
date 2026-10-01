import SwiftUI

/// Everything a device card shows, as plain values (so it can be drawn from sample data too).
struct DeviceCardModel: Identifiable, Equatable {
    struct Row: Identifiable, Equatable {
        var id: String { symbol + text }
        let symbol: String
        let text: String
    }
    enum Status: Equatable { case thisDevice, connected, pairing, connecting, nearby, offline }

    let id: String
    var name: String
    var subtitle: String
    var symbol: String
    var status: Status
    /// e.g. "2 ms · USB-C cable"
    var detail: String?
    var rows: [Row]
    var isTrusted = true

    var statusText: String {
        switch status {
        case .thisDevice: return "This Device"
        case .connected: return "Connected"
        case .pairing: return "Pairing…"
        case .connecting: return "Connecting…"
        case .nearby: return "Nearby"
        case .offline: return "Offline"
        }
    }

    var statusColor: Color {
        switch status {
        case .thisDevice, .connected: return .green
        case .pairing, .connecting: return .orange
        case .nearby: return .blue
        case .offline: return .secondary
        }
    }

    // MARK: Building from live data

    static func symbol(for info: DeviceInfoPayload?) -> String {
        guard let info else { return "desktopcomputer" }
        if info.kind == "laptop" { return "laptopcomputer" }
        return info.model.hasPrefix("Macmini") ? "macmini" : "desktopcomputer"
    }

    static func subtitle(for info: DeviceInfoPayload?) -> String {
        guard let info else { return "Mac" }
        if info.kind == "laptop" { return "MacBook" }
        if info.model.hasPrefix("Macmini") { return "Mac mini" }
        if info.model.hasPrefix("iMac") { return "iMac" }
        return "Mac"
    }

    static func rows(for info: DeviceInfoPayload?) -> [Row] {
        guard let info else { return [] }
        func label(_ p: DeviceInfoPayload.Peripheral) -> String {
            var parts = [p.name]
            if p.transport != "Built-in" { parts.append(p.transport) }
            if let b = p.battery { parts.append("\(b)%") }
            return parts.joined(separator: " · ")
        }
        var rows: [Row] = []
        if let n = info.network {
            rows.append(Row(symbol: n == "Wi-Fi" ? "wifi" : (n == "Other" ? "network" : "cable.connector"), text: n))
        }
        if let a = info.audioOutput { rows.append(Row(symbol: "speaker.wave.2", text: a)) }
        for k in info.keyboards { rows.append(Row(symbol: "keyboard", text: label(k))) }
        // A laptop's built-in keyboard and trackpad are one device; list it once.
        for p in info.pointers where !info.keyboards.contains(where: { $0.name == p.name }) {
            rows.append(Row(symbol: p.name.lowercased().contains("trackpad") ? "rectangle.and.hand.point.up.left" : "computermouse", text: label(p)))
        }
        return rows
    }
}

struct DeviceCard: View {
    let model: DeviceCardModel
    var actions: [CardAction] = []

    struct CardAction: Identifiable {
        let id: String
        let title: String
        var prominent = false
        let run: () -> Void
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: model.symbol)
                    .font(.system(size: 20))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 42, height: 42)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.14)))
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(model.statusColor).frame(width: 7, height: 7)
                    Text(model.statusText).font(.caption2).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name).font(.headline).lineLimit(1)
                Text(model.detail.map { "\(model.subtitle) · \($0)" } ?? model.subtitle)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if !model.rows.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(model.rows) { row in
                        HStack(spacing: 8) {
                            Image(systemName: row.symbol).font(.caption).foregroundStyle(.secondary).frame(width: 16)
                            Text(row.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            if !actions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(actions) { a in
                        Button(a.title, action: a.run).controlSize(.small)
                            .buttonStyle(.bordered).tint(a.prominent ? .accentColor : nil)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .hubCard()
    }
}
