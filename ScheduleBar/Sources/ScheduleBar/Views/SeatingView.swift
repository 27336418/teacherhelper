import SwiftUI
import AppKit

// MARK: - 班级学生座位安排（Excel 式一张完整大表 / 讲台在表格里面（左右可排座位）/
//                              框选多格整体移动 / 待用栏 / 性别配色）
// ⚠️ 2026-09-12 起取消全部「分组」功能（组成小组 / 色块 / ⌘拖整组 / 取消分组）。
struct SeatingView: View {
    @EnvironmentObject var store: SeatingStore
    @EnvironmentObject var coordinator: AppCoordinator

    /// 当前拖拽高亮的落点：格子 "r-c" 或 待用栏 "pool" 或 讲台 "podium"
    @State private var highlight: String? = nil
    @State private var dragging: String? = nil
    /// 正在编辑的格子（双击姓名进入编辑态，单击即时选中，互不等待）
    @State private var editingKey: CellKey? = nil

    private let cellHeight: CGFloat = 34
    private let headerW: CGFloat = 22          // 行/列号表头宽度
    private let minCellWidth: CGFloat = 34     // 低于此宽才左右滑动

    /// 多选锚点（⇧ 单击从此格框选到目标格，Excel 式）
    @State private var selectAnchor: CellKey? = nil
    /// 待用栏多选（单击选中 / ⌘单击加选；右键批量移除）
    @State private var poolSelection: Set<String> = []
    /// 导入下拉菜单（窗口内自绘，保证永不被其他界面挡住）
    @State private var showImportMenu = false

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    poolArea
                    gridArea(availWidth: max(geo.size.width - 32, 300))

                    if let notice = store.notice {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .transition(.opacity)
                    }

                    footer
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                // 拖动被外部打断（切走 App / 窗口失去 key / 面板收起）→ 清掉本视图的拖动标记，
                // 否则格子会一直保持半透明「正在拖动」的样子，且下次拖动带着旧来源。
                .onReceive(NotificationCenter.default.publisher(for: .dragSessionDidReset)) { _ in
                    dragging = nil
                    highlight = nil
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
                .help("教师视角：讲台在最下方；学生视角：整张表 180° 镜像（讲台跟着翻到最上方）")
            }

