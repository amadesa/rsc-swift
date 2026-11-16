import SwiftUI

/// The Apple Watch app. A first, minimal version: it runs the same game core
/// as the iPhone app through rsc-relay, with settings synced from the iPhone.
@main
struct RSCWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            GameScreenView(game: WatchGame.shared)
        }
        .onChange(of: scenePhase) { phase in
            // keep the connection going while the screen is dimmed, but
            // don't draw
            WatchGame.shared.setBackground(phase != .active)

            if phase == .active {
                KeepAlive.shared.start()
            }
        }
    }
}
