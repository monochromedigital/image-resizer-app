import SwiftUI

@main
struct ImageResizerApp: App {
    @StateObject private var model = ResizeViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 780, minHeight: 650)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 460)
                .padding()
        }
    }
}
