import Foundation
import Testing
import CmuxFoundation
import CmuxTerminalCore

@Suite
struct TitlebarFontSizeConfigTests {
    @Test func defaultTitlebarFontSizeMatchesBaseline() {
        let config = GhosttyConfig()

        #expect(abs(config.titlebarFontSize - 13) <= 0.0001)
        #expect(abs(config.titlebarFontSize - GhosttyConfig.defaultTitlebarFontSize) <= 0.0001)
    }

    @Test(arguments: [("titlebar-font-size = 18", 18.0), ("titlebar-font-size = 16.5", 16.5), ("titlebar-font-size=20", 20.0)])
    func parsesTitlebarFontSize(line: String, expected: Double) {
        var config = GhosttyConfig()

        config.parse(line)

        #expect(abs(config.titlebarFontSize - expected) <= 0.0001)
    }

    @Test(arguments: [("titlebar-font-size = 4", GhosttyConfig.minTitlebarFontSize), ("titlebar-font-size = 23", GhosttyConfig.maxTitlebarFontSize), ("titlebar-font-size = 48", GhosttyConfig.maxTitlebarFontSize)])
    func parseClampsTitlebarFontSizeToRange(line: String, expected: CGFloat) {
        var config = GhosttyConfig()

        config.parse(line)

        #expect(abs(config.titlebarFontSize - expected) <= 0.0001)
    }

    @Test func parseTitlebarFontSizeIgnoresInvalidAndNonFiniteValues() {
        var config = GhosttyConfig()

        config.parse("titlebar-font-size = 18")
        config.parse(
            """
            titlebar-font-size = not-a-number
            titlebar-font-size = nan
            titlebar-font-size = inf
            titlebar-font-size = -inf
            titlebar-font-size =
            """
        )

        #expect(abs(config.titlebarFontSize - 18) <= 0.0001)
    }

    @Test func titlebarAndTabBarFontSizesAreIndependent() {
        var config = GhosttyConfig()

        config.parse(
            """
            surface-tab-bar-font-size = 14
            titlebar-font-size = 20
            """
        )

        #expect(abs(config.titlebarFontSize - 20) <= 0.0001)
        #expect(abs(config.surfaceTabBarFontSize - 14) <= 0.0001)
    }

    @Test func loadUsesParsedTitlebarFontSizeFromInjectedLoader() {
        let loaded = GhosttyConfig.load(
            preferredColorScheme: .dark,
            useCache: false,
            loadFromDisk: { _ in
                var config = GhosttyConfig()
                config.parse("titlebar-font-size = 18")
                return config
            }
        )

        #expect(abs(loaded.titlebarFontSize - 18) <= 0.0001)
    }

    /// The title bar renders the size through `cmuxFont`, which applies Global
    /// Font Magnification itself; scaling here too would apply it twice.
    @Test func globalMagnificationDoesNotScaleTitlebarFontSize() {
        let loaded = GhosttyConfig.load(
            preferredColorScheme: .dark,
            useCache: false,
            globalFontMagnificationPercent: 200,
            loadFromDisk: { _ in
                var config = GhosttyConfig()
                config.parse(
                    """
                    titlebar-font-size = 18
                    surface-tab-bar-font-size = 12
                    """
                )
                return config
            }
        )

        #expect(abs(loaded.titlebarFontSize - 18) <= 0.0001)
        #expect(abs(loaded.surfaceTabBarFontSize - 24) <= 0.0001, "Control: magnification did apply to the tab bar size")
    }

    @Test func editorAndConfigShareTitlebarBounds() {
        #expect(GhosttyConfig.defaultTitlebarFontSize == CGFloat(CmuxGhosttyConfigSettingEditor.defaultTitlebarFontSize))
        #expect(GhosttyConfig.minTitlebarFontSize == CGFloat(CmuxGhosttyConfigSettingEditor.minTitlebarFontSize))
        #expect(GhosttyConfig.maxTitlebarFontSize == CGFloat(CmuxGhosttyConfigSettingEditor.maxTitlebarFontSize))
        #expect(CmuxGhosttyConfigSettingEditor().clampedTitlebarFontSize(.nan) == CmuxGhosttyConfigSettingEditor.defaultTitlebarFontSize)
        #expect(CmuxGhosttyConfigSettingEditor().clampedTitlebarFontSize(.infinity) == CmuxGhosttyConfigSettingEditor.defaultTitlebarFontSize)
    }

    @Test func editorParsesLastTitlebarValueAndClamps() {
        let contents = """
        titlebar-font-size = 12
        titlebar-font-size = 40
        """

        #expect(CmuxGhosttyConfigSettingEditor().parsedTitlebarFontSize(in: contents)
            == CmuxGhosttyConfigSettingEditor.maxTitlebarFontSize)
    }

    @Test func editorReturnsNilWhenTitlebarValueAbsent() {
        let contents = """
        sidebar-font-size = 14
        surface-tab-bar-font-size = 12
        """

        #expect(CmuxGhosttyConfigSettingEditor().parsedTitlebarFontSize(in: contents) == nil)
    }

    @Test func editorFormatsTitlebarValueTrimmingTrailingZerosAndClamping() {
        #expect(CmuxGhosttyConfigSettingEditor().formattedTitlebarFontSize(18) == "18")
        #expect(CmuxGhosttyConfigSettingEditor().formattedTitlebarFontSize(16.5) == "16.5")
        #expect(CmuxGhosttyConfigSettingEditor().formattedTitlebarFontSize(30) == "22")
    }

    @Test func editorWriteSettingRoundTripsTitlebarValue() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-titlebar-font-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.ghostty")
        try "font-size = 13\nsurface-tab-bar-font-size = 12\n".write(to: url, atomically: true, encoding: .utf8)

        try CmuxGhosttyConfigSettingEditor().writeSetting(
            key: CmuxGhosttyConfigSettingEditor.titlebarFontSizeKey,
            value: "18",
            to: url
        )
        try CmuxGhosttyConfigSettingEditor().writeSetting(
            key: CmuxGhosttyConfigSettingEditor.titlebarFontSizeKey,
            value: "20.5",
            to: url
        )

        let contents = try String(contentsOf: url, encoding: .utf8)
        var reparsed = GhosttyConfig()
        reparsed.parse(contents)
        #expect(contents.components(separatedBy: "titlebar-font-size").count == 2, "A second write replaces the line instead of appending")
        #expect(contents.contains("surface-tab-bar-font-size = 12"))
        #expect(contents.contains("font-size = 13"))
        #expect(CmuxGhosttyConfigSettingEditor().parsedTitlebarFontSize(in: contents) == 20.5)
        #expect(abs(reparsed.titlebarFontSize - 20.5) <= 0.0001)
    }
}
