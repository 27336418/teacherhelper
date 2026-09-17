import AppKit
import Foundation
import UserNotifications

// MARK: - 定时提醒调度器：用系统通知（UserNotifications）到点弹窗
// 每次 reminders 变化时重建所有本地通知；到点系统横幅/声音提醒。
// 文字带 URL 时，点通知会打开默认浏览器访问该地址。

final class NotificationScheduler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationScheduler()

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                if granted {
                    self.scheduleAll()
                }
            }
        }
    }

    /// 根据当前提醒列表重建所有本地通知
    func scheduleAll() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()

        let reminders = ReminderStore.shared.reminders
        for r in reminders {
            schedule(r)
        }
    }

    private func schedule(_ r: Reminder) {
        let content = UNMutableNotificationContent()
        content.title = "课表提醒"
        content.body = r.title
        content.sound = .default

        // 未勾任何星期 → **一次性**提醒：只给「当天」排一条不重复的系统通知。
        // （2026-09-17 之前这里直接什么都不排，等于系统通知永远不会来；用户要求改成「当天该时刻提醒一次」）
        if r.weekdays.isEmpty {
            guard let date = r.oneShotDate(), date > Date() else { return }
            var comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            comps.second = 0
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let request = UNNotificationRequest(identifier: "\(r.id.uuidString)-oneshot",
                                               content: content, trigger: trigger)
            UNUserNotificationCenter.current().add(request)
            return
        }

        for day in r.weekdays {
            // UNCalendarNotificationTrigger 用 DateComponents：weekday 1=周日
            var comps = DateComponents()
            comps.weekday = day
            comps.hour = r.hour
            comps.minute = r.minute
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)

            let id = "\(r.id.uuidString)-\(day)"
            let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
            UNUserNotificationCenter.current().add(request)
        }
    }

    // MARK: 前台也显示通知（默认前台不弹，需此代理）
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // 点击通知：若提醒含 URL 则打开浏览器
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        // 通知 id 形如 "<uuid>-<星期>" 或 "<uuid>-oneshot" → 用前缀匹配 uuid（别再解析后缀数字）
        if let reminder = ReminderStore.shared.reminders.first(where: { id.hasPrefix($0.id.uuidString) }),
           let url = URL(string: reminder.url), !reminder.url.isEmpty {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }
}
