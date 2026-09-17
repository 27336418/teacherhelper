import Foundation
import EventKit
import AppKit
import Combine

// MARK: - 日程 → 系统日历（EventKit）自动同步
// ① 校历「按天备注」→ 一条全天事件（改备注=改事件标题，清空备注=删事件）
// ② 「提醒设置」里的定时提醒 → 一条每周重复事件（改提醒=改事件，删提醒=删事件）
// 事件标识分别存在 calendar_remarks.json 的 "ek-day-yyyy-MM-dd" 键，
// 以及 calendar_events.json 的「提醒 UUID → 事件标识」映射里，跨次启动继续更新同一条事件。
final class CalendarSyncService: ObservableObject {
    static let shared = CalendarSyncService()

    /// 定时提醒是否同步到系统日历（可在「提醒设置」里开关；默认开启）
    @Published var syncReminders: Bool {
        didSet {
            guard oldValue != syncReminders else { return }
            UserDefaults.standard.set(syncReminders, forKey: Self.enabledKey)
            if syncReminders {
                syncAllReminders(reason: "开启同步")
            } else {
                removeAllReminderEvents()
            }
        }
    }
    /// 最近一次同步结果（显示在「提醒设置」里）
    @Published private(set) var summary: String = "尚未同步"
    /// 日历权限被拒绝（用于提示用户去系统设置里打开）
    @Published private(set) var permissionDenied = false

    /// 提醒日程写进系统日历的日历名称（显示给用户）
    static var calendarName: String { calendarTitle }

    private let store = EKEventStore()
    private var granted = false
    private var cachedCalendar: EKCalendar?
    private let debouncer = Debouncer()

    private static let enabledKey = "calendarSyncReminders"
    private static let calendarTitle = "教师助手"

