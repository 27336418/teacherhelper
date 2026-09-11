import SwiftUI

// MARK: - 提醒窗口内容（非模态）
// 放在独立浮窗里，不阻塞主面板：弹窗开着时仍可自由打开菜单栏面板查看课表 / 处理事情。
struct ReminderAlertView: View {
    let title: String
    let message: String
    let isRepeat: Bool
    let options: [(label: String, interval: TimeInterval)]
    let defaultIndex: Int
    let hasURL: Bool
    var onDone: () -> Void
    var onSnooze: (TimeInterval) -> Void
    var onOpenURL: (() -> Void)?

    @State private var sel: Int

    init(title: String,
         message: String,
         isRepeat: Bool,
         options: [(label: String, interval: TimeInterval)],
         defaultIndex: Int,
         hasURL: Bool,
         onDone: @escaping () -> Void,
         onSnooze: @escaping (TimeInterval) -> Void,
         onOpenURL: (() -> Void)? = nil) {
        self.title = title
        self.message = message
        self.isRepeat = isRepeat
        self.options = options
        self.defaultIndex = defaultIndex
        self.hasURL = hasURL
        self.onDone = onDone
        self.onSnooze = onSnooze
        self.onOpenURL = onOpenURL
        _sel = State(initialValue: min(max(0, defaultIndex), max(0, options.count - 1)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: isRepeat ? "clock.badge.exclamationmark" : "alarm")
                    .foregroundStyle(isRepeat ? .orange : .red)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
            }

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text("本窗口不会锁住面板，可先切到教师助手处理完再回来点。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()

            // 单行：间隔选择 + 等会处理 + 打开链接 + 马上处理（窗口加宽保证文字完整）
            HStack(spacing: 10) {
                Picker("", selection: $sel) {
                    ForEach(options.indices, id: \.self) { i in
                        Text(options[i].label).tag(i)
                    }
                }
                .labelsHidden()
                .frame(width: 112)
                .clipped()
                .help("选择「等会处理」的间隔")

                Button {
                    onSnooze(options[sel].interval)
                } label: {
                    Text("等会处理")
                }
                .fixedSize()
                .help("按所选时间后再提醒一次，直到点「马上处理」")

                Spacer(minLength: 0)

                if let onOpenURL, hasURL {
                    Button("打开链接", action: onOpenURL)
                        .fixedSize()
                        .help("打开该提醒的网址，并视为已处理")
                }

                Button {
                    onDone()
                } label: {
                    Text("马上处理")
                }
                .fixedSize()
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .help("本次提醒结束，不再重复弹窗")
            }
        }
        .padding(14)
        .frame(width: 400, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
