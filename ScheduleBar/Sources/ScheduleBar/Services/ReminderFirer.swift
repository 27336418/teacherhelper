import AppKit
import Foundation
import SwiftUI

// MARK: - 提醒触发器：主队列定时轮询，到点弹出应用内弹窗（不依赖系统通知权限，保证必弹）
// 修复要点：
// 1) 菜单栏应用会被 App Nap 挂起计时器 → 用 beginActivity(.userInitiated) 阻止；
// 2) Timer 默认只在 runloop default 模式跑，弹窗/菜单打开时会停 → 改用 DispatchSourceTimer（主队列不受模式影响）；
// 3) 系统睡眠错过整点 → 唤醒后补检：3 分钟内的错过的提醒仍会弹出；
// 4) 每条提醒每天同一时刻只弹一次；
// 5) 弹窗提供「马上处理 / 等会处理」：点「等会处理」可在弹窗内选择稍后间隔
//    （默认 30 分钟，可选 10 分钟 / 1 小时 / 2 小时 / 明天），到点再弹，循环直到「马上处理」。
// 6) 弹窗改为**独立非模态浮窗**（不再用 NSAlert.runModal）。runModal 会启动模态运行循环，
//    锁死整个应用 —— 菜单栏面板打不开、无法切换过去查看课表/处理事情。现在弹窗开着时
//    面板可照常打开操作，处理完再回来点「马上处理」即可。

final class ReminderFirer {
    static let shared = ReminderFirer()

