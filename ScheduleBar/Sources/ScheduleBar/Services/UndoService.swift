import Foundation
import SwiftUI

// MARK: - 全局撤销服务
// 任何破坏性操作（删除行/列/节次/楼层/提醒、清空、隐藏板块等）在执行前
// 调用 register 压入一个「恢复快照」闭包；用户点撤销按钮或按 ⌘Z 时按后进先出回退。
// 仅内存保存（退出应用后清空），栈深上限 50 条。

final class UndoService: ObservableObject {
    static let shared = UndoService()

    /// 撤销栈条目
    private struct Entry {
        let label: String          // 操作名，用于 UI 提示（如「删除学生行」）
        let restore: () -> Void    // 恢复快照
    }

    @Published private(set) var canUndo: Bool = false
    @Published private(set) var lastLabel: String? = nil

    private var stack: [Entry] = []
    private let limit = 50

    private init() {}

    /// 登记一个可撤销操作（应在操作执行前调用）
    func register(_ label: String, restore: @escaping () -> Void) {
        stack.append(Entry(label: label, restore: restore))
        if stack.count > limit { stack.removeFirst(stack.count - limit) }
        publish()
    }

    /// 撤销最近一次操作
    @discardableResult
    func undo() -> Bool {
        guard let entry = stack.popLast() else { return false }
        entry.restore()
        publish()
        return true
    }

    /// 清空撤销栈（**自检脚本专用**：上一条用例登记的撤销闭包会把刚摆好的测试数据改回去，
    /// 所以每条用例之间必须先清栈；正常界面流程不会调用它）
    func clear() {
        stack.removeAll()
        publish()
    }

    private func publish() {
        canUndo = !stack.isEmpty
        lastLabel = stack.last?.label
    }
}
