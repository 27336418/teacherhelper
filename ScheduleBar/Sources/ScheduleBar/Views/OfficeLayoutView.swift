import SwiftUI

// MARK: - 工位拖动对换代理
struct OfficeSeatSwapDelegate: DropDelegate {
    let officeID: UUID
    let row: Int
    let col: Int
    let store: OfficeLayoutStore

    func dropEntered(info: DropInfo) {
        store.swapSeatTo(officeID: officeID, row: row, col: col)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        store.finishSeatDrag()
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
                    Picker("视角", selection: $store.studentView) {
                        Text("内部视角").tag(false)
                        Text("外部视角").tag(true)
                    }
                    .pickerStyle(.segmented)
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

                // 姓名查询：命中工位高亮闪烁
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

                // 4 列以内保持双列；列数增加后改为单列纵向排列，
                // 避免办公室卡片仍被固定在 324pt 内而发生横向重叠。
                LazyVGrid(columns: officeGridColumns,
                          alignment: .leading, spacing: 12) {
                    ForEach($store.offices) { $office in
                        OfficeCard(office: $office, keyword: appliedKeyword)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(16)
        }
    }

    /// 工位列较多的办公室需要整行占满，卡片改为纵向排列以保证宽度。
    private var officeGridColumns: [GridItem] {
        let hasWideOffice = store.offices.contains { office in
            (office.seats.map(\.count).max() ?? OfficeLayoutStore.seatColumns) > 4
        }
        if hasWideOffice {
            return [GridItem(.flexible(minimum: 0), spacing: 12)]
        }
        return [GridItem(.flexible(minimum: 324), spacing: 12),
                GridItem(.flexible(minimum: 324), spacing: 12)]
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

    private let seatWidth: CGFloat = 68

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
            HStack(spacing: 4) {
                ForEach(0..<columnCount, id: \.self) { displayCol in
                    let c = modelCol(displayCol)
                    HStack(spacing: 2) {
                        Text("列\(c + 1)")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .frame(width: seatWidth - 16)
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
                    .frame(width: seatWidth)
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
                            Color.clear.frame(width: seatWidth, height: 30)
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

    private func doorRow(left: String, right: String) -> some View {
        HStack(spacing: 4) {
            doorLabel(left)
            Spacer()
            doorLabel(right)
        }
    }

    private func doorLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: seatWidth, height: 20)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.yellow.opacity(0.35)))
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
                                    height: 30,
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
        .contentShape(Rectangle())
        .onDrag {
            store.beginSeatDrag(officeID: office.id, row: r, col: c)
            return NSItemProvider(object: "office-seat" as NSString)
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