    private var timer: DispatchSourceTimer?
    private var activity: NSObjectProtocol?
    private var lastFired: [UUID: String] = [:]   // 提醒 id → "yyyy-MM-dd HH:mm"（目标时刻）
    private var snoozed: [UUID: Date] = [:]       // 提醒 id → 「等会处理」后的下次弹出时刻
    private var windows: [UUID: NSWindow] = [:]   // 提醒 id → 已打开的非模态窗口（防重复弹）
    private var closeObservers: [UUID: NSObjectProtocol] = [:]  // 窗口关闭通知的监听 token

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func start() {
        guard timer == nil else { return }
        // 阻止 App Nap（否则菜单栏应用空闲时计时器被暂停，到点不触发）
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated], reason: "定时提醒轮询")

        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 3, repeating: 10, leeway: .seconds(2))
        t.setEventHandler { [weak self] in self?.check() }
        t.resume()
        timer = t

        // 系统从睡眠唤醒后立即补检一次
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.check() }
    }

    private func check() {
        let now = Date()
        let cal = Calendar.current
        let dayKey = Self.dayFormatter.string(from: now)   // "yyyy-MM-dd"（一次性提醒也按它判「当天」）

        // 清理过期记录，防止字典无限增长
        if lastFired.count > 64 {
            lastFired = lastFired.filter { $0.value.hasPrefix(dayKey) }
        }

        // 1) 「等会处理」到期的提醒：继续弹，直到用户点「马上处理」
        let dueSnoozes = snoozed.filter { $0.value <= now }.map { $0.key }
        for id in dueSnoozes {
            guard let r = ReminderStore.shared.reminders.first(where: { $0.id == id }) else {
                snoozed.removeValue(forKey: id)      // 提醒已被删除
                continue
            }
            snoozed.removeValue(forKey: id)
            fire(r, isRepeat: true) { [weak self] action in
                if case .snooze(let t) = action {
                    self?.snoozed[id] = Date().addingTimeInterval(t)
                }
            }
        }

        // 2) 到点提醒（每条每天同一时刻只弹一次）
        //    · 勾了星期 → 只在勾选的星期那天；错过 3 分钟内仍补弹
        //    · 没勾星期 → **一次性**：只在「当天」提醒；当天即使已经过点也补弹一次，绝不静默跳过
        //      （2026-09-17 用户要求：未勾星期默认为当天设定的时间提醒，而不是「不会提醒」）
        for r in ReminderStore.shared.reminders {
            let verdict = Self.dueCheck(r, now: now, calendar: cal)
            guard verdict.due else { continue }

            let key = "\(dayKey) \(String(format: "%02d:%02d", r.hour, r.minute))"
            guard lastFired[r.id] != key else { continue }
            lastFired[r.id] = key
            // 一次性提醒：把「今天已弹」落到 reminders.json，重启 App 不会又弹一遍
            if r.isOneShot { ReminderStore.shared.markOneShotFired(r.id, day: dayKey) }
            if verdict.lateMinutes >= 1 {
                SeatingStore.seatLog("提醒：「\(r.title)」\(verdict.reason)")
            }
            fire(r) { [weak self] action in
                if case .snooze(let t) = action {
                    self?.snoozed[r.id] = Date().addingTimeInterval(t)
                }
            }
        }
    }

    /// 纯函数（供自检复用）：这条提醒在 now 这一刻该不该弹、以及为什么。
    /// · 勾了星期：命中勾选星期 + 已到点 + 错过的仍在 3 分钟补弹窗口内。
    /// · 没勾星期：一次性 —— 只在 `oneShotDay` 当天；当天不论迟多久都补弹一次（错过一整天＝那天不再提醒）。
    static func dueCheck(_ r: Reminder, now: Date, calendar cal: Calendar = .current)
        -> (due: Bool, lateMinutes: Int, reason: String) {
        let oneShot = r.weekdays.isEmpty

        if oneShot {
            guard let day = r.oneShotDay else { return (false, 0, "未设置提醒日") }
            let today = Reminder.dayString(now)
            guard day == today else {
                return (false, 0, day < today ? "一次性提醒已到期（原定 \(day)）" : "还没到提醒日（\(day)）")
            }
            // 弹过就落盘了 → 同一天重启 App 不再重复弹
            if r.firedOn == today { return (false, 0, "今天已提醒过") }
        } else {
            let weekday = cal.component(.weekday, from: now)
            guard r.fires(on: weekday) else { return (false, 0, "今天不在勾选的星期里") }
        }

        guard let target = cal.date(bySettingHour: r.hour, minute: r.minute, second: 0, of: now) else {
            return (false, 0, "时刻无效")
        }
        guard now >= target else { return (false, 0, "还没到点") }

        let late = Int(now.timeIntervalSince(target) / 60)
        if !oneShot && now.timeIntervalSince(target) >= 180 {
            return (false, 0, "错过超过 3 分钟")
        }
        if oneShot {
            return (true, late, late < 1 ? "一次性提醒到点" : "一次性提醒补弹（已过 \(late) 分钟）")
        }
        return (true, late, late < 1 ? "到点提醒" : "补弹（已过 \(late) 分钟）")
    }

    /// 用户在弹窗上的选择
    private enum AlertAction {
        case done                    // 马上处理：本次提醒结束
        case snooze(TimeInterval)    // 等会处理：按所选间隔再弹
    }

    /// 弹窗按钮「等会处理」对应的稍后间隔选项（默认 30 分钟）
    private static let snoozeOptions: [(label: String, interval: TimeInterval)] = [
        ("10 分钟后", 600),
        ("30 分钟后", 1800),
        ("1 小时后", 3600),
        ("2 小时后", 7200),
        ("明天再提醒", 86400),
    ]
    private static let defaultSnoozeIndex = 1   // 30 分钟

    /// 测试用：立刻弹一次这条提醒的窗口，用来确认「到点弹窗」链路正常。
    /// 不写 `lastFired`（不影响正常的到点判断），也不产生「稍后提醒」。
    func fireTest(_ r: Reminder) {
        fire(r, isRepeat: false, isTest: true) { _ in }
    }

    /// 弹出提醒窗口（**非模态**：不锁面板，用户可先切到教师助手处理完再回来点）。
    /// isRepeat=true 表示这是「等会处理」后的再次提醒；用户选择通过 onFinish 回调。
    private func fire(_ r: Reminder, isRepeat: Bool = false, isTest: Bool = false,
                      onFinish: @escaping (AlertAction) -> Void) {
        // 已在主队列（DispatchSourceTimer 队列为 .main）
        let time = String(format: "%02d:%02d", r.hour, r.minute)

        // 同一条提醒已有窗口在等用户处理：只置顶，不重复弹
        if let w = windows[r.id] {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let trimmed = r.url.trimmingCharacters(in: .whitespaces)
        let url = URL(string: trimmed)
        let validURL = (!trimmed.isEmpty && url?.scheme != nil) ? url : nil

        let view = ReminderAlertView(
            title: (isRepeat ? "稍后提醒 · " : "提醒 · ") + time,
            message: r.title,
            isRepeat: isRepeat,
            options: Self.snoozeOptions,
            defaultIndex: Self.defaultSnoozeIndex,
            hasURL: validURL != nil,
            onDone: { [weak self] in
                self?.closeWindow(for: r.id)
                onFinish(.done)
            },
            onSnooze: { [weak self] t in
                self?.closeWindow(for: r.id)
                onFinish(.snooze(t))
            },
            onOpenURL: validURL == nil ? nil : { [weak self] in
                if let u = validURL { NSWorkspace.shared.open(u) }
                self?.closeWindow(for: r.id)
                onFinish(.done)                      // 打开链接视为已处理
            })

        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 180),
                           styleMask: [.titled, .closable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.contentViewController = hosting
        win.title = "提醒"
        // 置顶到自家浮层（popover≈101）之上，避免被教师助手面板挡住（.floating=3 会被压住）
        win.level = NSWindow.Level(rawValue: 102)
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.hidesOnDeactivate = false               // 切到其它应用时仍保留在屏幕
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.animationBehavior = .default

        // 点红叉关闭 = 按默认间隔稍后再提醒（避免随手关掉就漏掉事情）
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: win, queue: .main
        ) { [weak self] note in
            guard let self,
                  let w = note.object as? NSWindow,
                  let id = self.windows.first(where: { $0.value === w })?.key else { return }
            self.windows.removeValue(forKey: id)
            if let obs = self.closeObservers.removeValue(forKey: id) {
                NotificationCenter.default.removeObserver(obs)
            }
            // 测试弹窗不产生「稍后提醒」
            guard !isTest else { return }
            let def = Self.snoozeOptions[Self.defaultSnoozeIndex].interval
            self.snoozed[id] = Date().addingTimeInterval(def)
        }
        closeObservers[r.id] = token
        windows[r.id] = win

        // 尺寸按内容自适应后，放到屏幕右上角；多个提醒纵向错开
        DispatchQueue.main.async {
            let size = hosting.view.fittingSize
            win.setContentSize(NSSize(width: 400, height: max(160, size.height)))
            if let screen = NSScreen.main ?? NSScreen.screens.first {
                let vf = screen.visibleFrame
                let x = vf.maxX - win.frame.width - 16
                var y = vf.maxY - 44 - win.frame.height
                y -= CGFloat(max(0, self.windows.count - 1)) * 20
                y = max(y, vf.minY + 12)
                win.setFrameOrigin(NSPoint(x: x, y: y))
            }
        }

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSSound(named: .init("Ping"))?.play()       // 轻提示音
    }

    /// 关闭某条提醒的窗口（按钮点击路径）
    private func closeWindow(for id: UUID) {
        if let obs = closeObservers.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(obs)
        }
        guard let w = windows.removeValue(forKey: id) else { return }
        w.close()
    }
}
