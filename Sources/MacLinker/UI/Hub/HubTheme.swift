import SwiftUI

/// Shared look for the hub: soft rounded cards that adapt to light and dark mode.
extension View {
    func hubCard(padding: CGFloat = 16, radius: CGFloat = 16) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 26, weight: .bold))
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer()
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) { self.title = title; self.subtitle = subtitle; self.trailing = EmptyView() }
}

/// Spins while a refresh is running.
struct RefreshButton: View {
    let isRefreshing: Bool
    let action: () -> Void
    @State private var angle = 0.0

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .rotationEffect(.degrees(angle))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.bordered)
        .help("Refresh devices")
        .disabled(isRefreshing)
        .onChange(of: isRefreshing) { spinning in
            if spinning { withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) { angle = 360 } }
            else { withAnimation(.default) { angle = 0 } }
        }
    }
}

struct EmptyStateCard: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
        .hubCard(padding: 24)
    }
}

/// A rounded quick-action button like the ones along the bottom of Home.
struct QuickActionButton: View {
    let title: String
    let symbol: String
    var prominent = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 40)
                .foregroundStyle(prominent ? Color.accentColor : (enabled ? Color.primary : Color.secondary))
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(prominent ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// A button that acts on one connected Mac: direct if there is one, a menu if there are several.
struct DeviceActionButton: View {
    struct Target: Identifiable, Equatable { let id: String; let name: String }
    let title: String
    let symbol: String
    let targets: [Target]
    let action: (String) -> Void

    var body: some View {
        if targets.count > 1 {
            Menu {
                ForEach(targets) { t in Button(t.name) { action(t.id) } }
            } label: {
                label(enabled: true)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        } else {
            Button { if let t = targets.first { action(t.id) } } label: { label(enabled: !targets.isEmpty) }
                .buttonStyle(.plain)
                .disabled(targets.isEmpty)
        }
    }

    private func label(enabled: Bool) -> some View {
        Label(title, systemImage: symbol)
            .font(.callout.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 40)
            .foregroundStyle(enabled ? Color.primary : Color.secondary)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}
