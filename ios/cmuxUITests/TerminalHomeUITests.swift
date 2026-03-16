import XCTest

final class TerminalHomeUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testDirectFixtureOpensTerminalWorkspaceDetail() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UITEST_TERMINAL_DIRECT_FIXTURE"] = "1"
        app.launch()

        let home = app.otherElements["terminal.home"]
        XCTAssertTrue(home.waitForExistence(timeout: 6), "Expected terminal home to appear")

        let serverButton = app.buttons["terminal.server.cmux-macmini"]
        XCTAssertTrue(serverButton.waitForExistence(timeout: 4), "Expected direct fixture server pin")
        serverButton.tap()

        XCTAssertTrue(app.navigationBars["Mac mini"].waitForExistence(timeout: 4), "Expected workspace title")
        XCTAssertTrue(app.otherElements["terminal.workspace.detail"].waitForExistence(timeout: 4), "Expected terminal workspace detail")
    }
}
