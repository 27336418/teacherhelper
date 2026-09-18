import SwiftUI

// MARK: - 统一「保存」按钮（2026-09-17 新增）
//
// 各可编辑板块的工具栏都挂一个：
//   · 有未保存改动 → **实心强调色**「保存」，点一下立刻写入磁盘（等同 ⌘S）
//   · 没有改动     → 灰色「已保存」，点一下也会强制再写一次（确认用）
//   · 刚保存完     → 绿色「✓ 已保存」停留 1.8 秒
//
// 即使一次都没点过，停手 8 秒 / 收起面板 / 关闭窗口 / 退出 App 时也会自动落盘，
// 所以这个按钮是「把主动权交回给用户」，不是「不点就会丢」。
struct SaveButton: View {
    @ObservedObject private var hub = SaveHub.shared

    var body: some View {
        Group {
            if hub.hasUnsaved {
                Button {
                    SaveHub.shared.saveNow(reason: "点击保存按钮")
                } label: {
                    Label("保存", systemImage: "square.and.arrow.down.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .help(unsavedHelp)
                .transition(.opacity)
            } else {
                Button {
                    SaveHub.shared.saveNow(reason: "点击保存按钮（确认）")
                } label: {
                    Label(hub.justSaved ? "已保存" : "已保存",
                          systemImage: hub.justSaved ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .buttonStyle(.bordered)
                .foregroundStyle(hub.justSaved ? Color.green : Color.secondary)
                .help("当前没有未保存的改动")
            }
        }
        .animation(.easeInOut(duration: 0.15), value: hub.hasUnsaved)
    }

    private var unsavedHelp: String {
        "有未保存的改动：\(hub.unsavedList)\n"
        + "点击立即保存（也可按 ⌘S）；停手 8 秒或收起面板会自动保存，不会丢。"
    }
}
