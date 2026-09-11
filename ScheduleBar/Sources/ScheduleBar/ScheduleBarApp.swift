import AppKit
import SwiftUI

// MARK: - App Entry
// 菜单栏常驻应用（代理模式，不显示 Dock 图标）
@main
struct ScheduleBarApp {
    static func main() {
        // 隐藏自检入口（不启动 UI）：--selftest-import <xlsx 路径>
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest-import"), i + 1 < args.count {
            SelfTest.runImport(path: args[i + 1])
            return
        }
        if args.contains("--selftest-seating") {
            SelfTest.runSeatingCheck()
            return
        }
        // 节次规整自检（只读预演，不改数据）：--selftest-periods
        if args.contains("--selftest-periods") {
            SelfTest.runPeriodCheck()
            return
        }
        // 下载模板结构自检（只读）：--selftest-templates
        if args.contains("--selftest-templates") {
            SelfTest.runTemplateCheck()
            return
        }
        if let i = args.firstIndex(of: "--selftest-update") {
            let repo = (i + 1 < args.count && !args[i + 1].hasPrefix("--")) ? args[i + 1] : nil
            SelfTest.runUpdateCheck(override: repo)
            return
        }
        // 定时提醒 → 系统日历 链路自检（只读，不写入日历）：--selftest-calendar
        if args.contains("--selftest-calendar") {
            SelfTest.runCalendarSyncCheck()
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // 仅菜单栏，无 Dock 图标
        app.run()
    }
}

private func writeLaunchLog(_ line: String) {
    let dir = NSHomeDirectory() + "/Library/Logs"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = dir + "/教师助手.log"
    let stamp: String = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f.string(from: Date())
    }()
    let text = "[\(stamp)] \(line)\n"
    if let data = text.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: path), let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

// MARK: - Dock 图标开关（持久化到 UserDefaults）
enum DockPrefs {
    static let key = "showDockIcon"

    static var show: Bool { UserDefaults.standard.bool(forKey: key) }

    static func set(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
        apply()
    }

    /// 应用激活策略：有 Dock 图标 / 独立窗口 → regular；否则只留菜单栏
    static func apply() {
        let policy: NSApplication.ActivationPolicy =
            (show || PanelWindowController.shared.isOpen) ? .regular : .accessory
        NSApp.setActivationPolicy(policy)
    }
}

// MARK: - 独立窗口（可最小化到 Dock）
final class PanelWindowController: NSObject, NSWindowDelegate {
    static let shared = PanelWindowController()

    private var window: NSWindow?
    var isOpen: Bool { window != nil }

    func open() {
        // 与菜单栏浮层互斥：打开窗口前先收起浮层，避免同屏两份界面
        AppDelegate.sharedPopover?.performClose(nil)
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            w.deminiaturize(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 760),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "教师助手"
        w.contentViewController = NSHostingController(rootView: AnyView(AppDelegate.makeRootView()))
        w.delegate = self
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)   // 有窗口 → 出现在 Dock，最小化后进 Dock
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    func close() {
        window?.close()
    }

