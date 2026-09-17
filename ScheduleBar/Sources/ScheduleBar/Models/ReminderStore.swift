import Foundation
import SwiftUI

// MARK: - 定时提醒设置（时间 + 一周循环星期 + 自定义文字 + 可选 URL；自动保存）
// 持久化 reminders.json。

struct Reminder: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String          // 提醒文字
    var hour: Int              // 0-23
    var minute: Int            // 0-59
    var weekdays: Set<Int>     // 1=周日 ... 7=周六（与 Calendar.weekday 一致）
    var url: String            // 可选 web 地址（空则无）
    /// 未勾选任何星期时，这条提醒 = **一次性**：只在 oneShotDay 这一天的 hour:minute 提醒一次（"yyyy-MM-dd"）。
    /// 勾了星期则恒为 nil。
    /// ⚠️ 2026-09-17 用户反馈：老版本「空星期 = 永远不会提醒」是错的（界面还挂着「未勾选任何星期，不会提醒」
    ///    的橙色警告），用户要求改成「默认为当天设定的时间」，也就是按当天这个点提醒一次。
    var oneShotDay: String? = nil

    /// 是否在 weekdayIndex（1-7，周日=1）当天触发
    func fires(on weekday: Int) -> Bool { weekdays.contains(weekday) }

    /// 一次性提醒（没勾任何星期）
    var isOneShot: Bool { weekdays.isEmpty }

    /// "yyyy-MM-dd"（本地时区），用于一次性提醒的日期键
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static func dayString(_ d: Date) -> String { dayFormatter.string(from: d) }

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
    /// · 一个都没勾 → 记下「今天」为提醒日；若原来记的日期已经过去（提醒已到期），重设为今天
    mutating func syncOneShot(now: Date = Date()) {
        guard weekdays.isEmpty else { oneShotDay = nil; return }
        let today = Reminder.dayString(now)
        if let d = oneShotDay, d >= today { return }
        oneShotDay = today
    }
}

final class ReminderStore: ObservableObject {
    static let shared = ReminderStore()

    @Published var reminders: [Reminder] {
        didSet { save() }
    }

    init() {
        var loaded = ReminderStore.load() ?? ReminderStore.defaults()
        // ⚠️ 一次性修正历史数据的「星期错位一天」（详见 weekdayLabel 的说明）：
        //    旧版本的星期按钮标签整体错位一天（按钮写「周六」实际存的是 6 = 周五），
        //    所以老数据要把每个值搬回它**标签所代表的**那一天，用户当初的勾选意图才不变。
        let fixedKey = "reminderWeekdayLabelFixed"
        if !UserDefaults.standard.bool(forKey: fixedKey) {
            UserDefaults.standard.set(true, forKey: fixedKey)
            if !loaded.isEmpty {
                loaded = loaded.map { r in
                    var m = r
                    m.weekdays = Set(r.weekdays.map { ReminderStore.correctedWeekday($0) })
                    return m
                }
                ReminderStore.writeToDisk(loaded)
                SeatingStore.seatLog("提醒：已修正 \(loaded.count) 条历史提醒的星期错位（标签曾整体偏差一天）")
            }
        }

        // ⚠️ 2026-09-17：老版本把「一个都没勾」当成「永远不提醒」（还挂橙色警告），用户要求改成
        //    「默认为当天设定的时间」＝当天提醒一次。这里把历史里没勾星期的提醒补上 oneShotDay，
        //    让它们立刻按新语义生效（幂等：补过一次后 oneShotDay 非 nil，不会再补）。
        let needOneShot = loaded.indices.filter {
            loaded[$0].weekdays.isEmpty && loaded[$0].oneShotDay == nil
        }
        if !needOneShot.isEmpty {
            for i in needOneShot { loaded[i].oneShotDay = Reminder.dayString(Date()) }
            ReminderStore.writeToDisk(loaded)
            SeatingStore.seatLog("提醒：\(needOneShot.count) 条未勾选星期的提醒已改为「当天提醒一次」（不再永远不提醒）")
        }

        self.reminders = loaded
    }

    /// 旧数据 → 正确星期：按钮标签是 `[w % 7]`，所以标签代表的那一天 = `(w % 7) + 1`
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
            self.save()
            NotificationScheduler.shared.scheduleAll()
        }
    }
    func update(_ r: Reminder) {
        if let i = reminders.firstIndex(where: { $0.id == r.id }) {
            reminders[i] = r
        }
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
    func save() {
        ReminderStore.writeToDisk(reminders)
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
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        return base.appendingPathComponent("ScheduleBar", isDirectory: true)
                  .appendingPathComponent("reminders.json")
    }
}
