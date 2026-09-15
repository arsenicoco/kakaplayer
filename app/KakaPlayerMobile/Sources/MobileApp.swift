import SwiftUI

@main
struct MobileApp: App {
    @StateObject private var model = MobileModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .onOpenURL { open($0) }
                .task { model.checkEngine() }
        }
        .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
    }

    /// An `acestream://` link handed to us by Safari, Messages or a playlist app.
    ///
    /// With an engine configured this plays straight away — that is the whole point of
    /// tapping a link. Without one, playing is impossible, so the link is parked in the
    /// field and Settings opens instead of failing with an error the user cannot act on.
    private func open(_ url: URL) {
        guard let link = AceLink.parse(url.absoluteString) else {
            model.open(url.absoluteString)   // lets the model report why it is not a link
            return
        }
        model.linkText = link.canonical
        if model.engineURL != nil {
            model.play(link)
        } else {
            model.appendLog("[app] opened \(link.displayName) with no engine configured")
            model.showSettings = true
        }
    }
}
