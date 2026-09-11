import Foundation
import EventKit

// MARK: - 日历备注 → 系统日历（EventKit）自动同步
// 每条按天备注对应系统日历里一条全天事件；修改备注=改事件标题，清除备注=删事件。
// 事件标识存在 calendar_remarks.json 的 "ek-day-yyyy-MM-dd" 键里，跨次启动可继续更新同一条事件。
final class CalendarSyncService {
    static let shared = CalendarSyncService()

    private let store = EKEventStore()
    private var granted = false

    private init() {}

    /// 同步一条按天备注。text 为空 = 删除事件；返回事件标识（删除/失败返回 nil）。
    func syncDayRemark(_ text: String, day: Date, eventID: String?, done: @escaping (String?) -> Void) {
        ensureAccess { [weak self] ok in
            guard let self, ok else { done(text.isEmpty ? nil : eventID); return }
            DispatchQueue.main.async { self.performSync(text, day: day, eventID: eventID, done: done) }
        }
    }

    private func performSync(_ text: String, day: Date, eventID: String?, done: @escaping (String?) -> Void) {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)

        // 清除备注 → 删除对应事件
        if text.isEmpty {
            if let id = eventID, let ev = store.event(withIdentifier: id) {
                do {
                    try store.remove(ev, span: .thisEvent, commit: true)
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

    /// 请求日历权限（只问一次；拒绝后不再弹，静默失败并记日志）
    private func ensureAccess(_ comp: @escaping (Bool) -> Void) {
        if granted { comp(true); return }
        store.requestAccess(to: .event) { [weak self] g, err in
            if let err { SeatingStore.seatLog("系统日历：权限错误 \(err.localizedDescription)") }
            if g == false { SeatingStore.seatLog("系统日历：未获授权，备注不会同步到系统日历（可在 系统设置→隐私与安全性→日历 中开启）") }
            self?.granted = g
            comp(g)
        }
    }
}
