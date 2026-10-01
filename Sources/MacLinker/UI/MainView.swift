import SwiftUI

struct MainView: View {
    var body: some View {
        TabView {
            DeviceListView().tabItem { Label("Devices", systemImage: "laptopcomputer.and.arrow.down") }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
            ActivityView().tabItem { Label("Transfers", systemImage: "arrow.up.arrow.down") }
        }
        .padding()
        .frame(minWidth: 600, minHeight: 480)
    }
}
