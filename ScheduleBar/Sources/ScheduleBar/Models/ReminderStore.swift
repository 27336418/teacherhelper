import Foundation
import SwiftUI

// MARK: - 定时提醒设置（时间 + 一周循环星期 + 自定义文字 + 可选 URL；自动保存）
// 持久化 reminders.json。

struct Reminder: Identifiable, Codable, Equatable {
    /// 长周期循环（2026-09-28 用户要求）：每月 / 每半年 / 每年。
    /// 与「按星期循环」「一次性」三者互斥：设了长周期 → weekdays 必为空、且不再算「一次性」。
    /// 循环日期以 `oneShotDay` 为锚点（每月=锚点的「日」；每半年=锚点月-日 与 半年后同月-日；每年=锚点月-日）。
    enum LongCycle: String, Codable, CaseIterable {
        case monthly, halfYearly, yearly
        var label: String {
            switch self {
            case .monthly: return "每月"
            case .halfYearly: return "每半年"
            case .yearly: return "每年"
            }
        }
    }

    var id: UUID = UUID()
    var title: String          // 提醒文字
    var hour: Int              // 0-23
    var minute: Int            // 0-59
    var weekdays: Set<Int>     // 1=周日 ... 7=周六（与 Calendar.weekday 一致）
    var url: String            // 可选 web 地址（空则无）
    /// 长周期循环（nil = 旧逻辑：weekdays 非空=按星期循环；空=一次性提醒）。
    var longCycle: LongCycle? = nil
    /// 未勾选任何星期时，这条提醒 = **一次性**：只在 oneShotDay 这一天的 hour:minute 提醒一次（"yyyy-MM-dd"）。
    /// 勾了星期则恒为 nil。
    /// ⚠️ 2026-09-17 用户反馈：老版本「空星期 = 永远不会提醒」是错的（界面还挂着「未勾选任何星期，不会提醒」
    ///    的橙色警告），用户要求改成「默认为当天设定的时间」，也就是按当天这个点提醒一次。
    var oneShotDay: String? = nil
    /// 一次性提醒**已经弹过**的那一天（"yyyy-MM-dd"）。
    /// ⚠️ 2026-09-28 起**退役为历史字段**（只用于兼容老数据解码，逻辑不再读写）：
    ///    原用途是「弹过就落盘，重启不再弹」，但弹窗窗口是纯内存状态 —— App 重启窗口丢失
    ///    后 firedOn 还拦着 → 用户看到「已弹窗·待处理」却永远找不到窗口（死锁，当日实测）。
    ///    「不再弹」改由 `completedOn` 表达；「同一进程内不重复弹」由 ReminderFirer.lastFired 保证。
    var firedOn: String? = nil
    /// 一次性提醒**已完成**的那一天（"yyyy-MM-dd"）。
    /// 2026-09-28 用户明确：在弹窗上点「马上处理」（或「打开链接」）才算处理完成 ——
    /// 与 `firedOn`（到点弹窗就记，用来防重启重弹）是两回事：点「等会处理」的不算完成。
    var completedOn: String? = nil

    /// 是否在 weekdayIndex（1-7，周日=1）当天触发
    func fires(on weekday: Int) -> Bool { weekdays.contains(weekday) }

    /// 一次性提醒（没勾任何星期、也没设长周期循环）
    var isOneShot: Bool { weekdays.isEmpty && longCycle == nil }

    /// 长周期循环的触发日匹配（anchor = oneShotDay 的「月 / 日」；未设锚点 → 永不命中）。
    /// 每月 = anchor 的「日」；每半年 = anchor 月-日 与 半年后的同月-日；每年 = anchor 月-日。
    /// ⚠️ 每月 29/30/31 日在没有该日的月份里当月跳过（与系统日历的每月重复行为一致）。
    func matchesLongCycle(on date: Date, calendar cal: Calendar = .current) -> Bool {
        guard let cycle = longCycle, let anchor = oneShotDay else { return false }
        let parts = anchor.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        let aMonth = parts[1], aDay = parts[2]
        let m = cal.component(.month, from: date), d = cal.component(.day, from: date)
        switch cycle {
        case .monthly:
            return d == aDay
        case .halfYearly:
            let m2 = ((aMonth - 1 + 6) % 12) + 1
            return d == aDay && (m == aMonth || m == m2)
        case .yearly:
            return m == aMonth && d == aDay
        }
    }

