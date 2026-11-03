import XCTest

/// Behavioral UI tests for the Settings **Sidebar** section, scoped to the
/// controls called out for this section: the *Sidebar Branch Layout* picker
/// (vertical vs inline) and the active-tab *indicator style*.
///
/// What is actually assertable through XCUITest here, and why:
///
/// The real runtime consumers of these settings render *inside the
/// workspace sidebar rows* — surfaces that only exist once a workspace has
/// been materialized. The shared `SettingsUITestCase` harness launches the
/// app with `makeLaunchedApp()` (no `CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP`
/// launch env), so the app comes up with an empty main window and no
/// workspace rows. That means the *downstream* render effects (branch text
/// stacked vs inline in a workspace row) are NOT reachable without modifying
/// the harness or adding a launch-time setup seam, which this task forbids.
///
/// What *is* reachable and genuinely behavioral: each of these controls is
/// wired through a live `@AppStorage` / `@Setting` binding whose value
/// drives a *derived, reactive subtitle* in the same Settings window. The
/// subtitle text is computed from the current setting value
/// (`sidebarBranchVerticalLayout ? "Vertical: …" : "Inline: …"`). Asserting that the
/// subtitle label flips when the control changes verifies the full
/// binding → store → dependent-view path, not merely that the control's
/// own state toggled. These subtitle strings are surfaced as `staticText`
/// in the Settings window and are unique, so they are stable to query.
///
/// Tiering for this section is recorded in the structured output. The
/// downstream consumer effects are documented in the TIER 2 block below.
final class SettingsSidebarBetaBehaviorUITests: SettingsUITestCase {

    // userDefaultsKeys for the in-scope settings, reset before/after each
    // test so the run starts from the shipped default.
    //  - sidebarBranchVerticalLayout: SidebarCatalogSection.branchVerticalLayout (default true / "Vertical")
    //  - sidebarActiveTabIndicatorStyle: indicator style key (default "leftRail")
    private let inScopeDefaultsKeys = [
        "sidebarBranchVerticalLayout",
        "sidebarActiveTabIndicatorStyle",
    ]

    // Branch-layout subtitle strings (exact defaultValue copy from
    // SettingsPickerRow at cmuxApp.swift / SidebarSection.swift).
    private let branchVerticalSubtitle = "Vertical: each branch appears on its own line."
    private let branchInlineSubtitle = "Inline: all branches share one line."

    override func setUp() {
        super.setUp()
        resetDefaults(inScopeDefaultsKeys)
    }

    override func tearDown() {
        resetDefaults(inScopeDefaultsKeys)
        super.tearDown()
    }

    // MARK: - TIER 1: Sidebar Branch Layout picker

    /// Changing the **Sidebar Branch Layout** picker from Vertical to Inline
    /// flips the row's derived subtitle. The subtitle is computed from the
    /// `sidebarBranchVerticalLayout` binding, so a change in the rendered
    /// subtitle proves the picker selection propagated through the live
    /// settings store into a dependent view (not just that the popUpButton
    /// value changed).
    func testBranchLayoutPickerDrivesDerivedSubtitle() {
        let app = makeLaunchedApp()
        let window = openSettings(app)
        defer { closeSettings(app, window) }

        navigate(window, to: "Sidebar")

        // Default is Vertical → the Vertical subtitle must be present and the
        // Inline subtitle absent.
        let verticalSubtitle = window.staticTexts[branchVerticalSubtitle]
        let inlineSubtitle = window.staticTexts[branchInlineSubtitle]
        XCTAssertTrue(
            poll(timeout: 5.0) { verticalSubtitle.exists },
            "Expected the default Vertical branch-layout subtitle to be shown"
        )
        XCTAssertFalse(inlineSubtitle.exists, "Inline subtitle should not be shown while Vertical is selected")

        // The branch-layout picker renders as a .menu Picker → a popUpButton
        // whose displayed value is the selected tag title ("Vertical").
        let layoutPopUp = requireElement(
            candidates: [
                window.popUpButtons["Vertical"],
                window.popUpButtons.matching(NSPredicate(format: "value == %@", "Vertical")).firstMatch,
            ],
            timeout: 5.0,
            description: "branch layout picker showing Vertical"
        )
        layoutPopUp.click()

        // Select "Inline" from the opened menu.
        let inlineItem = requireElement(
            candidates: [
                app.menuItems["Inline"],
                window.menuItems["Inline"],
            ],
            timeout: 4.0,
            description: "Inline menu item"
        )
        inlineItem.click()

        // Effect: derived subtitle flips to the Inline string and the Vertical
        // string disappears.
        XCTAssertTrue(
            poll(timeout: 5.0) { inlineSubtitle.exists },
            "Expected the Inline branch-layout subtitle after selecting Inline"
        )
        XCTAssertFalse(
            verticalSubtitle.exists,
            "Vertical subtitle should be gone once Inline is selected"
        )
    }

    // MARK: - Tiering documentation for this section
    //
    // TIER 2 (needs runtime seam): Sidebar Branch Layout downstream render —
    //   the vertical-vs-inline arrangement only affects the branch/directory
    //   text *inside a workspace sidebar row* (ContentView workspace row,
    //   `usesVerticalBranchLayout`). The harness `makeLaunchedApp()` launches
    //   with no workspaces (no CMUX_UI_TEST_BONSPLIT setup env), so no
    //   workspace row exists to inspect, and the two layouts carry no
    //   distinguishing accessibilityIdentifier. Verifying the rendered layout
    //   would require the bonsplit/workspace setup launch env the fixed
    //   harness does not provide. The picker binding itself is covered above.
    //
    // TIER 2 (needs runtime seam): Active-tab indicator style — the control
    //   that edits `sidebarActiveTabIndicatorStyle` lives in the *Workspace
    //   Colors* section, not in Sidebar/Beta, so it is out of this section's
    //   UI. Its runtime effect is purely visual chrome on the active
    //   workspace row in the sidebar (left rail / dot / stripe drawn in
    //   SidebarAppearanceSupport + ContentView). With no workspace rows at
    //   harness launch there is nothing to render the indicator on, and the
    //   distinction is pixel-level appearance with no accessibility element.
    //   This would need a workspace-setup launch seam plus screenshot
    //   sampling to verify.
}
