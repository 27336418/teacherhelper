import SwiftUI

// MARK: - 普通日历（固定 22 周；第一天为周一；左列周次、最右列备注）
// 日期由「设置-第1周开始日期」推算；当天绿色高亮、法定节假日红色、右键自定义颜色。
struct ChongqingCalendarView: View {
    @EnvironmentObject var weekStore: WeekStore
    // 注意：必须观察 Store，否则右键换色后视图不会刷新（此前换色“未生效”的根因）
    @ObservedObject private var remarkStore = CalendarRemarkStore.shared
    @ObservedObject private var dayColorStore = CalendarDayColorStore.shared

    private let labelWidth: CGFloat = 64
    private let dayWidth: CGFloat = 56
    private let remarkWidth: CGFloat = 180
    private let rowHeight: CGFloat = 34

    // 当天用绿色高亮
    private let todayGreen = Color(hex: 0x27AE60)
    private let holidayRed = Color(hex: 0xC0392B)
    // 日历普通格底色（浅灰，配合 40% 不透明度 = 60% 透明）
    private let calendarCellGray = Color(hex: 0xB8C0C8)

    // 按天备注：窗口内弹层编辑（替代系统弹窗，永不被挡）
    @State private var remarkTarget: Date? = nil
    @State private var remarkDraft = ""
    @FocusState private var remarkFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("学年日历")
                        .font(.title3.bold())
                        .foregroundStyle(semester1Color)
                    Text("共 \(ChongqingCalendar.totalWeeks) 周 · 起点为设置的第 1 周")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    UndoButton()
                    SaveButton()
                }

                // 头部：星期
                HStack(spacing: 2) {
                    Text("周次")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: labelWidth)
                        .foregroundStyle(semester1Color)
                    ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { d in
                        Text(d)
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: dayWidth)
                            .foregroundStyle(semester1Color)
                    }
                    Text("备注")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: remarkWidth, alignment: .leading)
                        .foregroundStyle(semester1Color)
                }
                .padding(.horizontal, 2)

                // 数据行：固定第 1 周 ~ 第 22 周
                ForEach(1...ChongqingCalendar.totalWeeks, id: \.self) { n in
                    weekRow(n)
                }
            }
            .padding(16)
            // 按天备注编辑弹层：直接画在本窗口内，不可能被其他界面挡住
            .overlay {
                if let target = remarkTarget {
                    ZStack {
                        Color.primary.opacity(0.2)
                            .contentShape(Rectangle())
                            .onTapGesture { remarkTarget = nil }
                        VStack(spacing: 10) {
                            Text("日期备注")
                                .font(.system(size: 13, weight: .semibold))
                            Text(Self.dayText(target))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            TextField("例如：月考 / 教研活动 / 放假", text: $remarkDraft)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 220)
                                .focused($remarkFocused)
                                .onSubmit { commitDayRemark() }
                            HStack(spacing: 10) {
                                Button("清除备注") {
                                    remarkStore.set("", forDay: target)
                                    if dayColorStore.color(for: target) == Self.remarkGreen {
                                        dayColorStore.setColor(nil, for: target)
                                    }
                                    remarkTarget = nil
                                }
                                Button("取消") { remarkTarget = nil }
                                Button {
                                    commitDayRemark()
                                } label: {
                                    Text("确定").frame(width: 60)
                                }
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut(.defaultAction)
                            }
                        }
                        .padding(16)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.2), lineWidth: 1))
                        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                    }
                    .zIndex(9999)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // 单周行
    private func weekRow(_ n: Int) -> some View {
        let cal = Calendar.current
        let anchor = weekStore.firstWeekMonday ?? weekStore.alignedMonday(of: Date())
        let monday = ChongqingCalendar.monday(week: n, firstWeekMonday: anchor)
        let weekDays: [Date] = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: monday) }
        let today = cal.startOfDay(for: Date())
        let isCurrentWeek = today >= cal.startOfDay(for: monday)
            && today < cal.startOfDay(for: cal.date(byAdding: .day, value: 7, to: monday)!)

        return HStack(spacing: 2) {
            // 周次
            Text("第\(n)周")
                .font(.system(size: 12, weight: isCurrentWeek ? .bold : .regular))
                .foregroundStyle(isCurrentWeek ? weekAmber : semester1Color)
                .frame(width: labelWidth, height: rowHeight)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(isCurrentWeek ? weekRowYellow.opacity(0.9) : Color.clear))

            // 七天日期（日/月）
            ForEach(Array(weekDays.enumerated()), id: \.offset) { _, d in
                dayCell(d, isCurrentWeek: isCurrentWeek, today: today)
            }

            // 备注（可编辑，自动保存）
            TextField("", text: Binding(
                get: { remarkStore.remark(forWeek: n) },
                set: { remarkStore.set($0, forWeek: n) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(isCurrentWeek ? weekAmber : .secondary)
            .lineLimit(2)
            .frame(width: remarkWidth, height: rowHeight, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(calendarCellGray.opacity(isCurrentWeek ? 0 : 0.4))
            )
            .help("点击可编辑备注")
        }
        .padding(.horizontal, 2)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(isCurrentWeek ? weekRowYellow.opacity(0.85) : Color.clear))
    }

    // 单日格：日/月显示 + 分层配色（自定义 > 当天绿 > 节假日红 > 当前周黄 > 默认）+ 右键换色
    private func dayCell(_ d: Date, isCurrentWeek: Bool, today: Date) -> some View {
        let cal = Calendar.current
        let text = "\(cal.component(.day, from: d))/\(cal.component(.month, from: d))"
        let isToday = today == cal.startOfDay(for: d)
        let holiday = ChongqingCalendar.holidayName(for: d)
        let customHex = dayColorStore.color(for: d)

        let cellFill: Color
        let cellText: Color
        if customHex != nil {
            cellFill = Color(hexString: customHex).opacity(0.30)
            cellText = Color.primary
        } else if isToday {
            cellFill = todayGreen
            cellText = Color.white
        } else if holiday != nil {
            cellFill = Color(hex: 0xE74C3C).opacity(0.15)
            cellText = holidayRed
        } else if isCurrentWeek {
            cellFill = weekRowYellow.opacity(0.9)
            cellText = weekAmber
        } else {
            // 普通日期格：浅灰底 + 60% 透明（不透明度 40%），格子清晰又不压字
            cellFill = calendarCellGray.opacity(0.4)
            cellText = Color.primary
        }

        return Text(text)
            .font(.system(size: 11.5, weight: isToday || isCurrentWeek ? .bold : .regular))
            .foregroundStyle(cellText)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: dayWidth, height: rowHeight)
            .background(RoundedRectangle(cornerRadius: 4).fill(cellFill))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isToday ? todayGreen : Color.clear, lineWidth: 1.5)
            )
            .contextMenu {
                Button {
                    remarkDraft = remarkStore.remark(forDay: d)
                    remarkTarget = d
                    DispatchQueue.main.async { remarkFocused = true }
                } label: {
                    Label(remarkStore.remark(forDay: d).isEmpty ? "添加备注…" : "编辑备注…",
                          systemImage: "square.and.pencil")
                }
                Divider()
                ColorPaletteMenu(current: customHex) { dayColorStore.setColor($0, for: d) }
            }
            // 悬停立即显示：备注 / 节假日（不等系统 tooltip）
            .instantTooltip(Self.hoverTip(remark: remarkStore.remark(forDay: d),
                                          holiday: holiday, custom: customHex != nil),
                            below: false)
            .help(holiday == nil && customHex != nil ? "右键可备注/更换颜色" : "")
    }

    private static func dayText(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEEE"
        return f.string(from: d)
    }

    /// 悬停气泡文案：备注优先，其次节假日
    private static func hoverTip(remark: String, holiday: String?, custom: Bool) -> String {
        var parts: [String] = []
        if !remark.isEmpty { parts.append(remark) }
        if let h = holiday { parts.append("节假日：\(h)") }
        if parts.isEmpty, custom { parts.append("右键可备注/更换颜色") }
        return parts.joined(separator: " ｜ ")
    }

    private func commitDayRemark() {
        guard let target = remarkTarget else { return }
        remarkStore.set(remarkDraft, forDay: target)
        // 有备注 → 自动把该天设为绿色（与调色板「绿色」一致）
        if !remarkDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            dayColorStore.setColor(Self.remarkGreen, for: target)
        } else if dayColorStore.color(for: target) == Self.remarkGreen {
            // 清空备注且颜色是自动加的绿色 → 一并还原（不覆盖用户手动选的其他颜色）
            dayColorStore.setColor(nil, for: target)
        }
        remarkTarget = nil
    }

    /// 添加备注时自动填充的日期颜色（调色板「绿色」）
    private static let remarkGreen = "2ECC71"
}
