import SwiftUI

// MARK: - 第1周设置弹窗（由顶部「第 N 周」胶囊点开）
struct WeekSetupView: View {
    @EnvironmentObject var weekStore: WeekStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Date = Date()

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("第 1 周设置")
                .font(.headline)
            Text("每周从周一开始。选择第 1 周所在的那一周，应用会把它自动对齐到该周的周一。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            DatePicker("第 1 周开始日期", selection: $draft, displayedComponents: .date)
                .datePickerStyle(.field)
                .labelsHidden()
                .frame(maxWidth: .infinity)

            if weekStore.isConfigured,
               let monday = weekStore.firstWeekMonday {
                Text("当前设置：第 1 周 = \(Self.dateFmt.string(from: monday)) 起")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("未设置：当前按「今天所在周为第 1 周」显示")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("设为第 1 周") {
                    weekStore.setStart(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                Button("恢复默认") {
                    weekStore.clear()
                    dismiss()
                }
                .buttonStyle(.bordered)
                Spacer()
            }
        }
        .padding(12)
        .frame(width: 320)
        .onAppear {
            draft = weekStore.firstWeekMonday ?? weekStore.alignedMonday(of: Date())
        }
    }
}
