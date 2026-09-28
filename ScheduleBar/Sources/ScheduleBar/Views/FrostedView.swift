import SwiftUI
import AppKit

// MARK: - 半透明磨砂背景
/// 用于让课表面板呈现半透明的毛玻璃效果
///
/// ⚠️ 2026-09-28 已用 `--perf-tabs` 跑批**证伪**过的三个猜想，别再来一遍：
///   ① `.withinWindow` 的整窗模糊不是切页慢的原因 —— 把面板底色/冻结表头换成 `.behindWindow`
///      或不透明纯色，交替 A/B 各两轮实测（总耗时）：毛玻璃 4469 / 4648ms，全不透明 3870 / 4760ms，
///      差异全在机器漂移的量级内（同一配置两次能差 900ms），**不是**一层模糊的开销；
///   ② 隐藏页的布局不是原因 —— 把隐藏页缩成 1×1 尺寸提议，耗时不变（4649 vs 4632ms）；
///   ③ 隐藏页的 body 重算不是原因 —— 计数器显示「延时监考」的 body 整场只跑 1 次，
///      套 `EquatableView` 后耗时也没变（4359 vs 4632ms）。
///    真正的原因见 `Views/PanelHost.swift` 顶部的说明（切页成本 ≈ 窗口图层树里活着的页面内容量）。
struct FrostedView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}
