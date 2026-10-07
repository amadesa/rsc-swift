import UIKit

/// Creates the game window on iOS 13 and later, where apps built with
/// current SDKs must use the scene life cycle. Listed in Config/Info.plist.
/// Earlier iOS versions have no scenes, so AppDelegate makes the window there.
@available(iOS 13.0, *)
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene, willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = GameViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}
