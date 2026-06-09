import SwiftUI

@main
struct OwnscribeApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(app)
                .task { await app.bootstrap() }
        } label: {
            Image(systemName: app.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Window("Ownscribe Settings", id: "settings") {
            SettingsView()
                .environmentObject(app)
        }
        .windowResizability(.contentSize)
    }
}
