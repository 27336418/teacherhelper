import AppKit

// MARK: - 拖拽会话守护（修复「拖一次之后就拖不动 / 切到别的 App 后拖不动」）
//
// 症状（2026-09-12 用户报告，macOS 26.5）：
//   启动后第一次拖动对换正常；**之后必须切到桌面再点回面板才能再拖一次**。
//
// 根因有两条，缺一不可：
//   ① SwiftUI 的 `.onDrag` 底层要发起 AppKit 拖拽会话，它要求
//      「App 处于激活状态 + 源窗口是 key window」。菜单栏 App 是
//      `.accessory` + NSPopover：面板一旦不是 key（点过别处、拖过一次后），
//      后续 `.onDrag` 就静默失效——点击、双击编辑、输入全都还正常，
//      所以极容易被误判成「只有拖拽坏了」。
//   ② 落点处理里做了异步换位（loadObject → DispatchQueue.main.async），
//      拖拽会话在 macOS 26 上因此不会复位，`.onDrag` 便不再触发。
//      这一条在 DragSwapSupport.swift 里改成同步换位解决。
//
// 本文件负责 ①：
//   - 鼠标按下后（**异步**，避免打断 SwiftUI 手势起手）补齐「App 激活 + 窗口 key」；
//   - 兜底轮询：面板显示期间，只要「没有任何窗口是 key」就补一次；
//   - 拖拽提交后立即补一次；
//   - 切走 App / 面板收起 → 清空拖动残影与 DragContext（只复位状态，不动数据）。
//
// ⚠️ 不要用「窗口失去 key 就复位拖动状态」的做法：菜单栏窗口会频繁失去 key
//    （点内部浮层、编辑文本等），那会在拖动进行中把来源清掉，落点就换不了。
// ⚠️ 也不要在鼠标按下的**同步**阶段 makeKeyAndOrderFront：那会重新 orderFront，
//    打断 SwiftUI 的拖拽手势起手。
enum DragSessionGuard {
    private static var installed = false
    private static var keyWatch: Timer?

    static func install() {
        guard !installed else { return }
        installed = true

        // ① 鼠标按下（左右键都算）：
        //    - 同步清掉上一轮可能残留的 DragContext（新拖拽会在 .onDrag 里重新登记，
        //      所以这里清是安全的；能避免「上一次拖到别的 App 之后，来源一直留在内存里」）；
        //    - 异步补齐「App 激活 + 窗口 key」（同步做会 orderFront，打断 SwiftUI 手势起手）。
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            DragContext.cancel()
            let win = event.window
            DispatchQueue.main.async { ensureInteractive(win, reason: "鼠标按下") }
            return event
        }

        // ② 切到别的 App（录屏软件、课件、浏览器…）→ 拖动会话作废
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: nil, queue: .main) { _ in
            DragContext.cancel()
            if resetDragState(reason: "App 失去激活") { dragWasInterrupted = true }
        }

        // ③ 回到自己：立刻补齐 key，用户不必再点第二次才能拖
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { _ in
            DispatchQueue.main.async { ensureInteractive(nil, reason: "App 重新激活") }
        }

        // ④ 兜底轮询：面板显示期间每 0.5 秒检查一次「有没有窗口是 key」。
        //    轮询**不激活 App**（避免用户切到别的 App 时把焦点抢回来），只在自己已经在前台时补 key。
        let t = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            ensureInteractive(nil, reason: "轮询", allowActivate: false)
        }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        keyWatch = t
    }

    /// 有一次拖动因为「切走 App」被打断（没有走完成功落点）。
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

    /// 把窗口设为 key（App 未激活时 makeKey 无效，所以调用前要先 activateApp）
    static func makeKey(_ window: NSWindow?) {
        guard let w = window, w.isVisible else { return }
        if !w.isKeyWindow { w.makeKeyAndOrderFront(nil) }
    }

    /// 面板窗口（菜单栏浮层的内容窗口）
    static var panelWindow: NSWindow? {
        AppDelegate.sharedPopover?.contentViewController?.view.window
    }

    /// 当前是不是「没有任何窗口是 key」（菜单栏图标窗口抢了 key 也算）
    private static func keyNeedsRestoring() -> Bool {
        guard let kw = NSApp.keyWindow else { return true }
        if kw === panelWindow { return false }
        // 菜单栏图标自己的窗口（NSStatusBarWindow）会短暂抢走 key，这种情况要补回来；
        // 其它窗口（系统弹窗 / SwiftUI 内部浮层）保持原状，别去抢。
        let cls = String(describing: type(of: kw))
        return cls.contains("StatusBar")
    }

    /// 补齐「App 激活 + 面板窗口 key」。
    /// - Parameter allowActivate: 是否允许把 App 拉到前台。轮询时传 false
    ///   （用户可能正切在别的 App 上，只补 key、不抢焦点）。
    static func ensureInteractive(_ window: NSWindow?, reason: String, allowActivate: Bool = true) {
        guard let pop = AppDelegate.sharedPopover, pop.isShown else { return }
        // 有模态弹窗（NSAlert / 打开面板 / 保存面板）时绝对不要抢 key
        guard NSApp.modalWindow == nil else { return }
        if !NSApp.isActive {
            guard allowActivate else { return }
            NSApp.activate(ignoringOtherApps: true)
        }
        guard keyNeedsRestoring() else { return }
        let w = window ?? panelWindow
        guard let w, w.isVisible else { return }
        w.makeKeyAndOrderFront(nil)
        log("面板窗口补 key（\(reason)）")
    }

    /// 拖拽提交完成（落点处理结束）→ 立刻补一次 key。
    /// 这一步很关键：AppKit 的拖拽会话结束后，面板窗口常常不再是 key，
    /// 于是「下一次拖拽」就起不来了（用户看到的正是这个现象）。
    static func panelDropDidFinish(reason: String) {
        log("拖拽提交：\(reason)")
        DispatchQueue.main.async {
            ensureInteractive(nil, reason: "拖拽提交后")
        }
    }

    /// 清掉所有模块的「拖动中」残影：来源、快照、落点高亮。
    /// 拖动过程中本来就没有改过任何单元格内容，所以这里只复位状态，不涉及撤销。
    /// - Returns: 之前是否真的有一次**未完成**的拖动
    @discardableResult
    static func resetDragState(reason: String) -> Bool {
        DragContext.cancel()
        var had = ScheduleStore.shared.cancelCellDrag()
        if ClassScheduleStore.shared.cancelCellDrag() { had = true }
        if OfficeLayoutStore.shared.cancelSeatDrag() { had = true }
        if ClassroomStore.shared.cancelDrag() { had = true }
        // 座位表的拖动标记保存在视图 @State 里，用通知让它一起清掉
        NotificationCenter.default.post(name: .dragSessionDidReset, object: nil)
        if had { log("拖动状态已复位（\(reason)，此前有一次未完成的拖动）") }
        return had
    }

    /// 统一日志（与启动日志同一个文件，便于排查）
    static func log(_ line: String) {
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
    /// 拖拽会话被强制中断（切走 App / 面板收起）→ 视图清掉自己的拖动标记
    static let dragSessionDidReset = Notification.Name("DragSessionDidReset")
}
