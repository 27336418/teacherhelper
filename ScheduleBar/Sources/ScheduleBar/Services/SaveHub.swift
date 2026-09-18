import Foundation
import Combine

// MARK: - 统一保存中心（SaveHub）
//
// 2026-09-17 新增。此前每个板块都是「改一下 → 0.4 秒后自动落盘」，
// 用户既看不到「当前有没有没存上的改动」，也没有一个可以主动按的保存动作。
//
// 现在改成：
//   ① 编辑发生  → 只标脏（数据立刻在内存/界面生效），顶栏「保存」按钮高亮成可点状态；
//   ② 点保存 / ⌘S              → 立刻把全部数据写入磁盘，按钮显示「✓ 已保存」；
//   ③ 停手 8 秒没新动作        → 兜底自动落盘（用户忘了点也绝不丢数据）；
//   ④ 收起面板 / 关窗口 / 退出 → 兜底自动落盘。
//
// 「哪些板块脏了」用板块名做键（如「学生座位」「个人课表」），
// 界面上的提示文案与日志都直接用它。

final class SaveHub: ObservableObject {
    static let shared = SaveHub()

    // MARK: 对外状态

    /// 有未保存改动的板块名（如「学生座位」「班级课表」）
    @Published private(set) var dirtyAreas: Set<String> = []
    /// 最近一次落盘时间
    @Published private(set) var lastSavedAt: Date?
    /// 刚保存完的瞬时标记 —— 按钮据此短暂显示「✓ 已保存」
    @Published private(set) var justSaved = false

    /// 停手多久之后兜底自动落盘（秒）。给用户留出「按一下保存」的窗口，
    /// 又保证忘了按也不会丢数据。
    static let fallbackDelay: TimeInterval = 8

    private var fallbackTimer: DispatchWorkItem?
    private var flashTimer: DispatchWorkItem?
    private let lock = NSLock()

    /// 真正的落盘动作，默认＝`SaveHub.writeAll`（写全部 Store 的 json）。
    /// 改成 var 是为了让 `--selftest-save` 能换成计数替身，
    /// 从而验证「标脏 → 保存」这条链而**不触碰真实数据文件**。
    private(set) var writer: () -> Void
    /// writer 是否还是默认实现 —— 只影响日志措辞（替身落盘时不能谎称「已写入磁盘」）
    private var writerIsDefault = true

    private init() { writer = { SaveHub.writeAll() } }

    /// 自检专用：把落盘实现换成替身（不写盘，只计数）
    func useStubWriter(_ stub: @escaping () -> Void) {
        writer = stub
        writerIsDefault = false
    }

    /// 自检专用：恢复默认落盘实现
    func useDefaultWriter() {
        writer = { SaveHub.writeAll() }
        writerIsDefault = true
    }

    // MARK: 查询

    var hasUnsaved: Bool { !dirtyAreas.isEmpty }
    var unsavedCount: Int { dirtyAreas.count }

    /// 「学生座位、个人课表」（按名称排序，稳定可读）
    var unsavedList: String { dirtyAreas.sorted().joined(separator: "、") }

    // MARK: 标脏

    /// 记录某个板块发生了「用户编辑」——只标脏，不立即写盘。
    func markDirty(_ area: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.markDirty(area) }
            return
        }
        if dirtyAreas.contains(area) {
            scheduleFallback()          // 同一板块连续编辑：只续兜底计时
            return
        }
        if ProcessInfo.processInfo.environment["SCHEDULEBAR_TRACE_DIRTY"] != nil {
            let frames = Thread.callStackSymbols.dropFirst().prefix(6)
                .map { $0.split(separator: " ").dropFirst(3).joined(separator: " ") }
            Self.log("脏来源：\(area) ← \(frames.joined(separator: " | "))")
        }
        dirtyAreas.insert(area)
        justSaved = false
        scheduleFallback()
    }

    /// 清掉脏标记但不写盘（极少用：数据被外部整体重置时）
    func clearDirty(_ area: String? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.clearDirty(area) }
            return
        }
        if let area { dirtyAreas.remove(area) } else { dirtyAreas.removeAll() }
        if dirtyAreas.isEmpty { cancelFallback() }
    }

    // MARK: 落盘

    /// 立刻把全部数据写入磁盘。返回值＝落盘前有几个板块处于「未保存」。
    @discardableResult
    func saveNow(reason: String) -> Int {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in _ = self?.saveNow(reason: reason) }
            return 0
        }
        lock.lock()
        let areas = dirtyAreas
        lock.unlock()

        cancelFallback()
        writer()
        dirtyAreas.removeAll()
        lastSavedAt = Date()
        showSavedFlash()

        let detail = areas.isEmpty ? "无未保存改动（用户主动确认）"
                                   : "\(areas.count) 个板块：\(areas.sorted().joined(separator: "、"))"
        let outcome = writerIsDefault ? "已写入磁盘" : "（自检替身，未写盘）"
        Self.log("保存：\(reason) → \(outcome)（\(detail)）")
        return areas.count
    }

    /// 兜底：只有在确实有未保存改动时才写盘（用于关面板 / 退出前，避免无谓 IO）
    func saveIfNeeded(reason: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.saveIfNeeded(reason: reason) }
            return
        }
        guard hasUnsaved else { return }
        saveNow(reason: reason)
    }

    // MARK: 兜底计时

    private func scheduleFallback() {
        fallbackTimer?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.hasUnsaved else { return }
            self.saveNow(reason: "停手 \(Int(Self.fallbackDelay)) 秒自动保存")
        }
        fallbackTimer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fallbackDelay, execute: w)
    }

    private func cancelFallback() {
        fallbackTimer?.cancel()
        fallbackTimer = nil
    }

    private func showSavedFlash() {
        justSaved = true
        flashTimer?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.justSaved = false }
        flashTimer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: w)
    }

    // MARK: 真正的写盘动作
    //
    // 顺序无关紧要：每个 Store 各自写自己的 json（互不依赖）。
    // 迁移 / 导入类写盘不在这里，那些是「数据被替换」而非「用户编辑」，各自立即落盘。
    private static func writeAll() {
        ScheduleStore.shared.save()          // 个人课表
        ClassScheduleStore.shared.save()     // 班级课表
        SeatingStore.shared.save()           // 学生座位
        StaffStore.shared.save()             // 年级师资
        StudentStore.shared.save()           // 学生信息
        OfficeLayoutStore.shared.save()      // 教师工位
        ClassroomStore.shared.save()         // 教室布局
        ExtendScheduleStore.shared.save()    // 延时监考
        ReminderStore.shared.save()          // 日程提醒
        CalendarRemarkStore.shared.save()    // 校历备注
        CalendarDayColorStore.shared.save()  // 校历单日颜色
        NavPrefsStore.shared.save()          // 左侧导航顺序 / 隐藏
        WeekStore.shared.save()              // 当前是第几周
        CardTitleStore.shared.save()         // 板块标题改名
    }

    // MARK: 日志（沿用「教师助手.log」的统一格式）
    static func log(_ s: String) {
        let dir = NSHomeDirectory() + "/Library/Logs"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/教师助手.log"
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let data = "[\(f.string(from: Date()))] \(s)\n".data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: path), let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
