import SwiftUI
import AppKit

@main
struct KakaPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("KakaPlayer", id: "main") {
            ContentView()
                .environmentObject(appDelegate.model)
        }
        .defaultSize(width: 1180, height: 720)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Engine") {
                Button("Restart Engine") { appDelegate.model.shutdown(); appDelegate.model.startEngine() }
                Button("Reset Engine Image…") { appDelegate.model.shutdown(); appDelegate.model.startEngine(reinstall: true) }
                Divider()
                Button("Show Log") { appDelegate.model.showLog.toggle() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set the running app's icon explicitly so the Dock and Cmd-Tab switcher show it
        // even when LaunchServices has a stale cache for this (ad-hoc signed) bundle.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            ?? Bundle.main.url(forResource: "AppMark", withExtension: "png"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate(ignoringOtherApps: true)
        model.startEngine()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        NSApp.activate(ignoringOtherApps: true)
        model.open(url.absoluteString)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Shut the VM down off the main thread, then exit. Never hang the quit.
        model.appendLog("[app] quitting, shutting down engine VM")
        let model = self.model
        Thread.detachNewThread {
            let done = DispatchSemaphore(value: 0)
            Task { @MainActor in model.shutdown(); done.signal() }
            _ = done.wait(timeout: .now() + 15)
            DispatchQueue.main.async { exit(0) }
        }
        return .terminateLater
    }
}