    /// 长周期循环的显示文本（列表行用）：每月28日 / 每半年（3月28日、9月28日）/ 每年9月28日
    var longCycleText: String {
        guard let cycle = longCycle else { return "" }
        guard let anchor = oneShotDay else { return "\(cycle.label)（未设日期）" }
        let parts = anchor.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return cycle.label }
        let aMonth = parts[1], aDay = parts[2]
        switch cycle {
        case .monthly:
            return "每月\(aDay)日"
        case .halfYearly:
            let m2 = ((aMonth - 1 + 6) % 12) + 1
            return "每半年（\(aMonth)月\(aDay)日、\(m2)月\(aDay)日）"
        case .yearly:
            return "每年\(aMonth)月\(aDay)日"
        }
    }

    /// 一次性提醒已「完成」＝ 用户在弹窗上点过「马上处理 / 打开链接」（completedOn 落盘；
    /// 改时间/改星期重新武装时会清回 nil，所以 `completedOn != nil` ⟺ 已完成）。
    ///
    /// 2026-09-28 用户要求：
    ///   · 已完成 → **提醒列表里不再显示**（但系统日历里的事件要保留，见 `CalendarSyncService.keepsEventInCalendar`）；
    ///   · 过期未完成（oneShotDay 已过、没点过完成）→ 列表里**一直保留**，直到用户删掉或把它改时间「完成」。
    var isCompleted: Bool { isOneShot && completedOn != nil }

    /// "yyyy-MM-dd"（本地时区），用于一次性提醒的日期键
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static func dayString(_ d: Date) -> String { dayFormatter.string(from: d) }

    /// 一次性提醒日推断（2026-09-28 用户要求）：设定时刻今天还没到 → 今天；
    /// **已经过了（含正好此刻）→ 顺延到明天**。
    /// 背景：用户 23:29 把提醒时间设成 17:30，旧逻辑记成「今天」→ dueCheck 当场补弹
    /// （日志「一次性提醒补弹（已过 331 分钟）」）。规则改为：设置的时间比当前时间早
    /// = 用户指的必然是下一次（明天）的那个时刻，绝不当场弹。
    static func oneShotDayFor(hour: Int, minute: Int, now: Date = Date(), calendar cal: Calendar = .current) -> String {
        guard let target = cal.date(bySettingHour: hour, minute: minute, second: 0, of: now) else {
            return dayString(now)   // 时刻构造失败（理论上不会）→ 至少不崩
        }
        guard now < target else {
            let tomorrow = cal.date(byAdding: .day, value: 1, to: now) ?? now
            return dayString(tomorrow)
        }
        return dayString(now)
    }

    /// 一次性提醒的目标时刻（oneShotDay 当天 hour:minute）；非一次性或未设日期 → nil
    func oneShotDate(calendar cal: Calendar = .current) -> Date? {
        guard weekdays.isEmpty, let day = oneShotDay else { return nil }
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var c = DateComponents()
        c.year = parts[0]; c.month = parts[1]; c.day = parts[2]
        c.hour = hour; c.minute = minute; c.second = 0
        return cal.date(from: c)
    }

    /// 让「星期勾选」与「一次性日期」保持同步：
    /// · 勾了任意星期 → 清掉 oneShotDay（回到每周重复）
    /// · 一个都没勾 → 记下提醒日：日期没设或已过期时，按「下一次该时刻」重定 ——
    ///   今天该时刻还没到 = 今天；**已过 = 明天**（2026-09-28 用户要求，见 oneShotDayFor）。
    ///   今天已定（含「已弹窗·待处理」）的保持不动，不影响重启补弹。
    mutating func syncOneShot(now: Date = Date()) {
        // 长周期循环：oneShotDay 是循环锚点（月/日定义循环日期），绝不能当「一次性日期」改写
        guard longCycle == nil else { return }
        guard weekdays.isEmpty else { oneShotDay = nil; firedOn = nil; completedOn = nil; return }
        let today = Reminder.dayString(now)
        if let d = oneShotDay, d >= today { return }
        oneShotDay = Reminder.oneShotDayFor(hour: hour, minute: minute, now: now)
        firedOn = nil                     // 重新定日 → 允许按新日期再提醒一次
        completedOn = nil                 // 重新武装 → 上一次的「已完成」作废
    }

    /// 用户改了提醒时间（或想再来一次）→ 清掉「今天已提醒过」和「已完成」的标记，好按新时间再提醒；
    /// 提醒日同步重定：未来日期保持不动；今天/已过期 → 按「下一次该时刻」
    /// （时刻今天已过 → 明天，2026-09-28 用户要求：设置的时间比当前早 = 第二天）。
    mutating func rearmOneShot(now: Date = Date()) {
        guard weekdays.isEmpty, longCycle == nil else { return }
        let today = Reminder.dayString(now)
        if let d = oneShotDay, d > today {
            // 已定的未来日期不动：改时间不该把「10月1日」的提醒搬到今天/明天
        } else {
            oneShotDay = Reminder.oneShotDayFor(hour: hour, minute: minute, now: now)
        }
        firedOn = nil
        completedOn = nil                 // 重新武装 → 回到「未完成」，列表里重新显示
    }
}

