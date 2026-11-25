import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - 格子「双击进编辑 → 拿到键盘焦点」自检（2026-11-25）
//
// 用户报：「座次表里面无法双击输入学生姓名」。
// 现象：双击后格子有描边、有光标，敲字却没反应，编辑态也不退出。
// 根因：面板是 `.accessory` + NSPopover。窗口不是 key 时，只把 `@FocusState` 置 true
//       并不会让输入框真的成为第一响应者。课表 `ScheduleCell` 早有 `requestFocus()`
//       补「App 激活 + 面板窗口 key」，而座位/工位/教室/师资共用的
//       `EditableGridCell` 漏了这段 —— 本自检锁住这条路径，防止以后再被删掉。
//
// 取证方式：程序化触发编辑态 + 运行时日志实测数字（不依赖屏幕是否解锁、不需要截图）。
// 用法：ScheduleBar --selftest-cell-focus
enum CellFocusCheck {

    private final class Probe: ObservableObject {
        @Published var editing = false
        @Published var text = ""
    }

    private struct ProbeView: View {
        @ObservedObject var probe: Probe
        var body: some View {
            EditableGridCell(text: $probe.text,
                             width: 90, height: 30,
                             externalEditing: $probe.editing)
                .frame(width: 240, height: 100)
        }
    }

    private static var pass = 0, fail = 0
    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("  \(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "  [\(detail)]")")
        ok ? (pass += 1) : (fail += 1)
    }

    private static var logPath: String {
        NSHomeDirectory() + "/Library/Logs/教师助手.log"
    }

    private static func logLength() -> Int {
        (try? String(contentsOfFile: logPath, encoding: .utf8))?.count ?? 0
    }

    /// 让主队列上的 async / asyncAfter 真的跑起来（自检分支没有 App 的 runloop）
    private static func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private static func findTextField(_ v: NSView) -> NSTextField? {
        if let t = v as? NSTextField { return t }
        for sub in v.subviews {
            if let t = findTextField(sub) { return t }
        }
        return nil
    }

    static func run() {
        print("=== 格子编辑焦点 自检 ===")
        let app = NSApplication.shared
        let probe = Probe()
        let win = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 300, height: 140),
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        let host = NSHostingView(rootView: ProbeView(probe: probe))
        win.contentView = host
        win.makeKeyAndOrderFront(nil)
        pump(0.3)

        check("初始不是编辑态", !probe.editing)
        check("显示态没有输入框", findTextField(host) == nil)

        let before = logLength()
        // 程序化模拟「双击」：外部把 editing 置 true（座次表就是这么进编辑态的）
        probe.editing = true
        pump(0.6)

        let full = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        let tail = String(full.dropFirst(min(before, full.count)))
        print("  运行时日志新增：")
        for line in tail.split(separator: "\n") where line.contains("格子编辑") {
            print("    \(line)")
        }

        check("编辑态真的渲染出了输入框", findTextField(host) != nil)
        check("进编辑时执行了补焦点流程（第一次）",
              tail.contains("格子编辑焦点：App激活="))
        check("0.1s 后再补一次焦点（幂等）",
              tail.contains("格子编辑补焦点：仍在编辑态=true"))
        check("日志带实测数字（App 激活 / key 窗口）",
              tail.contains("App激活=") && tail.contains("key窗口="))
        check("程序化触发后仍是编辑态", probe.editing)
        print("  实测：App激活=\(app.isActive)  key窗口=\(app.keyWindow != nil)")

        print("———————————————————————————")
        print("格子编辑焦点自检：\(pass) 通过 / \(fail) 失败")
        win.orderOut(nil)
        if fail > 0 { exit(1) }
    }
}
