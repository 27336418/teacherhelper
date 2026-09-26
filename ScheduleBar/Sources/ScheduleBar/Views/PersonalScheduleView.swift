import SwiftUI
import Foundation

// MARK: - 班级配色图例项
private struct ClassLegendItem: Identifiable {
    let id = UUID()
    let name: String
    let color: Color
}

// MARK: - 个人课表卡片（与班级课表一致的分组结构：上午 / 下午 / 晚自习，节次可增删）
struct PersonalScheduleView: View {
    @EnvironmentObject var store: ScheduleStore
    @EnvironmentObject var coordinator: AppCoordinator

    @State private var selected: ScheduleCellID? = nil
    @State private var editing: ScheduleCellID? = nil

    // 与班级课表严格一致：节次标签 52 + n×(列宽 + 间距 8)（n = 可见列数，周六/周日按开关增减）
    //
    // ⚠️ 列宽**不是常量**：2026-09-26 用户要求「显示周六时自动缩小列宽，保证整体没有向右扩展宽度」。
    //    面板内容区恒为 709（课表页不再撑宽面板），所以 7 列时列宽由 94 压到 80，
    //    整表 684 ≤ 689（709 − 20 滚动条余量），一列都不会被切。
    //    6 列以内仍是 94 → 默认视图与旧版像素级一致。
    private var colWidth: CGFloat {
        ScheduleWeek.scheduleColumnWidth(columns: dayPrefs.visibleDayCount)
    }

    /// 跨天自动刷新（避免过了午夜仍高亮昨天那一列）
    @ObservedObject private var clock = TodayClock.shared

    /// 星期列显隐（三张课表共用一份设置）
    @ObservedObject private var dayPrefs = ScheduleDayPrefsStore.shared

    /// 当前可见的星期列下标 —— 数据永远是 7 列，这里只是**渲染层过滤**，隐藏不删数据
    private var visibleDays: [Int] { dayPrefs.visibleDayIndices }

    /// 今天对应的表头列下标（周一~周六→0~5，周日→6）
    private var todayColumn: Int? { clock.weekdayColumn }
    private let labelWidth: CGFloat = 52
    private let spacing: CGFloat = 8

    /// 选中格的班级键（"7"/"7班" 都归为 "7班"），用于高亮全表同班级的格子
    private var selectedKey: String? {
        guard let s = selected else { return nil }
        let key = classKey(store.cell(s.period, s.day))
        return key.isEmpty ? nil : key
    }