            HStack(spacing: 8) {
                UndoButton()
                SaveButton()

                if !store.selection.isEmpty {
                    Button("取消选择") { store.selection = [] }
                        .fixedSize()
                }

                Spacer()

                Menu {
                    podiumMenuItems
                } label: {
                    Label("讲台", systemImage: "rectangle.split.3x1")
                }
                .fixedSize()
                .help("讲台放在表格里面：占一行中连续的几格，左边/右边仍可排座位")

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

    // MARK: 讲台菜单（顶部按钮与讲台右键共用）
    @ViewBuilder
    private var podiumMenuItems: some View {
        if let p = store.podium {
            Text("讲台：\(p.compactLabel)")
            Button("居中") { store.centerPodium() }
            Button("移到最上一行") { store.podiumToEdge(top: true) }
            Button("移到最下一行") { store.podiumToEdge(top: false) }
            Divider()
            Text("讲台宽度（左右各留出座位）")
            ForEach([2, 3, 4, 5], id: \.self) { s in
                Button(p.span == s ? "✓ \(s) 格宽" : "\(s) 格宽") { store.setPodiumSpan(s) }
            }
            Divider()
            Button(role: .destructive) {
                store.removePodium()
            } label: {
                Label("移出表格（不显示讲台）", systemImage: "rectangle.slash")
            }
        } else {
            Button("把讲台放进表格") { store.addPodium() }
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

    /// 讲台在「显示坐标」下占的列区间（学生视角整表 180° 镜像）
    private func podiumDisplayRange(dRow: Int) -> Range<Int>? {
        guard let p = store.podium else { return nil }
        let rows = store.rows, cols = store.cols
        let mRow = store.studentView ? rows - 1 - dRow : dRow
        guard mRow == p.row else { return nil }
        let start = store.studentView ? cols - p.col - p.span : p.col
        let s = max(0, min(start, max(cols - 1, 0)))
        let e = min(max(s + 1, start + p.span), cols)
        return s..<e
    }

    // MARK: 拖动中的落点预览（框选矩形 / 框选整体移动的目标位置）
    private var dropPreview: Set<CellKey> {
        guard DragContext.belongs(to: DragPayload.seating),
              let raw = DragContext.payload,
              let hl = highlight, hl != "pool", hl != "podium",
              let dst = SeatingStore.parse(hl) else { return [] }
        if raw.hasPrefix("marquee|") {
            guard let a = SeatingStore.parse(String(raw.dropFirst("marquee|".count))) else { return [] }
            var s: Set<CellKey> = []
            for r in min(a.0, dst.0)...max(a.0, dst.0) {
                for c in min(a.1, dst.1)...max(a.1, dst.1) {
                    let k = SeatingStore.key(r, c)
                    if store.isPodium(k) { continue }
                    // 预览与最终选区保持一致：只亮「坐着学生」的格
                    if !store.hasStudent(k) { continue }
                    s.insert(k)
                }
            }
            return s
        }
        if raw.hasPrefix("selblock|") {
            guard let g = SeatingStore.parse(String(raw.dropFirst("selblock|".count))) else { return [] }
            let dr = dst.0 - g.0, dc = dst.1 - g.1
            return Set(store.selection.compactMap { k -> CellKey? in
                guard let (r, c) = SeatingStore.parse(k) else { return nil }
                let nr = r + dr, nc = c + dc
                guard nr >= 0, nr < store.rows, nc >= 0, nc < store.cols else { return nil }
                return SeatingStore.key(nr, nc)
            })
        }
        return []
    }

    // MARK: 座位大表（Excel 式：列 A/B/C… + 行 1/2/3…；讲台也在表内）
    @ViewBuilder
    private func gridArea(availWidth: CGFloat) -> some View {
        let cols = store.cols
        let fit = (availWidth - headerW - 8) / CGFloat(cols)
        let cw: CGFloat = fit >= minCellWidth ? min(fit, 92) : minCellWidth
        let needsScroll = fit < minCellWidth

        let table = VStack(spacing: 0) {
            // 左上角空格 + 列号 A、B、C…
            HStack(spacing: 0) {
                Text("")
                    .frame(width: headerW, height: headerW)
                    .background(Color.primary.opacity(0.09))
                    .overlay(Rectangle().stroke(Color.primary.opacity(0.16), lineWidth: 0.5))
                ForEach(0..<cols, id: \.self) { dc in
                    colHeader(dCol: dc, width: cw)
                }
            }
            // 每一行：行号 + 格子（讲台所在行中间嵌一块讲台，左右两侧仍是座位）
            ForEach(0..<store.rows, id: \.self) { dr in
                tableRow(dRow: dr, width: cw)
            }
        }

        VStack(spacing: 10) {
            if needsScroll {
                ScrollView(.horizontal, showsIndicators: true) { table }
            } else {
                table
                    .background(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.18), lineWidth: 1))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    /// 一行：行号 + 若干座位格；若该行有讲台，则在讲台位置插一块横向合并的讲台
    @ViewBuilder
    private func tableRow(dRow: Int, width cw: CGFloat) -> some View {
        let cols = store.cols
        if let pr = podiumDisplayRange(dRow: dRow) {
            HStack(spacing: 0) {
                rowHeader(dRow: dRow)
                ForEach(0..<pr.lowerBound, id: \.self) { dc in
                    seatCell(dRow: dRow, dCol: dc, width: cw)
                }
                podiumBlock(width: cw * CGFloat(pr.count), height: cellHeight)
                ForEach(pr.upperBound..<max(cols, pr.upperBound), id: \.self) { dc in
                    seatCell(dRow: dRow, dCol: dc, width: cw)
                }
            }
        } else {
            HStack(spacing: 0) {
                rowHeader(dRow: dRow)
                ForEach(0..<cols, id: \.self) { dc in
                    seatCell(dRow: dRow, dCol: dc, width: cw)
                }
            }
        }
    }

    /// 列号表头（1/2/3…，与左侧行号同一套数字；右键：左/右插入列、删除此列）
    private func colHeader(dCol: Int, width: CGFloat) -> some View {
        let (_, c) = modelRC(dRow: 0, dCol: dCol)
        let mirrored = store.studentView
        let label = SeatingStore.columnLabel(dCol)
        return Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: max(width, headerW), height: headerW)
            .background(Color.primary.opacity(0.06))
            .overlay(Rectangle().stroke(Color.primary.opacity(0.14), lineWidth: 0.5))
            .contentShape(Rectangle())
            .contextMenu {
                Button(mirrored ? "在 \(label) 列右侧插入列" : "在 \(label) 列左侧插入列") {
                    store.insertColumn(at: mirrored ? c + 1 : c)
                }
                Button(mirrored ? "在 \(label) 列左侧插入列" : "在 \(label) 列右侧插入列") {
                    store.insertColumn(at: mirrored ? c : c + 1)
                }
                Divider()
                Button(role: .destructive) { store.removeColumn(c) } label: {
                    Label("删除 \(label) 列（学生回待用栏）", systemImage: "minus.circle")
                }
            }
            .help("第 \(label) 列：右键可在任意位置插入/删除列")
    }

    /// 行号表头（右键：上/下插入行、删除此行）
    private func rowHeader(dRow: Int) -> some View {
        let (r, _) = modelRC(dRow: dRow, dCol: 0)
        let mirrored = store.studentView
        return Text("\(dRow + 1)")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: headerW, height: cellHeight)
            .background(Color.primary.opacity(0.06))
            .overlay(Rectangle().stroke(Color.primary.opacity(0.14), lineWidth: 0.5))
            .contentShape(Rectangle())
            .contextMenu {
                Button(mirrored ? "在此行下方插入行" : "在此行上方插入行") { store.insertRow(at: mirrored ? r + 1 : r) }
                Button(mirrored ? "在此行上方插入行" : "在此行下方插入行") { store.insertRow(at: mirrored ? r : r + 1) }
                Divider()
                Button(role: .destructive) { store.removeRow(r) } label: {
                    Label("删除此行（学生回待用栏）", systemImage: "minus.circle")
                }
            }
            .help("第 \(dRow + 1) 行：右键可在任意位置插入/删除行（Excel 式）")
    }

    /// 讲台：在表格里面，横跨一格行内的连续几格（左右两侧照样是座位格）
    private func podiumBlock(width: CGFloat, height: CGFloat) -> some View {
        let hot = highlight == "podium"
        let p = store.podium
        return Text("讲　台")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(width: width, height: height)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(hot ? 0.18 : 0.10)))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .stroke(hot ? Color.accentColor : Color.primary.opacity(0.30),
                        lineWidth: hot ? 2 : 1))
            .contentShape(Rectangle())
            .onDrag { beginDrag(SeatingStore.payloadPodium) }
            .onDrop(of: [.text], delegate: SeatDropDelegate(
                key: "podium",
                highlight: $highlight,
                onDrop: { _ in
                    dragging = nil
                    if let pp = p {
                        store.handleDrop(SeatingStore.payloadPodium,
                                         toKey: SeatingStore.key(pp.row, pp.col + pp.span / 2))
                    }
                }
            ))
            .contextMenu { podiumMenuItems }
            .help("讲台（在表格内）：拖动可换行/换列，左右两侧仍可排座位；右键可调宽度 / 居中 / 移出表格")
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