final class ReminderStore: ObservableObject {
    static let shared = ReminderStore()

    @Published var reminders: [Reminder] {
        didSet { scheduleSave() }
    }

    init() {
        var loaded = ReminderStore.load() ?? ReminderStore.defaults()

        // ⚠️ 2026-09-18 删除了一段「星期错位一次性修正」迁移（历史事故，勿再写回）：
        //    原先它用 `UserDefaults.standard.bool(forKey: "reminderWeekdayLabelFixed")` 当开关，
        //    但直接运行 `.build/…/ScheduleBar`（无 App bundle）时偏好域与正常 App 不同，
        //    开关读不到 → 迁移被当成「首次运行」重跑 → 用户提醒的星期**整体又错位一天**。
        //    （2026-09-18 实测：自检进程把「周一~周五 [2,3,4,5,6]」改成了 [3,4,5,6,7]。）
        //
        //    结论：这段修正**已经**在引入它的版本里跑过一次，使命完成；留着只会在
        //    偏域不同的进程里二次生效。一次性迁移要用「数据本身」表达幂等，
        //    绝对不要用 UserDefaults 开关。
        //    下面这段 oneShotDay 补写就是正确做法的样例（补过一次后非 nil，天然幂等）。

        // ⚠️ 2026-09-17：老版本把「一个都没勾」当成「永远不提醒」（还挂橙色警告），用户要求改成
        //    「默认为当天设定的时间」＝当天提醒一次。这里把历史里没勾星期的提醒补上 oneShotDay，
        //    让它们立刻按新语义生效（幂等：补过一次后 oneShotDay 非 nil，不会再补）。
        let needOneShot = loaded.indices.filter {
            loaded[$0].weekdays.isEmpty && loaded[$0].oneShotDay == nil
        }
        if !needOneShot.isEmpty {
            // 2026-09-28 起按「下一次该时刻」补日期：时刻今天已过 → 明天（不当天补弹）
            for i in needOneShot {
                loaded[i].oneShotDay = Reminder.oneShotDayFor(hour: loaded[i].hour, minute: loaded[i].minute)
            }
            ReminderStore.writeToDisk(loaded)
            SeatingStore.seatLog("提醒：\(needOneShot.count) 条未勾选星期的提醒已改为「当天提醒一次」（不再永远不提醒）")
        }

        self.reminders = loaded
        isInitializing = false   // 装载结束，之后的改动才算用户编辑
    }

    /// 旧数据 → 正确星期：按钮标签是 `[w % 7]`，所以标签代表的那一天 = `(w % 7) + 1`。
    ///
    /// ⚠️ **绝对不要再对用户数据自动调用它**（见 `init` 里的历史事故说明）：
    ///    这段映射已经在修正版本里跑过一次，再跑一次就是把星期又搬错一天。
    ///    保留它只是为了在需要人工核对/修复时能看到当初的映射关系（逆映射＝`((v + 5) % 7) + 1`）。
    static func correctedWeekday(_ w: Int) -> Int {
        guard (1...7).contains(w) else { return w }
        return (w % 7) + 1
    }

    /// 默认提醒（含「请记得填晨午检表」，见 DefaultData.swift）
    static func defaults() -> [Reminder] {
        return DefaultData.reminders
    }

    func add(_ r: Reminder) {
        reminders.append(r)
    }
    func remove(_ id: UUID) {
        let snap = reminders
        let title = reminders.first(where: { $0.id == id })?.title ?? ""
        reminders.removeAll { $0.id == id }
        UndoService.shared.register("删除提醒\(title.isEmpty ? "" : "「\(title)」")") { [weak self] in
            guard let self else { return }
            self.reminders = snap
            self.scheduleSave()
            NotificationScheduler.shared.scheduleAll()
        }
    }
    func update(_ r: Reminder) {
        if let i = reminders.firstIndex(where: { $0.id == r.id }) {
            reminders[i] = r
        }
    }