    /// 提醒 UUID → 系统日历事件标识
    private var eventIDs: [String: String] = [:]

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private init() {
        syncReminders = (UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool) ?? true
        loadEventMap()
        // 系统日历被外部改动（例如用户手动删了事件）→ 丢弃缓存的日历对象
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged,
                                               object: store, queue: .main) { [weak self] _ in
            self?.cachedCalendar = nil
        }
    }

    // MARK: - ① 校历按天备注

    /// 同步一条按天备注。text 为空 = 删除事件；返回事件标识（删除/失败返回 nil）。
    func syncDayRemark(_ text: String, day: Date, eventID: String?, done: @escaping (String?) -> Void) {
        ensureAccess { [weak self] ok in
            guard let self, ok else { done(text.isEmpty ? nil : eventID); return }
            DispatchQueue.main.async { self.performSyncDayRemark(text, day: day, eventID: eventID, done: done) }
        }
    }

    private func performSyncDayRemark(_ text: String, day: Date, eventID: String?, done: @escaping (String?) -> Void) {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)

        // 清除备注 → 删除对应事件
        if text.isEmpty {
            if let id = eventID, let ev = store.event(withIdentifier: id) {
                do {
                    try store.remove(ev, span: ev.hasRecurrenceRules ? .futureEvents : .thisEvent, commit: true)
                    SeatingStore.seatLog("系统日历：已删除备注事件（\(id)）")
                } catch {
                    SeatingStore.seatLog("系统日历：删除事件失败 \(error.localizedDescription)")
                }
            }
            done(nil)
            return
        }

        // 已有事件 → 更新标题
        if let id = eventID, let ev = store.event(withIdentifier: id) {
            ev.title = text
            do {
                try store.save(ev, span: .thisEvent, commit: true)
                done(id)
            } catch {
                SeatingStore.seatLog("系统日历：更新事件失败 \(error.localizedDescription)")
                done(nil)
            }
            return
        }

        // 新建全天事件（写入系统默认日历）
        guard let target = store.defaultCalendarForNewEvents else {
            SeatingStore.seatLog("系统日历：未找到可写入的日历，备注未同步")
            done(nil)
            return
        }
        let ev = EKEvent(eventStore: store)
        ev.title = text
        ev.isAllDay = true
        ev.startDate = dayStart
        ev.endDate = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        ev.calendar = target
        do {
            try store.save(ev, span: .thisEvent, commit: true)
            SeatingStore.seatLog("系统日历：备注已同步为全天事件「\(text)」")
            done(ev.eventIdentifier)
        } catch {
            SeatingStore.seatLog("系统日历：保存事件失败 \(error.localizedDescription)")
            done(nil)
        }
    }

    // MARK: - ② 定时提醒 → 每周重复事件

    /// 去抖同步：在提醒设置里改文字时，避免每敲一个字都写一次日历
    func scheduleSyncAllReminders(delay: TimeInterval = 0.9) {
        debouncer.schedule(delay: delay) { [weak self] in
            self?.syncAllReminders(reason: "提醒变化")
        }
    }

    /// 全量同步：新增/更新所有提醒对应事件，并清理「已删除提醒」遗留的事件
    func syncAllReminders(reason: String = "手动") {
        guard syncReminders else {
            removeAllReminderEvents()
            return
        }
        let reminders = ReminderStore.shared.reminders
        guard !reminders.isEmpty else {
            removeAllReminderEvents()
            summary = "暂无提醒"
            return
        }
        ensureAccess { [weak self] ok in
            guard let self else { return }
            guard ok else {
                self.summary = "未获日历权限，未能同步"
                return
            }
            DispatchQueue.main.async { self.performSyncAll(reminders, reason: reason) }
        }
    }

    private func performSyncAll(_ reminders: [Reminder], reason: String) {
        var created = 0, updated = 0, deleted = 0

        // 1) 提醒已被删除 → 删掉系统日历里对应的重复事件
        let live = Set(reminders.map { $0.id.uuidString })
        for (rid, eid) in eventIDs where !live.contains(rid) {
            if deleteEvent(eid) { deleted += 1 }
            eventIDs.removeValue(forKey: rid)
        }

        // 2) 逐条新增 / 更新
        for r in reminders {
            switch upsertReminder(r) {
            case .created: created += 1
            case .updated: updated += 1
            case .deleted: deleted += 1
            case .failed:  break
            }
        }
        saveEventMap()

        var parts: [String] = []
        if created > 0 { parts.append("新增 \(created)") }
        if updated > 0 { parts.append("更新 \(updated)") }
        if deleted > 0 { parts.append("清理 \(deleted)") }
        let stamp = Self.stampFormatter.string(from: Date())
        summary = parts.isEmpty
            ? "\(stamp) 已是最新（\(reminders.count) 条）"
            : "\(stamp) 已同步 \(reminders.count) 条（\(parts.joined(separator: "、"))）"
        SeatingStore.seatLog("系统日历：提醒同步完成（\(reason)）共 \(reminders.count) 条，\(parts.joined(separator: "、"))")
    }

    private enum UpsertResult { case created, updated, deleted, failed }

    private func upsertReminder(_ r: Reminder) -> UpsertResult {
        let key = r.id.uuidString

        // 未勾任何星期 → 一次性提醒（只在 oneShotDay 当天那个时刻），照常写一条「不重复」的日程；
        // 只有既没勾星期、又没记日期的老数据才算「永远不会触发」，日历里不留。
        // （2026-09-17 改：老版本把「没勾星期」一律当死数据，用户要求改成当天提醒一次）
        guard !(r.weekdays.isEmpty && r.oneShotDay == nil) else {
            if let eid = eventIDs[key], deleteEvent(eid) {
                eventIDs.removeValue(forKey: key)
                return .deleted
            }
            return .failed
        }

        let trimmed = r.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = trimmed.isEmpty ? "提醒" : trimmed

        // 已有事件 → 原地更新（文字/时间/星期/网址）
        if let eid = eventIDs[key], let ev = store.event(withIdentifier: eid) {
            applyReminder(r, to: ev, title: display)
            do {
                try store.save(ev, span: ev.hasRecurrenceRules ? .futureEvents : .thisEvent, commit: true)
                return .updated
            } catch {
                SeatingStore.seatLog("系统日历：更新提醒事件失败 \(error.localizedDescription)")
                return .failed
            }
        }

        // 新建重复事件
        guard let cal = reminderCalendar() else {
            SeatingStore.seatLog("系统日历：未找到可写入的日历，提醒未同步")
            return .failed
        }
        let ev = EKEvent(eventStore: store)
        ev.calendar = cal
        applyReminder(r, to: ev, title: display)
        do {
            try store.save(ev, span: .thisEvent, commit: true)
            eventIDs[key] = ev.eventIdentifier
            return .created
        } catch {
            SeatingStore.seatLog("系统日历：新建提醒事件失败 \(error.localizedDescription)")
            return .failed
        }
    }

    /// 把一条提醒写进 EKEvent（标题 / 时间 / 每周重复 / 网址 / 说明）
    private func applyReminder(_ r: Reminder, to ev: EKEvent, title: String) {
        let start = Self.startDate(for: r)
        ev.title = title
        ev.isAllDay = false
        ev.startDate = start
        ev.endDate = start.addingTimeInterval(30 * 60)
        // 一次性提醒（没勾星期）不写重复规则 → 日历里就只有那一天那一条
        ev.recurrenceRules = r.weekdays.isEmpty ? nil : [Self.weeklyRule(for: r.weekdays)]
        ev.notes = r.weekdays.isEmpty
            ? "由「教师助手 · 提醒设置」自动同步：未勾选星期 = 只在 \(r.oneShotDay ?? "-") 当天提醒一次。要改时间或文字，请回到应用内编辑。"
            : "由「教师助手 · 提醒设置」自动同步；要改时间或文字，请回到应用内编辑。"
        if !r.url.isEmpty, let u = URL(string: r.url) {
            ev.url = u
        } else {
            ev.url = nil
        }
    }

    /// 关闭同步 / 提醒被清空 → 删除所有由提醒生成的事件
    func removeAllReminderEvents() {
        guard !eventIDs.isEmpty else {
            summary = syncReminders ? "尚未同步" : "已关闭同步"
            return
        }
        ensureAccess { [weak self] ok in
            guard let self else { return }
            guard ok else { return }
            DispatchQueue.main.async {
                var n = 0
                for (rid, eid) in self.eventIDs {
                    if self.deleteEvent(eid) { n += 1 }
                    self.eventIDs.removeValue(forKey: rid)
                }
                self.saveEventMap()
                self.summary = self.syncReminders ? "已清空提醒日程" : "已从系统日历移除 \(n) 条提醒日程"
            }
        }
    }

    // MARK: - 纯函数（供自检复用）

    /// 提醒的星期集合 → 有序数组（1=周日 … 7=周六，与 Calendar.weekday 一致）
    static func orderedWeekdays(_ weekdays: Set<Int>) -> [Int] {
        weekdays.filter { (1...7).contains($0) }.sorted()
    }

    /// 每周重复规则（同一条事件里覆盖所勾选的所有星期）
    static func weeklyRule(for weekdays: Set<Int>) -> EKRecurrenceRule {
        let days: [EKRecurrenceDayOfWeek] = orderedWeekdays(weekdays).compactMap { d in
            guard let wd = EKWeekday(rawValue: d) else { return nil }
            return EKRecurrenceDayOfWeek(wd, weekNumber: 0)
        }
        return EKRecurrenceRule(recurrenceWith: .weekly,
                                interval: 1,
                                daysOfTheWeek: days.isEmpty ? nil : days,
                                daysOfTheMonth: nil,
                                monthsOfTheYear: nil,
                                weeksOfTheYear: nil,
                                daysOfTheYear: nil,
                                setPositions: nil,
                                end: nil)
    }

    /// 日程开始时间：一次性提醒（没勾星期）＝ oneShotDay 当天的 hour:minute；否则按每周重复的首次发生时间
    static func startDate(for r: Reminder,
                          calendar cal: Calendar = .current,
                          now: Date = Date()) -> Date {
        if r.weekdays.isEmpty, let d = r.oneShotDate(calendar: cal) { return d }
        return firstStart(from: r, calendar: cal, now: now)
    }

    /// 首次发生时间：今天或之后、第一个命中勾选星期的 0 点 + 提醒时分
    static func firstStart(from r: Reminder,
                           calendar cal: Calendar = .current,
                           now: Date = Date()) -> Date {
        var day = cal.startOfDay(for: now)
        for _ in 0..<7 {
            if r.weekdays.contains(cal.component(.weekday, from: day)) { break }
            day = cal.date(byAdding: .day, value: 1, to: day) ?? day
        }
        return cal.date(bySettingHour: r.hour, minute: r.minute, second: 0, of: day) ?? day
    }

    // MARK: - 系统日历里用哪个日历

    private func reminderCalendar() -> EKCalendar? {
        if let c = cachedCalendar { return c }
        let all = store.calendars(for: .event)

        // 已存在同名日历 → 直接用
        if let existing = all.first(where: { $0.title == Self.calendarTitle && $0.allowsContentModifications }) {
            cachedCalendar = existing
            return existing
        }
        // 有读权限（能列日历）→ 建一个专用日历，方便在系统日历里整体显示/隐藏
        if !all.isEmpty {
            let c = EKCalendar(for: .event, eventStore: store)
            c.title = Self.calendarTitle
            if let src = store.defaultCalendarForNewEvents?.source
                ?? all.first(where: { $0.allowsContentModifications })?.source {
                c.source = src
                do {
                    try store.saveCalendar(c, commit: true)
                    SeatingStore.seatLog("系统日历：已创建「\(Self.calendarTitle)」日历用于同步提醒")
                    cachedCalendar = c
                    return c
                } catch {
                    SeatingStore.seatLog("系统日历：创建专用日历失败，改用默认日历 \(error.localizedDescription)")
                }
            }
        }
        // 只读/仅写入权限等场景 → 退回系统默认日历
        let fallback = store.defaultCalendarForNewEvents
        cachedCalendar = fallback
        return fallback
    }

    @discardableResult
    private func deleteEvent(_ id: String) -> Bool {
        guard let ev = store.event(withIdentifier: id) else { return false }
        do {
            try store.remove(ev, span: ev.hasRecurrenceRules ? .futureEvents : .thisEvent, commit: true)
            return true
        } catch {
            SeatingStore.seatLog("系统日历：删除提醒事件失败 \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 事件映射持久化（calendar_events.json）

    private static var mapURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScheduleBar", isDirectory: true)
        return dir.appendingPathComponent("calendar_events.json")
    }

    private func loadEventMap() {
        guard let data = try? Data(contentsOf: Self.mapURL),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        eventIDs = map
    }

    private func saveEventMap() {
        let url = Self.mapURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(eventIDs)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[ScheduleBar] 日历事件映射保存失败: \(error)")
        }
    }

    // MARK: - 权限

    /// 请求日历权限（只问一次；拒绝后不再弹，静默失败并记日志）
    ///
    /// ⚠️ 2026-09-12 修正：macOS 14 起 `requestAccess(to:)` **已废弃且不再弹出授权对话框**
    ///   （直接返回 false），所以用户「看不到弹窗、也没法选允许/不允许」，
    ///   日志只会留下一句「未获授权」。14 及以上必须改用 `requestFullAccessToEvents`。
    ///   另外本 App 是 `.accessory`（无 Dock 图标），请求前先把自己拉到前台，
    ///   否则系统对话框可能被压在别的窗口后面，用户根本看不到。
    private func ensureAccess(_ comp: @escaping (Bool) -> Void) {
        if granted { permissionDenied = false; comp(true); return }

        let status = EKEventStore.authorizationStatus(for: .event)
        let statusDesc: String = {
            if #available(macOS 14.0, *) {
                switch status {
                case .notDetermined: return "未询问（应弹授权窗）"
                case .restricted:    return "受限"
                case .denied:        return "已拒绝（要去系统设置里打开）"
                case .fullAccess:    return "完全访问"
                case .writeOnly:     return "仅写入"
                @unknown default:    return "rawValue=\(status.rawValue)"
                }
            }
            return "rawValue=\(status.rawValue)"
        }()
        SeatingStore.seatLog("系统日历：当前授权状态 \(statusDesc)")

        let finish: (Bool, Error?) -> Void = { [weak self] g, err in
            if let err { SeatingStore.seatLog("系统日历：权限错误 \(err.localizedDescription)") }
            if g == false {
                SeatingStore.seatLog("系统日历：未获授权，日程不会同步到系统日历（可在 系统设置→隐私与安全性→日历 中开启）")
            } else {
                SeatingStore.seatLog("系统日历：已获授权")
            }
            self?.granted = g
            self?.permissionDenied = !g
            comp(g)
        }

        if #available(macOS 14.0, *) {
            // 未询问过 → 先把 App 拉到前台，保证系统授权弹窗用户能看见
            if status == .notDetermined {
                NSApp.activate(ignoringOtherApps: true)
            }
            store.requestFullAccessToEvents(completion: finish)
        } else {
            store.requestAccess(to: .event, completion: finish)
        }
    }

    /// 打开「系统设置 → 隐私与安全性 → 日历」
    static func openCalendarPrivacySettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(u)
        }
    }
}
