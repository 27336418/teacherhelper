import SwiftUI
import AppKit

// MARK: - 定时提醒设置（增删改提醒；启动即默认申请系统通知权限，到点弹窗+系统通知+系统日历日程）
struct ReminderSettingsView: View {
    @EnvironmentObject var reminderStore: ReminderStore
    @ObservedObject private var calendarSync = CalendarSyncService.shared

    @State private var editing: Reminder?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            titleRow
            hintText

            // ⚠️ 2026-09-26 用户要求「滚动时冻结这些内容」：
            //    标题行 + 使用说明留在滚动区**外面**，提醒条数多时往下翻也一直看得见。
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    calendarSyncCard

                    // 提醒列表
                    ForEach(reminderStore.reminders) { r in
                        // ⚠️ 别在这里再加 .onTapGesture { editing = r }：ReminderRow 内部已有
                        //    `.onTapGesture { onEdit() }`，外面再挂一层就是同一次点击设两遍 editing。
                        ReminderRow(reminder: r) {
                            editing = r
                        }
                    }

                    // 添加
                    Button {
                        let new = Reminder(title: "新提醒", hour: 9, minute: 0,
                                           weekdays: ReminderStore.weekdayWorkdays, url: "")
                        reminderStore.add(new)
                        editing = new
                    } label: {
                        Label("添加提醒", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(12)
        .sheet(item: $editing) { r in
            // 传值而不是传 Binding：弹窗自己持有草稿，见 ReminderEditSheet 的说明。
            ReminderEditSheet(reminder: r)
        }
        .onAppear { calendarSync.syncAllReminders(reason: "打开提醒设置") }
    }

    // MARK: - 顶部标题（冻结在滚动区外）
    private var titleRow: some View {
        HStack {
            Label("定时提醒", systemImage: "bell.badge.fill")
                .font(.headline)
            Spacer()
            UndoButton()
            SaveButton()
        }
    }

    // MARK: - 使用说明（冻结在滚动区外）
    private var hintText: some View {
        Text("到点会弹窗提醒，可点「等会处理」选择稍后再提醒；文字与网址可自定义并自动保存。不勾任何星期 = 只在当天该时刻提醒一次。")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: 系统日历同步卡片
    private var calendarSyncCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $calendarSync.syncReminders) {
                Label("同步到系统「日历」", systemImage: "calendar.badge.plus")
                    .font(.caption.weight(.medium))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Text("开启后，每条提醒会在 Mac 自带「日历」里生成一条每周重复的日程（时间、文字与提醒一致），改提醒或删提醒都会立即自动同步；日程位于「\(CalendarSyncService.calendarName)」日历中，可随时在系统日历里整体隐藏。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(calendarSync.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if calendarSync.permissionDenied {
                    Button("去系统设置授权") {
                        CalendarSyncService.openCalendarPrivacySettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.3)))
    }
}

// MARK: - 单条提醒行
struct ReminderRow: View {
    let reminder: Reminder
    let onEdit: () -> Void

