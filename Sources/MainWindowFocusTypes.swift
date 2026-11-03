import Foundation

enum MainWindowKeyboardFocusIntent: Equatable {
    case mainPanel(workspaceId: UUID, panelId: UUID)
}
