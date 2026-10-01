import SwiftUI

@main
struct MacLinkerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var app = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView().environmentObject(app)
        } label: {
            Image(systemName: app.isControlling ? "cursorarrow.motionlines"
                              : app.connectedCount > 0 ? "link.circle.fill" : "link.circle")
        }
        .menuBarExtraStyle(.window)
    }
}
