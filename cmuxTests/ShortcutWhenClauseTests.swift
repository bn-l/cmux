import XCTest
import CmuxSettings

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class ShortcutWhenClauseTests: XCTestCase {
    private func state(browser: Bool = false, markdown: Bool = false) -> ShortcutFocusState {
        ShortcutFocusState(browser: browser, markdown: markdown)
    }

    func testParsesNegatedAtom() {
        XCTAssertEqual(ShortcutWhenClause.parse("!browserFocus"), .not(.atom(.browserFocus)))
        XCTAssertEqual(ShortcutWhenClause.parse("  markdownFocus "), .atom(.markdownFocus))
    }

    func testParsesAndOrWithPrecedence() {
        // && binds tighter than ||: "a || b && c" == "a || (b && c)".
        XCTAssertEqual(
            ShortcutWhenClause.parse("terminalFocus || browserFocus && markdownFocus"),
            .or(.atom(.terminalFocus), .and(.atom(.browserFocus), .atom(.markdownFocus)))
        )
        XCTAssertEqual(
            ShortcutWhenClause.parse("(terminalFocus || browserFocus) && !markdownFocus"),
            .and(.or(.atom(.terminalFocus), .atom(.browserFocus)), .not(.atom(.markdownFocus)))
        )
    }

    func testRejectsMalformedExpressions() {
        XCTAssertNil(ShortcutWhenClause.parse("browserFocus &&"))
        XCTAssertNil(ShortcutWhenClause.parse("(browserFocus"))
        XCTAssertNil(ShortcutWhenClause.parse("!"))
        XCTAssertNil(ShortcutWhenClause.parse("paneCount >"))
    }

    func testUnknownKeyParsesToKey() {
        // An unknown bare key is a valid (always-false) clause, matching VS Code's
        // treatment of undefined context keys — it is no longer rejected as malformed.
        XCTAssertEqual(ShortcutWhenClause.parse("bogusKey"), .key("bogusKey"))
        XCTAssertEqual(ShortcutWhenClause.parse("commandPaletteVisible"), .key("commandPaletteVisible"))
    }

    func testEmptyClauseParsesToAlways() {
        // An empty or whitespace-only clause imposes no restriction.
        XCTAssertEqual(ShortcutWhenClause.parse(""), .always)
        XCTAssertEqual(ShortcutWhenClause.parse("   "), .always)
    }

    func testEvaluateAtoms() {
        XCTAssertTrue(ShortcutWhenClause.atom(.markdownFocus).evaluate(state(markdown: true)))
        XCTAssertFalse(ShortcutWhenClause.atom(.markdownFocus).evaluate(state(browser: true)))
        // terminalFocus is true exactly when nothing else is focused.
        XCTAssertTrue(ShortcutWhenClause.atom(.terminalFocus).evaluate(state()))
        XCTAssertFalse(ShortcutWhenClause.atom(.terminalFocus).evaluate(state(markdown: true)))
    }

    func testNegatedAtomExcludesOnlyThatFocus() throws {
        let clause = try XCTUnwrap(ShortcutWhenClause.parse("!browserFocus"))
        XCTAssertTrue(clause.evaluate(state()), "terminal focus → allowed")
        XCTAssertTrue(clause.evaluate(state(markdown: true)), "markdown focus → allowed")
        XCTAssertFalse(clause.evaluate(state(browser: true)), "browser focus → suppressed")
    }

    func testCanCoexistSeparatesComplementaryClauses() {
        let notBrowser = try! XCTUnwrap(ShortcutWhenClause.parse("!browserFocus"))
        let browser = ShortcutWhenClause.atom(.browserFocus)
        // The same key on `!browserFocus` and `browserFocus` does NOT conflict,
        // because no focus state activates both.
        XCTAssertFalse(ShortcutWhenClause.canCoexist(notBrowser, browser))
    }

    func testCanCoexistDetectsRealOverlap() {
        // Two always-on bindings on the same key genuinely collide.
        XCTAssertTrue(ShortcutWhenClause.canCoexist(.always, .always))
        // Not-browser still overlaps a markdown-scoped binding (markdown focus
        // satisfies both).
        let notBrowser = try! XCTUnwrap(ShortcutWhenClause.parse("!browserFocus"))
        XCTAssertTrue(ShortcutWhenClause.canCoexist(notBrowser, .atom(.markdownFocus)))
    }
}
