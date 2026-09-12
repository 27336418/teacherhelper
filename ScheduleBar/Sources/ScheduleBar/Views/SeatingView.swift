import SwiftUI
import AppKit

// MARK: - 班级学生座位安排 v2（一张完整大表 / Excel 式行列号 + 右键插删 / 点选格子组成小组（同色块）/ ⌘拖整体移动 / 待用栏）
struct SeatingView: View {
    @EnvironmentObject var store: SeatingStore
    @EnvironmentObject var coordinator: AppCoordinator

    /// 当前拖拽高亮的落点：格子 "r-c" 或 待用栏 "pool"
    @State private var highlight: String? = nil
    @State private var dragging: String? = nil
    /// 正在编辑的格子（双击姓名进入编辑态，单击即时选中，互不等待）
    @State private var editingKey: CellKey? = nil

    private let cellHeight: CGFloat = 34
    private let headerW: CGFloat = 20          // 行/列号表头宽度
    private let minCellWidth: CGFloat = 34     // 低于此宽才左右滑动

    /// 多选锚点（⇧ 单击从此格框选到目标格，Excel 式）
    @State private var selectAnchor: CellKey? = nil
    /// 待用栏多选（单击选中 / ⌘单击加选；右键批量移除）
    @State private var poolSelection: Set<String> = []
    /// 导入下拉菜单（窗口内自绘，保证永不被其他界面挡住）
    @State private var showImportMenu = false
    /// 小组改名（窗口内自绘弹层，替代 NSAlert，保证永不被挡）
    @State private var renameTarget: SeatRegion? = nil
    @State private var renameDraft = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    Text("座次表为一张完整表格（默认 8×8，完整显示）。右键行号/列号可在任意位置插删行列；多选与 Excel 一致：单击选中一格，⌘单击加选/减选，⇧单击框选一片；选好后「组成小组」用同一色块标出，悬停立即显示组名；想撤销分组就选中那些格子点「取消分组」（组被移空会自动解散），或右键组内格子「解散小组」；右键组内格子还可改名/整体放入待用栏；⌘拖组内格子整体移动小组（组名跟组走，⌘拖到待用栏=整组放入待用）；拖动姓名对换，拖到「待用栏」即移除。待用栏里：单击选中多个后右键可批量移除；「待用小组」可整体拖回座位表。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    poolArea

                    gridArea(availWidth: max(geo.size.width - 32, 300))

                    if let notice = store.notice {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .transition(.opacity)
                    }

                    HStack {
                        Spacer()
                        Text("在座 \(store.seatedCount) 人 · 待用 \(store.pool.count) 人 · 共 \(store.totalCount) 人")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                            .help("在座人数 + 待用栏人数 = 全班总人数（同一姓名不会同时出现在两处）")
                        Spacer()
                    }
                    .padding(.top, 4)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                // 拖动被外部打断（切走 App / 窗口失去 key / 面板收起）→ 清掉本视图的拖动标记，
                // 否则格子会一直保持半透明「正在拖动」的样子，且下次拖动带着旧来源。
                .onReceive(NotificationCenter.default.publisher(for: .dragSessionDidReset)) { _ in
                    dragging = nil
                    highlight = nil
                }
                // 小组改名弹层：直接画在本窗口内，层级天然最高，不可能被任何界面挡住
                .overlay {
                    if let rg = renameTarget {
                        ZStack {
                            Color.primary.opacity(0.2)
                                .contentShape(Rectangle())
                                .onTapGesture { renameTarget = nil }
                            VStack(spacing: 10) {
                                Text("小组改名")
                                    .font(.system(size: 13, weight: .semibold))
                                TextField("小组名称", text: $renameDraft)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 210)
                                    .focused($renameFocused)
                                    .onSubmit { commitRename(rg) }
                                HStack(spacing: 10) {
                                    Button("取消") { renameTarget = nil }
                                        .frame(width: 70)
                                    Button {
                                        commitRename(rg)
                                    } label: {
                                        Text("确定").frame(width: 70)
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
        }
    }

    // MARK: 顶部标题 + 操作（两行布局，避免按钮文字被截断）
    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                EditableCardTitle(icon: "square.grid.3x3.fill", key: "seating")
                Spacer()
                Picker("", selection: $store.studentView) {
                    Text("教师视角").tag(false)
                    Text("学生视角").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("教师视角：讲台在最下方；学生视角：讲台在最上方（整张表 180° 镜像）")
            }

            HStack(spacing: 8) {
                UndoButton()

                if !store.selection.isEmpty {
                    Button("取消选择") { store.selection = [] }
                        .fixedSize()
                    Button {
                        store.createRegion(from: store.selection)
                    } label: {
                        Label("组成小组(\(store.selection.count))", systemImage: "square.fill.on.square.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
                    .help("把点选中的格子组成一个小组（同一色块显示；⌘Z 可撤销）")
                }

                // 选中的格子里有属于小组的 → 直接给「取消分组」入口（不必再逐格右键）
                if !store.selectionGroupCells.isEmpty {
                    Button {
                        store.ungroupSelection()
                    } label: {
                        Label("取消分组(\(store.selectionGroupCells.count))", systemImage: "square.slash")
                    }
                    .fixedSize()
                    .help("把选中的格子从所在小组里移出来（学生留在原位；整组被移空则自动解散；⌘Z 可撤销）")
                }

                Spacer()

                // 导入下拉：自绘在窗口内，不会被浮层/其他界面挡住
                ZStack(alignment: .topTrailing) {
                    Button {
                        showImportMenu.toggle()
                    } label: {
                        Label("导入", systemImage: "square.and.arrow.down")
                    }
                    .fixedSize()

                    if showImportMenu {
                        // 点击空白处关闭
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { showImportMenu = false }
                            .zIndex(1)
                        VStack(alignment: .leading, spacing: 2) {
                            Button("导入座位表 xlsx") {
                                showImportMenu = false
                                coordinator.importSeating()
                            }
                            Button("从「学生信息」导入名单") {
                                showImportMenu = false
                                importFromStudentInfo()
                            }
                            Divider()
                            Button("下载填写模板") {
                                showImportMenu = false
                                coordinator.downloadTemplate(.seating)
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .padding(8)
                        .frame(width: 180, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.2), lineWidth: 1))
                        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                        .padding(.top, 26)
                        .zIndex(2)
                    }
                }

                Button("下载") { coordinator.exportSeating() }
                    .fixedSize()
            }
        }
    }

    // MARK: 统一「拿起」入口（拖拽）
    //
    // ⚠️ 座位表的**每一处** `.onDrag` 都必须走这里。
    // 落点 `SeatDropDelegate.performDrop` 是**同步**从 `DragContext` 读载荷的
    // （不能再用异步 `loadObject`：macOS 26 上异步换位会让拖拽会话不复位，
    //  之后所有 `.onDrag` 静默失效 →「拖一次就再也拖不动」）。
    // 所以只要有一处 `.onDrag` 忘了登记 DragContext，那个来源就永远拖不动
    // —— 2026-09-12 的故障就是这么来的（座位格 / 待用小组 / ⌘拖组都漏了登记）。
    private func beginDrag(_ payload: String) -> NSItemProvider {
        dragging = payload
        store.seatLog("座位：拿起拖动（载荷=\(payload)）")
        DragContext.begin(module: DragPayload.seating, payload: payload)
        return NSItemProvider(object: payload as NSString)
    }

    // MARK: 显示坐标 ⇄ 数据坐标（学生视角整表 180° 镜像）
    private func modelRC(dRow: Int, dCol: Int) -> (Int, Int) {
        store.studentView ? (store.rows - 1 - dRow, store.cols - 1 - dCol)
                          : (dRow, dCol)
    }

    // MARK: 座位大表（行列号表头 + 完整显示）
    @ViewBuilder
    private func gridArea(availWidth: CGFloat) -> some View {
        let rows = store.rows
        let cols = store.cols
        let fit = (availWidth - headerW - 8) / CGFloat(cols)
        let cw: CGFloat = fit >= minCellWidth ? min(fit, 92) : minCellWidth
        let needsScroll = fit < minCellWidth

        let table = VStack(spacing: 0) {
            // 列号表头
            HStack(spacing: 0) {
                Color.clear.frame(width: headerW, height: headerW)
                ForEach(0..<cols, id: \.self) { dc in
                    colHeader(dCol: dc, width: cw)
                }
            }
            // 每一行：行号 + 格子
            ForEach(0..<rows, id: \.self) { dr in
                HStack(spacing: 0) {
                    rowHeader(dRow: dr)
                    ForEach(0..<cols, id: \.self) { dc in
                        seatCell(dRow: dr, dCol: dc, width: cw)
                    }
                }
            }
        }

        VStack(spacing: 10) {
            if store.studentView { podium }
            if needsScroll {
                ScrollView(.horizontal, showsIndicators: true) { table }
            } else {
                table
                    .background(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.18), lineWidth: 1))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            if !store.studentView { podium }
        }
    }

    /// 列号表头（右键：左/右插入列、删除此列）
    private func colHeader(dCol: Int, width: CGFloat) -> some View {
        let (_, c) = modelRC(dRow: 0, dCol: dCol)
        let mirrored = store.studentView
        return Text("\(dCol + 1)")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: max(width, headerW), height: headerW)
            .background(Color.primary.opacity(0.045))
            .overlay(Rectangle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
            .contentShape(Rectangle())
            .contextMenu {
                Button(mirrored ? "在此列右侧插入列" : "在此列左侧插入列") { store.insertColumn(at: mirrored ? c + 1 : c) }
                Button(mirrored ? "在此列左侧插入列" : "在此列右侧插入列") { store.insertColumn(at: mirrored ? c : c + 1) }
                Divider()
                Button(role: .destructive) { store.removeColumn(c) } label: {
                    Label("删除此列（学生回待用栏）", systemImage: "minus.circle")
                }
            }
            .help("列号：右键可在任意位置插入/删除列（Excel 式）")
    }

    /// 行号表头（右键：上/下插入行、删除此行）
    private func rowHeader(dRow: Int) -> some View {
        let (r, _) = modelRC(dRow: dRow, dCol: 0)
        let mirrored = store.studentView
        return Text("\(dRow + 1)")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: headerW, height: cellHeight)
            .background(Color.primary.opacity(0.045))
            .overlay(Rectangle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
            .contentShape(Rectangle())
            .contextMenu {
                Button(mirrored ? "在此行下方插入行" : "在此行上方插入行") { store.insertRow(at: mirrored ? r + 1 : r) }
                Button(mirrored ? "在此行上方插入行" : "在此行下方插入行") { store.insertRow(at: mirrored ? r : r + 1) }
                Divider()
                Button(role: .destructive) { store.removeRow(r) } label: {
                    Label("删除此行（学生回待用栏）", systemImage: "minus.circle")
                }
            }
            .help("行号：右键可在任意位置插入/删除行（Excel 式）")
    }

    /// 讲台横条（居中）
    private var podium: some View {
        Text("讲　台")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 220, height: 34)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.22), lineWidth: 1))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
    }

    // MARK: 待用栏（可拖入 / 拖出）
    private var poolArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("待用栏", systemImage: "tray.full")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(store.pool.count) 人")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.allToPool()
                } label: {
                    Label("全部待用", systemImage: "arrow.up.to.line")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(store.seatedCount == 0)
                .help("把所有座位上的学生撤到待用栏（⌘Z 可撤销），便于每周重新排座")
                Button {
                    promptAddStudent()
                } label: {
                    Image(systemName: "plus.circle").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("手动添加学生到待用栏")
            }

            if store.pool.isEmpty && store.poolGroups.isEmpty {
                Text("暂无待用学生（可把座位上的姓名拖到这里，或右键小组色块「整体放入待用栏」）")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    // 待用小组（整体）：拖到座位表的小组色块上即可整组放回
                    if !store.poolGroups.isEmpty {
                        ForEach(store.poolGroups) { pg in
                            poolGroupChip(pg)
                        }
                    }
                    if !store.pool.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6)], spacing: 6) {
                            ForEach(Array(store.pool.enumerated()), id: \.offset) { idx, name in
                                poolChip(name: name, index: idx)
                            }
                        }
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(highlight == "pool" ? 0.14 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(highlight == "pool" ? Color.accentColor : Color.primary.opacity(0.08),
                        lineWidth: highlight == "pool" ? 2 : 1)
        )
        .onDrop(of: [.text], delegate: SeatDropDelegate(
            key: "pool",
            highlight: $highlight,
            onDrop: { payload in store.handleDrop(payload, toKey: nil) }
        ))
    }

    /// 待用小组（整体）：可整体拖回座位，右键拆成个人 / 移除
    private func poolGroupChip(_ pg: PoolGroup) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "square.grid.3x3.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("\(pg.title)（\(pg.names.count) 人整体）")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Spacer()
            Text(pg.names.joined(separator: "、"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor.opacity(0.45), lineWidth: 1))
        .contentShape(Rectangle())
        .onDrag {
            beginDrag(SeatingStore.payload(poolGroup: pg.id))
        }
        .contextMenu {
            Button {
                store.explodePoolGroup(id: pg.id)
            } label: {
                Label("拆成个人（逐个安排）", systemImage: "person.2")
            }
            Divider()
            Button(role: .destructive) {
                store.removePoolGroup(id: pg.id)
            } label: {
                Label("移除该小组", systemImage: "trash")
            }
        }
        .help("拖到座位表的某个小组色块上，即整组放回；右键可拆成个人或移除")
    }

    private func poolChip(name: String, index: Int) -> some View {
        let g = store.gender(of: name)
        let selected = poolSelection.contains(name)
        return Text(name)
            .font(.system(size: 12))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(width: 84)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(SeatGenderStyle.background(g) ?? Color.primary.opacity(0.06))
            )
            .foregroundStyle(SeatGenderStyle.color(g))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(selected ? Color.accentColor : SeatGenderStyle.color(g).opacity(0.5),
                            lineWidth: selected ? 2 : 0.6)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                // 单击选中/取消；⌘单击加选/减选（与座位格一致）
                if NSEvent.modifierFlags.contains(.command) {
                    poolSelection.formSymmetricDifference([name])
                } else {
                    poolSelection = selected ? [] : [name]
                }
            }
            .onDrag {
                beginDrag(SeatingStore.payload(pool: index))
            }
            .contextMenu {
                // 批量操作（选中多个时）
                if poolSelection.count > 1, selected {
                    Text("已选中 \(poolSelection.count) 人")
                    Button("标为男生") { for n in poolSelection { store.setGender(n, "男") } }
                    Button("标为女生") { for n in poolSelection { store.setGender(n, "女") } }
                    Divider()
                    Button(role: .destructive) {
                        store.removeFromPool(names: Array(poolSelection))
                        poolSelection = []
                    } label: {
                        Label("移除选中的 \(poolSelection.count) 人", systemImage: "trash")
                    }
                    Divider()
                }
                Button("男生") { store.setGender(name, "男") }
                Button("女生") { store.setGender(name, "女") }
                Button("清除性别") { store.setGender(name, nil) }
                Divider()
                Button(role: .destructive) {
                    store.removeFromPool(names: [name])
                    poolSelection.remove(name)
                } label: {
                    Label("移除", systemImage: "trash")
                }
            }
            .help("拖动到座位上即可安排；单击选中（⌘单击多选），选中后右键可批量移除/设性别")
    }

    // MARK: 手动添加学生
    private func promptAddStudent() {
        let alert = NSAlert()
        alert.messageText = "添加学生到待用栏"
        alert.informativeText = "一次可输入多个姓名，用逗号、空格或换行分隔。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "例如：张三 李四 王五"
        alert.accessoryView = field
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")
        PanelHelper.prepare()
        PanelHelper.bringFront(alert)
        if alert.runModal() == .alertFirstButtonReturn {
            let raw = field.stringValue
            let parts = raw.components(separatedBy: CharacterSet(charactersIn: "，,、 \n\t"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for p in parts { store.addToPool(p) }
        }
    }

    // MARK: 从「学生信息」导入名单
    private func importFromStudentInfo() {
        let s = StudentStore.shared
        guard let nameIdx = s.headers.firstIndex(where: { $0.contains("姓名") }) else {
            let a = NSAlert()
            a.messageText = "未找到姓名列"
            a.informativeText = "请先在「学生信息」里导入学生名单，并确保表头有「姓名」列。"
            PanelHelper.prepare()
            PanelHelper.bringFront(a)
            a.runModal()
            return
        }
        let genderIdx = s.headers.firstIndex(where: { $0.contains("性别") })
        var names: [String] = []
        var gd: [String: String] = [:]
        for row in s.rows where nameIdx < row.cells.count {
            let n = row.cells[nameIdx].trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else { continue }
            names.append(n)
            if let gi = genderIdx, gi < row.cells.count {
                let g = row.cells[gi].trimmingCharacters(in: .whitespaces)
                if g == "男" || g == "女" { gd[n] = g }
            }
        }
        guard !names.isEmpty else {
            let a = NSAlert()
            a.messageText = "学生信息里没有姓名数据"
            PanelHelper.prepare()
            PanelHelper.bringFront(a)
            a.runModal()
            return
        }
        store.importRoster(names: names, genders: gd)
        let a = NSAlert()
        a.messageText = "已导入 \(names.count) 名学生到待用栏"
        a.informativeText = "把待用栏的姓名拖到座位上即可安排座位。"
        PanelHelper.prepare()
        PanelHelper.bringFront(a)
        a.runModal()
    }

    // MARK: 单个座位格（显示坐标 → 数据坐标）
    private func seatCell(dRow: Int, dCol: Int, width cw: CGFloat) -> some View {
        let (r, c) = modelRC(dRow: dRow, dCol: dCol)
        let modelKey = SeatingStore.key(r, c)                        // 数据坐标键（拖拽/选择统一用）
        let name = store.name(at: modelKey) ?? ""
        let g = store.gender(of: name)
        let region = store.region(at: modelKey)
        let isSelected = store.selection.contains(modelKey)
        let isHighlight = highlight == modelKey
        let isDragging = dragging == SeatingStore.payload(cell: modelKey)

        // 底色：小组色块优先，其次性别色
        let bg: Color? = region.map { RegionPalette.color($0.colorIndex).opacity(0.22) }
            ?? SeatGenderStyle.background(g)

        return EditableGridCell(text: Binding(
            get: { store.name(at: modelKey) ?? "" },
            set: { store.setCell(modelKey, $0) }
        ),
        width: cw,
        height: cellHeight,
        font: .system(size: max(8.5, min(11, cw / 6.2))),
        backgroundColor: bg,
        textColor: SeatGenderStyle.color(g),
        externalEditing: Binding(
            get: { editingKey == modelKey },
            set: {
                if $0 { editingKey = modelKey }
                else if editingKey == modelKey { editingKey = nil }
            }
        ),
        onTap: { handleSelectTap(modelKey: modelKey) })
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(isSelected ? Color.accentColor :
                        (isHighlight ? Color.accentColor : Color.clear),
                        lineWidth: isSelected ? 2 : 1.5)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isHighlight ? Color.accentColor.opacity(0.14) : Color.clear)
                )
        )
        .opacity(isDragging ? 0.45 : 1)
        .contentShape(Rectangle())
        .onDrag {
            // ⌘ 拖组内格子 = 整组移动；普通拖 = 拖学生
            if let rg = region, NSEvent.modifierFlags.contains(.command) {
                return beginDrag(SeatingStore.payload(region: rg.id, grab: modelKey))
            }
            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                return NSItemProvider(object: "" as NSString)
            }
            return beginDrag(SeatingStore.payload(cell: modelKey))
        }
        .onDrop(of: [.text], delegate: SeatDropDelegate(
            key: modelKey,
            highlight: $highlight,
            onDrop: { payload in
                dragging = nil
                store.handleDrop(payload, toKey: modelKey)
            }
        ))
        .contextMenu {
            let n = name.trimmingCharacters(in: .whitespaces)
            // 批量操作（选中多格时）
            if store.selection.count > 1, isSelected {
                Text("已选中 \(store.selection.count) 格")
                Button("选中项标为男生") { store.batchSetGender("男") }
                Button("选中项标为女生") { store.batchSetGender("女") }
                Button("清除选中项性别") { store.batchSetGender(nil) }
                Divider()
                Button("选中项移到待用栏") { store.batchToPool() }
                Button(role: .destructive) { store.batchClear() } label: {
                    Label("清空选中座位", systemImage: "minus.square")
                }
                Divider()
            }
            if !n.isEmpty {
                Button("标记为男生") { store.setGender(n, "男") }
                Button("标记为女生") { store.setGender(n, "女") }
                Button("清除性别") { store.setGender(n, nil) }
                Divider()
                Button("移到待用栏") {
                    store.handleDrop(SeatingStore.payload(cell: modelKey), toKey: nil)
                }
                Button("清空此座位") { store.setCell(modelKey, "") }
            } else {
                Text("空座位：双击输入姓名")
            }
            if let rg = region {
                Divider()
                Text("小组：\(rg.title)")
                Button("小组改名…") { promptRenameRegion(rg) }
                if store.selection.count > 1, isSelected, !store.selectionGroupCells.isEmpty {
                    Button {
                        store.removeFromRegions(keys: store.selection)
                    } label: {
                        Label("取消分组（选中的 \(store.selectionGroupCells.count) 格移出小组）",
                              systemImage: "square.slash")
                    }
                }
                Button {
                    store.regionToPool(id: rg.id)
                } label: {
                    Label("小组整体放入待用栏", systemImage: "tray.and.arrow.down")
                }
                .help("组内学生全部撤到待用栏并作为一个整体保存；色块区域同步撤掉、腾空位置，便于其他小组整体移动过来；之后可把「待用小组」拖回")
                Divider()
                Button(role: .destructive) { store.dissolveRegion(id: rg.id) } label: {
                    Label("解散小组（学生留在原位）", systemImage: "xmark.square")
                }
            }
        }
        .instantTooltip(region.map { "小组：\($0.title)" } ?? "", below: dRow == 0)
        .help(region == nil ? "单击选中，⌘单击加选/减选，⇧单击框选；双击输入姓名；拖动对换；右键批量设置性别/移到待用"
                          : "⌘拖可整体移动小组；单击选中，⌘/⇧多选；双击输入姓名；右键更多（组名已即时显示在气泡中）")
    }

    /// Excel 式选择：单击单选；⌘单击加/减选；⇧单击从锚点框选一片
    private func handleSelectTap(modelKey: CellKey) {
        let cmd = NSEvent.modifierFlags.contains(.command)
        let shift = NSEvent.modifierFlags.contains(.shift)
        if shift, let a = selectAnchor,
           let (ar, ac) = SeatingStore.parse(a),
           let (br, bc) = SeatingStore.parse(modelKey) {
            var keys: Set<CellKey> = []
            for rr in min(ar, br)...max(ar, br) {
                for cc in min(ac, bc)...max(ac, bc) {
                    keys.insert(SeatingStore.key(rr, cc))
                }
            }
            store.selection = keys
        } else if cmd {
            store.selection.formSymmetricDifference([modelKey])
            selectAnchor = modelKey
        } else {
            store.selection = [modelKey]
            selectAnchor = modelKey
        }
    }

    /// 小组改名：窗口内弹层（不再用 NSAlert，彻底解决被挡问题）
    private func promptRenameRegion(_ rg: SeatRegion) {
        renameDraft = rg.title
        renameTarget = rg
        DispatchQueue.main.async { renameFocused = true }
        store.seatLog("座位：打开小组改名弹层「\(rg.title)」")
    }

    private func commitRename(_ rg: SeatRegion) {
        let t = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty {
            store.renameRegion(id: rg.id, t)
            store.seatLog("座位：小组改名完成「\(rg.title)」→「\(t)」")
        }
        renameTarget = nil
    }
}

// MARK: - 拖拽落点代理
private struct SeatDropDelegate: DropDelegate {
    let key: String
    @Binding var highlight: String?
    let onDrop: (String) -> Void

    /// 本落点只管座位表自己发起的拖拽（其它模块 / 外部文本一律拒绝，光标显示「不可放」）
    private var isOurs: Bool { DragContext.belongs(to: DragPayload.seating) }

    func validateDrop(info: DropInfo) -> Bool { isOurs }

    func dropEntered(info: DropInfo) {
        guard isOurs else { return }
        highlight = key
    }

    func dropExited(info: DropInfo) { if highlight == key { highlight = nil } }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        isOurs ? DropProposal(operation: .move) : nil
    }

    func performDrop(info: DropInfo) -> Bool {
        highlight = nil
        // **同步**提交：载荷在拿起时已由 DragContext 记好，不再走异步的 loadObject。
        // （异步换位会让 macOS 26 的拖拽会话不复位，之后所有 .onDrag 静默失效）
        guard DragContext.belongs(to: DragPayload.seating),
              let payload = DragContext.payload, !payload.isEmpty else {
            DragContext.reject(DragPayload.seating)
            return false
        }
        onDrop(payload)
        DragContext.finish(reason: "座位")
        return true
    }
}
