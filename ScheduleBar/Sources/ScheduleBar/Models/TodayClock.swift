import Foundation
import AppKit

// MARK: - 今日时钟
// 问题：表头「今天」高亮以前用 Date() 现算，视图不会因为跨天而重绘，
//       所以过了午夜（或睡眠唤醒后）仍高亮昨天那一列，必须退出重开才刷新。
// 方案：一个全局单例，定时 + 系统唤醒 + App 激活时检查日期是否变化，
//       变化才发通知触发重绘（@Published），视图观察它即可自动更新。

final class TodayClock: ObservableObject {
    static let shared = TodayClock()

    /// 今天（当天 0 点）；跨天时才变化
    @Published private(set) var today: Date = Calendar.current.startOfDay(for: Date())

    private var timer: Timer?

    private init() {
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            self?.refreshNow()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // App 被激活（点开面板等）
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.refreshNow()
        }
        // 系统睡眠唤醒
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.refreshNow()
        }
        // 系统时钟被调整 / 时区变化
        NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.refreshNow()
        }
    }

    /// 立即检查是否已跨天（面板打开时调用，保证一打开就是正确的高亮）
    func refreshNow() {
        let start = Calendar.current.startOfDay(for: Date())
        if start != today { today = start }
    }

    /// 今天对应的课表列下标（周一~周六 → 0~5，周日 → 6）
    /// ⚠️ 课表现在是 7 列：周六在 index 5、周日在 index 6（见 `ScheduleWeek`）。
    var weekdayColumn: Int? {
        let wd = Calendar.current.component(.weekday, from: today)   // 1 = 周日 … 7 = 周六
        switch wd {
        case 2...7: return wd - 2          // 周一~周六 → 0~5
        case 1:     return ScheduleWeek.sunday
        default:    return nil
        }
    }
}
