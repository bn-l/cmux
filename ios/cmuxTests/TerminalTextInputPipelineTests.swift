import XCTest
@testable import cmux_DEV

final class TerminalTextInputPipelineTests: XCTestCase {
    func testComposingTextStaysBufferedUntilCommit() {
        let result = TerminalTextInputPipeline.process(text: "nihon", isComposing: true)

        XCTAssertNil(result.committedText)
        XCTAssertEqual(result.nextBufferText, "nihon")
    }

    func testCommittedUnicodeTextEmitsAndClearsBuffer() {
        let result = TerminalTextInputPipeline.process(text: "日本", isComposing: false)

        XCTAssertEqual(result.committedText, "日本")
        XCTAssertEqual(result.nextBufferText, "")
    }
}
