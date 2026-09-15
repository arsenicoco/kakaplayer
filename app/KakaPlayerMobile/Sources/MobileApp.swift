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
                .onOpenURL { url in model.open(url.absoluteString) }
                .task { model.checkEngine() }
        }
        .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
    }
}
