import SwiftUI

struct PelicanApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1440, height: 860)
        .windowStyle(.titleBar)
        .commands {
            // Single-window app — remove New Window.
            CommandGroup(replacing: .newItem) {}
        }
    }
}
