import SwiftUI

// MARK: - 横向滚动探针（冻结「姓名」列用）
// 滚动容器里铺一张和整表同尺寸的透明 GeometryReader，它的 minX 就等于「表格内容左边缘」的位置，
// 取负号即横向滚动位移。详见 `StudentInfoView` 里 `hOffset` 的说明。
private struct StudentTableHOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - 学生信息视图（表头冻结、姓名搜索、增删行、双击编辑、导入导出 xlsx）
// 身份证列自动校验：有效=绿，无效=红并提示原因；性别列文字色区分男/女（行不加底色）；
// 「姓名」「身份证…」列为关键列，禁止删除；支持按姓名/性别升序或降序排序。
// 2026-09-26 新增：左右滑动时「姓名」列冻结在左边缘（见 frozenStickX 的说明）。
struct StudentInfoView: View {
    @EnvironmentObject var store: StudentStore
    @EnvironmentObject var coordinator: AppCoordinator

    @State private var keyword: String = ""
    @State private var appliedKeyword: String = ""   // 去抖后的关键字（避免每次键入都重算表格）
    @State private var searchWork: DispatchWorkItem?

    // 排序状态：sortColumn=nil 表示原顺序；点击表头在 升序 → 降序 → 原顺序 间循环
    @State private var sortColumn: Int? = nil
    @State private var sortAscending: Bool = true
    @State private var renameIndex: Int? = nil       // 表头右键「重命名」目标列
    @State private var renameText: String = ""
    @FocusState private var headerFocus: Bool

    private let rowHeight: CGFloat = 26
    private let gap: CGFloat = 4

    /// 表格滚动容器的坐标空间名（探针与它配对使用）
    private static let tableSpace = "studentInfoTable"

    /// 当前横向滚动位移（pt）。
    ///
    /// ⚠️ 为什么用「读位移 + 反向 offset」这种土办法冻结姓名列，而不是把它拆成独立的一列：
    ///   表格是**一个** `ScrollView([.vertical, .horizontal])`，表头靠 `pinnedViews` 钉在顶部。
    ///   如果把姓名列拆出去单独放，就会出现两个新问题 ——
    ///   ① 表头和数据各自一个横向滚动视图 → 横向滚动不同步，列头与列内容立刻错位（§39a 的老坑）；
    ///   ② 冻结列与右侧区各自纵向滚动 → 行高对不上就上下错位。
    ///   反向 offset 不复制任何布局，只把「姓名格」按滚动量推回去，因此天然与表头/行严格对齐。
    @State private var hOffset: CGFloat = 0

    /// 「姓名」列之前的列宽总和（含列间距）—— 横向滚过这段距离，姓名列就贴到左边缘
    private var frozenPrefixWidth: CGFloat {
        guard let n = store.nameColumn, n > 0 else { return 0 }
        let upper = min(n, store.headers.count)
        return (0..<upper).reduce(0) { $0 + colWidth(store.headers[$1]) + gap }
    }

    /// 姓名列的「贴左」位移：0 = 还没滚到该列，>0 = 已经钉在左边缘（Excel 冻结窗格的手感）
    private var frozenStickX: CGFloat {
        store.nameColumn == nil ? 0 : max(0, hOffset - frozenPrefixWidth)
    }

    /// 冻结列的底色：**只在真的钉住时**才铺不透明底
    /// （否则行行都变不透明白条，磨砂面板的观感就没了）
    @ViewBuilder
    private func frozenBackground(_ on: Bool) -> some View {
        if on && frozenStickX > 0 {
            RoundedRectangle(cornerRadius: 5).fill(Color(NSColor.windowBackgroundColor))
        } else {
            Color.clear
        }
    }

