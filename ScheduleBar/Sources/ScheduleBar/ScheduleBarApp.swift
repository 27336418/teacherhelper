import AppKit
import SwiftUI

// MARK: - App Entry
// 菜单栏常驻应用（代理模式，不显示 Dock 图标）
@main
struct ScheduleBarApp {
    static func main() {
        // 1) 进入 main() 第一件事：关掉 AppKit 的「AutoFill 启发式扫描」。
        // 我们的菜单栏浮层里一旦含几个文本框，macOS 就会在窗口成为 key 时走 `nextValidKeyView`
        // 遍历整个 SwiftUI 视图树寻找密码 / 联系人候选键。在快速打开面板时
        // 这条 walk 常常阻塞主线程 1-2 秒（用户能在 M1 Mac 上拿到 hang 报告）。
        // 关闭它是 Alacritty/VSCode 等同样做法：写一个本进程默认值即可，零侵入。
        // 入口越早越好（必须在 NSApplication.shared 创建之前/同期）。
        UserDefaults.standard.register(defaults: [
            "NSAutoFillHeuristicControllerEnabled": false
        ])

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
        // 座位拖拽 / 取消分组自检（纯逻辑，临时数据目录）：--selftest-seating-drag
        if args.contains("--selftest-seating-drag") {
            SelfTest.runSeatingDragCheck()
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
        // 工位拖动对换自检（纯逻辑，改后还原 offices.json）：--selftest-offices
        if args.contains("--selftest-offices") {
            SelfTest.runOfficeSeatCheck()
            return
        }
        // 教师课表自检（纯逻辑 + 临时数据目录）：--selftest-teacher
        if args.contains("--selftest-teacher") {
            SelfTest.runTeacherCheck()
            return
        }
        // 教师课表：解析一份 xlsx 长表（--import-teacher <xlsx> [--write]）
        if let i = args.firstIndex(of: "--import-teacher"), i + 1 < args.count {
            SelfTest.importTeacherFile(args[i + 1], write: args.contains("--write"))
            return
        }
        // 师资单元格颜色自检（纯逻辑，临时数据目录）：--selftest-staff
        if args.contains("--selftest-staff") {
            SelfTest.runStaffColorCheck()
            return
        }
        // 统一保存中心自检（纯逻辑，不触碰真实数据文件）：--selftest-save
        if args.contains("--selftest-save") {
            SelfTest.runSaveCheck()
            return
        }
        // 保存按钮两种状态离屏渲染（临时取证）：--render-save-button <out.png>
        if let i = args.firstIndex(of: "--render-save-button"), i + 1 < args.count {
            if #available(macOS 14.0, *) {
                MainActor.assumeIsolated { CellPreview.renderSaveButton(to: args[i + 1]) }
            } else {
                print("✗ --render-save-button 需要 macOS 14+")
            }
            return
        }
        // 课表单元格「同内容高亮」离屏渲染取证（不依赖屏幕是否解锁）：--render-cells <out.png>
        // 纯视觉改动必须靠它验证 —— 逻辑自检看不出一圈「本色描边」等于没画。
        if let i = args.firstIndex(of: "--render-cells"), i + 1 < args.count {
            if #available(macOS 14.0, *) {
                MainActor.assumeIsolated {
                    CellPreview.renderScheduleCells(to: args[i + 1])
                }
            } else {
                print("✗ --render-cells 需要 macOS 14+（仅诊断用，不影响 App 本体运行）")
            }
            return
        }

