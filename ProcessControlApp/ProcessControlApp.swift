import SwiftUI
import AppKit

@main
struct MacProcessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        if let icon = AppIconProvider.loadAppIcon() {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    var body: some Scene {
        WindowGroup { DashboardView() }
            .windowStyle(.hiddenTitleBar)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        if let icon = AppIconProvider.loadAppIcon() {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let icon = AppIconProvider.loadAppIcon() {
            NSApplication.shared.applicationIconImage = icon
        }
    }
}
