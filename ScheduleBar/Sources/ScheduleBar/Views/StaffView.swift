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

    // 点击高亮：选中的那一格。它承载的文本就是「分组键」——同一个人（姓名）或同一个班型，
    // 全表所有内容相同的格子一起高亮（与课表「点一格看同内容的其它格」是同一套交互）。
    @State private var selected: StaffCellRef? = nil

    // 列宽：表头与数据行共用同一组宽度（列宽之和 604 + 列间距 40 ≈ 644），保证上下严格对齐。
    // ⚠️ 表头「科目列」右侧要留 16pt 放删除按钮，所以表头单元格取 colWidths[i] - 16，外层再框成 colWidths[i]。
    private var colWidths: [CGFloat] {
        let first: CGFloat = 44
        let rest = max(36, (604 - first) / CGFloat(max(1, store.headers.count - 1)))
        return [first] + Array(repeating: rest, count: max(0, store.headers.count - 1))
    }

    // MARK: 点击高亮（同一人 / 同一班型）
    /// 单元格唯一引用：颜色跟行、高亮跟内容，所以排序/移动都不会错位
    private struct StaffCellRef: Equatable {
        let rowID: UUID
        let col: Int
    }

    /// 当前高亮的分组键（选中格的文本）；空内容 = 不高亮任何格子
    private var highlightKey: String? {
        guard let s = selected,
              let row = store.rows.first(where: { $0.id == s.rowID }),
              row.cells.indices.contains(s.col) else { return nil }
        let t = row.cells[s.col].trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// 该格是否命中当前高亮（忽略大小写、忽略首尾空格）
    private func isHighlighted(_ row: StaffRow, _ col: Int) -> Bool {
        guard let key = highlightKey, row.cells.indices.contains(col) else { return false }
        return StaffStore.matches(row.cells[col], key)
    }

    /// 命中格数（提示条用）
    private var matchCount: Int {
        guard let key = highlightKey else { return 0 }
        return store.rows.reduce(0) { acc, row in
            acc + row.cells.filter { StaffStore.matches($0, key) }.count
        }
    }

    /// 单击一格：选中并高亮同内容；再点同一格取消；点空格清空高亮。
    /// 文本实时从 store 取（编辑完立刻单击也拿到最新值）。
    private func select(_ ref: StaffCellRef) {
        guard let row = store.rows.first(where: { $0.id == ref.rowID }),
              row.cells.indices.contains(ref.col) else {
            selected = nil
            return
        }
        let t = row.cells[ref.col].trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || selected == ref {
            selected = nil
        } else {
            selected = ref
        }
    }

    /// 单元格底色（优先级从高到低）：
    /// ① 右键设过自定义色 → 用自定义色；
    /// ② 学科列 → 用该学科的配色（**不同学科不同颜色**，同一学科整列同色）；
    /// ③ 非学科列（班级 / 班主任 / 班型…）→ 原来的默认灰。
    private func cellFill(_ hex: String?, col: Int) -> Color {
        if let hex, !hex.isEmpty { return Color(hexString: hex).opacity(0.55) }
        guard let subject = subjectHex(col) else { return Color.gray.opacity(0.20) }
        return Color(hexString: subject).opacity(0.30)
    }

    /// 该列对应的学科色（非学科列 → nil）。取色规则集中在 StaffStore，视图不另存一份。
    private func subjectHex(_ col: Int) -> String? {
        guard store.headers.indices.contains(col) else { return nil }
        return StaffStore.subjectColor(forColumnHeader: store.headers[col])
    }

    var body: some View {
        // ⚠️ 这里原来是 ScrollView（整页滚动）→ 顶栏和表头行会被一起滚走。
        //    2026-09-13 用户要求「冻结班级 / 班主任所在的行」+「高亮几处显示在标题旁边」，
        //    所以改成：外层撑满内容区，顶栏与表头固定，只有数据行在内部 ScrollView 里滚。
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    EditableCardTitle(icon: "person.text.rectangle", key: "staff")
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                    // 高亮计数：紧贴标题右侧，不占用别的位置（顶栏固定，滚动时一直可见）
                    highlightBadge
                    Spacer()
                    UndoButton()
                    SaveButton()
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
                    // 表头：第一列为「班级」固定名，科目列可双击改名；列右侧 ⊖ 删除该列
                    // ⚠️ 每列总占用宽度必须等于 colWidths[i]（与数据行一致），否则上下会错位
                    HStack(spacing: 4) {
                        // 班级（第 0 列，表头固定不可改名，但可点击排序）
                        SortableHeaderCell(
                            title: "班级",
                            width: colWidths[0],
                            height: 24,
                            hPadding: 3,
                            iconSize: 7,
                            isSorted: sortColumn == 0,
                            ascending: sortAscending,
                            onToggleSort: { toggleSort(0) }
                        )
                        ForEach(Array(store.headers.enumerated()), id: \.offset) { i, h in
                            if i > 0 {
                                SortableHeaderCell(
                                    title: h,
                                    width: max(30, colWidths[i] - 14),
                                    height: 24,
                                    hPadding: 3,
                                    iconSize: 7,
                                    isSorted: sortColumn == i,
                                    ascending: sortAscending,
                                    isSortable: isSortableColumn(i),
                                    onToggleSort: { toggleSort(i) },
                                    onRename: { newName in store.renameColumn(i, newName) },
                                    onDelete: { store.removeColumn(i) },
                                    // 学科列的表头也染成该学科的颜色 —— 表头即图例
                                    accentHex: subjectHex(i)
                                )
                                .frame(width: colWidths[i], alignment: .leading)
                                .overlay(alignment: .trailing) {
                                    Button {
                                        store.removeColumn(i)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Color.white, Color.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .frame(width: 14, height: 24)
                                    .contentShape(Rectangle())
                                    .help("删除「\(h)」列")
                                }
                            }
                        }
                    }

                    // 数据行（按排序列展示）——只有这一块滚动，表头行留在滚动区外面
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(displayedRows) { row in
                                rowView(binding(for: row.id))
                            }
                        }
                        .padding(.bottom, 2)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.3)))
                // 表格卡片撑满剩余高度：表头固定，数据行在卡片内部滚动
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: 高亮计数徽标（紧贴「年级师资安排」标题右侧；红色，与高亮同色）
    // 放在顶栏里 = 不占用别的版面；顶栏固定不滚动，所以往下翻表也一直看得见「高亮了几处」。
    @ViewBuilder
    private var highlightBadge: some View {
        if let key = highlightKey {
            HStack(spacing: 5) {
                Image(systemName: "highlighter")
                    .font(.system(size: 10, weight: .bold))
                Text("高亮 \(matchCount) 处「\(key)」")
                    .font(.system(size: 11, weight: .semibold))
                    .fixedSize()
                Button {
                    selected = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.red.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("取消高亮（再点一次高亮格、点空格或按 ✕ 都行）")
            }
            .foregroundStyle(Color.red)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.red.opacity(0.14)))
            .overlay(Capsule().stroke(Color.red.opacity(0.45), lineWidth: 1))
            .fixedSize()
            .transition(.opacity)
        }
    }

    // MARK: 数据行
    private func rowView(_ row: Binding<StaffRow>) -> some View {
        let r = row.wrappedValue
        return HStack(spacing: 4) {
            ForEach(row.cells.indices, id: \.self) { c in
                let ref = StaffCellRef(rowID: r.id, col: c)
                let hex = r.colors["\(c)"]
                EditableGridCell(text: row.cells[c],
                                 width: colWidths[c],
                                 height: 28,
                                 bold: c == 0,
                                 backgroundColor: cellFill(hex, col: c),
                                 isSelected: selected == ref,
                                 isHighlighted: isHighlighted(r, c),
                                 highlightColor: .red,
                                 onSingleTap: { select(ref) })
                .contextMenu {
                    cellMenu(rowID: r.id, col: c, text: r.cells[c], hex: hex)
                }
                .help("单击：高亮同一个人 / 同班型的全部格子；双击：编辑；右键：换颜色（默认按学科配色）")
            }
            Button {
                store.removeRow(r.id)
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("删除此行")
        }
    }

    // MARK: 单元格右键菜单（换色）
    @ViewBuilder
    private func cellMenu(rowID: UUID, col: Int, text: String, hex: String?) -> some View {
        ColorPaletteMenu(current: hex) { store.setColor($0, rowID: rowID, col: col) }

        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            Divider()
            // 与「单击高亮」同一套分组：一次把这个人 / 这个班型的全部格子改成同一色
            Menu("「\(key)」的全部格子一起设色") {
                ColorPaletteMenu(current: nil, header: nil) {
                    store.setColorForAllCells(text: key, hex: $0)
                }
            }
        }

        Divider()
        // ⚠️ 文案用「恢复默认色」而不是「清除颜色」：清掉自定义色后会回到**学科配色**，
        //    不是回到灰色，说「清除」会让用户以为格子会变白。
        Button("恢复本格默认色") { store.setColor(nil, rowID: rowID, col: col) }
            .disabled(hex == nil)
        Button(role: .destructive) {
            store.clearAllColors()
        } label: {
            Label("恢复整表默认色（学科配色）", systemImage: "eraser")
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
