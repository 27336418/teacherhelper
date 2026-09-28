import SwiftUI
import AppKit

// MARK: - 板块页面的 AppKit 宿主容器（2026-09-28 性能重构）
//
// ## 为什么要这么做
// 旧做法是把所有「访问过的板块」都留在同一个 SwiftUI ZStack 里，靠 `.opacity(0)` 隐藏。
// 实测把 11 个板块的内容全换成占位色块后，21 次切换总耗时从 4632ms 掉到 **789ms** —— 说明
// 开销几乎全在「窗口里活着的页面内容量」上。而 `.opacity(0)` **只是不绘制像素**：
// 隐藏页的图层仍然挂在窗口的图层树上，CoreAnimation 每次提交照样要遍历它们，
// 所以访问过的板块越多、每页越复杂，每次切页的固定开销越大（这就是「越用越慢」的真原因）。
//
// ## 现在的做法
// **每个访问过的板块一个 `NSHostingView`，非当前页 `isHidden = true`**。
// AppKit 对隐藏视图会整棵子树跳过布局与绘制，CA 也会把隐藏图层从渲染树里剪掉 ——
// 这才是「页面还在（切回零重建）但完全不参与合成」的正确做法。
// 顺带解决一个老问题：隐藏视图不是拖拽落点，所以 2026-09-12 那套
// 「把选中页挪到 ZStack 末尾来抢拖拽落点」的 hack 不再需要。
//
// ## 实测（同一份二进制交替 A/B，`--perf-tabs`，11 板块轮播两遍 = 21 次切换，主线程耗时总计）
//   | | 本实现（NSHostingView + isHidden） | 旧实现（ZStack + opacity） |
//   |---|---|---|
//   | 总耗时 | 4463ms / 5263ms | 5910ms / 6629ms |
//   | 轻量页**热切** | **17~53ms** | 91~201ms |
//   | 重页热切 | 195~317ms | 371~434ms |
//   → 热切换（最常发生的事）快约 3~4 倍。第一遍「首次建页」略贵（多一层 hosting view 创建），
//     但总量仍然更低。
//
// ## 「页面还画不画得出来」怎么自证
// 这是结构性改造，光有性能数字不够（切页「成功」不代表画出了东西）。本机截图 / `osascript` /
// `Quartz` 三条视觉取证路都不通，于是加了**离屏渲染自检**：
// `--selftest-render`（见 `Services/PanelRenderCheck.swift`）把 11 个页面逐个渲染成位图，
// 断言「唯一色 ≥ 20 且墨点 ≥ 200」＋「恰好只有当前页不隐藏」。实测 11/11 通过
// （唯一色 167~2186、墨点 568~155016）。加 `SCHEDULEBAR_RENDER_PNG=/tmp/xxx` 还能落盘 PNG 供人眼复核。
//
// ## ⚠️ 已经用交替 A/B 逐条证伪的猜想（别再改回去）
//   · 隐藏页在布局 → 把隐藏页缩成 1×1 提议：4649ms（原 4632），没变；
//   · 隐藏页 body 被重算 → 计数器显示每页 body 整场只跑 1 次，`EquatableView` 也没用；
//   · `ForEach` 数组顺序每次变化 → 去掉「选中页挪到末尾」：4592ms，没变；
//   · 每格的 `.help` 工具提示 → 摘掉 63 个：1042ms（原 1046），没变；
//   · 满窗毛玻璃 `.withinWindow` 的整窗模糊 → 换 `.behindWindow` / 不透明纯色：差异全在漂移内；
//   · 「只留当前页 + 上一页」→ **更慢**（6281 vs 4582ms）：每次切页都要拆旧页 + 建新页。
//   ⚠️ 本机这套跑批**机器漂移很大**（同配置两次能差 900ms）→ 结论只认交替 A/B 或单调趋势。
//
// ## ⚠️ 环境对象必须**显式再注入一遍**
// `NSHostingView` 是独立的一棵 SwiftUI 树，**不会继承**外层 SwiftUI 的环境。
// 这里列的类型必须与 `ScheduleBarApp.swift` 根注入保持一致（共 12 个），少一个就会在页面
// body 里 `@EnvironmentObject` 取值时崩。
final class PanelHostContainer: NSView {
    private var hosts: [PanelTab: NSHostingView<AnyView>] = [:]

