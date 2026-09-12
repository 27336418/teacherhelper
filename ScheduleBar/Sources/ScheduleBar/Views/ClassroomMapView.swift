import SwiftUI
import UniformTypeIdentifiers

// MARK: - 教室分布视图
// 每层一张卡片：层名 + 若干「排」，每排是一条平铺的格子序列（教室 / 办公室同级），
// 格子支持拖动对换（含把办公室拖到任意位置）；行尾只有一个「+」菜单。
struct ClassroomMapView: View {
    @EnvironmentObject var store: ClassroomStore
    @EnvironmentObject var coordinator: AppCoordinator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    EditableCardTitle(icon: "square.grid.3x3", key: "classroom")
                    Spacer()
                    UndoButton()
                    // 与其它模块一致的「导入（含下载模板）+ 下载」
                    Menu {
                        Button("教室分布") { coordinator.importClassroom() }
                        Divider()
                        Button("下载填写模板") { coordinator.downloadTemplate(.classroom) }
                    } label: {
                        Label("导入", systemImage: "square.and.arrow.down")
                    }
                    .help("下载模板：先导出空白模板，填写后从这里导入")
                    Button("下载") { coordinator.exportClassroom() }
                    Button {
                        store.addFloor()
                    } label: {
                        Label("添加楼层", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                }

                ForEach($store.floors) { $floor in
                    FloorCard(floor: $floor)
                }
            }
            .padding(16)
        }
    }
}

// MARK: - 拖动对换（与学生座位同一套做法）
// 拖动经过格子只做高亮，不改任何数据；松手（performDrop）时才读取拖拽载荷，
// 确认来源属于本模块后执行一次对换并登记撤销。
struct ClassroomSwapDelegate: DropDelegate {
    let floorID: UUID
    let rowID: UUID?          // nil = 主行
    let index: Int
    let store: ClassroomStore

    func validateDrop(info: DropInfo) -> Bool { true }

    func dropEntered(info: DropInfo) {
        store.setDropTarget(floorID: floorID, rowID: rowID, index: index)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        store.setDropTarget(floorID: floorID, rowID: rowID, index: index)
        return DropProposal(operation: .move)
    }

    /// 唯一提交点：**同步**对换一次 → 登记撤销、清理状态。
    /// （不能放进 loadObject 的异步回调：macOS 26 上拖拽会话会因此不复位，之后再也拖不动）
    func performDrop(info: DropInfo) -> Bool {
        store.clearDropTarget()
        if DragContext.belongs(to: DragPayload.classroomCell) {
            store.swapTo(floorID: floorID, rowID: rowID, index: index)
        }
        store.finishDrag()
        DragContext.finish(reason: "教室")
        return true
    }
}

struct FloorCard: View {
    @Binding var floor: ClassroomFloor
    @EnvironmentObject var store: ClassroomStore
    @State private var titleEditing = false
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool

    private let blockWidth: CGFloat = 52
    private let gap: CGFloat = 3
    private let btnWidth: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            floorHeader
            row(cells: $floor.cells, rowID: nil)                    // 主行
            ForEach(floor.extraRows.indices, id: \.self) { r in      // 附加行
                HStack(alignment: .top, spacing: gap) {
                    row(cells: $floor.extraRows[r].cells, rowID: floor.extraRows[r].id)
                    deleteRowButton(floor.extraRows[r].id)
                }
                .id(floor.extraRows[r].id)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.3)))
    }

    // MARK: 层名 + 层操作
    private var floorHeader: some View {
        HStack(spacing: 6) {
            if titleEditing {
                TextField("", text: $titleDraft)
                    .focused($titleFocused)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .onAppear {
                        titleDraft = floor.title
                        DispatchQueue.main.async { titleFocused = true }
                    }
                    .onChange(of: titleFocused) { f in
                        if !f {
                            titleEditing = false
                            floor.title = titleDraft
                        }
                    }
                    .onSubmit { titleFocused = false }
            } else {
                Text(floor.title)
                    .font(.headline)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { titleEditing = true }
                    .help("双击重命名")
            }
            Spacer()
            Button {
                let width = max(1, floor.cells.count)
                floor.extraRows.append(ClassroomRow(cells: (0..<width)
                    .map { _ in ClassroomCell(kind: .room, klass: "", room: "") }))
            } label: {
                Label("添加行", systemImage: "plus.rectangle").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("在本楼层下方增加一排教室")
            Button {
                store.removeFloor(floor.id)
            } label: {
                Image(systemName: "trash").font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("删除此楼层")
        }
    }

    // MARK: 一排格子：拖动对换 + 行尾「+」菜单
    // 用格子的 UUID 作为 id（拖动对换后视图能正确复用，不会串内容）
    private func row(cells: Binding<[ClassroomCell]>, rowID: UUID?) -> some View {
        HStack(alignment: .top, spacing: gap) {
            ForEach(Array(cells.wrappedValue.enumerated()), id: \.element.id) { i, _ in
                cellBlock(cells[i], rowID: rowID, index: i)
            }
            addCellMenu { cells.wrappedValue.append($0) }
        }
    }

    private func deleteRowButton(_ rowID: UUID) -> some View {
        Button {
            let snap = store.floors
            floor.extraRows.removeAll { $0.id == rowID }
            UndoService.shared.register("删除教室行") {
                store.floors = snap
                store.save()
            }
        } label: {
            Image(systemName: "minus.circle").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("删除这一行")
    }

    /// 行尾「+」：一个按钮，展开为「添加教室 / 添加办公室」
    private func addCellMenu(_ add: @escaping (ClassroomCell) -> Void) -> some View {
        Menu {
            Button("添加教室") { add(ClassroomCell(kind: .room, klass: "", room: "")) }
            Button("添加办公室") { add(ClassroomCell(kind: .office, klass: "办公室", room: "")) }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .bold))
                .frame(width: btnWidth, height: 46)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.01)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: btnWidth)
        .foregroundStyle(.secondary)
        .help("在本行末尾添加教室或办公室")
    }

    // MARK: 单个格子（教室 / 办公室同级，可拖动对换）
    private func cellBlock(_ cell: Binding<ClassroomCell>, rowID: UUID?, index: Int) -> some View {
        let value = cell.wrappedValue
        let isOffice = value.kind == .office
        return VStack(spacing: 2) {
            EditableGridCell(text: cell.klass, width: blockWidth, height: isOffice ? 22 : 24,
                             font: .system(size: isOffice ? 10 : 11), bold: true,
                             tint: isOffice ? Color(hex: 0xF39C12) : .accentColor)
            EditableGridCell(text: cell.room, width: blockWidth, height: isOffice ? 22 : 20,
                             font: .system(size: isOffice ? 11 : 10), bold: isOffice,
                             tint: isOffice ? Color(hex: 0xF39C12) : .accentColor)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 5).fill(cellFill(for: value)))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.accentColor.opacity(isDropTarget(rowID: rowID, index: index) ? 0.95 : 0),
                        lineWidth: 2)
                .allowsHitTesting(false)
        )
        .contentShape(Rectangle())
        .onDrag {
            store.beginDrag(floorID: floor.id, rowID: rowID, index: index)
            // 拿起时同步登记来源模块，落点据此同步换位（见 DragSwapSupport.swift 的说明）
            let payload = DragPayload.classroom(floor: floor.id, row: rowID, index: index)
            DragContext.begin(module: DragPayload.classroomCell, payload: payload)
            return NSItemProvider(object: payload as NSString)
        }
        .onDrop(of: [.text], delegate: ClassroomSwapDelegate(floorID: floor.id, rowID: rowID,
                                                            index: index, store: store))
        .contextMenu {
            ColorPaletteMenu(current: value.color) { cell.wrappedValue.color = $0 }
            Divider()
            Button(role: .destructive) {
                removeCell(rowID: rowID, index: index)
            } label: {
                Label(isOffice ? "删除这个办公室" : "删除这间教室", systemImage: "trash")
            }
        }
        .help("拖动可与其它格子对换位置；双击编辑文字，右键更换颜色 / 删除")
    }

    /// 删除一个格子（可撤销）
    private func removeCell(rowID: UUID?, index: Int) {
        let snap = store.floors
        if let rid = rowID {
            guard let r = floor.extraRows.firstIndex(where: { $0.id == rid }),
                  floor.extraRows[r].cells.indices.contains(index) else { return }
            floor.extraRows[r].cells.remove(at: index)
        } else {
            guard floor.cells.indices.contains(index) else { return }
            floor.cells.remove(at: index)
        }
        UndoService.shared.register("删除教室") {
            store.floors = snap
            store.save()
        }
    }

    /// 格子底色：自定义色 > 办公室默认略深 > 教室默认（同个人课表底色）
    private func cellFill(for cell: ClassroomCell) -> AnyShapeStyle {
        if let hex = cell.color, !hex.isEmpty {
            return AnyShapeStyle(Color(hexString: hex).opacity(0.4))
        }
        if cell.kind == .office {
            return AnyShapeStyle(.quaternary.opacity(0.55))
        }
        return AnyShapeStyle(.quaternary.opacity(0.3))
    }

    /// 当前格子是否为拖动经过的目标（仅用于高亮描边）
    private func isDropTarget(rowID: UUID?, index: Int) -> Bool {
        guard let t = store.dropTarget else { return false }
        return t.floorID == floor.id && t.rowID == rowID && t.index == index
    }
}
