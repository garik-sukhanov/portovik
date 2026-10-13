import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in Monitor.shared.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: Prefs.showMenuBar)
    }
}

@main
struct PortovikApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var monitor = Monitor.shared
    @AppStorage(Prefs.showMenuBar) private var showMenuBar = true

    init() {
        Prefs.register()
    }

    var body: some Scene {
        Window("Портовик", id: "main") {
            MainView()
                .environment(monitor)
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarView()
                .environment(monitor)
        } label: {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}