            if store.pool.isEmpty {
                Text("暂无待用学生")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6)], spacing: 6) {
                    ForEach(Array(store.pool.enumerated()), id: \.offset) { idx, name in
                        poolChip(name: name, index: idx)
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
            onDrop: { payload in
                dragging = nil
                store.handleDrop(payload, toKey: nil)
            }
        ))
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

    // MARK: 底部人数统计
    private var footer: some View {
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
        let isSelected = store.selection.contains(modelKey)
        let isHighlight = highlight == modelKey || dropPreview.contains(modelKey)
        // 「正在被拿起的那一格」：单格拖动 / 框选整块拖动 / 框选起手格
        let isDragSource = dragging == SeatingStore.payload(cell: modelKey)
                        || dragging == SeatingStore.payload(selection: modelKey)
                        || dragging == SeatingStore.payload(marquee: modelKey)
        let draggingStudent = (dragging?.hasPrefix("cell|") ?? false)
                           || (dragging?.hasPrefix("selblock|") ?? false)
        // 拖着一个学生、而落点这一格也有人 → 松手即互换，用**橙色**与普通蓝色高亮区分
        let isSwapTarget = isHighlight && draggingStudent && !isDragSource && store.hasStudent(modelKey)

        return EditableGridCell(text: Binding(
            get: { store.name(at: modelKey) ?? "" },
            set: { store.setCell(modelKey, $0) }
        ),
        width: cw,
        height: cellHeight,
        font: .system(size: max(8.5, min(11, cw / 6.2))),
        backgroundColor: SeatGenderStyle.background(g),
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
                        (isSwapTarget ? Color.orange :
                         (isHighlight ? Color.accentColor : Color.clear)),
                        lineWidth: isSelected ? 2 : (isSwapTarget ? 2.5 : 1.5))
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isSwapTarget ? Color.orange.opacity(0.22)
                                           : (isHighlight ? Color.accentColor.opacity(0.14) : Color.clear))
                )
        )
        .opacity(isDragSource ? 0.45 : 1)
        .contentShape(Rectangle())
        .onDrag {
            // ① 已框选多格，拖其中任意一格 = 整块移动（学生一起走）
            if store.selection.count > 1, store.selection.contains(modelKey) {
                return beginDrag(SeatingStore.payload(selection: modelKey))
            }
            // ② 有学生 → 拖学生对换
            if !name.trimmingCharacters(in: .whitespaces).isEmpty {
                return beginDrag(SeatingStore.payload(cell: modelKey))
            }
            // ③ 空格子起手 → 拖到另一格即框选那一片（Excel 式框选）
            return beginDrag(SeatingStore.payload(marquee: modelKey))
        }
        .onDrop(of: [.text], delegate: SeatDropDelegate(
            key: modelKey,
            highlight: $highlight,
            onDrop: { payload in
                dragging = nil
                if payload.hasPrefix("marquee|"),
                   let a = SeatingStore.parse(String(payload.dropFirst("marquee|".count))) {
                    selectAnchor = SeatingStore.key(a.0, a.1)
                }
                store.handleDrop(payload, toKey: modelKey)
            }
        ))
        .contextMenu {
            let n = name.trimmingCharacters(in: .whitespaces)
            // 批量操作（选中多格时）
            if store.selection.count > 1, isSelected {
                Text("已选中 \(store.selection.count) 格（拖到空位 = 整块移动，拖到有学生的格 = 两格互换）")
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
                // 兜底入口：双击之外，右键也能改姓名
                Button("编辑姓名…") { editingKey = modelKey }
                Divider()
                Button("标记为男生") { store.setGender(n, "男") }
                Button("标记为女生") { store.setGender(n, "女") }
                Button("清除性别") { store.setGender(n, nil) }
                Divider()
                Button("移到待用栏") {
                    store.handleDrop(SeatingStore.payload(cell: modelKey), toKey: nil)
                }
                Button("清空此座位") { store.setCell(modelKey, "") }
            } else {
                Button("输入姓名…") { editingKey = modelKey }
            }
        }
        .help("单击选中·⌘单击加选·⇧单击框选（只框住坐着学生的座位）；拖动学生 = 与落点格互换；从空格拖动 = 框选一片；框选后拖到空位 = 整块移动、拖到有学生的格 = 两格互换；双击输入姓名；右键更多")
    }

    /// Excel 式选择：单击单选；⌘单击加/减选；⇧单击从锚点框选一片
    /// （框选只收「坐着学生」的格子，空格子不进选区 —— 见 `selectRect`）
    private func handleSelectTap(modelKey: CellKey) {
        let cmd = NSEvent.modifierFlags.contains(.command)
        let shift = NSEvent.modifierFlags.contains(.shift)
        if shift, let a = selectAnchor {
            store.selectRect(from: a, to: modelKey)
        } else if cmd {
            store.selection.formSymmetricDifference([modelKey])
            selectAnchor = modelKey
        } else {
            store.selection = [modelKey]
            selectAnchor = modelKey
        }
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
