import SwiftUI

@main
struct HopApp: App {
    @StateObject private var core = Core()
    @AppStorage("theme") private var theme = "dark"
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(core)
                .preferredColorScheme(theme == "light" ? .light : .dark)
                .onChange(of: phase) { p in
                    if p == .active { core.becameActive() }
                }
        }
    }
}
