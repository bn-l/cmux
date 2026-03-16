import XCTest
@testable import cmux_DEV

final class GhosttySurfaceContractTests: XCTestCase {
    func testGhosttySurfaceReportsGridSizeAfterLayout() async throws {
        let (_, delegate) = try await MainActor.run {
            let (surfaceView, delegate) = try makeSurfaceView()
            surfaceView.frame = CGRect(x: 0, y: 0, width: 480, height: 320)
            surfaceView.layoutIfNeeded()
            return (surfaceView, delegate)
        }

        let size = try await MainActor.run {
            try XCTUnwrap(delegate.lastSize)
        }
        XCTAssertGreaterThan(size.columns, 0)
        XCTAssertGreaterThan(size.rows, 0)
    }

    func testGhosttySurfaceEmitsOutboundBytesForTypedText() async throws {
        let (surfaceView, delegate) = try await MainActor.run {
            try makeSurfaceView()
        }

        let dataExpectation = expectation(description: "ghostty surface emitted typed bytes")
        await MainActor.run {
            delegate.onInput = { data in
                if data == Data("a".utf8) {
                    dataExpectation.fulfill()
                }
            }
        }

        await MainActor.run {
            surfaceView.simulateTextInputForTesting("a")
        }

        await fulfillment(of: [dataExpectation], timeout: 2.0)
    }

    func testShowOnScreenKeyboardActionFocusesTargetSurface() async throws {
        let (surfaceView, _) = try await MainActor.run {
            try makeSurfaceView()
        }

        let focusExpectation = expectation(description: "show keyboard action focuses target surface")
        try await MainActor.run {
            surfaceView.onFocusInputRequestedForTesting = {
                focusExpectation.fulfill()
            }
        }

        let handled = try await MainActor.run {
            let surface = try XCTUnwrap(surfaceView.surface)
            return GhosttyRuntime.simulateSurfaceActionForTesting(
                surface: surface,
                tag: GHOSTTY_ACTION_SHOW_ON_SCREEN_KEYBOARD
            )
        }

        XCTAssertTrue(handled)
        await fulfillment(of: [focusExpectation], timeout: 2.0)
    }

    func testCopyTitleActionWritesCurrentSurfaceTitleToClipboard() async throws {
        let (surfaceView, _) = try await MainActor.run {
            try makeSurfaceView()
        }

        let recorder = await MainActor.run { ClipboardRecorder() }
        await MainActor.run {
            GhosttyRuntime.setClipboardHandlersForTesting(
                reader: { Optional<String>.none },
                writer: { value in
                    recorder.value = value
                }
            )
        }
        defer {
            Task { @MainActor in
                GhosttyRuntime.resetClipboardHandlersForTesting()
            }
        }

        let handled = try await MainActor.run {
            let surface = try XCTUnwrap(surfaceView.surface)
            XCTAssertTrue(
                GhosttyRuntime.simulateSurfaceSetTitleActionForTesting(
                    surface: surface,
                    title: "deploy terminal"
                )
            )
            return GhosttyRuntime.simulateSurfaceActionForTesting(
                surface: surface,
                tag: GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD
            )
        }

        XCTAssertTrue(handled)
        let copiedValue = await MainActor.run { recorder.value }
        XCTAssertEqual(copiedValue, "deploy terminal")
    }

    @MainActor
    private func makeSurfaceView() throws -> (GhosttySurfaceView, GhosttySurfaceTestDelegate) {
        let runtime = try GhosttyRuntime.shared()
        let delegate = GhosttySurfaceTestDelegate()
        let surfaceView = GhosttySurfaceView(runtime: runtime, delegate: delegate)
        return (surfaceView, delegate)
    }
}

@MainActor
private final class ClipboardRecorder {
    var value: String?
}

@MainActor
private final class GhosttySurfaceTestDelegate: GhosttySurfaceViewDelegate {
    var lastSize: TerminalGridSize?
    var onInput: ((Data) -> Void)?

    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {
        onInput?(data)
    }

    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize) {
        lastSize = size
    }
}
