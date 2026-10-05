import XCTest

/// Checks that tapping into a game text field gives the hidden keyboard
/// proxy keyboard focus (which is what makes the on-screen keyboard appear).
final class KeyboardTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLoginFocusesKeyboard() throws {
        let app = XCUIApplication()
        app.launch()

        let proxy = app.textFields["keyboardProxy"]
        XCTAssertTrue(proxy.waitForExistence(timeout: 30), "keyboard proxy missing")

        // "Login" is the first stacked button under the logo. tapping it
        // focuses the username field, which requests the keyboard. the game
        // may still be loading, so keep tapping until it responds.
        let window = app.windows.firstMatch
        let frame = window.frame
        let safeTop = 62.0, safeBottom = 34.0  // iPhone 16 Pro portrait
        let gameHeight = frame.height - safeTop - safeBottom
        let loginY = (safeTop + gameHeight / 2 - 120 + 171) / frame.height
        let login = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: loginY))

        var focused = false
        let deadline = Date().addingTimeInterval(180)

        while Date() < deadline {
            login.tap()
            sleep(3)

            if (proxy.value(forKey: "hasKeyboardFocus") as? Bool) == true {
                focused = true
                break
            }
        }

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)

        XCTAssertTrue(focused, "tapping Login never gave the keyboard focus")
    }
}
