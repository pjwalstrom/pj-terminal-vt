import SwiftUI

struct PJTerminalVTApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 500)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .windowStyle(.titleBar)
    }
}
