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

    /// 是否在 weekdayIndex（1-7，周日=1）当天触发
    func fires(on weekday: Int) -> Bool { weekdays.contains(weekday) }
}

final class ReminderStore: ObservableObject {
    static let shared = ReminderStore()

    @Published var reminders: [Reminder] {
        didSet { save() }
    }

    init() {
        self.reminders = ReminderStore.load() ?? ReminderStore.defaults()
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

    // 便捷星期标签：1=周日
    static func weekdayLabel(_ w: Int) -> String {
        ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][w % 7]
    }

    // MARK: 持久化
    func save() {
        do {
            let url = Self.fileURL()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(reminders)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[ScheduleBar] 提醒保存失败: \(error)")
        }
        // 提醒列表变化后重建系统通知
        NotificationScheduler.shared.scheduleAll()
        // 同步到系统自带日历（去抖，避免编辑文字时每敲一个字都写一次）
        CalendarSyncService.shared.scheduleSyncAllReminders()
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
