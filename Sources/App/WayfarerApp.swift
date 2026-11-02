import SwiftUI

@main
struct WayfarerApp: App {
    @State private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView().environment(store).tint(Theme.accent)
                .task { store.playback.setSceneActive(scenePhase == .active); await store.load() }
                .onChange(of: scenePhase) { _, phase in
                    store.playback.setSceneActive(phase == .active)
                    if phase == .background { store.pauseForBackground() }
                }
        }
    }
}
