import AppKit
import SwiftUI

// MARK: - 板块页面「真的画出来了」自证（2026-09-28）
//
// 用途：`--selftest-render`
//
// ## 为什么需要这个
// 2026-09-28 把面板从「一个 SwiftUI ZStack + `.opacity(0)` 隐藏」改成了
// 「每页一个 `NSHostingView` + 非当前页 `isHidden = true`」（见 `Views/PanelHost.swift`）。
// 这是一次**结构性**改造，风险不在耗时，而在「页面还画不画得出来」：
// `NSHostingView` 是独立的一棵 SwiftUI 树，**不继承**外层环境 —— 少注入一个 `@EnvironmentObject`
// 就会在 body 里取不到值（崩或空白），而这在性能日志里完全看不出来（切页照样「成功」）。
//
// 本机没有可用的视觉取证手段：popover 与截图不在同一 Space（截到的是别的 App）、
// `osascript set frontmost` 报 -10004 权限违例、`import Quartz` 不可用。
// 所以改成**进程内离屏渲染**：`cacheDisplay` 把每个页面画进位图，统计像素多样性。
// 不依赖窗口是否可见、不依赖录屏权限、不受 Space 影响，而且完全可重复。
//
// ## 判读
//   · 唯一色 1~2 且墨点（与主色不同的采样点数）为 0 → 一片空白
//     （环境对象漏注入 / 尺寸为 0 / 没进布局）
//   · 有文字、边框、表格线的真实页面 → 几百种颜色、墨点几千个
//   ⚠️ **不要看主色占比**：日程提醒这类「内容只占上半屏」的页面主色占比高达 99.8%，
//      但画面完全正常（标题＋开关＋两条提醒＋添加按钮）。
// 同时断言「恰好只有一个页面可见」——旧方案是「全部可见只是不绘制」，那样性能收益不成立。
//
// ## 数据安全
// 读**真实数据**渲染（才是有意义的验证），但先把数据目录整份拷到临时目录、再让进程指向副本，
// 这样即使某个视图在渲染过程中触发了保存，落的也是副本；跑完删临时目录，真实数据一个字节不动。
enum PanelRenderCheck {

    /// 面板内容区的实际尺寸（与 `PanelHost` 宿主一致即可；880×700 是面板的典型实测尺寸）
    private static let panelSize = NSSize(width: 880, height: 700)

    static func run() {
        // 1) 先把真实数据目录拷成副本，再让进程读副本 —— 渲染过程绝不写真实目录
        let realDir = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/ScheduleBar")
        let tmp = "/tmp/selftest-render-\(UUID().uuidString.prefix(8))"
        var copied = "（真实数据目录不存在，用空目录渲染）"
        if FileManager.default.fileExists(atPath: realDir) {
            do {
                try FileManager.default.copyItem(atPath: realDir, toPath: tmp)
                copied = "已整份拷贝真实数据"
            } catch {
                copied = "拷贝失败（\(error.localizedDescription)），改用空目录"
                try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
            }
        } else {
            try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        }
        setenv("SCHEDULEBAR_DATA_DIR", tmp, 1)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        print("=== 板块页面渲染自检 ===")
        print("真实数据目录 = \(realDir)")
        print("本次渲染目录 = \(tmp)   \(copied)（跑完删除，真实数据不受影响）")

        // 2) 需要 AppKit 起来才谈得上渲染（但**不** run 事件循环）
        _ = NSApplication.shared

        // 3) 建宿主容器，按真实运行时的注入方式把 12 个环境对象灌进每一页
        //    ⚠️ 这一组必须与 `Views/PanelHost.swift` / `ScheduleBarApp.swift` 完全一致
        let makeContent: (PanelTab) -> AnyView = { tab in
            AnyView(
                SchedulePanelPages.content(tab)
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
            )
        }

        let container = PanelHostContainer()
        container.frame = NSRect(origin: .zero, size: panelSize)
        let pngDir = ProcessInfo.processInfo.environment["SCHEDULEBAR_RENDER_PNG"]
        if let pngDir { print("PNG 落盘目录 = \(pngDir)") }

        // 4) 先建好全部页面（模拟「所有板块都访问过」的最重场景），再逐页切过去逐个取证
        container.sync(tabs: PanelTab.allCases, selected: .personal, makeContent: makeContent)
        container.layoutSubtreeIfNeeded()

        var passed = 0
        var failures: [String] = []
        for tab in PanelTab.allCases {
            container.sync(tabs: PanelTab.allCases, selected: tab, makeContent: makeContent)
            container.layoutSubtreeIfNeeded()

            // 4a) 可见性：切到这一页后，必须**只有这一页**可见
            let visible = container.visibilitySnapshot().filter { !$0.hidden }.map(\.tab)
            let visibilityOK = (visible == [tab.rawValue])

            // 4b) 渲染指纹：这一页必须真的画出内容
            let stats = container.renderStats(for: tab, pngDirectory: pngDir)

            // 4c) 判读
            if visibilityOK && stats.looksDrawn {
                passed += 1
                print("  ✓ \(tab.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)) 可见页=\(visible.joined(separator: ","))  \(stats.described)")
            } else {
                let why = [
                    visibilityOK ? nil : "可见页异常(\(visible.joined(separator: ",")))",
                    stats.looksDrawn ? nil : "疑似空白（唯一色 \(stats.uniqueColors)、墨点 \(stats.inkPoints)）"
                ].compactMap { $0 }.joined(separator: " + ")
                failures.append("\(tab.rawValue)：\(why)")
                print("  ✗ \(tab.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)) 可见页=\(visible.joined(separator: ","))  \(stats.described)   ← \(why)")
            }
        }

        print("---")
        if failures.isEmpty {
            print("结果：全部 \(PanelTab.allCases.count) 个板块页面均「真的渲染出内容 + 恰好一个可见」通过")
        } else {
            print("结果：\(passed)/\(PanelTab.allCases.count) 通过，失败 \(failures.count) 项：")
            for f in failures { print("      · \(f)") }
        }
        print("说明：唯一色 = 采样到的不同 RGB 值个数（空白页只有 1~2 个）；墨点 = 与主色不同的采样点数")
        print("      （真正画了东西的量；空白页为 0）。判定：唯一色 ≥ 20 且墨点 ≥ 200 才算「画出来了」。")
        print("      ⚠️ 别看主色占比：日程提醒「内容只占上半屏」时主色占比 99.8% 仍是完全正常的页面。")
    }
}