        // 教师工位工具栏（三行布局）离屏渲染取证：--render-office-toolbar <out.png>
        if let i = args.firstIndex(of: "--render-office-toolbar"), i + 1 < args.count {
            if #available(macOS 14.0, *) {
                MainActor.assumeIsolated {
                    CellPreview.renderOfficeToolbar(to: args[i + 1])
                }
            } else {
                print("✗ --render-office-toolbar 需要 macOS 14+（仅诊断用，不影响 App 本体运行）")
            }
            return
        }

        // 提醒弹窗视觉自检：--fire-reminder-test [提示文字]
        // 启动 1.2 秒后弹一次真实提醒窗口来取证（**不写盘、不动 reminders.json、不影响到点判断**），
        // 锁屏/不方便手动点「测试弹窗」时用它。「未勾星期的提醒到底会不会弹」就靠它验。
        if let i = args.firstIndex(of: "--fire-reminder-test") {
            AppDelegate.fireTestTitle =
                (i + 1 < args.count && !args[i + 1].hasPrefix("--")) ? args[i + 1] : "测试提醒（--fire-reminder-test）"
        }

        // 启动即停在指定板块：--tab <板块名>（如 --tab 教师课表）
        // 截图取证用：比合成点击侧栏坐标稳得多（popover 每次交互都会重定位，坐标会偏）。
        if let i = args.firstIndex(of: "--tab"), i + 1 < args.count {
            AppDelegate.initialTabName = args[i + 1]
            SaveHub.log("启动参数：--tab = \(args[i + 1])（将停在对应板块）")
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
        SaveHub.shared.saveIfNeeded(reason: "关闭独立窗口")
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
    /// 上次收起面板时是否留有「未完成的拖动」→ 下次展开重建面板窗口（丢弃残留拖拽会话）
    private var needsFreshPopoverWindow = false
    /// 供独立窗口使用：打开窗口前先收起浮层（两者互斥）
    static weak var sharedPopover: NSPopover?
    /// 命令行 --fire-reminder-test 传入的提示文字（非 nil 时启动后弹一次测试提醒，不写盘）
    static var fireTestTitle: String?
    /// 命令行 --tab <板块名> 指定启动后停在哪个板块（如「教师课表」）。
    /// 用途：截图取证时不必靠「合成点击侧栏坐标」——坐标在这台机器上会偏（popover 每次重定位）。
    static var initialTabName: String?

    /// 退出前兜底：把还没保存的改动写盘（忘了点「保存」也绝不丢数据）
    func applicationWillTerminate(_ notification: Notification) {
        SaveHub.shared.saveIfNeeded(reason: "退出应用")
    }

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
        editMenu.addItem(NSMenuItem.separator())
        // 保存：把各板块的改动立刻写入磁盘（不点也不会丢 —— 停手 8 秒 / 收起面板 / 退出前自动保存）
        let saveItem = NSMenuItem(title: "保存改动",
                                  action: #selector(saveAllNow),
                                  keyEquivalent: "s")
        saveItem.target = self
        editMenu.addItem(saveItem)
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu

        popover = makePopover()

        // 拖拽会话守护：切到别的 App（录屏软件等）之后仍能正常拖动对换。
        // 详见 Services/DragSessionGuard.swift 的说明（accessory App + NSPopover 的 key 问题）。
        DragSessionGuard.install()

        // 通知中心代理 + 启动时按已保存提醒重建系统通知
        NotificationScheduler.shared.requestPermission()
        NotificationScheduler.shared.scheduleAll()
        // 应用内弹窗轮询（到点必弹，不依赖系统通知权限）
        ReminderFirer.shared.start()
        // 提醒弹窗视觉自检（--fire-reminder-test）：只弹一次，不写盘、不登记 lastFired
        if let title = AppDelegate.fireTestTitle {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let now = Date()
                let cal = Calendar.current
                let r = Reminder(title: title,
                                 hour: cal.component(.hour, from: now),
                                 minute: cal.component(.minute, from: now),
                                 weekdays: [], url: "")
                ReminderFirer.shared.fireTest(r)
                writeLaunchLog("提醒：--fire-reminder-test 弹出测试提醒「\(title)」（未写入 reminders.json）")
            }
        }
        // 启动 3 秒后把「定时提醒」同步到 Mac 自带日历（首次会弹一次日历授权）
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            CalendarSyncService.shared.syncAllReminders(reason: "启动")
        }
        writeLaunchLog("面板/服务初始化完成")

        // 启动后自动展开面板，让用户立即看到界面（点其他位置自动关闭）
        // （--fire-reminder-test 取证时不展开，免得浮层挡住提醒窗口）
        if Self.fireTestTitle == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let btn = self.statusItem?.button else { return }
                self.showPopover(relativeTo: btn, reason: "启动")
            }
        }
    }

    /// 新建面板（全新的内容视图 + 全新的 popover 窗口）。
    /// 「拖动被硬中断」之后重建面板，可以连同窗口上残留的拖拽会话状态一起丢掉。
    private func makePopover() -> NSPopover {
        let hosting = NSHostingController(rootView: AnyView(Self.makeRootView()))
        let pop = NSPopover()
        pop.contentViewController = hosting
        pop.behavior = .transient
        pop.contentSize = NSSize(width: 880, height: 720)
        pop.animates = true
        pop.delegate = self            // 展示后补齐「App 激活 + 窗口 key」，否则拖不动
        AppDelegate.sharedPopover = pop
        return pop
    }

    /// 展开面板的统一入口：**先激活 App，再把面板窗口设为 key**。
    /// SwiftUI 的 `.onDrag` 只在「App 处于激活状态 + 源窗口是 key window」时才起得来；
    /// 只调 makeKey() 而不激活 App，会让之后所有拖动静默失效（点击、输入仍正常，
    /// 所以很容易被误判成「只有拖拽坏了」）。
    private func showPopover(relativeTo button: NSButton, reason: String) {
        // 上一轮拖动是被打断的（切走 App 时半途中断）→ 换一个全新窗口，
        // 彻底丢掉可能残留的拖拽会话，保证这次一定能拖。
        if needsFreshPopoverWindow {
            popover?.delegate = nil
            popover = makePopover()
            needsFreshPopoverWindow = false
            writeLaunchLog("面板：上次拖动被中断，已重建面板窗口")
        }
        guard let popover, !popover.isShown else { return }
        DragSessionGuard.activateApp()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        DragSessionGuard.makeKey(popover.contentViewController?.view.window)
        writeLaunchLog("\(reason)：面板已展开（App 激活 + 窗口 key）")
    }

    // ⌘S：立刻把全部板块的未保存改动写入磁盘
    @objc private func saveAllNow() {
        SaveHub.shared.saveNow(reason: "菜单 ⌘S")
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
            showPopover(relativeTo: button, reason: "点击菜单栏")
        }
    }
}

// MARK: - NSPopoverDelegate：把「App 激活 + 窗口 key」补在面板真正显示之后
extension AppDelegate: NSPopoverDelegate {
    func popoverDidShow(_ notification: Notification) {
        DragSessionGuard.activateApp()
        DragSessionGuard.makeKey(popover?.contentViewController?.view.window)
    }

    /// 面板收起 → 任何半途中的拖动都作废，清掉残影，避免下一轮换错位置；
    /// 若确实有一次被打断的拖动，下次展开时换一个全新窗口，彻底复位拖拽会话。
    func popoverDidClose(_ notification: Notification) {
        SaveHub.shared.saveIfNeeded(reason: "面板收起")
        let interrupted = DragSessionGuard.consumeDragInterrupted()
        let hadDrag = DragSessionGuard.resetDragState(reason: "面板收起")
        if interrupted || hadDrag { needsFreshPopoverWindow = true }
    }
}
