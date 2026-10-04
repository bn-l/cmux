import Foundation

/// Settings under the dotted-id prefix `workspaceColors.*`.
public struct WorkspaceColorsCatalogSection: SettingCatalogSection {
    public let indicatorStyle = DefaultsKey<WorkspaceIndicatorStyle>(
        id: "workspaceColors.indicatorStyle",
        defaultValue: .leftRail,
        userDefaultsKey: "sidebarActiveTabIndicatorStyle"
    )

    public let selectionColorHex = DefaultsKey<String>(
        id: "workspaceColors.selectionColor",
        defaultValue: "",
        userDefaultsKey: "sidebarSelectionColorHex"
    )

    public let notificationBadgeColorHex = DefaultsKey<String>(
        id: "workspaceColors.notificationBadgeColor",
        defaultValue: "",
        userDefaultsKey: "sidebarNotificationBadgeColorHex"
    )

    /// Show the selected workspace's color as a dot before its name in the
    /// title bar. Workspaces without a color show no dot.
    public let titlebarIndicator = DefaultsKey<Bool>(
        id: "workspaceColors.titlebarIndicator",
        defaultValue: true,
        userDefaultsKey: "workspaceColorTitlebarIndicator"
    )

    /// Outline the focused pane in the selected workspace's color, even when
    /// the workspace has a single pane. Workspaces without a color fall back to
    /// the plain active-pane border (`activePaneBorderColor`).
    public let paneBorder = DefaultsKey<Bool>(
        id: "workspaceColors.paneBorder",
        defaultValue: true,
        userDefaultsKey: "workspaceColorPaneBorder"
    )

    public let palette = DefaultsKey<[String: String]>(
        id: "workspaceColors.colors",
        defaultValue: [:],
        userDefaultsKey: "workspaceTabColor.colors"
    )

    public let paletteOverrides = JSONKey<[String: String]>(
        id: "workspaceColors.paletteOverrides",
        defaultValue: [:]
    )

    public let customColors = JSONKey<[String]>(
        id: "workspaceColors.customColors",
        defaultValue: []
    )

    public init() {}
}
