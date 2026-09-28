import Foundation
import CoreFoundation
import QuartzCore

// MARK: - 切页性能取证（`SCHEDULEBAR_TRACE_PERF=1`）
//
// 目的：用户反馈「切换板块有点慢」。慢在哪儿不靠猜 —— 用**运行时日志打实测毫秒数**。
//
// 测的是「主线程恢复空闲所需时间」：
//   ① `mark()` 记下起点并装一个 `CFRunLoopObserver(.beforeWaiting)`；
//   ② 状态改动（切页）触发的 body 求值 + 布局 + 绘制提交都在本轮 runloop 内跑完；
//   ③ runloop 即将空闲时回调 → 此刻的耗时 = 这一页真正花掉的主线程时间。
// ⚠️ 观察者注册在 CoreAnimation 之后，所以它提交 CATransaction 的动作**已经跑完**，
//    我们量到的是「含提交」的总时长（而不是只到 body 求值）。
//
// 配套开关 `--perf-tabs`：面板打开后自动轮播所有板块，跑完打一张汇总表（见 SchedulePanelView）。

final class PerfTrace {
    static let shared = PerfTrace()

    /// 严格按开关判断，默认全关（零开销：连观察者都不装）。
    /// 开关两选一：环境变量 `SCHEDULEBAR_TRACE_PERF`，或偏好域 `tracePerf`。
    /// ⚠️ 为什么还要偏好域：直接 nohup 起的进程会被沙箱在 ~10 秒后回收；
    ///    用 `open` 起才活得久，而 `open --args` 在本机传不进参数、环境变量也不跟随，
    ///    于是留一条 `defaults write com.schedulebar.app tracePerf -bool YES` 的路。
    static var enabled: Bool {
        if ProcessInfo.processInfo.environment["SCHEDULEBAR_TRACE_PERF"] != nil { return true }
        return UserDefaults.standard.bool(forKey: "tracePerf")
    }

    private var observer: CFRunLoopObserver?
    private var pending: [(label: String, start: CFAbsoluteTime)] = []
    private var samples: [(label: String, ms: Double)] = []

    private init() {}

    // MARK: 单次计时

    /// 在「即将触发重绘」的动作**之前**调用（例：`selectedTab = t` 之前）
    func mark(_ label: String) {
        guard Self.enabled else { return }
        pending.append((label, CFAbsoluteTimeGetCurrent()))
        installObserverIfNeeded()
    }

    private func installObserverIfNeeded() {
        guard observer == nil else { return }
        let obs = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 0
        ) { [weak self] _, _ in
            self?.flush()
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
        observer = obs
    }

    /// runloop 即将空闲 → 本轮所有工作都做完了，结算所有待测项
    private func flush() {
        guard !pending.isEmpty else { return }
        let now = CFAbsoluteTimeGetCurrent()
        for p in pending {
            let ms = (now - p.start) * 1000
            samples.append((p.label, ms))
            SaveHub.log("性能[切页] \(p.label) 主线程耗时 \(Int(ms.rounded()))ms")
        }
        pending.removeAll()
    }

    // MARK: 轮播跑批

    /// 汇总表（跑完 `--perf-tabs` 后打印）
    func dumpSummary(title: String) {
        guard Self.enabled, !samples.isEmpty else { return }
        SaveHub.log("════ 切页性能汇总（\(title)）════")
        var total = 0.0
        var worst = ("", 0.0)
        for s in samples {
            total += s.ms
            if s.ms > worst.1 { worst = s }
            SaveHub.log(String(format: "  %-22@ %6.0f ms", s.label as NSString, s.ms))
        }
        SaveHub.log(String(format: "  合计 %@：%d 次 / 总 %.0f ms / 平均 %.0f ms / 最慢 %@ %.0f ms",
                           title as NSString, samples.count, total, total / Double(samples.count),
                           worst.0 as NSString, worst.1))
    }

    func reset() {
        samples.removeAll()
        pending.removeAll()
    }
}
