import SwiftUI

// MARK: - 工位拖动对换代理
// 设计要点：拖动过程中只做「高亮」反馈（不改数据），真正交换只在 performDrop 时发生一次。
// 这样保证：① 交换确定（不会因 hover 多次触发而乱跳）；② 撤销一定生效（提交点唯一）；
// ③ 拖完后可立即再次拖动任意工位对换。内部/外部视角下都用模型坐标，天然都支持。
struct OfficeSeatSwapDelegate: DropDelegate {
    let officeID: UUID
    let row: Int
    let col: Int
    let store: OfficeLayoutStore

    /// 本落点是否该管家下的这次拖拽（不是工位模块 → 一概不理，
    /// 尤其不能顺手清掉 DragContext，否则「拖了没换」之后下一拖也没有来源）
    private var isOurs: Bool { DragContext.belongs(to: DragPayload.officeSeat) }

    func validateDrop(info: DropInfo) -> Bool { isOurs }

    func dropEntered(info: DropInfo) {
        guard isOurs else { return }
        store.setDropHighlight(officeID: officeID, row: row, col: col)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard isOurs else { return nil }
        store.setDropHighlight(officeID: officeID, row: row, col: col)
        return DropProposal(operation: .move)
    }

    // 唯一提交点：**同步**执行一次交换并登记撤销，随后清除高亮。
    // （不能放进 loadObject 的异步回调：macOS 26 上拖拽会话会因此不复位，之后再也拖不动）
    func performDrop(info: DropInfo) -> Bool {
        guard isOurs else { DragContext.reject(DragPayload.officeSeat); return false }
        store.swapSeatTo(officeID: officeID, row: row, col: col)
        store.clearDropHighlight()
        store.finishSeatDrag()
        DragContext.finish(reason: "工位")
        return true
    }
}

// MARK: - 办公室工位布局视图（双列卡片；座位/标题双击编辑，座位右键换色，可增删行/办公室）
struct OfficeLayoutView: View {
    @EnvironmentObject var store: OfficeLayoutStore
    @EnvironmentObject var coordinator: AppCoordinator

    @State private var keyword = ""
    @State private var appliedKeyword = ""     // 去抖后的关键字（避免每次键入都重算）
    @State private var searchWork: DispatchWorkItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    EditableCardTitle(icon: "person.3.fill", key: "office")
                    Spacer()
                    UndoButton()
                    Menu {
                        Button("导入 xlsx") { coordinator.importOffice() }
                        Button("下载填写模板") { coordinator.downloadTemplate(.office) }
                    } label: {
                        Label("导入", systemImage: "square.and.arrow.down")
                    }
                    .help("导入工位布局；可先下载模板（办公室分段 + 每排座位）填写")
                    Button("下载") { coordinator.exportOffice() }
                    Picker("", selection: $store.studentView) {
                        Text("内部视角").tag(false)
                        Text("外部视角").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("内部视角：从办公室内部看，左右门在工位上方；外部视角：从办公室外部看，整张工位表 180° 镜像，左右门移到工位下方")
                    Toggle("显示左右门", isOn: $store.showDoors)
                        .toggleStyle(.checkbox)
                        .fixedSize()
                        .help("隐藏或显示办公室的左右门标识（内部视角在工位上方，外部视角在工位下方）")
                    Button {
                        store.addOffice()
                    } label: {
                        Label("添加办公室", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                }

                // 姓名查询（左半行）+ 所有办公室人数之和（右半行）
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("输入姓名查找工位", text: $keyword)
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
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        if !appliedKeyword.trimmingCharacters(in: .whitespaces).isEmpty {
                            Text("找到 \(hitCount) 个工位")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                    .frame(maxWidth: .infinity)

                    HStack(spacing: 6) {
                        Image(systemName: "person.3.fill")
                            .foregroundStyle(.secondary)
                        Text("办公室共 \(totalHeadcount) 人")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                    .frame(maxWidth: .infinity)
                }

                // 每间办公室独立决定是否占满一行：宽办公室单独占一行，
                // 其它办公室继续两列排列，后面的办公室自然向下移动。
                officeRows
            }
            .padding(16)
        }
    }

