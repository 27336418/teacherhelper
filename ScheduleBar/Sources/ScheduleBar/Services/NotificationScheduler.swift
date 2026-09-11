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
        for day in r.weekdays {
            // UNCalendarNotificationTrigger 用 DateComponents：weekday 1=周日
            var comps = DateComponents()
            comps.weekday = day
            comps.hour = r.hour
            comps.minute = r.minute
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)

            let content = UNMutableNotificationContent()
            content.title = "课表提醒"
            content.body = r.title
            content.sound = .default

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
        let day = Int(id.split(separator: "-").last ?? "0") ?? 0
        let base = id.replacingOccurrences(of: "-\(day)", with: "")
        if let reminder = ReminderStore.shared.reminders.first(where: { $0.id.uuidString == base }),
           let url = URL(string: reminder.url), !reminder.url.isEmpty {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }
}
