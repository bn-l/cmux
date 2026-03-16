import XCTest

final class TerminalReconnectUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testDirectDaemonReconnectShowsProgressAndRecovers() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UITEST_TERMINAL_DIRECT_FIXTURE"] = "1"
        app.launchEnvironment["CMUX_UITEST_TERMINAL_RECONNECT_DELAY"] = "0.2"
        app.launch()

        let serverButton = app.buttons["terminal.server.cmux-macmini"]
        XCTAssertTrue(serverButton.waitForExistence(timeout: 6))
        serverButton.tap()

        XCTAssertTrue(app.navigationBars["Mac mini"].waitForExistence(timeout: 4))
        XCTAssertTrue(
            app.staticTexts["Reconnecting to cmuxd"].waitForExistence(timeout: 6),
            "Expected reconnect progress banner"
        )

        let banner = app.otherElements["terminal.status.banner"]
        XCTAssertTrue(waitForDisappearance(of: banner, timeout: 6))
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
