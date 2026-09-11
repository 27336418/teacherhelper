import SwiftUI
import UniformTypeIdentifiers

// MARK: - 统一拖拽对换（与学生座位一致的做法）
//
// 所有「格子对调」模块（个人课表 / 班级课表 / 教室分布 / 办公室工位）共用这套约定：
//   1. `.onDrag` 时把「来源」编码成载荷字符串（前缀 + 定位信息），同时让 store 记下快照；
//   2. 拖动过程中（dropEntered / dropUpdated）只做高亮等视觉反馈，**不改任何数据**；
//   3. 松手（performDrop）时读取载荷，确认来源属于本模块后，**只执行一次对换**，并登记撤销。
//
// 这样做的原因：早期版本在 dropEntered 里直接换位，拖过一串格子会被连续触发，
// 表现为「内容被覆盖 / 反复乱跳」。改成松手一次性提交后，落点唯一、撤销可靠。

/// 拖拽载荷：`模块|类型|定位…`
enum DragPayload {
    /// 课表格子（个人课表）前缀
    static let personalCell = "psc"
    /// 课表格子（班级课表）前缀
    static let classCell = "csc"
    /// 教室分布格子前缀
    static let classroomCell = "classroom"
    /// 办公室工位前缀
    static let officeSeat = "office"

    static func cell(_ table: String, _ period: String, _ day: Int) -> String {
        "\(table)|cell|\(period)|\(day)"
    }

    static func classroom(floor: UUID, row: UUID?, index: Int) -> String {
        "\(classroomCell)|cell|\(floor.uuidString)|\(row?.uuidString ?? "main")|\(index)"
    }

    static func office(_ office: UUID, row: Int, col: Int) -> String {
        "\(officeSeat)|seat|\(office.uuidString)|\(row)|\(col)"
    }

    /// 载荷是否属于某个模块（前缀匹配）
    static func belongs(_ raw: String, to table: String) -> Bool {
        raw.hasPrefix(table + "|")
    }
}

// MARK: - 课表格子对换代理（个人课表 & 班级课表共用）
struct ScheduleCellSwapDelegate: DropDelegate {
    /// 本模块的载荷前缀（DragPayload.personalCell / .classCell）
    let table: String
    /// 松手时唯一提交点：与落点格子对换内容
    let onPerform: () -> Void
    /// 提交后清理拖动状态并登记撤销
    let onFinish: () -> Void
    /// 拖动经过时的视觉反馈（默认不做任何事，学生座位用高亮，课表用系统拖影）
    var onEnter: () -> Void = {}

    func validateDrop(info: DropInfo) -> Bool { true }

    func dropEntered(info: DropInfo) { onEnter() }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        onEnter()
        return DropProposal(operation: .move)
    }

    /// 唯一提交点：先读拖拽载荷确认来源是本模块的格子，再执行一次对换。
    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else {
            // 拿不到载荷（极少数情况）也兜底提交一次，避免「拖了但没换」
            onPerform()
            onFinish()
            return true
        }
        provider.loadObject(ofClass: NSString.self) { obj, _ in
            DispatchQueue.main.async {
                let raw = obj as? String ?? ""
                if raw.isEmpty || DragPayload.belongs(raw, to: table) {
                    onPerform()
                }
                onFinish()
            }
        }
        return true
    }
}
