import XCTest

final class YappyUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        app = XCUIApplication()
        app.launchArguments = ["-YappyUITesting"]
        app.launch()
    }

    func testAppLaunchesWithMainWindow() {
        // Matched by accessibility identifier, not title: the window uses a
        // transparent titlebar, so its title is not a dependable AX label.
        let mainWindow = app.windows["window.main"]

        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10), "Main window never appeared")
        // A window that exists but is empty would still pass the check above,
        // so assert it actually rendered its content.
        XCTAssertTrue(
            app.buttons["sidebar.home"].waitForExistence(timeout: 5),
            "Main window appeared without its sidebar"
        )
    }

    func testSidebarNavigationShowsEachScreen() {
        let destinations = [
            ("Home", "home"),
            ("Shortcuts", "shortcuts"),
            ("Commands", "commands"),
            ("Dictionary", "dictionary"),
            ("Modes", "modes"),
            ("Answers", "answers"),
            ("Settings", "settings"),
        ]

        for (title, identifierSuffix) in destinations {
            let sidebarButton = app.buttons["sidebar.\(identifierSuffix)"]
            XCTAssertTrue(sidebarButton.waitForExistence(timeout: 5), "Missing \(title) sidebar button")
            sidebarButton.click()

            let screen = app.descendants(matching: .any)["screen.\(identifierSuffix)"]
            XCTAssertTrue(screen.waitForExistence(timeout: 5), "\(title) screen did not appear")
            XCTAssertTrue(
                screen.staticTexts[title].waitForExistence(timeout: 5),
                "\(title) screen did not render its title"
            )
        }
    }

    func testSettingsRendersExpectedSections() {
        let settingsButton = app.buttons["sidebar.settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.click()

        let settingsScreen = app.descendants(matching: .any)["screen.settings"]
        XCTAssertTrue(settingsScreen.waitForExistence(timeout: 5))

        // Section headers are collapse/expand buttons, so match the label on
        // any element type rather than assuming a static text.
        for title in [
            "Dictation",
            "AI cleanup",
            "History & privacy",
            "Software update",
            "Permissions",
            "Answers",
        ] {
            let header = settingsScreen.descendants(matching: .any)[title]
            XCTAssertTrue(
                header.waitForExistence(timeout: 5),
                "Settings section \(title) did not render"
            )
        }
    }
}
