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
                    // 提醒列表
                    // 2026-09-28 用户要求：一次性提醒「已完成」（当天已弹过）就不再显示，
                    // 但事件仍保留在系统日历里（见 CalendarSyncService.keepsEventInCalendar）；
                    // 过期未完成的继续留在列表里，直到用户删掉或改时间完成它。
                    ForEach(reminderStore.reminders.filter { !$0.isCompleted }) { r in
                        // ⚠️ 别在这里再加 .onTapGesture { editing = r }：ReminderRow 内部已有
                        //    `.onTapGesture { onEdit() }`，外面再挂一层就是同一次点击设两遍 editing。
                        ReminderRow(reminder: r) {
                            editing = r
                        }
                    }

                    // 添加
                    // 2026-09-28 用户要求的默认值：
                    //   ① 不默认勾选周一～周五 —— 一个都不勾 = 一次性提醒，只在该日该时刻提醒一次；
                    //   ② 默认时间 = 点「添加」这一刻**往后 30 分钟**（跨午夜则自动定到明天）；
                    //   ③ 默认自动保存 —— add() 触发 didSet → ReminderStore.scheduleSave() 立即落盘。
                    Button {
                        let target = Date().addingTimeInterval(30 * 60)
                        var new = Reminder(title: "新提醒",
                                           hour: Calendar.current.component(.hour, from: target),
                                           minute: Calendar.current.component(.minute, from: target),
                                           weekdays: [], url: "")
                        new.oneShotDay = Reminder.dayString(target)   // 一次性提醒：记 30 分钟后那天（跨午夜=明天）
                        reminderStore.add(new)
                        editing = new
                    } label: {
                        Label("添加提醒", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)

                    // 查看已完成（2026-09-28 用户要求）：已完成的一次性提醒不再显示在列表里，
                    // 但事件留档在系统「日历」的「教师助手」日历中 → 一键打开日历去看。
                    Button {
                        NSWorkspace.shared.launchApplication("Calendar")
                    } label: {
                        Label("查看已完成", systemImage: "calendar")
                    }
                    .buttonStyle(.bordered)
                    .help("已完成的一次性提醒已保留在系统「日历」（\(CalendarSyncService.calendarName)）里，点击打开日历查看")
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
            // 同步到系统「日历」（2026-09-28 用户要求：默认开启；开关放在撤销左边、一行对齐，
            //    原来滚动区里的整卡简介已删）。权限被拒时旁边亮一个橙色告警图标。
            Toggle(isOn: $calendarSync.syncReminders) {
                Label("同步日历", systemImage: "calendar.badge.plus")
                    .font(.caption.weight(.medium))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("每条提醒在 Mac 自带「日历」的「\(CalendarSyncService.calendarName)」日历里生成日程；改/删提醒自动同步，已完成的提醒留档在日历里")
            if calendarSync.permissionDenied {
                Button {
                    CalendarSyncService.openCalendarPrivacySettings()
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("日历权限被拒绝，点击去系统设置授权（\(calendarSync.summary)）")
            }
            UndoButton()
        }
    }

    // MARK: - 使用说明（冻结在滚动区外）
    private var hintText: some View {
        Text("到点会弹窗提醒：点「马上处理」= 处理完成（一次性提醒完成后从列表消失、日历里保留），点「等会处理」可稍后再提醒。文字与网址可自定义并自动保存。不勾任何星期 = 只在当天该时刻提醒一次。")
            .font(.caption)
            .foregroundStyle(.secondary)
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
                    if reminder.isOneShot {
                        // 一天都没勾、也没设长周期 = **一次性提醒**（只在该天提醒一次），不再是「不会提醒」
                        // 2026-09-17 用户要求：未勾星期默认为当天设定的时间提醒
                        // 2026-09-28：「已完成」的整条不再显示（上面 ForEach 已过滤）；
                        //    今天已过点但没点「马上处理」的标「已弹窗 · 待处理」。
                        //    ⚠️ 不读 firedOn：它已退役（弹窗窗口是内存状态，标记落盘曾造成
                        //    「显示已弹窗但找不到窗口」死锁）；「过没过点」由时间直接算（Self.isPastDue）。
                        if reminder.oneShotDay == Reminder.dayString(Date()), Self.isPastDue(reminder) {
                            Text("已弹窗 · 待处理")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.orange)
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
        // 长周期循环（每月 / 每半年 / 每年，2026-09-28）：显示循环锚点
        if reminder.longCycle != nil { return reminder.longCycleText + " 循环" }
        // 一次性提醒（没勾任何星期）：显示日期，而不是星期
        if reminder.weekdays.isEmpty {
            guard let d = reminder.oneShotDay else { return "未设置提醒日" }
            return "仅 \(Self.shortDay(d)) 提醒一次"
        }
        // 按「周一…周六、周日」显示（只是显示顺序，取值仍是 1=周日…7=周六）
        let ordered = ReminderStore.weekdayDisplayOrder.filter { reminder.weekdays.contains($0) }
        return ordered.map { ReminderStore.weekdayLabel($0) }.joined(separator: " ")
    }

    /// 今天的一次性提醒是否已经过了该弹窗的时刻（hour:minute ≤ 现在）
    static func isPastDue(_ r: Reminder) -> Bool {
        let cal = Calendar.current
        guard let target = cal.date(bySettingHour: r.hour, minute: r.minute, second: 0, of: Date()) else { return false }
        return Date() >= target
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

            // 快捷定到「现在 + N」（2026-09-28 用户要求：30分钟 / 1小时 / 2小时 / 4小时后；
            // 要定具体时刻仍用上面的时间框）
            HStack(spacing: 6) {
                Text("快捷")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Self.quickOffsets, id: \.label) { item in
                    Button(item.label) { setRelative(item.seconds) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
                Spacer()
            }

            // 星期循环（显示顺序：周一…周六、周日；取值仍是 1=周日…7=周六）
            HStack(spacing: 6) {
                Text("一周哪些天重复")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("每天") { mutate { r in r.weekdays = ReminderStore.weekdayEveryDay; r.longCycle = nil; r.syncOneShot() } }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .help("勾选周一到周日全部七天")
                Button("周一至周五") { mutate { r in r.weekdays = ReminderStore.weekdayWorkdays; r.longCycle = nil; r.syncOneShot() } }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                Button("周一至周六") { mutate { r in r.weekdays = ReminderStore.weekdayMonToSat; r.longCycle = nil; r.syncOneShot() } }
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
                            // 勾星期 = 放弃长周期循环（三者互斥）；一个都没勾就记成今天（一次性）
                            r.longCycle = nil
                            r.syncOneShot()
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            // 长周期循环（2026-09-28 用户要求：每月 / 每半年 / 每年；与按星期、一次性三者互斥，
            // 循环月/日以「锚点日期」为准 —— 默认今天，可先用下面时间框调整）
            HStack(spacing: 6) {
                Text("长周期循环")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Reminder.LongCycle.allCases, id: \.self) { c in
                    Button(c.label) { setCycle(c) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .foregroundStyle(draft.longCycle == c ? Color.accentColor : Color.secondary)
                }
                if draft.longCycle != nil {
                    Button("取消循环") { mutate { r in r.longCycle = nil; r.syncOneShot() } }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .help("回到「一次性提醒」（日期记成今天）")
                }
                Spacer()
            }

            // 长周期循环说明
            if let cycle = draft.longCycle {
                Text("\(draft.longCycleText)：每到循环日 \(String(format: "%02d:%02d", draft.hour, draft.minute)) 提醒（锚点 "
                     + "\(ReminderRow.shortDay(draft.oneShotDay ?? Reminder.dayString(Date())))）；要改回按星期或一次性，直接勾星期或点「取消循环」。")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 未勾任何星期、也没设长周期 → 一次性提醒（2026-09-17 用户要求：默认为当天设定的时间提醒，而不是不提醒）
            if draft.isOneShot {
                Text("未勾选星期 = 一次性提醒：只在 \(ReminderRow.shortDay(draft.oneShotDay ?? Reminder.dayString(Date()))) "
                     + "\(String(format: "%02d:%02d", draft.hour, draft.minute)) 提醒一次（不每周重复）；要每周重复请勾选上面的星期，要每月/每半年/每年请点上面的长周期。")
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

    /// 设为长周期循环（每月 / 每半年 / 每年）：与按星期互斥；
    /// 循环月/日以 oneShotDay 为锚点（没设过就默认今天）。
    private func setCycle(_ c: Reminder.LongCycle) {
        mutate { r in
            r.longCycle = c
            r.weekdays = []
            if r.oneShotDay == nil { r.oneShotDay = Reminder.dayString(Date()) }
            r.firedOn = nil
            r.completedOn = nil
        }
    }

    /// 编辑弹窗里的快捷时段（2026-09-28 用户要求：默认 30 分钟后，可一键改 1 / 2 / 4 小时后）
    private static let quickOffsets: [(label: String, seconds: TimeInterval)] = [
        ("30分钟后", 30 * 60),
        ("1小时后", 60 * 60),
        ("2小时后", 2 * 60 * 60),
        ("4小时后", 4 * 60 * 60),
    ]

    /// 快捷定为「现在 + seconds」：一次性提醒跨午夜时把提醒日推到明天（与「添加提醒」按钮同一规则）
    private func setRelative(_ seconds: TimeInterval) {
        let target = Date().addingTimeInterval(seconds)
        let cal = Calendar.current
        mutate { r in
            r.hour = cal.component(.hour, from: target)
            r.minute = cal.component(.minute, from: target)
            if r.weekdays.isEmpty {
                r.oneShotDay = Reminder.dayString(target)
                r.firedOn = nil
                r.completedOn = nil          // 重新武装 → 允许按新时间再提醒一次
            }
        }
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