    @EnvironmentObject var reminderStore: ReminderStore

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "alarm")
                .foregroundStyle(Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(timeText + " · " + weekText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if reminder.weekdays.isEmpty {
                        // 一天都没勾 = **一次性提醒**（只在该天提醒一次），不再是「不会提醒」
                        // 2026-09-17 用户要求：未勾星期默认为当天设定的时间提醒
                        if reminder.firedOn == Reminder.dayString(Date()) {
                            Text("今天已提醒")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        } else if reminder.oneShotDay == Reminder.dayString(Date()) {
                            Text("今天提醒")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.orange)
                        } else if reminder.oneShotDay == nil {
                            Text("未设置提醒日")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.orange)
                        } else {
                            Text("已过期")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer()
            if !reminder.url.isEmpty {
                Link(destination: urlAbsolute) {
                    Image(systemName: "link")
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .help("打开 \(reminder.url)")
            }
            Button {
                reminderStore.remove(reminder.id)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("删除提醒")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.3)))
        .contentShape(Rectangle())
        .onTapGesture { onEdit() }
        .help("点击编辑")
    }

    private var timeText: String {
        String(format: "%02d:%02d", reminder.hour, reminder.minute)
    }
    private var weekText: String {
        // 一次性提醒（没勾任何星期）：显示日期，而不是星期
        if reminder.weekdays.isEmpty {
            guard let d = reminder.oneShotDay else { return "未设置提醒日" }
            return "仅 \(Self.shortDay(d)) 提醒一次"
        }
        // 按「周一…周六、周日」显示（只是显示顺序，取值仍是 1=周日…7=周六）
        let ordered = ReminderStore.weekdayDisplayOrder.filter { reminder.weekdays.contains($0) }
        return ordered.map { ReminderStore.weekdayLabel($0) }.joined(separator: " ")
    }

    /// "2026-09-17" → "9月17日"（不是今年则带上年份）
    static func shortDay(_ day: String) -> String {
        let parts = day.split(separator: "-")
        guard parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]) else { return day }
        let y = Int(parts[0]) ?? 0
        let thisYear = Calendar.current.component(.year, from: Date())
        return y == thisYear ? "\(m)月\(d)日" : "\(y)年\(m)月\(d)日"
    }
    private var urlAbsolute: URL { URL(string: reminder.url) ?? URL(string: "https://www.baidu.com")! }
}

// MARK: - 编辑弹窗
//
// ⚠️ 2026-09-23 重写（用户反馈「M1 + macOS 15.7.3 上无法选择周一周二等星期」）：
//    原实现是 `@Binding var reminder: Reminder`，binding 由父视图用
//    `Binding(get: { store… }, set: { store.update(…) })` **手工构造**。
//    这种绑定 SwiftUI 无法追踪其依赖 —— 弹窗要不要重绘，全看「父视图重绘时会不会
//    顺手把 sheet 的内容闭包重算一遍」。这条行为**在不同系统版本上并不一致**：
//    本机 macOS 26.5 会重算（所以星期点得动、看得见变化），而 macOS 15 上可能不重算，
//    于是「点击其实生效了、但按钮外观永远停在初始状态」→ 用户看到的就是「选不了」。
//    现在改成弹窗**自己持有 @State 草稿**：任何一次改动都必然重绘（@State 语义保证），
//    同时在 setter 里顺手写回 store（列表与持久化照旧立刻更新）。
//    ⚠️ 别改回「纯 @Binding + 父视图手工 Binding」，也别把草稿退回成从 store 现算的计算属性。
struct ReminderEditSheet: View {
    @State private var draft: Reminder
    @Environment(\.dismiss) private var dismiss

    init(reminder: Reminder) {
        _draft = State(initialValue: reminder)
    }

    /// 改草稿的**唯一入口**：改完立刻写回 store。
    /// · `draft = r` 让弹窗**自己重绘** —— `@State` 的重绘语义在任何 macOS 版本上都成立，
    ///   这正是修掉「点星期按钮看不出变化」的关键；
    /// · `ReminderStore.shared.update(r)` 让列表行与持久化立刻跟上。
    /// 用 `ReminderStore.shared` 而不是 `@EnvironmentObject`：弹窗里少一个环境依赖，
    /// 避免「环境没传进来直接崩」这类更难查的问题（`.shared` 就是根视图注入的那个实例）。
    private func mutate(_ change: (inout Reminder) -> Void) {
        var r = draft
        change(&r)
        draft = r
        ReminderStore.shared.update(r)
    }

