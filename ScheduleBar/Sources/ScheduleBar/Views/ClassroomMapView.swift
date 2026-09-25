import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 教室分布视图
// 每层一张卡片：层名 + 若干「排」，每排是一条平铺的格子序列（教室 / 办公室同级），
// 格子支持拖动对换（含把办公室拖到任意位置）；行尾只有一个「+」菜单。
// 单击格子 = 选中（描蓝框），再按 Delete / ⌫ 直接删除该教室（可撤销）。
struct ClassroomMapView: View {
    @EnvironmentObject var store: ClassroomStore
    @EnvironmentObject var coordinator: AppCoordinator

    /// 删除键监听器（见 installKeyMonitor）
    @State private var keyMonitor: Any?

    var body: some View {
        GeometryReader { geo in
            let frameW = classroomFrameWidth(available: geo.size.width)
            let _ = traceClassroomLayout(available: geo.size.width, frameWidth: frameW)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        EditableCardTitle(icon: "square.grid.3x3", key: "classroom")
                        Spacer()
                        UndoButton()
                        SaveButton()
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

                    Text("提示：单击教室 / 办公室即可选中，按 Delete 键删除；拖动可对换位置（可跨楼层），双击编辑文字")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // 教室卡片区：只有这一块在「教室太多、超过面板最大宽度」时左右滑动。
                    // ⚠️ 顶部工具栏与提示行必须留在横向 ScrollView **外面**：
                    //    否则它们会被排到整页最右端（例如 1544pt 处），用户看到的就是
                    //    「右上角显示不全」（用户 2026-09-23 反馈）。
                    ScrollView(.horizontal, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach($store.floors) { $floor in
                                FloorCard(floor: $floor)
                            }
                        }
                        // 卡片区宽度：至少撑满可视区（灰底卡片保持原来的满宽观感），
                        // 教室更多时按「最宽一行」的自然宽度铺开，多出来的部分左右滑动。
                        .frame(width: frameW, alignment: .leading)
                    }
                }
                .padding(16)
                // 点空白处取消选中。背景在最底层：落在格子上时由格子自己的单击手势先接管。
                .background(
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { store.clearSelection() }
                )
            }
        }
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
    }

    /// 卡片区宽度：至少撑满可视区（灰底卡片保持满宽观感），教室更多时按「最宽一行」的自然宽度铺开。
    private func classroomFrameWidth(available: CGFloat) -> CGFloat {
        max(0, max(available - ClassroomStore.pagePadding,
                   store.idealContentWidth - ClassroomStore.pagePadding))
    }

    /// 取证：`SCHEDULEBAR_TRACE_CLASSROOM=1` → 日志打「可视宽 / 卡片区宽 / 卡片实际需要宽 / 余量」。
    /// **余量 < 0 就说明行尾图标会被卡片右边缘切掉**（2026-09-26「减号只显示一半」就是这个）。
    private func traceClassroomLayout(available: CGFloat, frameWidth: CGFloat) {
        guard ProcessInfo.processInfo.environment["SCHEDULEBAR_TRACE_CLASSROOM"] == "1" else { return }
        let need = store.widestRowRequiredWidth
        let key = "可视 \(Int(available.rounded()))pt｜卡片区 \(Int(frameWidth.rounded()))pt"
            + "｜卡片需要 \(Int(need.rounded()))pt（\(store.maxCellsAcrossFloors) 格）"
            + "｜余 \(Int((frameWidth - need).rounded()))pt"
        guard key != Self.lastClassroomTrace else { return }
        Self.lastClassroomTrace = key
        SaveHub.log("教室列宽：\(key)")
    }
    private static var lastClassroomTrace = ""

    // MARK: - Delete 键删除选中教室
    // 用 AppKit 的本地事件监听而不是 SwiftUI 的 onDeleteCommand：
    // 面板是 NSPopover 里的自定义视图层级，没有稳定的「聚焦列表」，onDeleteCommand 收不到键。
    // 监听器全程只做一件事——把 Delete / ⌫ 翻译成「删掉 store.selection」；
    // 任何一个前提不成立就原样放行（返回 event），绝不吞键。
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyDown(event) ? nil : event   // nil = 已消费，不再往下传
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }

    /// - Returns: true = 这个按键已经被「删除教室」消费掉了
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        // 只认 Delete(51) / 前向删除(117)；带 ⌘⌃⌥ 的组合键（如 ⌘⌫）不是删格子的意图
        guard event.keyCode == 51 || event.keyCode == 117,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        else { return false }
        // ⚠️ 正在输入文字（双击编辑格子、改层名）时绝不能删格子 —— 让文本框自己处理退格
        if NSApp.keyWindow?.firstResponder is NSTextView { return false }
        // 面板窗口必须在前台，且确实选中了某个格子
        guard let panel = DragSessionGuard.panelWindow,
              NSApp.keyWindow === panel,
              AppDelegate.sharedPopover?.isShown == true,
              store.selection != nil
        else { return false }
        return store.deleteSelectedCell()
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

    private var isOurs: Bool { DragContext.belongs(to: DragPayload.classroomCell) }

    func validateDrop(info: DropInfo) -> Bool { isOurs }

    func dropEntered(info: DropInfo) {
        guard isOurs else { return }
        store.setDropTarget(floorID: floorID, rowID: rowID, index: index)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard isOurs else { return nil }
        store.setDropTarget(floorID: floorID, rowID: rowID, index: index)
        return DropProposal(operation: .move)
    }

    /// 唯一提交点：**同步**对换一次 → 登记撤销、清理状态。
    /// （不能放进 loadObject 的异步回调：macOS 26 上拖拽会话会因此不复位，之后再也拖不动）
    /// 不是本模块的拖拽原样拒绝，什么都不清 —— 详见 DragSwapSupport.swift 的说明。
    func performDrop(info: DropInfo) -> Bool {
        guard isOurs else { DragContext.reject(DragPayload.classroomCell); return false }
        store.clearDropTarget()
        store.swapTo(floorID: floorID, rowID: rowID, index: index)
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

    // 尺寸全部取自 `ClassroomStore`（单一来源）：`idealContentWidth` 靠同一套数字算出来，
    // 两边各写一份就会出现「面板以为够了、实际差一点」→ 卡片右边缘切掉行尾图标（2026-09-26 踩过）。
    private var blockWidth: CGFloat { ClassroomStore.cellBlockWidth }
    private var gap: CGFloat { ClassroomStore.rowGap }
    private var btnWidth: CGFloat { ClassroomStore.colMenuWidth }

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
                store.scheduleSave()
            }
        } label: {
            // ⚠️ 宽度必须显式定死：`idealContentWidth` 是按 `ClassroomStore.deleteRowWidth` 算的，
            //    这里若交给字形自己撑（约 11~14pt 浮动），面板刚好卡在最小宽度时就会差几个 pt 被切掉。
            Image(systemName: "minus.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: ClassroomStore.deleteRowWidth, height: 20)
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
        let isSelected = store.selection?.cellID == value.id
        return VStack(spacing: 2) {
            EditableGridCell(text: cell.klass, width: blockWidth, height: isOffice ? 22 : 24,
                             font: .system(size: isOffice ? 10 : 11), bold: true,
                             tint: isOffice ? Color(hex: 0xF39C12) : .accentColor,
                             onSingleTap: { selectCell(value.id, rowID: rowID) })
            EditableGridCell(text: cell.room, width: blockWidth, height: isOffice ? 22 : 20,
                             font: .system(size: isOffice ? 11 : 10), bold: isOffice,
                             tint: isOffice ? Color(hex: 0xF39C12) : .accentColor,
                             onSingleTap: { selectCell(value.id, rowID: rowID) })
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 5).fill(cellFill(for: value)))
        // 选中态：整块加一层淡蓝底 + 蓝框（画在拖动落点高亮之下，拖动时仍能看清落点）
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.accentColor.opacity(isSelected ? 0.14 : 0))
                .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.accentColor, lineWidth: isSelected ? 2 : 0)
                .allowsHitTesting(false)
        )
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
                removeCell(rowID: rowID, index: index, cellID: value.id)
            } label: {
                Label(isOffice ? "删除这个办公室" : "删除这间教室", systemImage: "trash")
            }
        }
        .help("单击选中后按 Delete 键删除；拖动可与其它格子对换位置（可跨楼层）；双击编辑文字，右键更换颜色 / 删除")
    }

    /// 单击选中（再按 Delete 就删它）。位置用 id 记，拖动换位后依然指对同一个格子。
    private func selectCell(_ cellID: UUID, rowID: UUID?) {
        store.select(floorID: floor.id, rowID: rowID, cellID: cellID)
    }

    /// 删除一个格子（可撤销）
    private func removeCell(rowID: UUID?, index: Int, cellID: UUID) {
        let snap = store.floors
        if let rid = rowID {
            guard let r = floor.extraRows.firstIndex(where: { $0.id == rid }),
                  floor.extraRows[r].cells.indices.contains(index) else { return }
            floor.extraRows[r].cells.remove(at: index)
        } else {
            guard floor.cells.indices.contains(index) else { return }
            floor.cells.remove(at: index)
        }
        store.clearSelection(ifCellID: cellID)
        UndoService.shared.register("删除教室") {
            store.floors = snap
            store.scheduleSave()
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
