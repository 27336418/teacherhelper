import SwiftUI
import UniformTypeIdentifiers

// MARK: - 统一拖拽对换（与学生座位一致的做法）
//
// 所有「格子对调」模块（个人课表 / 班级课表 / 教室分布 / 办公室工位 / 学生座位）共用这套约定：
//   1. `.onDrag` 时把「来源」登记到 DragContext（同步），同时让 store 记下快照；
//   2. 拖动过程中（dropEntered / dropUpdated）只做高亮等视觉反馈，**不改任何数据**；
//   3. 松手（performDrop）时读 DragContext，确认来源属于本模块后，**同步**执行一次对换，
//      并登记撤销。
//
// ⚠️ 2026-09-12（macOS 26 / Tahoe）关键修复：落点必须**同步**换位。
//   原实现是 `provider.loadObject(...)` → `DispatchQueue.main.async { 换位 }`，
//   视图更新发生在拖拽会话结束之后；而 SwiftUI 26 上拖拽会话只有在落点处理里
//   同步更新视图才会正常复位，否则后续 `.onDrag` 不再触发——
//   表现就是「拖一次之后再也拖不动，必须切到别的 App 再点回来」。
//   现在改成：拿起时同步记录 DragContext，落点按它判断归属并直接换位，全同步。

/// 拖拽载荷 / 模块标识
enum DragPayload {
    /// 课表格子（个人课表）前缀
    static let personalCell = "psc"
    /// 课表格子（班级课表）前缀
    static let classCell = "csc"
    /// 教室分布格子前缀
    static let classroomCell = "classroom"
    /// 办公室工位前缀
    static let officeSeat = "office"
    /// 学生座位（单元格 / 待用 / 待用小组 / 小组区域）统一模块名
    static let seating = "seating"

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

/// 「当前正在进行的拖拽」记录：由 `.onDrag` 在**拿起时同步**写入，供落点同步读取。
///
/// 为什么不用 `DropInfo.itemProviders(...).loadObject(...)`：
/// 那个回调是异步的，换位会晚于拖拽会话结束 → 在 macOS 26 上会让拖拽会话不复位，
/// 之后所有 `.onDrag` 都静默失效。改成同步登记后，落点处理里就能立刻换位。
enum DragContext {
    /// 当前拖拽所属模块（DragPayload 里的常量）
    private(set) static var module: String?
    /// 当前拖拽的载荷字符串（学生座位要用它解析来源）
    private(set) static var payload: String?

    /// 拿起（在 `.onDrag` 里同步调用）
    static func begin(module: String, payload: String) {
        self.module = module
        self.payload = payload
        DragSessionGuard.log("拖拽开始：模块=\(module) 载荷=\(payload)")
    }

    /// 落点是否属于本模块
    static func belongs(to m: String) -> Bool { module == m }

    /// 是否正有一次已拿起、尚未落地的拖动
    static var isDragging: Bool { module != nil }

    /// 落点处理完毕（不论有没有真的换位）→ 清状态，并让面板窗口重新成为 key
    static func finish(reason: String) {
        module = nil
        payload = nil
        DragSessionGuard.panelDropDidFinish(reason: reason)
    }

    /// 拖拽被打断（切走 App / 面板收起）：只清状态，不动任何数据
    static func cancel() {
        module = nil
        payload = nil
    }

    /// 落点不属于本模块 → 原样拒绝。**只记日志，绝不改任何状态**
    /// （尤其不能 `finish`：那会把同一次拖拽的来源抹掉，下一拖也跟着失效）。
    static func reject(_ table: String) {
        DragSessionGuard.log("落点拒绝：落点=\(table) 当前拖动=\(module ?? "无")")
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

    /// 本落点是否该管家下的这次拖拽（不是本模块 → 一概不理，光标也显示为「不可放」）
    private var isOurs: Bool { DragContext.belongs(to: table) }

    func validateDrop(info: DropInfo) -> Bool { isOurs }

    func dropEntered(info: DropInfo) {
        guard isOurs else { return }
        onEnter()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard isOurs else { return nil }
        onEnter()
        return DropProposal(operation: .move)
    }

    /// 唯一提交点：**同步**对换一次（不能放进 loadObject 的异步回调，
    /// 否则 macOS 26 上拖拽会话不复位，后续就拖不动了）。
    ///
    /// ⚠️ 不是本模块的拖拽必须「原样拒绝、什么都不清」：
    ///   缓存页（ZStack 里 opacity=0 的已访问页面）的 `.onDrop` 依然会被 AppKit 当成
    ///   拖拽落点，落点落错页时如果顺手 `DragContext.finish`，同一次拖拽的来源就没了——
    ///   表现就是「拖了没换」＋「下一拖也随之失效」。（座位表代理一直是这么写的，所以最稳）
    func performDrop(info: DropInfo) -> Bool {
        guard DragContext.belongs(to: table) else { DragContext.reject(table); return false }
        onPerform()
        onFinish()
        DragContext.finish(reason: table)
        return true
    }
}