    /// 一次性提醒「处理完成」（2026-09-28 用户要求）：在弹窗点「马上处理 / 打开链接」时调用。
    /// 赋值触发 didSet → scheduleSave() 立即落盘 + 自动同步系统日历：
    /// 列表里归入「已完成」不再显示，日历事件保留（keepsEventInCalendar）。
    func markOneShotCompleted(_ id: UUID, day: String) {
        guard let i = reminders.firstIndex(where: { $0.id == id }),
              reminders[i].weekdays.isEmpty,
              reminders[i].completedOn != day else { return }
        reminders[i].completedOn = day
        SeatingStore.seatLog("提醒：「\(reminders[i].title)」已处理完成（不再显示，日历保留）")
    }

    /// 清空全部提醒（保留设置，仅删除已配置的提醒项）
    func clearAll() {
        reminders = []
    }

    // 便捷星期标签：1=周日 … 7=周六（与 Calendar.weekday / DateComponents.weekday 一致）
    // ⚠️ 2026-09-12 修正：原实现是 `["周日",…,"周六"][w % 7]`，等于把每个按钮都往后挪了一天
    //   （按钮写「周一」实际存 1=周日，写「周六」实际存 6=周五，写「周日」实际存 7=周六）。
    //   后果：勾了「周一~周六」的人，周六那天**不会弹提醒**（值里压根没有 7），
    //   写进系统日历的重复规则也跟着错一天。现在按 `w - 1` 取，标签与取值一致。
    static func weekdayLabel(_ w: Int) -> String {
        guard (1...7).contains(w) else { return "?" }
        return ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][w - 1]
    }

    /// 界面里星期的显示顺序（周一在前，周日最后；只是显示顺序，不影响取值）
    static let weekdayDisplayOrder: [Int] = [2, 3, 4, 5, 6, 7, 1]

    /// 常用的整周选择
    static let weekdayEveryDay: Set<Int> = [1, 2, 3, 4, 5, 6, 7]
    static let weekdayWorkdays: Set<Int> = [2, 3, 4, 5, 6]      // 周一~周五
    static let weekdayMonToSat: Set<Int> = [2, 3, 4, 5, 6, 7]   // 周一~周六

    // MARK: 持久化
    /// 装载/规范化期间为 true —— 此时对属性的赋值不是「用户编辑」，不该让保存按钮亮起来。
    /// ⚠️ `@Published` 属性的 `didSet` 在 `init` 里**也会触发**（赋值走的是属性包装器的
    ///    setter，不是纯初始化路径），所以必须有这道闸门：否则 App 一启动就有
    ///    「个人课表 / 学生座位 / 当前周」三个板块显示「有未保存的改动」
    ///    （2026-09-18 实测）。init 末尾把它置回 false。
    private var isInitializing = true

    /// 用户编辑 → **立即落盘**（用户 2026-09-28 要求「默认自动保存」）。
    /// 与「教室布局」同一惯例（2026-09-23 起）：改一下就写盘，不走 SaveHub 标脏，
    /// 直接关掉 App 也不丢改动；2026-09-28 晚起全部板块都改成了这个惯例。
    func scheduleSave() {
        guard !isInitializing else { return }   // 装载期不算用户编辑
        save()
    }

    func save() {
        ReminderStore.writeToDisk(reminders)
        // ⚠️ CLI 自检进程没有 App bundle，碰 `UNUserNotificationCenter` 会抛 NSException
        //    （`--selftest-save` 注释里记录过这个限制）。无 bundle 时只落盘、
        //    跳过通知/日历副作用 —— 数据行为一致，副作用本来也只属于真实 App 运行。
        guard Bundle.main.bundleIdentifier != nil else { return }
        // 提醒列表变化后重建系统通知
        NotificationScheduler.shared.scheduleAll()
        // 同步到系统自带日历（去抖，避免编辑文字时每敲一个字都写一次）
        CalendarSyncService.shared.scheduleSyncAllReminders()
    }

    /// 只写盘、不触发通知/日历同步 —— 供 `init` 里的历史数据修正使用
    /// （init 里不能调 `save()`：会去读 `ReminderStore.shared`，而 shared 此刻还没建好）
    static func writeToDisk(_ list: [Reminder]) {
        do {
            let url = Self.fileURL()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(list)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[ScheduleBar] 提醒保存失败: \(error)")
        }
    }

    static func load() -> [Reminder]? {
        let url = fileURL()
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([Reminder].self, from: data)
    }

    static func fileURL() -> URL {
        // 统一走 AppPaths：自检可用 SCHEDULEBAR_DATA_DIR 把数据目录重定向到
        // 临时目录 —— 所有 store 都必须支持，否则它在 init 里的迁移会写真实数据。
        AppPaths.file("reminders.json")
    }
}