    /// 静默关闭（不展示 UI）：用于打开文件面板前腾出前面板位置
    func dismissIfShown() {
        guard let w = window else { return }
        // 不调用 windowWillClose（避免误关 Dock 图标）
        w.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        DockPrefs.apply()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    /// 撤销项仅在「有可撤销操作」且「当前焦点不在文本输入框」时可用
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undoLastAction) {
            guard UndoService.shared.canUndo else { return false }
            if let fr = NSApp.keyWindow?.firstResponder, fr is NSTextView { return false }
            return true
        }
        return true
    }
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    /// 供独立窗口使用：打开窗口前先收起浮层（两者互斥）
    static weak var sharedPopover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let sysVer = ProcessInfo.processInfo.operatingSystemVersionString
        writeLaunchLog("启动：macOS \(sysVer)")
        DockPrefs.apply()   // 用户开了「Dock 图标」就显示

        // 启动 8 秒后悄悄自动检测升级（不打扰用户，只在有新版本时才弹面板）
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            if GitHubUpdateService.shared.isConfigured {
                GitHubUpdateService.shared.checkForUpdates(auto: true) { _ in }
            } else {
                writeLaunchLog("启动：未配置 GitHub 仓库，跳过自动检查更新")
            }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            let img = NSImage(systemSymbolName: "tablecells.fill",
                              accessibilityDescription: "教师助手")
            img?.isTemplate = true
            button.image = img
            // 图标缺失（系统版本较老没有该符号）时，用文字兜底，保证菜单栏一定看得见
            if img == nil { button.title = "教师助手" }
            button.toolTip = "教师助手"
            // 左键弹面板；右键也弹面板（不劫持给菜单）
            button.action = #selector(togglePopover(_:))
            button.target = self
            writeLaunchLog("菜单栏图标已创建 图标:\(img != nil)")
        } else {
            writeLaunchLog("⚠️ 菜单栏图标创建失败")
        }

        // 全局主菜单：「退出」+「编辑」。菜单栏应用必须有编辑菜单，⌘C/⌘V/⌘X 才能路由到输入框（否则网址等无法粘贴）
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "教师助手")
        appMenu.addItem(NSMenuItem(title: "退出教师助手",
                                    action: #selector(NSApplication.terminate(_:)),
                                    keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenu.addItem(NSMenuItem.separator())
        // 撤销：删除等破坏性操作的全局回退（文本框内有焦点时让位给系统文字撤销）
        let undoItem = NSMenuItem(title: "撤销",
                                  action: #selector(undoLastAction),
                                  keyEquivalent: "z")
        undoItem.target = self
        editMenu.addItem(undoItem)
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu

        let hosting = NSHostingController(rootView: AnyView(Self.makeRootView()))

        let pop = NSPopover()
        pop.contentViewController = hosting
        pop.behavior = .transient
        pop.contentSize = NSSize(width: 880, height: 720)
        pop.animates = true
        popover = pop
        AppDelegate.sharedPopover = pop

        // 通知中心代理 + 启动时按已保存提醒重建系统通知
        NotificationScheduler.shared.requestPermission()
        NotificationScheduler.shared.scheduleAll()
        // 应用内弹窗轮询（到点必弹，不依赖系统通知权限）
        ReminderFirer.shared.start()
        // 启动 3 秒后把「定时提醒」同步到 Mac 自带日历（首次会弹一次日历授权）
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            CalendarSyncService.shared.syncAllReminders(reason: "启动")
        }
        writeLaunchLog("面板/服务初始化完成")

        // 启动后自动展开面板，让用户立即看到界面（点其他位置自动关闭）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let pop = self.popover, let btn = self.statusItem?.button else { return }
            if !pop.isShown {
                pop.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
                pop.contentViewController?.view.window?.makeKey()
                writeLaunchLog("启动后自动展开面板 ✓")
            }
        }
    }

    // ⌘Z：回退最近一次删除 / 清空 / 隐藏等重要操作
    @objc private func undoLastAction() {
        UndoService.shared.undo()
    }

    // MARK: 面板根视图（菜单栏浮层与独立窗口共用）
    fileprivate static func makeRootView() -> some View {
        SchedulePanelView()
            .environmentObject(ScheduleStore.shared)
            .environmentObject(ClassScheduleStore.shared)
            .environmentObject(ExtendScheduleStore.shared)
            .environmentObject(CardTitleStore.shared)
            .environmentObject(WeekStore.shared)
            .environmentObject(ReminderStore.shared)
            .environmentObject(OfficeLayoutStore.shared)
            .environmentObject(ClassroomStore.shared)
            .environmentObject(StaffStore.shared)
            .environmentObject(StudentStore.shared)
            .environmentObject(SeatingStore.shared)
            .environmentObject(AppCoordinator.shared)
    }

    /// 点击 Dock 图标（且没有可见窗口）→ 打开独立窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { PanelWindowController.shared.open() }
        return true
    }

    @objc private func togglePopover(_ sender: Any?) {
        TodayClock.shared.refreshNow()      // 打开面板时先校准「今天」，保证星期高亮正确
        guard let popover = popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // 与独立窗口互斥：避免同屏出现两份界面
            PanelWindowController.shared.close()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