    /// 把办公室按两列分组；超过 4 列的办公室单独占一行，
    /// 但不会改变其它办公室的排列方式。
    @ViewBuilder
    private var officeRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(officeRowIDs.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 12) {
                    ForEach(row, id: \.self) { id in
                        // 宽度交给外层 HStack 等分：一行两间 → 各占半行（宽度相等的两列网格）；
                        // 超过 4 列的宽办公室独占一行。卡片内部列宽也会等分撑满，
                        // 因此不会出现「卡片被撑开、右侧留大片空白」的情况。
                        OfficeCard(office: binding(for: id), keyword: appliedKeyword)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // 一行只有一间普通办公室时补一个等宽占位，让它恰好占半行，
                    // 右半行留给下一间（而不是被自己撑满整行留出内部空白）。
                    if row.count == 1 && !isWide(id: row[0]) {
                        Color.clear.frame(maxWidth: .infinity, minHeight: 1)
                    }
                }
            }
        }
    }

    private var officeRowIDs: [[UUID]] {
        var rows: [[UUID]] = []
        var index = 0
        while index < store.offices.count {
            let office = store.offices[index]
            if isWide(office) {
                rows.append([office.id])
                index += 1
            } else if index + 1 < store.offices.count && !isWide(store.offices[index + 1]) {
                rows.append([office.id, store.offices[index + 1].id])
                index += 2
            } else {
                rows.append([office.id])
                index += 1
            }
        }
        return rows
    }

    private func isWide(id: UUID) -> Bool {
        guard let office = store.offices.first(where: { $0.id == id }) else { return false }
        return isWide(office)
    }

    private func isWide(_ office: OfficeBlock) -> Bool {
        (office.seats.map(\.count).max() ?? OfficeLayoutStore.seatColumns) > 4
    }

    private func binding(for id: UUID) -> Binding<OfficeBlock> {
        guard let index = store.offices.firstIndex(where: { $0.id == id }) else {
            return .constant(OfficeBlock(title: "", seats: [[]]))
        }
        return $store.offices[index]
    }

    /// 所有办公室人数之和（空白与「水池」不计入）。
    private var totalHeadcount: Int {
        store.offices.reduce(0) { $0 + headcount(of: $1) }
    }

    /// 实际姓名人数：空白和固定设施不计入。
    private func headcount(of office: OfficeBlock) -> Int {
        office.seats.flatMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "水池" }
            .count
    }

    /// 命中的工位数（所有办公室合计）
    private var hitCount: Int {
        let k = appliedKeyword.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return 0 }
        var n = 0
        for o in store.offices {
            for row in o.seats {
                for s in row where s.localizedCaseInsensitiveContains(k) { n += 1 }
            }
        }
        return n
    }
}

// 单间办公室卡片
struct OfficeCard: View {
    @Binding var office: OfficeBlock
    @EnvironmentObject var store: OfficeLayoutStore
    var keyword: String = ""                 // 查询姓名（已去抖）；命中的工位高亮闪烁
    @State private var titleEditing = false
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool

    // 座位宽度仅作为「列宽上限参考」：卡片内的列已改为等分撑满，
    // 这里保留常量供门牌等固定元素使用。
    private let seatWidth: CGFloat = 60
    /// 行尾「删除本行/本列」按钮统一占位，保证表头行与座位行栅格对齐
    private let trailingButtonWidth: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 标题行：双击改名 + 删除办公室
            HStack(spacing: 6) {
                if titleEditing {
                    TextField("", text: $titleDraft)
                        .focused($titleFocused)
                        .textFieldStyle(.plain)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .onAppear {
                            titleDraft = office.title
                            DispatchQueue.main.async { titleFocused = true }
                        }
                        .onChange(of: titleFocused) { f in
                            if !f {
                                titleEditing = false
                                office.title = titleDraft
                            }
                        }
                        .onSubmit { titleFocused = false }
                } else {
                    Text(office.title)
                        .font(.headline)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { titleEditing = true }
                        .help("双击重命名")
                }
                Text("\(headcount)人")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    .help("当前办公室实际人数")
                Button {
                    store.removeOffice(office.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("删除此办公室")
            }

            if store.showDoors && !store.studentView {
                // 内部视角：从办公室内部看，门在工位上方
                doorRow(left: "左门", right: "右门")
            }

            // 列管理：每列可删除，末尾可增加一列（外部视角下显示列号镜像）
            // 列宽等分撑满卡片，避免 4 列只占左侧、右侧留白
            HStack(spacing: 4) {
                ForEach(0..<columnCount, id: \.self) { displayCol in
                    let c = modelCol(displayCol)
                    HStack(spacing: 2) {
                        Text("列\(c + 1)")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity)
                        Button {
                            store.removeColumn(office.id, c)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("删除第\(c + 1)列")
                    }
                    .frame(maxWidth: .infinity)
                }
                Button {
                    store.addColumn(office.id)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("增加一列")
                .frame(width: trailingButtonWidth)
            }

            // 座位（动态列数 × N 行；右键可换座位颜色）
            ForEach(0..<rowCount, id: \.self) { displayRow in
                let r = modelRow(displayRow)
                HStack(spacing: 4) {
                    ForEach(0..<columnCount, id: \.self) { displayCol in
                        let c = modelCol(displayCol)
                        if office.seats.indices.contains(r), office.seats[r].indices.contains(c) {
                            seatCell(row: r, col: c)
                        } else {
                            Color.clear.frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26)
                        }
                    }
                    Button {
                        store.removeRow(office.id, r)
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("删除此行")
                    .frame(width: trailingButtonWidth)
                }
            }

            Button {
                store.addRow(office.id)
            } label: {
                Label("添加一行", systemImage: "plus")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            if store.showDoors && store.studentView {
                // 外部视角：门移到工位下方，左门仍在左、右门仍在右（与内部视角的命名一致）
                doorRow(left: "左门", right: "右门")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.3)))
    }

    /// 门牌行：与座位栅格对齐——左门落在第一列、右门落在最后一列，中间留空列。
    private func doorRow(left: String, right: String) -> some View {
        HStack(spacing: 4) {
            if columnCount >= 2 {
                doorLabel(left)
                ForEach(1..<max(1, columnCount - 1), id: \.self) { _ in
                    Color.clear.frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20)
                }
                doorLabel(right)
            } else {
                doorLabel(left)
                Spacer(minLength: 8)
                doorLabel(right)
            }
            Color.clear.frame(width: trailingButtonWidth, height: 20)
        }
    }

