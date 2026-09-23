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

    // 与班级课表严格一致：标签 52 + 6×94 + 间距 8×5 = 656，撑满内容区
    private let colWidth: CGFloat = 94

    /// 跨天自动刷新（避免过了午夜仍高亮昨天那一列）
    @ObservedObject private var clock = TodayClock.shared

    /// 今天对应的表头列下标（周一~周五→0~4，周日→5；周六无列返回 nil）
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
            HStack {
                EditableCardTitle(icon: "person.crop.rectangle", key: "personal")
                Spacer()
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

            // 表头（当前星期列高亮，课表内容不变）
            HStack(spacing: spacing) {
                Text("节次").font(.caption.bold()).frame(width: labelWidth, alignment: .leading)
                ForEach(0..<ScheduleStore.days.count, id: \.self) { d in
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

            // 按分组动态渲染（组头可添加节次，节次右键删除）
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
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.3)))
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

            ForEach(0..<ScheduleStore.days.count, id: \.self) { d in
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