    /// 取某个字段的绑定（给 TextField 用）。
    private func field<T>(_ keyPath: WritableKeyPath<Reminder, T>) -> Binding<T> {
        Binding(get: { draft[keyPath: keyPath] },
                set: { v in mutate { r in r[keyPath: keyPath] = v } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("提醒设置")
                .font(.headline)

            TextField("提醒文字", text: field(\.title))
                .textFieldStyle(.roundedBorder)
                .font(.body)

            HStack(spacing: 8) {
                DatePicker("时间", selection: timeBinding, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.field)
                Text("每天该时刻")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 星期循环（显示顺序：周一…周六、周日；取值仍是 1=周日…7=周六）
            HStack(spacing: 6) {
                Text("一周哪些天重复")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("每天") { mutate { r in r.weekdays = ReminderStore.weekdayEveryDay; r.syncOneShot() } }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .help("勾选周一到周日全部七天")
                Button("周一至周五") { mutate { r in r.weekdays = ReminderStore.weekdayWorkdays; r.syncOneShot() } }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                Button("周一至周六") { mutate { r in r.weekdays = ReminderStore.weekdayMonToSat; r.syncOneShot() } }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                Spacer()
            }
            HStack(spacing: 6) {
                ForEach(ReminderStore.weekdayDisplayOrder, id: \.self) { w in
                    WeekdayChip(label: ReminderStore.weekdayLabel(w),
                                isOn: draft.weekdays.contains(w)) {
                        mutate { r in
                            if r.weekdays.contains(w) { r.weekdays.remove(w) }
                            else { r.weekdays.insert(w) }
                            // 勾选变了 → 同步「一次性提醒」的日期（一个都没勾就记成今天）
                            r.syncOneShot()
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            // 未勾任何星期 → 一次性提醒（2026-09-17 用户要求：默认为当天设定的时间提醒，而不是不提醒）
            if draft.weekdays.isEmpty {
                Text("未勾选星期 = 一次性提醒：只在 \(ReminderRow.shortDay(draft.oneShotDay ?? Reminder.dayString(Date()))) "
                     + "\(String(format: "%02d:%02d", draft.hour, draft.minute)) 提醒一次（不每周重复）；要每周重复请勾选上面的星期。")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("网址（可选，点击提醒打开）", text: field(\.url))
                .textFieldStyle(.roundedBorder)
                .font(.caption)

            HStack {
                Button("测试弹窗") {
                    ReminderFirer.shared.fireTest(draft)
                }
                .help("立刻弹一次这条提醒的窗口，用来确认到点弹窗正常（不影响正常的提醒时间）")
                Spacer()
                Button("完成") {
                    dismiss()
                    // 取消人工「立即同步」按钮后，编辑完成即写一次系统日历
                    CalendarSyncService.shared.syncAllReminders(reason: "编辑完成")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                let cal = Calendar.current
                var comps = DateComponents()
                comps.year = 2000; comps.month = 1; comps.day = 1
                comps.hour = draft.hour; comps.minute = draft.minute
                return cal.date(from: comps) ?? Date()
            },
            set: { date in
                let cal = Calendar.current
                mutate { r in
                    r.hour = cal.component(.hour, from: date)
                    r.minute = cal.component(.minute, from: date)
                    // 改了时间 → 一次性提醒若已过期就重新定成今天，并允许按新时间再提醒一次
                    r.rearmOneShot()
                }
            }
        )
    }
}

// MARK: - 星期芯片
//
// ⚠️ 2026-09-23 新增（用户反馈「M1 + macOS 15.7.3 上无法选择周一周二等星期」）：
//    原来这里是 `Button(标签).buttonStyle(.bordered).tint(选中 ? .accentColor : .gray)`。
//    `.tint` 作用在 `.bordered` 按钮上的着色规则**随 macOS 版本变过**：
//    本机 macOS 26.5 上选中项会变蓝、未选中是灰的；但 macOS 15 上两种状态可能长得一样，
//    于是「点了其实生效了，按钮却看不出任何变化」→ 用户只能判定为「选不了」。
//    现在把选中态**自己画出来**（实心填充 + 白字加粗 vs 浅灰填充 + 次要色文字 + 细描边），
//    差异是明度/几何级的，任何系统、深色浅色背景下都一眼可辨，不再依赖系统控件的着色实现。
//    ⚠️ 别再改回 `.tint(...)` 表达选中态；也别只靠改文字颜色（对比太弱）。
struct WeekdayChip: View {
    let label: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Color.white : Color.secondary)
                .frame(width: 44, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isOn ? Color.accentColor : Color.gray.opacity(0.16))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isOn ? Color.accentColor : Color.gray.opacity(0.35),
                                      lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(isOn ? "\(label)：已勾选（点一下取消）" : "\(label)：未勾选（点一下勾上）")
    }
}
