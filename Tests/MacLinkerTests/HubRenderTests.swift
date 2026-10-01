import XCTest
import SwiftUI
@testable import MacLinker

final class HubRenderTests: XCTestCase {
    private func sampleModel() -> HomeModel {
        let local = DeviceInfoProvider.snapshot(link: nil)
        let this = DeviceCardModel(id: "me", name: "K’s Mac Mini", subtitle: DeviceCardModel.subtitle(for: local),
                                   symbol: DeviceCardModel.symbol(for: local), status: .thisDevice, detail: nil,
                                   rows: DeviceCardModel.rows(for: local))
        let air = DeviceInfoPayload(kind: "laptop", model: "Mac14,2", osVersion: "macOS 15.1",
                                    keyboards: [.init(name: "Apple Internal Keyboard / Trackpad", transport: "Built-in", battery: nil)],
                                    pointers: [.init(name: "Apple Internal Keyboard / Trackpad", transport: "Built-in", battery: nil),
                                               .init(name: "MX Master 3S", transport: "Bluetooth", battery: 64)],
                                    audioOutput: "MacBook Air Speakers", network: "USB-C cable")
        let other = DeviceCardModel(id: "air", name: "Kaung’s MacBook Air", subtitle: DeviceCardModel.subtitle(for: air),
                                    symbol: DeviceCardModel.symbol(for: air), status: .connected, detail: "2 ms · USB-C cable",
                                    rows: DeviceCardModel.rows(for: air))
        return HomeModel(greeting: "Good evening", subtitle: "Connected to Kaung’s MacBook Air.", thisDevice: this,
                         others: [other], targets: [.init(id: "air", name: other.name)], warning: nil)
    }

    @MainActor private func render<V: View>(_ view: V, name: String, dark: Bool = false) throws {
        let framed = view.frame(width: 1000, height: 680)
            .background(Color(nsColor: dark ? NSColor(white: 0.12, alpha: 1) : .white))
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
    }

    /// A design check: renders Home to /tmp/hub_home_*.png. Run with MACLINKER_RENDER=1 (it needs a window server).
    @MainActor func testRenderHomeScreens() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MACLINKER_RENDER"] == "1", "set MACLINKER_RENDER=1 to render")
        func screen(_ model: HomeModel) -> some View {
            HStack(spacing: 0) {
                SidebarView(selection: .constant(.home), footerText: model.others.isEmpty ? "No devices connected" : "1 device connected",
                            footerColor: model.others.isEmpty ? .orange : .green)
                Divider()
                HomeContent(model: model, scrollable: false).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        try render(screen(sampleModel()), name: "hub_home_connected")
        var empty = sampleModel(); empty.others = []; empty.targets = []; empty.subtitle = "Looking for your devices on the local network…"
        try render(screen(empty), name: "hub_home_empty")
        try render(screen(sampleModel()), name: "hub_home_dark", dark: true)
        var warned = sampleModel()
        warned.warning = SecureInput.message(for: SecureInputStatus(enabled: true, appName: "KGuard"))
        try render(screen(warned), name: "hub_home_warning")
    }
}
