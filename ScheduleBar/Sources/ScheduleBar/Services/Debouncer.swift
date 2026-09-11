import Foundation

// MARK: - 轻量去抖器：高频输入（单元格编辑/备注）合并为一次磁盘写入
final class Debouncer {
    private var work: DispatchWorkItem?

    /// 取消上一次未执行的任务，delay 秒后执行 block
    func schedule(delay: TimeInterval = 0.4, _ block: @escaping () -> Void) {
        work?.cancel()
        let w = DispatchWorkItem(block: block)
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    /// 立即执行并清空挂起任务（用于退出前 flush）
    func flush() {
        work?.perform()
        work = nil
    }
}
