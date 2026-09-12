import AppKit

// MARK: - 拖拽会话守护（修复「切到别的 App 后拖不动」）
//
// 症状（2026-09-12 用户报告）：
//   启动后立刻拖动对换「座位 / 工位 / 课表」都正常；
//   一旦打开录屏软件或其他 App，再回来就**再也拖不动**（点击、输入仍然正常）。
//
// 根因：教师助手是菜单栏 App（NSApp.setActivationPolicy(.accessory)）+ NSPopover。
//   SwiftUI 的 `.onDrag` 底层要发起 AppKit 的 NSDraggingSession，而它**必须**同时满足
//   「App 处于激活状态」+「源窗口是 key window」。切到别的 App 之后：
//     ① transient popover 被系统自动收起；
//     ② 再点菜单栏图标重开面板时，代码只调了 `makeKey()`，**没有激活 App**——
//        而 accessory App 在未激活时 makeKey() 是无效的（窗口不会真的成为 key），
//        于是后续所有 `.onDrag` 都起不来，表现就是「拖不动」。因为点击/输入不依赖这两条，
//        所以很容易误判成「只有拖拽坏了」。
//     ③ 半途被打断的拖动还会把 `dragOrigin / dragSnapshot` 留在 store 里。
//
// 处理：
//   ① 本地 mouseDown 监视器：鼠标一落进自家窗口，先补齐「App 激活 + 窗口 key」再放行事件
//      ——保证拖动能在正确的时机起手（也顺带修掉「第一下点击被吞掉」的体验问题）；
//   ② App 失去激活 / 窗口失去 key / 面板收起 → 广播 `.dragSessionDidReset` 并清空
//      各 store 的拖动残影（只复位来源与快照，不改单元格内容、不登记撤销）。
enum DragSessionGuard {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true

        // ① 鼠标按下（左右键都算）：抢在事件派发前把 App 激活 + 窗口设为 key
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            activateApp()
            makeKey(event.window)
            return event
        }

        // ② 切到别的 App（录屏软件、课件、浏览器…）→ 拖动会话作废
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: nil, queue: .main) { _ in
            if resetDragState(reason: "App 失去激活") { dragWasInterrupted = true }
        }

        // ③ 回到自己：立刻补齐 key，用户不必再点第二次才能拖
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { _ in
            guard let pop = AppDelegate.sharedPopover, pop.isShown else { return }
            makeKey(pop.contentViewController?.view.window)
        }

        // ④ 窗口失去 key（被别的窗口顶掉、面板关闭等）→ 清残影
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                               object: nil, queue: .main) { _ in
            if resetDragState(reason: "窗口失去 key") { dragWasInterrupted = true }
        }
    }

    /// 有一次拖动因为「切走 App / 窗口失去 key」被打断（没有走完成功落点）。
    /// AppDelegate 据此在下次展开面板时换一个全新窗口，彻底复位 AppKit 的拖拽会话。
    private(set) static var dragWasInterrupted = false

    /// 读取并清空「拖动被打断」标记
    static func consumeDragInterrupted() -> Bool {
        let v = dragWasInterrupted
        dragWasInterrupted = false
        return v
    }

    /// 激活本 App（菜单栏 App 默认不在前台，必须显式激活窗口才会成为 key）
    static func activateApp() {
        guard !NSApp.isActive else { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 把窗口设为 key（App 未激活时 makeKey 无效，所以调用前要先 activateApp）。
    /// 用 makeKeyAndOrderFront 而不是 makeKey：`activate` 是异步生效的，
    /// 这样即使此刻 App 还没真正激活，窗口也会在激活的瞬间成为 key。
    static func makeKey(_ window: NSWindow?) {
        guard let w = window, w.isVisible else { return }
        if !w.isKeyWindow { w.makeKeyAndOrderFront(nil) }
    }

    /// 清掉所有模块的「拖动中」残影：来源、快照、落点高亮。
    /// 拖动过程中本来就没有改过任何单元格内容，所以这里只复位状态，不涉及撤销。
    /// - Returns: 之前是否真的有一次**未完成**的拖动（据此判断要不要重建面板窗口，
    ///   因为被硬中断的 AppKit 拖拽会话只有把窗口丢掉才能彻底复位）
    @discardableResult
    static func resetDragState(reason: String) -> Bool {
        var had = ScheduleStore.shared.cancelCellDrag()
        if ClassScheduleStore.shared.cancelCellDrag() { had = true }
        if OfficeLayoutStore.shared.cancelSeatDrag() { had = true }
        if ClassroomStore.shared.cancelDrag() { had = true }
        // 座位表的拖动标记保存在视图 @State 里，用通知让它一起清掉
        NotificationCenter.default.post(name: .dragSessionDidReset, object: nil)
        writeLog("拖动状态已复位（\(reason)\(had ? "，此前有一次未完成的拖动" : "")）")
        return had
    }

    private static func writeLog(_ line: String) {
        let dir = NSHomeDirectory() + "/Library/Logs"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/教师助手.log"
        let stamp: String = {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f.string(from: Date())
        }()
        guard let data = "[\(stamp)] \(line)\n".data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: path), let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

extension Notification.Name {
    /// 拖拽会话被强制中断（切走 App / 窗口失去 key / 面板收起）→ 视图清掉自己的拖动标记
    static let dragSessionDidReset = Notification.Name("DragSessionDidReset")
}
