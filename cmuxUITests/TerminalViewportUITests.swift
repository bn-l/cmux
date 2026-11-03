import XCTest
import Foundation
import CoreGraphics

final class TerminalViewportUITests: XCTestCase {
    func testTerminalSurfaceUsesAvailableViewportAndTracksWindowResize() {
        let dataPath = "/tmp/cmux-ui-test-terminal-viewport-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: dataPath)

        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_VIEWPORT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_VIEWPORT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_VIEWPORT_WINDOW_SIZE"] = "900x620"
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_VIEWPORT_RESIZE_WINDOW_SIZE"] = "1180x780"
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_VIEWPORT_HIDE_SIDEBAR"] = "1"
        app.launchArguments += ["-workspacePresentationMode", "minimal"]
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }
        defer { app.terminate() }
        defer {
            try? FileManager.default.removeItem(atPath: dataPath)
        }

        if app.state == .runningBackground {
            app.activate()
        }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20) || app.windows.firstMatch.waitForExistence(timeout: 6))

        guard let small = waitForViewportGeometry(atPath: dataPath, prefix: "terminalViewportInitial", timeout: 20, matching: { geometry in
            geometry.windowWidth >= 560 &&
                geometry.panelWidth > 300 &&
                geometry.panelHeight > 220 &&
                geometry.fillsAvailableViewport
        }) else {
            XCTFail("Timed out waiting for small terminal viewport geometry. data=\(loadJSON(atPath: dataPath) ?? [:])")
            return
        }
        assertTerminalViewportFillsAvailableSpace(small)

        guard let large = waitForViewportGeometry(atPath: dataPath, prefix: "terminalViewportResized", timeout: 20, matching: { geometry in
            geometry.requestedWindowSize == "1180x780" &&
                geometry.windowWidth > small.windowWidth + 180 &&
                geometry.windowHeight > small.windowHeight + 120 &&
                geometry.panelWidth > small.panelWidth + 180 &&
                geometry.panelHeight > small.panelHeight + 120 &&
                geometry.fillsAvailableViewport
        }) else {
            XCTFail("Timed out waiting for resized terminal viewport geometry. data=\(loadJSON(atPath: dataPath) ?? [:])")
            return
        }
        assertTerminalViewportFillsAvailableSpace(large)
    }

    private struct ViewportGeometry {
        let data: [String: String]
        let requestedWindowSize: String
        let windowWidth: CGFloat
        let windowHeight: CGFloat
        let windowContentWidth: CGFloat
        let windowContentHeight: CGFloat
        let panelWidth: CGFloat
        let panelHeight: CGFloat
        let hostedFrameMinX: CGFloat
        let hostedFrameMinY: CGFloat
        let hostedFrameWidth: CGFloat
        let hostedFrameHeight: CGFloat
        let hostedBoundsWidth: CGFloat
        let hostedBoundsHeight: CGFloat

        var fillsAvailableViewport: Bool {
            windowContentWidth > 300 &&
                windowContentHeight > 240 &&
                abs(hostedFrameMinX) <= 3 &&
                abs(hostedFrameMinY) <= 3 &&
                abs(hostedFrameWidth - panelWidth) <= 3 &&
                abs(hostedFrameHeight - panelHeight) <= 3 &&
                abs(hostedBoundsWidth - hostedFrameWidth) <= 3 &&
                abs(hostedBoundsHeight - hostedFrameHeight) <= 3 &&
                panelWidth >= windowContentWidth - 24 &&
                panelHeight >= windowContentHeight - 130
        }

        init?(data: [String: String], prefix: String) {
            func key(_ suffix: String) -> String {
                "\(prefix)\(suffix)"
            }

            guard data[key("Ready")] == "1",
                  data[key("SidebarVisible")] == "0" else {
                return nil
            }
            self.data = data
            requestedWindowSize = data[key("RequestedWindowSize")] ?? ""
            guard let windowWidth = Self.number(key("WindowWidth"), in: data),
                  let windowHeight = Self.number(key("WindowHeight"), in: data),
                  let windowContentWidth = Self.number(key("WindowContentWidth"), in: data),
                  let windowContentHeight = Self.number(key("WindowContentHeight"), in: data),
                  let panelWidth = Self.number(key("PanelWidth"), in: data),
                  let panelHeight = Self.number(key("PanelHeight"), in: data),
                  let hostedFrameMinX = Self.number(key("HostedFrameMinX"), in: data),
                  let hostedFrameMinY = Self.number(key("HostedFrameMinY"), in: data),
                  let hostedFrameWidth = Self.number(key("HostedFrameWidth"), in: data),
                  let hostedFrameHeight = Self.number(key("HostedFrameHeight"), in: data),
                  let hostedBoundsWidth = Self.number(key("HostedBoundsWidth"), in: data),
                  let hostedBoundsHeight = Self.number(key("HostedBoundsHeight"), in: data) else {
                return nil
            }
            self.windowWidth = windowWidth
            self.windowHeight = windowHeight
            self.windowContentWidth = windowContentWidth
            self.windowContentHeight = windowContentHeight
            self.panelWidth = panelWidth
            self.panelHeight = panelHeight
            self.hostedFrameMinX = hostedFrameMinX
            self.hostedFrameMinY = hostedFrameMinY
            self.hostedFrameWidth = hostedFrameWidth
            self.hostedFrameHeight = hostedFrameHeight
            self.hostedBoundsWidth = hostedBoundsWidth
            self.hostedBoundsHeight = hostedBoundsHeight
        }

        private static func number(_ key: String, in data: [String: String]) -> CGFloat? {
            guard let rawValue = data[key], let value = Double(rawValue) else { return nil }
            return CGFloat(value)
        }
    }

    private func assertTerminalViewportFillsAvailableSpace(
        _ geometry: ViewportGeometry,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(geometry.hostedFrameMinX, 0, accuracy: 3, "geometry=\(geometry.data)", file: file, line: line)
        XCTAssertEqual(geometry.hostedFrameMinY, 0, accuracy: 3, "geometry=\(geometry.data)", file: file, line: line)
        XCTAssertEqual(geometry.hostedFrameWidth, geometry.panelWidth, accuracy: 3, "geometry=\(geometry.data)", file: file, line: line)
        XCTAssertEqual(geometry.hostedFrameHeight, geometry.panelHeight, accuracy: 3, "geometry=\(geometry.data)", file: file, line: line)
        XCTAssertEqual(geometry.hostedBoundsWidth, geometry.hostedFrameWidth, accuracy: 3, "geometry=\(geometry.data)", file: file, line: line)
        XCTAssertEqual(geometry.hostedBoundsHeight, geometry.hostedFrameHeight, accuracy: 3, "geometry=\(geometry.data)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(geometry.panelWidth, geometry.windowContentWidth - 24, "geometry=\(geometry.data)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(geometry.panelHeight, geometry.windowContentHeight - 130, "geometry=\(geometry.data)", file: file, line: line)
    }

    private func waitForViewportGeometry(
        atPath path: String,
        prefix: String,
        timeout: TimeInterval,
        matching predicate: (ViewportGeometry) -> Bool
    ) -> ViewportGeometry? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = loadJSON(atPath: path),
               let geometry = ViewportGeometry(data: data, prefix: prefix),
               predicate(geometry) {
                return geometry
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if let data = loadJSON(atPath: path),
           let geometry = ViewportGeometry(data: data, prefix: prefix),
           predicate(geometry) {
            return geometry
        }
        return nil
    }

    private func loadJSON(atPath path: String) -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return object
    }
}
