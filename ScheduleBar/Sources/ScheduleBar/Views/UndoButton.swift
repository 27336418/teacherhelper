import SwiftUI

// MARK: - 全局撤销按钮
// 放在各板块右上角工具区最左侧（「导入 / 添加」等按钮左边）。
// 没有可撤销的操作时自动隐藏，不占位；悬停提示会显示具体待撤销的操作名。
struct UndoButton: View {
    @ObservedObject private var undo = UndoService.shared

    var body: some View {
        if undo.canUndo {
            Button {
                UndoService.shared.undo()
            } label: {
                Label("撤销", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .foregroundStyle(.orange)
            .help(helpText)
            .transition(.opacity)
        }
    }

    private var helpText: String {
        if let label = undo.lastLabel, !label.isEmpty {
            return "撤销：\(label) (⌘Z)"
        }
        return "撤销上一步操作 (⌘Z)"
    }
}