    /// 底部图例：自动扫描课表中出现过的班级 → 对应颜色
    private var legend: [ClassLegendItem] {
        var map: [String: Color] = [:]
        for row in store.grid {
            for cell in row {
                for t in classTokens(cell) where !t.isEmpty {
                    map[t] = classTokenColor(t)
                }
            }
        }
        return map.sorted { a, b in
            let na = Int(a.0.replacingOccurrences(of: "班", with: "")) ?? Int.max
            let nb = Int(b.0.replacingOccurrences(of: "班", with: "")) ?? Int.max
            return na == nb ? a.0 < b.0 : na < nb
        }
        .map { ClassLegendItem(name: $0.0, color: $0.1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolbarRow

            // ⚠️ 2026-09-26 用户要求「滚动时冻结这些内容」：
            //    ① 工具栏（标题 / 撤销·保存·导入·下载）留在滚动区**外面**，往下翻节次时一直可见；
            //    ② 「节次 / 星期1…周日」表头行用 `pinnedViews: [.sectionHeaders]` 钉在表体顶部。
            //       ⚠️ 表头必须和表体在**同一个**滚动容器里：分开放会因滚动条占用宽度而错位（§39a）。
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(Array(store.groups.enumerated()), id: \.offset) { gIdx, group in
                            HStack(spacing: spacing) {
                                Text(group.title).font(.caption.bold())
                                    .frame(width: labelWidth, alignment: .leading)
                                Button {
                                    store.addPeriod(in: gIdx)
                                } label: {
                                    Image(systemName: "plus.circle")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("在「\(group.title)」添加节次")
                                Spacer()
                            }
                            .padding(.vertical, 2)

                            ForEach(group.periods, id: \.self) { p in
                                periodRow(p)
                            }
                        }

                        // 班级配色图例（不同班级 → 不同颜色）
                        if !legend.isEmpty {
                            HStack(spacing: 10) {
                                Text("班级色").font(.system(size: 10)).foregroundStyle(.secondary)
                                ForEach(legend) { item in
                                    HStack(spacing: 3) {
                                        Circle().fill(item.color).frame(width: 8, height: 8)
                                        Text(item.name).font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                        }
                    } header: {
                        columnHeaderRow
                            .padding(.bottom, 2)
                            .background { FrostedView() }
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.3)))
    }

    // MARK: - 顶部工具栏（冻结在滚动区外）
    private var toolbarRow: some View {
        HStack {
            EditableCardTitle(icon: "person.crop.rectangle", key: "personal")
            Spacer()
            WeekVisibilityMenu()
            UndoButton()
            SaveButton()
            // 与班级课表风格一致：右上角「导入」下拉 + 「下载」
            Menu {
                Button("本人课表") { coordinator.importPersonalFile() }
                Divider()
                Button("下载填写模板") { coordinator.downloadTemplate(.personal) }
            } label: {
                Label("导入", systemImage: "square.and.arrow.down")
            }
            .help("下载模板：先导出空白模板，填写后从这里导入")
            Button("下载") { coordinator.exportPersonal() }
        }
    }

    // MARK: - 表头行（节次 / 星期1…周日，钉在表体顶部）
    private var columnHeaderRow: some View {
        HStack(spacing: spacing) {
            Text("节次").font(.caption.bold()).frame(width: labelWidth, alignment: .leading)
            ForEach(visibleDays, id: \.self) { d in
                let isToday = d == todayColumn
                Text(ScheduleStore.days[d]).font(.caption.bold())
                    .frame(width: colWidth)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isToday ? Color.accentColor.opacity(0.16) : Color.clear)
                    )
                    .foregroundStyle(isToday ? Color.accentColor : Color.secondary)
            }
        }
    }

    // MARK: 一行节次
    private func periodRow(_ p: String) -> some View {
        HStack(spacing: spacing) {
            Text(p).font(.caption)
                .frame(width: labelWidth, alignment: .trailing)
                .contentShape(Rectangle())
                .contextMenu {
                    Button(role: .destructive) {
                        store.removePeriod(p)
                        selected = nil
                        editing = nil
                    } label: {
                        Label("删除此节次", systemImage: "minus.circle")
                    }
                }
                .help("右键可删除此节次")

            ForEach(visibleDays, id: \.self) { d in
                cellView(period: p, day: d)
            }
        }
    }

    // MARK: 单个单元格：不同班级 → 不同颜色
    private func cellView(period: String, day: Int) -> some View {
        let id = ScheduleCellID(period: period, day: day)
        let cellText = store.cell(period, day)
        let sameContent = selectedKey != nil && classKey(cellText) == selectedKey
        return ScheduleCell(
            text: cellText,
            width: colWidth,
            id: id,
            color: classColor,
            isSelected: selected == id,
            isSameContent: sameContent,
            isEditing: editing == id,
            isDimmed: selectedKey != nil,
            onSelect: {
                editing = nil
                if selected == id { selected = nil } else { selected = id }
            },
            onStartEditing: {
                editing = id
                selected = nil
            },
            onUpdate: { store.setCell(period, day, $0) },
            onEndEditing: { editing = nil }
        )
        .onDrag {
            store.beginCellDrag(period, day)
            // 拿起时同步登记来源模块，落点据此同步换位（见 DragSwapSupport.swift 的说明）
            let payload = DragPayload.cell(DragPayload.personalCell, period, day)
            DragContext.begin(module: DragPayload.personalCell, payload: payload)
            return NSItemProvider(object: payload as NSString)
        }
        .onDrop(of: [.text], delegate: ScheduleCellSwapDelegate(
            table: DragPayload.personalCell,
            onPerform: { store.swapCellTo(period, day) },
            onFinish: { store.finishCellDrag() }
        ))
        .help("单击：高亮全表同班级，其余格子变灰；再点一次取消。双击编辑；拖动可与其它格子对换")
    }
}