    private func doorLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.yellow.opacity(0.35)))
    }

    private var headcount: Int {
        office.seats.flatMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "水池" }
            .count
    }

    private var columnCount: Int {
        max(1, office.seats.map(\.count).max() ?? OfficeLayoutStore.seatColumns)
    }

    private var rowCount: Int {
        max(1, office.seats.count)
    }

    private func modelRow(_ displayRow: Int) -> Int {
        store.studentView ? rowCount - 1 - displayRow : displayRow
    }

    private func modelCol(_ displayCol: Int) -> Int {
        store.studentView ? columnCount - 1 - displayCol : displayCol
    }

    /// 该座位是否命中查询（忽略大小写、忽略首尾空格）
    private func isHit(row r: Int, col c: Int) -> Bool {
        let k = keyword.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty, r < office.seats.count, c < office.seats[r].count else { return false }
        return office.seats[r][c].localizedCaseInsensitiveContains(k)
    }

    // 单个座位格：自定义底色 + 右键调色板；命中查询时包进 BreathingWrap 播放独立的呼吸动画
    private func seatCell(row r: Int, col c: Int) -> some View {
        let hex = office.seatColor(row: r, col: c)
        let hit = isHit(row: r, col: c)
        let cell = EditableGridCell(text: $office.seats[r][c],
                                    width: seatWidth,
                                    height: 26,
                                    flexible: true,
                                    backgroundColor: hex.map { Color(hexString: $0).opacity(0.30) },
                                    onSave: {})
        .contextMenu {
            ColorPaletteMenu(current: hex) { office.setSeatColor($0, row: r, col: c) }
        }
        .help("双击编辑文字，右键更换颜色")

        return Group {
            if hit {
                // 每个命中格独享动画：子视图销毁时动画随之消失，互不干扰
                BreathingWrap { cell }
            } else {
                cell
            }
        }
        .overlay(
            Group {
                if let hl = store.dropHighlight, hl.officeID == office.id, hl.row == r, hl.col == c {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.accentColor, lineWidth: 2.5)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.18)))
                }
            }
        )
        .contentShape(Rectangle())
        .onDrag {
            store.beginSeatDrag(officeID: office.id, row: r, col: c)
            // 拿起时同步登记来源模块，落点据此同步换位（见 DragSwapSupport.swift 的说明）
            let payload = DragPayload.office(office.id, row: r, col: c)
            DragContext.begin(module: DragPayload.officeSeat, payload: payload)
            return NSItemProvider(object: payload as NSString)
        }
        .onDrop(of: [.text], delegate: OfficeSeatSwapDelegate(officeID: office.id,
                                                               row: r, col: c, store: store))
        .help("双击编辑文字，拖动可与其它工位对换，右键更换颜色")
        .zIndex(hit ? 1 : 0)
    }
}

// MARK: - 命中工位的呼吸动画包装（放大缩小 + 橙色高亮，动画生命周期与本视图绑定）
private struct BreathingWrap<Content: View>: View {
    let content: () -> Content
    @State private var on = false

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.orange.opacity(on ? 0.75 : 0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.orange, lineWidth: on ? 3 : 2)
                    .opacity(on ? 1 : 0.5)
            )
            .shadow(color: Color.orange.opacity(on ? 0.5 : 0.15), radius: on ? 7 : 3)
            .scaleEffect(on ? 1.15 : 0.85)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) {
                    on = true
                }
            }
    }
}
