import SwiftUI

enum HubPage: String, CaseIterable, Identifiable {
    case home, devices, transfer, dropShelf, clipboard, actions, network, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .devices: return "Devices"
        case .transfer: return "Transfer"
        case .dropShelf: return "Drop Shelf"
        case .clipboard: return "Clipboard"
        case .actions: return "Actions"
        case .network: return "Network"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .devices: return "laptopcomputer.and.iphone"
        case .transfer: return "arrow.left.arrow.right"
        case .dropShelf: return "tray.and.arrow.down"
        case .clipboard: return "doc.on.clipboard"
        case .actions: return "bolt"
        case .network: return "globe"
        case .settings: return "gearshape"
        }
    }
}

struct SidebarView: View {
    @Binding var selection: HubPage
    let footerText: String
    let footerColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(HubPage.allCases) { page in
                Button { selection = page } label: {
                    HStack(spacing: 10) {
                        Image(systemName: page.symbol).frame(width: 20)
                        Text(page.title)
                        Spacer()
                    }
                    .font(.callout.weight(selection == page ? .semibold : .regular))
                    .foregroundStyle(selection == page ? Color.white : Color.primary)
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selection == page ? Color.accentColor : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(footerColor).frame(width: 7, height: 7)
                Text(footerText).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.bottom, 4)
        }
        .padding(.top, 36)   // clears the traffic-light buttons
        .padding(.horizontal, 10).padding(.bottom, 10)
        .frame(width: 210)
        .background(Color.primary.opacity(0.04))
    }
}

/// The main window: a sidebar of pages on the left, the selected page on the right.
struct HubView: View {
    @EnvironmentObject var app: AppState
    @State private var page: HubPage = .home

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(selection: $page, footerText: footerText, footerColor: app.connectedCount > 0 ? .green : .orange)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 560)
        .ignoresSafeArea()
    }

    private var footerText: String {
        switch app.connectedCount {
        case 0: return "No devices connected"
        case 1: return "1 device connected"
        default: return "\(app.connectedCount) devices connected"
        }
    }

    @ViewBuilder private var detail: some View {
        switch page {
        case .home: HomePage(openShelf: { page = .dropShelf })
        case .devices: DevicesPage()
        case .transfer: TransferPage()
        case .dropShelf: ShelfPage()
        case .clipboard: ClipboardPage()
        case .actions: ActionsPage()
        case .network: NetworkPage()
        case .settings: SettingsPage()
        }
    }
}
