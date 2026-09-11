import AppKit

// MARK: - 文件面板 / 弹窗 置顶辅助
// 背景：教师助手是菜单栏 App（NSApp.setActivationPolicy(.accessory)）。
// accessory 应用没有 Dock、不在「前台」，文件面板 / 弹窗经常被自家浮层或独立窗口挡住。
// 解决：① 准备时主动关闭 popover；② NSApp 抢焦点；③ 把所有面板/弹窗的 window.level
// 提到 .screenSaver(=1000)——远高于 NSPopover 实际层级，避免被自家任何界面压住。
enum PanelHelper {
    /// 高于 NSPopover（其窗口层级约 101-103，甚至 .normal+canJoinAllSpaces）。
    /// 用 .screenSaver=1000 确保稳压 popover，且不会盖住系统 Spotlight/通知面板。
    private static let abovePopover = NSWindow.Level.screenSaver

    /// 跑文件面板/弹窗前的通用准备（关闭可见的 popover、激活 app）
    static func prepare() {
        // 1. 关掉 popover，避免它继续抢层级
        if let pop = AppDelegate.sharedPopover, pop.isShown {
            pop.performClose(nil)
        }
        // 2. 关掉可选的独立窗口
        PanelWindowController.shared.dismissIfShown()
        // 3. 抢焦点（菜单栏 App 默认不能聚焦，必须 activate）
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 把一个面板提升到 .screenSaver(1000) 最前（不与系统 launcher/屏幕保护冲突）
    static func bringFront(_ panel: NSPanel) {
        panel.level = abovePopover
        panel.hidesOnDeactivate = false
        panel.collectionBehavior.insert(.fullScreenAuxiliary)
        panel.collectionBehavior.insert(.moveToActiveSpace)
        panel.makeKeyAndOrderFront(nil)
        SeatingStore.seatLog("弹窗置顶：文件面板 level=\(panel.level.rawValue)（press ScreenSaver=1000）")
    }

    /// NSAlert 同样提到 .screenSaver，再 makeKey 让它立刻抢到焦点
    static func bringFront(_ alert: NSAlert) {
        let w = alert.window
        w.level = abovePopover
        w.hidesOnDeactivate = false
        w.collectionBehavior.insert(.fullScreenAuxiliary)
        w.collectionBehavior.insert(.moveToActiveSpace)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        SeatingStore.seatLog("弹窗置顶：NSAlert「\(alert.messageText)」level=\(w.level.rawValue) frame=\(w.frame)")
    }
}