    /// 与 SwiftUI 同步：补齐新访问的页、切换可见性。
    /// - Parameter makeContent: 只在**首次**创建某页时调用一次（之后复用，切回零重建）。
    func sync(tabs: [PanelTab], selected: PanelTab, makeContent: (PanelTab) -> AnyView) {
        for tab in tabs where hosts[tab] == nil {
            let host = NSHostingView(rootView: makeContent(tab))
            host.translatesAutoresizingMaskIntoConstraints = true
            host.autoresizingMask = []
            if #available(macOS 13.0, *) { host.sizingOptions = [] }   // 尺寸由这里的 frame 决定，别让它按内容自撑
            host.frame = bounds
            addSubview(host)
            hosts[tab] = host
        }
        for (tab, host) in hosts {
            let shouldHide = (tab != selected)
            if host.isHidden != shouldHide { host.isHidden = shouldHide }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        fillSubviews()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        fillSubviews()
    }

    private func fillSubviews() {
        for v in subviews where v.frame != bounds { v.frame = bounds }
    }

    // MARK: - 渲染自证（只被 `--selftest-render` 调用，不在正常运行路径上）
    /// 一页的离屏渲染统计结果
    struct RenderStats {
        var uniqueColors = 0
        /// 出现最多的那个颜色的采样点数（背景）
        var dominantCount = 0
        var pixels = NSSize.zero
        var sampleCount = 0
        var pngPath: String?
        /// 非数字形式的失败原因（未创建 / 尺寸为 0 / 位图拿不到）
        var failureReason: String?

        var dominantShare: Double { sampleCount > 0 ? Double(dominantCount) / Double(sampleCount) : 1 }
        /// 「墨点」= 与主色不同的采样点数，也就是**真正画了东西**的量。
        /// ⚠️ 不能只看主色占比：日程提醒这类「内容只占上半屏」的页面主色占比高达 99.8%，
        ///    但那是完全正常的页面（标题＋开关＋两条提醒＋按钮），实测墨点仍有 ~550 个。
        ///    真·空白页是「唯一色 1~2 且墨点 0」。
        var inkPoints: Int { max(0, sampleCount - dominantCount) }

        /// 「真的画出内容了吗」：颜色够杂 + 墨点够多
        var looksDrawn: Bool { failureReason == nil && uniqueColors >= 20 && inkPoints >= 200 }

        var described: String {
            if let failureReason { return "✗ \(failureReason)" }
            return String(format: "唯一色 %4d  主色占比 %5.1f%%  墨点 %6d  位图 %.0f×%.0f%@",
                          uniqueColors, dominantShare * 100, inkPoints, pixels.width, pixels.height,
                          pngPath.map { "  PNG=\($0)" } ?? "")
        }
    }

    /// 把某个页面**离屏渲染**成位图并统计像素多样性（可选落盘 PNG 供人眼复核）。
    ///
    /// 为什么需要它：性能日志只能证明「切页发生了」，证明不了「新的宿主容器真的把 SwiftUI 内容画出来了」——
    /// 而本文件恰恰是一次结构性改造。本机截图 / `osascript` 置前 / `Quartz` 三条路都不可用
    /// （popover 与截图不在同一 Space、`set frontmost` 报 -10004 权限违例），所以改成**进程内**
    /// `cacheDisplay` 离屏渲染：不依赖窗口可见、不依赖录屏权限、不受 Space 影响。
    ///
    /// 判读：**唯一色极少（1~2）** 或 **主色占比≈100%** 就是「一片空白」——通常意味着
    /// 环境对象没注入、尺寸为 0、hosting view 没进布局。真实页面（有文字/边框/表格线）
    /// 会得到几百种颜色、主色占比显著低于 100%。见 `Services/PanelRenderCheck.swift`。
    func renderStats(for tab: PanelTab, pngDirectory: String? = nil) -> RenderStats {
        var stats = RenderStats()
        guard let host = hosts[tab] else {
            stats.failureReason = "未创建"
            return stats
        }
        let size = host.bounds.size
        guard size.width >= 1, size.height >= 1 else {
            stats.failureReason = String(format: "尺寸异常 %.0f×%.0f", size.width, size.height)
            return stats
        }
        host.layoutSubtreeIfNeeded()
        // SwiftUI 的显示列表要等一个 runloop 周期才稳定，先让 runloop 转一小会儿再取位图
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            stats.failureReason = "位图分配失败"
            return stats
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.bitmapData else {
            stats.failureReason = "位图无数据"
            return stats
        }

        // 每 3 个像素采一个点（够用且快），统计颜色直方图
        let step = 3
        var histogram: [UInt32: Int] = [:]
        var total = 0
        var y = 0
        while y < rep.pixelsHigh {
            var x = 0
            while x < rep.pixelsWide {
                let o = y * rep.bytesPerRow + x * rep.samplesPerPixel
                let key = UInt32(data[o]) << 16 | UInt32(data[o + 1]) << 8 | UInt32(data[o + 2])
                histogram[key, default: 0] += 1
                total += 1
                x += step
            }
            y += step
        }
        guard total > 0 else {
            stats.failureReason = "采样为 0"
            return stats
        }

        stats.uniqueColors = histogram.count
        stats.dominantCount = histogram.values.max() ?? 0
        stats.pixels = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        stats.sampleCount = total
        if let dir = pngDirectory, let png = rep.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let path = (dir as NSString).appendingPathComponent("板块-\(tab.rawValue).png")
            if (try? png.write(to: URL(fileURLWithPath: path))) != nil { stats.pngPath = path }
        }
        return stats
    }

