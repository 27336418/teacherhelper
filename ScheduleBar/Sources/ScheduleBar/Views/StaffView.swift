import SwiftUI

// MARK: - 年级师资安排视图（班级 × 科目表格；行/列可增删，表头与单元格双击编辑）
// 仅「班级」「班型」列支持点击排序（升→降→原顺序循环），其余列不排序；
// 表头双击/右键改名，科目列可删除。
struct StaffView: View {
    @EnvironmentObject var store: StaffStore
    @EnvironmentObject var coordinator: AppCoordinator

    // 排序状态：sortColumn=nil 表示原顺序
    @State private var sortColumn: Int? = nil
    @State private var sortAscending: Bool = true

    // 列宽：班级略窄，其余均分（合计 600，给标题行留足空间不溢出）
    private var colWidths: [CGFloat] {
        let first: CGFloat = 40
        let rest = max(36, (600 - first) / CGFloat(max(1, store.headers.count - 1)))
        return [first] + Array(repeating: rest, count: max(0, store.headers.count - 1))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    EditableCardTitle(icon: "person.text.rectangle", key: "staff")
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                    Spacer()
                    UndoButton()
                    Menu {
                        Button("年级师资安排") { coordinator.importStaffFile() }
                        Divider()
                        Button("下载填写模板") { coordinator.downloadTemplate(.staff) }
                    } label: {
                        Label("导入", systemImage: "square.and.arrow.down")
                    }
                    .help("导入 xlsx：首行为表头，其余为班级行；可先下载模板填写")
                    Button("下载") { coordinator.exportStaff() }
                    Button {
                        store.addColumn()
                    } label: {
                        Label("添加科目", systemImage: "plus.square.on.left.square")
                    }
                    .buttonStyle(.bordered)
                    .help("在末尾添加一列")
                    Button {
                        store.addRow()
                    } label: {
                        Label("添加班级", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                }

                VStack(alignment: .leading, spacing: 4) {
                    // 表头：第一列为「班级」固定名，科目列可双击改名；右键删除科目列
                    HStack(spacing: 4) {
                        // 班级（第 0 列，表头固定不可改名，但可点击排序）
                        SortableHeaderCell(
                            title: "班级",
                            width: colWidths[0],
                            height: 24,
                            isSorted: sortColumn == 0,
                            ascending: sortAscending,
                            onToggleSort: { toggleSort(0) }
                        )
                        ForEach(Array(store.headers.enumerated()), id: \.offset) { i, h in
                            if i > 0 {
                                HStack(spacing: 2) {
                                    SortableHeaderCell(
                                        title: h,
                                        width: colWidths[i] - 14,
                                        height: 24,
                                        isSorted: sortColumn == i,
                                        ascending: sortAscending,
                                        isSortable: isSortableColumn(i),
                                        onToggleSort: { toggleSort(i) },
                                        onRename: { newName in store.renameColumn(i, newName) },
                                        onDelete: { store.removeColumn(i) }
                                    )
                                    Button {
                                        store.removeColumn(i)
                                    } label: {
                                        Image(systemName: "minus.circle")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("删除「\(h)」列")
                                }
                            }
                        }
                    }

                    // 数据行（按排序列展示）
                    ForEach(displayedRows) { row in
                        rowView(binding(for: row.id))
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.3)))
            }
            .padding(16)
        }
    }

    // MARK: 数据行
    private func rowView(_ row: Binding<StaffRow>) -> some View {
        HStack(spacing: 4) {
            ForEach(row.cells.indices, id: \.self) { c in
                EditableGridCell(text: row.cells[c],
                                 width: colWidths[c],
                                 height: 28,
                                 bold: c == 0)
            }
            Button {
                store.removeRow(row.wrappedValue.id)
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("删除此行")
        }
    }

    // MARK: 排序
    /// 仅「班级」（第 0 列固定表头）与「班型」列可排序，其余列（班主任/学科）不参与排序
    private func isSortableColumn(_ i: Int) -> Bool {
        if i == 0 { return true }
        guard store.headers.indices.contains(i) else { return false }
        return store.headers[i].trimmingCharacters(in: .whitespacesAndNewlines) == "班型"
    }

    private func toggleSort(_ col: Int) {
        guard isSortableColumn(col) else {
            // 该列不可排序（例如表头被改名后不再匹配「班型」）：清掉可能遗留的排序
            if sortColumn != nil {
                sortColumn = nil
                sortAscending = true
            }
            return
        }
        if sortColumn == col {
            if sortAscending {
                sortAscending = false
            } else {
                sortColumn = nil
                sortAscending = true
            }
        } else {
            sortColumn = col
            sortAscending = true
        }
    }

    /// 排序后的行（空值恒沉底；同值按原始顺序稳定）
    private var displayedRows: [StaffRow] {
        guard let col = sortColumn else { return store.rows }
        let indexed = Array(store.rows.enumerated())
        let sorted = indexed.sorted { a, b in
            let av = cellText(a.element, col), bv = cellText(b.element, col)
            let ae = av.isEmpty, be = bv.isEmpty
            if ae && be { return a.offset < b.offset }
            if ae { return false }
            if be { return true }
            let r = av.compare(bv, options: [.caseInsensitive, .numeric],
                               range: nil, locale: Locale(identifier: "zh_CN"))
            if r == .orderedSame { return a.offset < b.offset }
            return sortAscending ? (r == .orderedAscending) : (r == .orderedDescending)
        }
        return sorted.map { $0.element }
    }

    private func cellText(_ row: StaffRow, _ col: Int) -> String {
        guard col >= 0, col < row.cells.count else { return "" }
        return row.cells[col]
    }

    /// 行绑定：按 id 回写 store.rows（支撑乱序展示下的编辑/删除）
    private func binding(for id: UUID) -> Binding<StaffRow> {
        Binding(
            get: { store.rows.first { $0.id == id } ?? StaffRow(cells: Array(repeating: "", count: store.headers.count)) },
            set: { newValue in
                guard let i = store.rows.firstIndex(where: { $0.id == id }) else { return }
                store.rows[i] = newValue
            }
        )
    }
}
