import SwiftUI
import AppKit

// MARK: - 定时提醒设置（增删改提醒；启动即默认申请系统通知权限，到点弹窗+系统通知+系统日历日程）
struct ReminderSettingsView: View {
    @EnvironmentObject var reminderStore: ReminderStore
    @ObservedObject private var calendarSync = CalendarSyncService.shared

    @State private var editing: Reminder?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("定时提醒", systemImage: "bell.badge.fill")
                        .font(.headline)
                    Spacer()
                    UndoButton()
                }

                Text("到点会弹窗提醒，可点「等会处理」选择稍后再提醒；文字与网址可自定义并自动保存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                calendarSyncCard

                // 提醒列表
                ForEach(reminderStore.reminders) { r in
                    ReminderRow(reminder: r) {
                        editing = r
                    }
                    .onTapGesture { editing = r }
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
            .padding(12)
        }
        .sheet(item: $editing) { r in
            ReminderEditSheet(reminder: binding(for: r))
        }
        .onAppear { calendarSync.syncAllReminders(reason: "打开提醒设置") }
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

    private func binding(for r: Reminder) -> Binding<Reminder> {
        Binding(
            get: { reminderStore.reminders.first { $0.id == r.id } ?? r },
            set: { reminderStore.update($0) }
        )
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
                        // 一天都没勾 → 永远不会弹，必须让用户看出来
                        Text("未勾选任何星期，不会提醒")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
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
        // 按「周一…周六、周日」显示（只是显示顺序，取值仍是 1=周日…7=周六）
        let ordered = ReminderStore.weekdayDisplayOrder.filter { reminder.weekdays.contains($0) }
        return ordered.map { ReminderStore.weekdayLabel($0) }.joined(separator: " ")
    }
    private var urlAbsolute: URL { URL(string: reminder.url) ?? URL(string: "https://www.baidu.com")! }
}

// MARK: - 编辑弹窗
struct ReminderEditSheet: View {
    @Binding var reminder: Reminder
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("提醒设置")
                .font(.headline)

            TextField("提醒文字", text: $reminder.title)
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
                Button("每天") { reminder.weekdays = ReminderStore.weekdayEveryDay }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .help("勾选周一到周日全部七天")
                Button("周一至周五") { reminder.weekdays = ReminderStore.weekdayWorkdays }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                Button("周一至周六") { reminder.weekdays = ReminderStore.weekdayMonToSat }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                Spacer()
            }
            HStack(spacing: 6) {
                ForEach(ReminderStore.weekdayDisplayOrder, id: \.self) { w in
                    Button(ReminderStore.weekdayLabel(w)) {
                        if reminder.weekdays.contains(w) {
                            reminder.weekdays.remove(w)
                        } else {
                            reminder.weekdays.insert(w)
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(reminder.weekdays.contains(w) ? .accentColor : .gray)
                }
            }

            TextField("网址（可选，点击提醒打开）", text: $reminder.url)
                .textFieldStyle(.roundedBorder)
                .font(.caption)

            HStack {
                Button("测试弹窗") {
                    ReminderFirer.shared.fireTest(reminder)
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
                comps.hour = reminder.hour; comps.minute = reminder.minute
                return cal.date(from: comps) ?? Date()
            },
            set: { date in
                let cal = Calendar.current
                reminder.hour = cal.component(.hour, from: date)
                reminder.minute = cal.component(.minute, from: date)
            }
        )
    }
}