    /// 诊断用：各页可见性快照。正常状态应**恰好一个 `false`（可见）**，其余全 `true`（隐藏）。
    /// 若出现多个可见（旧 `.opacity(0)` 方案就是全部「可见但不绘制」），性能收益就不成立。
    func visibilitySnapshot() -> [(tab: String, hidden: Bool)] {
        hosts.keys.sorted { $0.rawValue < $1.rawValue }.map { ($0.rawValue, hosts[$0]?.isHidden ?? true) }
    }
}

/// SwiftUI ↔ `PanelHostContainer` 的桥。
struct PanelHost: NSViewRepresentable {
    // ⚠️ 必须与 `ScheduleBarApp.swift` 根注入的那一组完全一致（共 12 个）
    @EnvironmentObject private var store: ScheduleStore
    @EnvironmentObject private var classStore: ClassScheduleStore
    @EnvironmentObject private var extStore: ExtendScheduleStore
    @EnvironmentObject private var titleStore: CardTitleStore
    @EnvironmentObject private var weekStore: WeekStore
    @EnvironmentObject private var reminderStore: ReminderStore
    @EnvironmentObject private var officeStore: OfficeLayoutStore
    @EnvironmentObject private var classroomStore: ClassroomStore
    @EnvironmentObject private var staffStore: StaffStore
    @EnvironmentObject private var studentStore: StudentStore
    @EnvironmentObject private var seatingStore: SeatingStore
    @EnvironmentObject private var coordinator: AppCoordinator

    let tabs: [PanelTab]
    let selected: PanelTab

    func makeNSView(context: Context) -> PanelHostContainer {
        PanelHostContainer()
    }

    func updateNSView(_ nsView: PanelHostContainer, context: Context) {
        nsView.sync(tabs: tabs, selected: selected) { tab in
            AnyView(
                SchedulePanelPages.content(tab)
                    .environmentObject(store)
                    .environmentObject(classStore)
                    .environmentObject(extStore)
                    .environmentObject(titleStore)
                    .environmentObject(weekStore)
                    .environmentObject(reminderStore)
                    .environmentObject(officeStore)
                    .environmentObject(classroomStore)
                    .environmentObject(staffStore)
                    .environmentObject(studentStore)
                    .environmentObject(seatingStore)
                    .environmentObject(coordinator)
            )
        }
    }

    // ⚠️ 不实现 `sizeThatFits(_:nsView:context:)`：它是 macOS 13+ 的 API，而本包部署目标是 macOS 12。
    //    尺寸交给 SwiftUI 侧的 `.frame(maxWidth: .infinity, maxHeight: .infinity)` ——
    //    `PanelHostContainer` 没有固有尺寸，SwiftUI 会把它撑成内容区大小，容器再让子视图铺满自己。
}

// MARK: - 板块 → 页面
enum SchedulePanelPages {
    /// 每个板块对应的页面视图（从 SchedulePanelView.tabView 原样搬过来，别再分叉）
    @ViewBuilder
    static func content(_ tab: PanelTab) -> some View {
        switch tab {
        // ⚠️ 2026-09-26：这三个页面**不再套外层 ScrollView**。
        //    它们内部自己已经是「工具栏冻结 + ScrollView 滚内容」（§39g），
        //    外面再套一层的话，内层 ScrollView 拿到的是「高度未定」的提议 → 直接撑成内容高度、
        //    自己永远不滚，真正滚动的是外层 → 刚冻结的工具栏又跟着滚走了。
        //    外层顺带提供的 16pt 内边距改由这里的 `.padding(16)` 顶替（观感不变）。
        case .personal:
            PersonalScheduleView()
                .padding(16)
        case .class7:
            ClassScheduleView()
                .padding(16)
        case .teacher:
            TeacherScheduleView()
        case .extend:
            ExtendScheduleView()
                .padding(16)
        case .calendar:
            ChongqingCalendarView()
        case .reminder:
            ReminderSettingsView()
        case .office:
            OfficeLayoutView()
        case .classroom:
            ClassroomMapView()
        case .staff:
            StaffView()
        case .student:
            StudentInfoView()
        case .seating:
            SeatingView()
        }
    }
}