    /// 冻结列右边缘的分隔线（钉住时才画）：让「这是一列被冻住的名字」一眼可见
    @ViewBuilder
    private func frozenEdge(_ on: Bool) -> some View {
        if on && frozenStickX > 0 {
            Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1)
        } else {
            Color.clear.frame(width: 0)
        }
    }

    private var totalWidth: CGFloat {
        store.headers.reduce(0) { $0 + colWidth($1) + gap } + 30
    }

    /// 取证用（用户要求「不用截图说明」）：把冻结姓名列的实测几何打进日志。
    /// 用法：`SCHEDULEBAR_TRACE_STUDENT=1 ./教师助手.app/Contents/MacOS/Student… --tab 学生信息`
    /// 关键判读：
    ///   · **表宽 > 可视宽** 才谈得上「左右滑动」；否则整张表本来就放得下，冻结无从谈起。
    ///   · 「该列前宽」= 横向滚过这么多 pt 后，姓名列贴到左边缘（Excel 冻结窗格的手感）。
    private func traceFrozenColumn(viewWidth: CGFloat) {
        guard ProcessInfo.processInfo.environment["SCHEDULEBAR_TRACE_STUDENT"] == "1" else { return }
        let n = store.nameColumn
        let prefix = Int(frozenPrefixWidth.rounded())
        let table = Int(totalWidth.rounded())
        let view = Int(viewWidth.rounded())
        DragSessionGuard.log("学生信息列冻结：列数 \(store.headers.count)｜表宽 \(table)pt｜可视 \(view)pt｜"
            + (table > view ? "需横向滑动 ✓" : "⚠️ 表宽未超可视宽，冻不冻都看不出差别")
            + "｜姓名列 #\(n.map(String.init) ?? "无")（\(n.map { store.headers.indices.contains($0) ? store.headers[$0] : "?" } ?? "—")）"
            + "｜该列前宽 \(prefix)pt → 横向滚过 \(prefix)pt 后钉在左边缘"
            + "｜列宽：\(store.headers.map { "\($0)=\(Int(colWidth($0).rounded()))" }.joined(separator: " "))")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 标题行：导入 / 下载 / 添加学生 / 添加列
            HStack {
                EditableCardTitle(icon: "person.2.fill", key: "student")
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                Spacer()
                UndoButton()
                SaveButton()
                Menu {
                    Button("学生信息") { coordinator.importStudentFile() }
                    Divider()
                    Button("下载填写模板") { coordinator.downloadTemplate(.student) }
                } label: {
                    Label("导入", systemImage: "square.and.arrow.down")
                }
                .help("导入 xlsx：首行为表头，其余为学生行；可先下载模板填写")
                Button("下载") { coordinator.exportStudent() }
                Button {
                    store.addColumn()
                } label: {
                    Label("添加列", systemImage: "plus.square.on.left.square")
                }
                .buttonStyle(.bordered)
                Button {
                    store.addRow()
                } label: {
                    Label("添加学生", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }

            // 姓名查询 + 排序
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("输入姓名查询", text: $keyword)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onChange(of: keyword) { v in
                        searchWork?.cancel()
                        let w = DispatchWorkItem { appliedKeyword = v }
                        searchWork = w
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
                    }
                if !keyword.isEmpty {
                    Button {
                        keyword = ""
                        appliedKeyword = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Text("共 \(visibleCount) 人")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                sortMenu
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))

            // 表格：横向 + 纵向滚动，表头冻结在顶部、姓名列冻结在左侧
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(visibleRows) { row in
                            rowView(binding(for: row.id))
                        }
                    } header: {
                        headerRow
                    }
                }
                .frame(width: totalWidth)
                // 探针：和整表同尺寸的透明层，它的 minX = 内容左边缘 → 取负即横向滚动位移
                .background(alignment: .topLeading) {
                    GeometryReader { g in
                        Color.clear.preference(key: StudentTableHOffsetKey.self,
                                               value: -g.frame(in: .named(Self.tableSpace)).minX)
                    }
                }
            }
            .coordinateSpace(name: Self.tableSpace)
            .onPreferenceChange(StudentTableHOffsetKey.self) { v in
                // 去抖：位移变化小于 0.5pt 不写 @State，避免每帧都触发整表重绘
                let clamped = max(0, v)
                if abs(clamped - hOffset) > 0.5 { hOffset = clamped }
            }
            .frame(maxHeight: .infinity)
            .padding(6)
            // 量一次「可视宽」给取证日志用（只在 SCHEDULEBAR_TRACE_STUDENT=1 时打印）
            .background(alignment: .topLeading) {
                GeometryReader { g in
                    Color.clear.onAppear { traceFrozenColumn(viewWidth: g.size.width) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.3)))
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 冻结表头（点击列头排序，双击改名，右键删除/改名）
    // 「姓名」列表头与数据格用同一套冻结位移，所以左右滑动时表头与内容永远对齐。
    private var headerRow: some View {
        HStack(spacing: gap) {
            ForEach(Array(store.headers.enumerated()), id: \.offset) { i, h in
                SortableHeaderCell(
                    title: h,
                    width: colWidth(h),
                    height: 28,
                    isSorted: sortColumn == i,
                    ascending: sortAscending,
                    onToggleSort: { toggleSort(i) },
                    onRename: store.isProtectedColumn(i) ? nil : { newName in store.renameColumn(i, newName) },
                    onDelete: store.isProtectedColumn(i) ? nil : { store.removeColumn(i) },
                    lockedNote: store.isProtectedColumn(i) ? "「\(h)」为关键列，不可改名或删除" : nil
                )
                .background(frozenBackground(i == store.nameColumn))
                .overlay(alignment: .trailing) { frozenEdge(i == store.nameColumn) }
                .offset(x: i == store.nameColumn ? frozenStickX : 0)
                .zIndex(i == store.nameColumn ? 2 : 0)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(Divider(), alignment: .bottom)
    }

    // MARK: 数据行（无底色；性别仅在对应格内以文字色区分）
    private func rowView(_ row: Binding<StudentRow>) -> some View {
        HStack(spacing: gap) {
            ForEach(row.cells.indices, id: \.self) { c in
                cellView(row, col: c)
            }
            Button {
                store.removeRow(row.wrappedValue.id)
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("删除这名学生")
        }
        .padding(.vertical, 1)
    }

    // MARK: 单元格：身份证列自动校验着色，其余普通
    @ViewBuilder
    private func cellView(_ row: Binding<StudentRow>, col c: Int) -> some View {
        let header = store.headers[c]
        let frozen = (c == store.nameColumn)
        Group {
            if c == store.idCardColumn {
                let text = row.wrappedValue.cells[c]
                let check = IdCardValidator.validate(text)   // nil=空串
                let bg: Color? = check == nil ? nil
                    : (check!.valid ? Color(hex: 0x27AE60).opacity(0.16)
                                    : Color(hex: 0xE74C3C).opacity(0.18))
                let tc: Color? = check == nil ? nil
                    : (check!.valid ? Color(hex: 0x1E8449) : Color(hex: 0xC0392B))
                EditableGridCell(text: row.cells[c],
                                 width: colWidth(header),
                                 height: rowHeight,
                                 font: .system(size: 11),
                                 backgroundColor: bg,
                                 textColor: tc)
                    .help(check?.message ?? "双击编辑身份证号")
            } else {
                // 性别列：文字色区分男/女（行不加底色）
                let tc = (c == store.genderColumn)
                    ? genderTextColor(row.wrappedValue.cells[c])
                    : nil
                EditableGridCell(text: row.cells[c],
                                 width: colWidth(header),
                                 height: rowHeight,
                                 font: .system(size: 11),
                                 textColor: tc)
            }
        }
        // 冻结「姓名」列：按横向滚动量反向位移把它推回左边缘；
        // 钉住时铺不透明底 + 画右分隔线，并抬 zIndex（否则会被它右边那些列盖住）。
        .background(frozenBackground(frozen))
        .overlay(alignment: .trailing) { frozenEdge(frozen) }
        .offset(x: frozen ? frozenStickX : 0)
        .zIndex(frozen ? 2 : 0)
    }

    // 性别文字色：男=蓝、女=粉；其它/无性别列返回无色（行底色一律不加）
    private func genderTextColor(_ g: String) -> Color? {
        if g.contains("男") { return Color(hex: 0x2E86C1) }
        if g.contains("女") { return Color(hex: 0xD81B60) }
        return nil
    }

    // MARK: 查询
    private func matches(_ row: StudentRow) -> Bool {
        let kw = appliedKeyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return true }
        if let n = store.nameColumn {
            return n < row.cells.count && row.cells[n].localizedCaseInsensitiveContains(kw)
        }
        return row.cells.contains { $0.localizedCaseInsensitiveContains(kw) }
    }

    private var visibleCount: Int {
        visibleRows.count
    }

    // MARK: 排序（先过滤再排序；空值永远排在最后；同值按姓名稳定）
    private var visibleRows: [StudentRow] {
        var list = store.rows.filter { matches($0) }
        if let col = sortColumn {
            list.sort {
                compareCell($0, $1, col: col, asc: sortAscending, tieBreak: true)
            }
        }
        return list
    }

    /// 单元格文本；越界/无列返回空串
    private func cellText(_ row: StudentRow, _ col: Int?) -> String {
        guard let col, col >= 0, col < row.cells.count else { return "" }
        return row.cells[col]
    }

    /// 排序比较器：升/降序，空值一律沉底；tieBreak=同值时按姓名稳定排序
    private func compareCell(_ a: StudentRow, _ b: StudentRow,
                             col: Int?, asc: Bool, tieBreak: Bool = false) -> Bool {
        let av = cellText(a, col), bv = cellText(b, col)
        if av.isEmpty && bv.isEmpty {
            return tieBreak ? compareCell(a, b, col: store.nameColumn, asc: true, tieBreak: false) : false
        }
        if av.isEmpty { return false }
        if bv.isEmpty { return true }
        let r = av.compare(bv, options: [.caseInsensitive, .numeric],
                           range: nil, locale: Locale(identifier: "zh_CN"))
        if r == .orderedSame {
            return tieBreak ? compareCell(a, b, col: store.nameColumn, asc: true, tieBreak: false) : false
        }
        return asc ? (r == .orderedAscending) : (r == .orderedDescending)
    }

    /// 点击某列表头：首次=升序，再点=降序，第三次=取消排序
    private func toggleSort(_ col: Int) {
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

    /// 该列是否正在参与排序
    private func isSorting(_ col: Int) -> Bool {
        sortColumn == col
    }
    /// 表格行的双向绑定（按 id 回写 store.rows，支撑乱序展示下的编辑/删除）
    private func binding(for id: UUID) -> Binding<StudentRow> {
        Binding(
            get: { store.rows.first { $0.id == id } ?? StudentRow(cells: Array(repeating: "", count: store.headers.count)) },
            set: { newValue in
                guard let i = store.rows.firstIndex(where: { $0.id == id }) else { return }
                store.rows[i] = newValue
            }
        )
    }

    // MARK: 排序菜单（快捷方式；表头点击同样可排序）
    private var sortMenu: some View {
        Menu {
            Button {
                sortColumn = nil
            } label: {
                if sortColumn == nil {
                    Label("不排序（原顺序）", systemImage: "checkmark")
                } else {
                    Text("不排序（原顺序）")
                }
            }
            Divider()
            ForEach(sortShortcuts, id: \.title) { sc in
                Button {
                    sortColumn = sc.col
                    sortAscending = sc.asc
                } label: {
                    if sortColumn == sc.col && sortAscending == sc.asc {
                        Label(sc.title, systemImage: "checkmark")
                    } else {
                        Text(sc.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: sortMenuIcon)
                    .font(.system(size: 10, weight: .semibold))
                Text(sortMenuText)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(Color.accentColor.opacity(sortColumn == nil ? 0.05 : 0.12)))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(Color.accentColor.opacity(sortColumn == nil ? 0.12 : 0.3), lineWidth: 0.6))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("按姓名 / 性别排序（点击表头可对任意列排序）")
    }

    /// 菜单按钮图标与文字：反映当前生效的排序列
    private var sortMenuIcon: String {
        guard sortColumn != nil else { return "arrow.up.arrow.down" }
        return sortAscending ? "arrow.up" : "arrow.down"
    }
    private var sortMenuText: String {
        guard let col = sortColumn, store.headers.indices.contains(col) else { return "排序" }
        let h = store.headers[col]
        return "\(h)\(sortAscending ? " ↑" : " ↓")"
    }

    /// 快捷排序项：姓名 / 性别两列（存在才加入）
    private var sortShortcuts: [(col: Int, asc: Bool, title: String)] {
        var out: [(col: Int, asc: Bool, title: String)] = []
        if let n = store.nameColumn {
            out.append((n, true, "按姓名 升序"))
            out.append((n, false, "按姓名 降序"))
        }
        if let g = store.genderColumn {
            out.append((g, true, "按性别 升序"))
            out.append((g, false, "按性别 降序"))
        }
        return out
    }

    // MARK: 列宽（按字段内容长短分配）
    private func colWidth(_ header: String) -> CGFloat {
        switch header {
        case "序号":                 return 42
        case "新班级", "原班级":      return 58
        case "年龄", "性别", "民族":  return 56
        case "姓名", "新班主任":      return 76
        case "监护人1", "监护人2":    return 76
        case "监护人1电话", "监护人2电话": return 108
        case "身份证号码":            return 168
        case "出生日期":              return 88
        case "智学网账号":            return 88
        case "所属省市":              return 78
        case "残疾", "单亲":          return 56
        case "特殊疾病":              return 160
        case "贫困或父母有残疾":      return 140
        case "备注":                  return 150
        case "住址":                  return 240
        default:                      return 96
        }
    }
}
