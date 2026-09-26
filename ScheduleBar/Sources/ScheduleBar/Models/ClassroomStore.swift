import Foundation
import SwiftUI

// MARK: - 教室分布（每层一行「平铺」格子：教室与办公室同为格子，可拖动对换）
// 数据来自「教室分布.xlsx」；持久化 classrooms.json。
// 旧格式（left / officeName / officeRoom / right / officeColor）在解码时自动迁移成 cells。

/// 格子类型：普通教室 / 办公室
enum ClassroomKind: String, Codable {
    case room     // 教室
    case office   // 办公室
}

/// 一个格子（教室或办公室）
struct ClassroomCell: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var kind: ClassroomKind = .room
    var klass: String = ""      // 教室=班级（19班）；办公室=名称（办公室）
    var room: String = ""       // 房号（X401）
    var color: String?          // 自定义颜色 hex（如 "E74C3C"），nil=默认

    init(id: UUID = UUID(),
         kind: ClassroomKind = .room,
         klass: String = "",
         room: String = "",
         color: String? = nil) {
        self.id = id
        self.kind = kind
        self.klass = klass
        self.room = room
        self.color = color
    }

    enum CodingKeys: String, CodingKey { case id, kind, klass, room, color }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let k = try c.decodeIfPresent(String.self, forKey: .kind) ?? "room"
        self.kind = ClassroomKind(rawValue: k) ?? .room
        self.klass = try c.decodeIfPresent(String.self, forKey: .klass) ?? ""
        self.room = try c.decodeIfPresent(String.self, forKey: .room) ?? ""
        self.color = try c.decodeIfPresent(String.self, forKey: .color)
    }
}

/// 旧版格子（仅用于读回历史 JSON）
struct ClassroomSide: Codable, Equatable {
    var klass: String
    var room: String
    var color: String?
}

/// 拖动经过的目标格子（仅用于高亮提示，不代表任何数据变化）
struct ClassroomDropTarget: Equatable {
    var floorID: UUID
    var rowID: UUID?      // nil = 主行
    var index: Int
}

/// 单击选中的格子（用户 2026-09-23：「教室可以直接点击，按删除键直接删除」）。
/// ⚠️ 存 `cellID` 而不是下标：拖动对换会改变 index，只有 id 才能一直指对同一个格子。
struct ClassroomSelection: Equatable {
    var floorID: UUID
    var rowID: UUID?      // nil = 主行
    var cellID: UUID
}

/// 楼层内附加的一排（走廊另一侧 / 额外一排），格子与主行同构
struct ClassroomRow: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var cells: [ClassroomCell]

    init(id: UUID = UUID(), cells: [ClassroomCell] = []) {
        self.id = id
        self.cells = cells
    }

    enum CodingKeys: String, CodingKey { case id, cells, blocks }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        if let cs = try c.decodeIfPresent([ClassroomCell].self, forKey: .cells) {
            self.cells = cs
        } else if let old = try c.decodeIfPresent([ClassroomSide].self, forKey: .blocks) {
            self.cells = old.map { ClassroomCell(kind: .room, klass: $0.klass, room: $0.room, color: $0.color) }
        } else {
            self.cells = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(cells, forKey: .cells)
    }
}

struct ClassroomFloor: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String                  // 层名（如 X栋4楼）
    var cells: [ClassroomCell]         // 主行：教室/办公室平铺混排（顺序即显示顺序）
    var extraRows: [ClassroomRow]      // 附加行（可增删）

    init(id: UUID = UUID(),
         title: String,
         cells: [ClassroomCell] = [],
         extraRows: [ClassroomRow] = []) {
        self.id = id
        self.title = title
        self.cells = cells
        self.extraRows = extraRows
    }

    enum CodingKeys: String, CodingKey {
        case id, title, cells, extraRows
        // 旧格式字段（仅解码用）
        case left, officeName, officeRoom, right, officeColor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.title = try c.decode(String.self, forKey: .title)
        self.extraRows = try c.decodeIfPresent([ClassroomRow].self, forKey: .extraRows) ?? []
        if let cs = try c.decodeIfPresent([ClassroomCell].self, forKey: .cells) {
            self.cells = cs
        } else {
            // 旧格式：左翼 + 中间办公室 + 右翼 → 平铺
            let left = try c.decodeIfPresent([ClassroomSide].self, forKey: .left) ?? []
            let right = try c.decodeIfPresent([ClassroomSide].self, forKey: .right) ?? []
            let name = try c.decodeIfPresent(String.self, forKey: .officeName) ?? ""
            let room = try c.decodeIfPresent(String.self, forKey: .officeRoom) ?? ""
            let color = try c.decodeIfPresent(String.self, forKey: .officeColor)
            var out = left.map { ClassroomCell(kind: .room, klass: $0.klass, room: $0.room, color: $0.color) }
            if !name.isEmpty || !room.isEmpty {
                out.append(ClassroomCell(kind: .office,
                                         klass: name.isEmpty ? "办公室" : name,
                                         room: room, color: color))
            }
            out.append(contentsOf: right.map {
                ClassroomCell(kind: .room, klass: $0.klass, room: $0.room, color: $0.color)
            })
            self.cells = out
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(cells, forKey: .cells)
        try c.encode(extraRows, forKey: .extraRows)
    }

    /// 该层主行 + 所有附加行的格子总数
    var cellCount: Int { cells.count + extraRows.reduce(0) { $0 + $1.cells.count } }
}

final class ClassroomStore: ObservableObject {
    static let shared = ClassroomStore()

    @Published var floors: [ClassroomFloor] {
        didSet { scheduleSave() }
    }

    /// 拖动中的来源位置（松手时一次性提交对换）；非 @Published，不触发视图刷新
    var dragSource: (floorID: UUID, rowID: UUID?, index: Int)?
    /// 拖动开始时的快照（用于撤销）
    private var dragSnapshot: [ClassroomFloor]?

    // MARK: 拖动经过的目标（只用于高亮，绝不改数据）
    @Published var dropTarget: ClassroomDropTarget?

    // MARK: 整层拖动对调（2026-09-26 用户要求「整个楼层也要可以拖动，上下交换整个楼层」）
    /// 拖动中的来源楼层下标（非 @Published，不触发视图刷新）
    var floorDragSource: Int?
    /// 整层拖动开始时的快照（用于撤销）
    private var floorDragSnapshot: [ClassroomFloor]?
    /// 拖动经过的目标楼层下标（只用于高亮）。与 `dropTarget`（格子落点）互斥，同时只亮一个。
    @Published var floorSwapTarget: Int?

    // MARK: 版面宽度（供面板「右侧自动扩宽」用）
    // ⚠️ 这套数字以前是「散在 FloorCard 里写死 + 这里抄一份」，抄漏一个就会出事：
    //    2026-09-26 用户截图「右边的减号没有显示完整」—— 就是因为 `rowTailWidth` 里
    //    没算附加行行尾那个「⊖ 删除这一行」的宽度，理想宽度少报约 14pt，
    //    面板卡在最小宽度时卡片右边缘正好把 ⊖ 从中间切掉（只剩左边半个圈）。
    //    所以现在**只有这一处常量**，`FloorCard` 全部从这里取。

    /// 一个教室格的宽度（`EditableGridCell` 的 width）
    static let cellBlockWidth: CGFloat = 52
    /// 格子上下两层各加的内边距（`cellBlock` 里的 `.padding(2)`）
    static let cellBlockPadding: CGFloat = 2
    /// 行内间距（`FloorCard.gap`）
    static let rowGap: CGFloat = 3
    /// 行尾「+」菜单的宽度（`FloorCard.addCellMenu`）
    static let colMenuWidth: CGFloat = 18
    /// 附加行行尾「⊖ 删除这一行」的宽度
    static let deleteRowWidth: CGFloat = 14
    /// 卡片内边距（`FloorCard` 的 `.padding(8)` ×2）
    static let cardPadding: CGFloat = 16
    /// 页面外边距（`ClassroomMapView` 的 `.padding(16)` ×2）
    static let pagePadding: CGFloat = 32

    /// 一个教室格占的横向步距：格宽 + 上下两格的内边距 + 行内间距。
    static var cellPitch: CGFloat { cellBlockWidth + cellBlockPadding * 2 + rowGap }

    /// 行尾占用（不含页面外边距）：删除行按钮 + 间距 + 「+」菜单 + 卡内边距。
    /// 这就是 `FloorCard` 里除去格子本身之外、右侧必须留出来的宽度。
    static var cardTailWidth: CGFloat {
        deleteRowWidth + rowGap + colMenuWidth + cardPadding
    }

    /// 行尾占用 + 页面外边距（面板据此决定要不要向右扩宽）
    static var rowTailWidth: CGFloat { cardTailWidth + pagePadding }

    /// 全页「最宽的一行」有多少个教室格
    var maxCellsAcrossFloors: Int {
        floors.reduce(0) { acc, f in
            let extra = f.extraRows.map { $0.cells.count }.max() ?? 0
            return max(acc, max(f.cells.count, extra))
        }
    }

    /// 最宽那一行的卡片「实际需要」的宽度（= `FloorCard` 的宽度，不含页面外边距）。
    /// 判据：`ClassroomMapView` 给卡片区的 frame 宽度必须 ≥ 它，否则行尾的「⊖」会被右边缘切掉。
    var widestRowRequiredWidth: CGFloat {
        CGFloat(maxCellsAcrossFloors) * Self.cellPitch + Self.cardTailWidth
    }

    /// 这一页「最宽的一行」自然需要多少宽度 —— 面板据此决定要不要向右扩宽。
    /// 超过面板基础宽度后由 `SchedulePanelView` 上限截断，剩下的交给横向滑动。
    var idealContentWidth: CGFloat {
        widestRowRequiredWidth + Self.pagePadding
    }

    func setDropTarget(floorID: UUID, rowID: UUID?, index: Int) {
        // 格子落点与整层落点互斥：亮格子就先把整层高亮清掉（同时只亮一个，用户才分得清落点）
        if floorSwapTarget != nil { floorSwapTarget = nil }
        let t = ClassroomDropTarget(floorID: floorID, rowID: rowID, index: index)
        if dropTarget != t { dropTarget = t }
    }

    func clearDropTarget() {
        if dropTarget != nil { dropTarget = nil }
    }

    // MARK: 单击选中 → 按 Delete 删除（不持久化，纯界面态）
    /// 当前选中的格子。存 cellID 而不是下标，拖动对换后仍能指对格子。
    @Published var selection: ClassroomSelection?

    func select(floorID: UUID, rowID: UUID?, cellID: UUID) {
        let s = ClassroomSelection(floorID: floorID, rowID: rowID, cellID: cellID)
        if selection != s { selection = s }
    }

    func clearSelection() {
        if selection != nil { selection = nil }
    }

    /// 删掉的就是当前选中的格子 → 顺手清掉选中态（避免选中一个已不存在的格子）
    func clearSelection(ifCellID id: UUID) {
        if selection?.cellID == id { selection = nil }
    }

    /// 按 id 重新定位选中格子**当前**所在的坐标。
    /// 拖动对换 / 增删之后下标会变，所以每次都要重算，不能缓存下标。
    func selectedCellLocation() -> (floor: Int, row: Int?, cell: Int)? {
        guard let sel = selection,
              let fi = floors.firstIndex(where: { $0.id == sel.floorID }) else { return nil }
        if let rid = sel.rowID {
            guard let ri = floors[fi].extraRows.firstIndex(where: { $0.id == rid }),
                  let ci = floors[fi].extraRows[ri].cells.firstIndex(where: { $0.id == sel.cellID })
            else { return nil }
            return (fi, ri, ci)
        }
        guard let ci = floors[fi].cells.firstIndex(where: { $0.id == sel.cellID }) else { return nil }
        return (fi, nil, ci)
    }

    /// 删除当前选中的格子（可撤销）。
    /// - Returns: 是否真的删掉了一个格子（没选中 / 选中目标已不存在 → false，按键原样放行）
    @discardableResult
    func deleteSelectedCell() -> Bool {
        guard let loc = selectedCellLocation() else {
            clearSelection()
            return false
        }
        let snap = floors
        let kind: ClassroomKind = {
            if let ri = loc.row { return floors[loc.floor].extraRows[ri].cells[loc.cell].kind }
            return floors[loc.floor].cells[loc.cell].kind
        }()
        if let ri = loc.row {
            floors[loc.floor].extraRows[ri].cells.remove(at: loc.cell)
        } else {
            floors[loc.floor].cells.remove(at: loc.cell)
        }
        clearSelection()
        UndoService.shared.register(kind == .office ? "删除办公室" : "删除教室") { [weak self] in
            guard let self else { return }
            self.floors = snap
            self.scheduleSave()
        }
        return true
    }

    init() {
        let loaded = ClassroomStore.load()
        self.floors = loaded?.floors ?? ClassroomStore.defaults()
        // 旧格式（left / officeName / right）在内存里已迁移成平铺 cells，这里顺手落盘成新格式
        if loaded?.wasLegacy == true { save() }
        isInitializing = false   // 装载结束，之后的改动才算用户编辑
    }

    func addFloor() {
        let empty = (0..<5).map { _ in ClassroomCell(kind: .room, klass: "", room: "") }
        let office = ClassroomCell(kind: .office, klass: "办公室", room: "")
        floors.append(ClassroomFloor(title: "新楼层", cells: empty + [office] + empty))
    }

    func removeFloor(_ id: UUID) {
        let snap = floors
        let title = floors.first(where: { $0.id == id })?.title ?? ""
        floors.removeAll { $0.id == id }
        UndoService.shared.register("删除\(title.isEmpty ? "楼层" : "「\(title)」")") { [weak self] in
            guard let self else { return }
            self.floors = snap
            self.scheduleSave()
        }
    }

    // MARK: 拖动对换（教室 / 办公室同级，可任意换位）
    func beginDrag(floorID: UUID, rowID: UUID?, index: Int) {
        dragSnapshot = floors
        dragSource = (floorID, rowID, index)
    }

    /// 把拖动来源与目标位置的格子对换。
    /// 2026-09-23 起**支持跨楼层**（用户要求「需要可以跨楼层也可以对调教室」）：
    /// 前提只剩「两边都能定位到格子」，楼层 / 行 / 下标完全相同才算原地（直接返回）。
    /// 做法是「先把两边都读出来，再分别写回」，所以即使源与目标在同一数组里也不会丢数据。
    func swapTo(floorID: UUID, rowID: UUID?, index: Int) {
        guard let src = dragSource else { return }
        // 原地落点：楼层、行、下标三者都相同才算没换
        guard !(src.floorID == floorID && src.rowID == rowID && src.index == index) else { return }
        guard let sf = floors.firstIndex(where: { $0.id == src.floorID }),
              let tf = floors.firstIndex(where: { $0.id == floorID }) else { return }
        guard let srcCell = cellAt(floor: sf, rowID: src.rowID, index: src.index),
              let dstCell = cellAt(floor: tf, rowID: rowID, index: index) else { return }

        setCell(srcCell, floor: tf, rowID: rowID, index: index)        // 来源 → 目标
        setCell(dstCell, floor: sf, rowID: src.rowID, index: src.index) // 目标 → 来源
        // 拖动来源跟着格子走，用户不松手继续拖时下一跳从新位置起算
        dragSource = (floorID, rowID, index)
        // 选中的格子被换走了 → 选中态跟着它走（否则再按 Delete 会找不到目标）
        if let sel = selection, sel.cellID == srcCell.id {
            selection = ClassroomSelection(floorID: floorID, rowID: rowID, cellID: sel.cellID)
        } else if let sel = selection, sel.cellID == dstCell.id {
            selection = ClassroomSelection(floorID: src.floorID, rowID: src.rowID, cellID: sel.cellID)
        }
    }

    /// 读取某楼层（主行或某附加行）指定下标的格子；越界返回 nil
    private func cellAt(floor fi: Int, rowID: UUID?, index: Int) -> ClassroomCell? {
        if let rid = rowID {
            guard let ri = floors[fi].extraRows.firstIndex(where: { $0.id == rid }),
                  floors[fi].extraRows[ri].cells.indices.contains(index) else { return nil }
            return floors[fi].extraRows[ri].cells[index]
        }
        guard floors[fi].cells.indices.contains(index) else { return nil }
        return floors[fi].cells[index]
    }

    /// 把格子写回某楼层（主行或某附加行）的指定下标；越界则什么都不做
    private func setCell(_ cell: ClassroomCell, floor fi: Int, rowID: UUID?, index: Int) {
        if let rid = rowID {
            guard let ri = floors[fi].extraRows.firstIndex(where: { $0.id == rid }),
                  floors[fi].extraRows[ri].cells.indices.contains(index) else { return }
            floors[fi].extraRows[ri].cells[index] = cell
        } else {
            guard floors[fi].cells.indices.contains(index) else { return }
            floors[fi].cells[index] = cell
        }
    }

    /// 拖动结束：若确实换过位就注册一次撤销
    func finishDrag() {
        defer { dragSource = nil; dragSnapshot = nil }
        guard let snap = dragSnapshot, snap != floors else { return }
        UndoService.shared.register("调整教室位置") { [weak self] in
            guard let self else { return }
            self.floors = snap
            self.scheduleSave()
        }
    }

    /// 拖动被外部打断（切走 App / 窗口失去 key / 面板收起）时清掉拖动状态与高亮。
    /// 只复位状态，不改任何教室内容、不登记撤销。
    /// - Returns: 之前是否真的有一次未完成的拖动
    @discardableResult
    func cancelDrag() -> Bool {
        let had = dragSource != nil
        dragSource = nil
        dragSnapshot = nil
        if dropTarget != nil { dropTarget = nil }
        return had
    }

    // MARK: 整层拖动对调
    func beginFloorDrag(_ index: Int) {
        floorDragSnapshot = floors
        floorDragSource = index
    }

    /// 高亮目标楼层（拖动经过时调用）。整层落点与格子落点互斥。
    func setFloorSwapTarget(_ index: Int?) {
        if dropTarget != nil { dropTarget = nil }
        if floorSwapTarget != index { floorSwapTarget = index }
    }

    /// 整层对调：把两个楼层在列表里的位置互换（a == b 视为原地，只更新来源下标）。
    /// 用 `swapAt` 而不是相邻位移 —— 用户要的是「上下交换整个楼层」。
    func swapFloors(_ a: Int, _ b: Int) {
        guard floors.indices.contains(a), floors.indices.contains(b) else { return }
        guard a != b else { floorDragSource = b; return }
        floors.swapAt(a, b)
        // 松手前继续拖的话，下一跳从新位置起算
        if floorDragSource == a { floorDragSource = b }
        else if floorDragSource == b { floorDragSource = a }
    }

    /// 整层拖动结束：确实换过位置就注册一次撤销
    func finishFloorDrag() {
        defer {
            floorDragSource = nil
            floorDragSnapshot = nil
            if floorSwapTarget != nil { floorSwapTarget = nil }
        }
        guard let snap = floorDragSnapshot, snap != floors else { return }
        UndoService.shared.register("调整楼层顺序") { [weak self] in
            guard let self else { return }
            self.floors = snap
            self.scheduleSave()
        }
    }

    /// 整层拖动被外部打断时复位（切走 App / 窗口失去 key / 面板收起）。只清状态，不改内容、不登记撤销。
    @discardableResult
    func cancelFloorDrag() -> Bool {
        let had = floorDragSource != nil || floorSwapTarget != nil
        floorDragSource = nil
        floorDragSnapshot = nil
        if floorSwapTarget != nil { floorSwapTarget = nil }
        return had
    }

    /// 某楼层当前的下标。楼层顺序会被拖动改变，所以**不要缓存下标**，每次按 id 现算。
    func floorIndex(of id: UUID) -> Int? {
        floors.firstIndex { $0.id == id }
    }

    /// 清空所有教室/办公室的名称与房号（保留楼层与格子结构，便于直接双击填写）
    func clearRooms() {
        var fs = floors
        for i in fs.indices {
            for j in fs[i].cells.indices {
                fs[i].cells[j].klass = ""
                fs[i].cells[j].room = ""
                fs[i].cells[j].color = nil
            }
            for r in fs[i].extraRows.indices {
                for j in fs[i].extraRows[r].cells.indices {
                    fs[i].extraRows[r].cells[j].klass = ""
                    fs[i].extraRows[r].cells[j].room = ""
                    fs[i].extraRows[r].cells[j].color = nil
                }
            }
        }
        floors = fs
    }

    /// 整表替换（导入用）
    func replaceAll(_ newFloors: [ClassroomFloor]) {
        let snap = floors
        floors = newFloors
        scheduleSave()
        UndoService.shared.register("导入教室分布") { [weak self] in
            guard let self else { return }
            self.floors = snap
            self.scheduleSave()
        }
    }

    // MARK: 调色板（教室/工位/校历右键共用，14 色 + 默认）
    static let palette: [(name: String, hex: String?)] = [
        ("默认", nil),
        ("红色", "E74C3C"),
        ("暗红", "C0392B"),
        ("橙色", "E67E22"),
        ("金黄色", "F1C40F"),
        ("绿色", "2ECC71"),
        ("深绿", "27AE60"),
        ("青色", "1ABC9C"),
        ("蓝色", "3498DB"),
        ("深蓝", "2C3E50"),
        ("紫色", "9B59B6"),
        ("玫红", "E91E63"),
        ("棕色", "8D6E63"),
        ("灰色", "95A5A6"),
    ]

    // MARK: 默认数据（已固化为当前填写的数据，见 DefaultData.swift）
    static func defaults() -> [ClassroomFloor] {
        return DefaultData.classrooms
    }

    // 早期预置数据（保留备用）
    static func presetFloors() -> [ClassroomFloor] {
        func room(_ k: String, _ r: String) -> ClassroomCell { ClassroomCell(kind: .room, klass: k, room: r) }
        func office(_ r: String) -> ClassroomCell { ClassroomCell(kind: .office, klass: "办公室", room: r) }
        func wing(_ prefix: String, _ src: [(String, String)]) -> [ClassroomCell] {
            src.map { room($0.0, "\(prefix)\($0.1)") }
        }
        return [
            ClassroomFloor(title: "X栋4楼",
                           cells: wing("X", [("19班", "401"), ("23班", "402"), ("24班", "403"), ("25班", "404"), ("22班", "405")])
                                + [office("X406")]
                                + wing("X", [("26班", "407"), ("27班", "408"), ("28班", "409"), ("29班", "410"), ("30班", "411")])),
            ClassroomFloor(title: "X栋5楼",
                           cells: wing("X", [("21班", "501"), ("20班", "502"), ("18班", "503"), ("17班", "504"), ("16班", "505")])
                                + [office("X506")]
                                + wing("X", [("15班", "507"), ("14班", "508"), ("13班", "509"), ("12班", "510"), ("11班", "511")])),
            ClassroomFloor(title: "S栋5楼",
                           cells: wing("S", [("1班", "501"), ("2班", "502"), ("3班", "503"), ("4班", "504"), ("5班", "505")])
                                + [office("S507")]
                                + wing("S", [("6班", "508"), ("8班", "509"), ("10班", "510"), ("9班", "511"), ("7班", "512")])),
        ]
    }

    // MARK: 持久化
    /// 装载/规范化期间为 true —— 此时对属性的赋值不是「用户编辑」，不该让保存按钮亮起来。
    /// ⚠️ `@Published` 属性的 `didSet` 在 `init` 里**也会触发**（赋值走的是属性包装器的
    ///    setter，不是纯初始化路径），所以必须有这道闸门：否则 App 一启动就有
    ///    「个人课表 / 学生座位 / 当前周」三个板块显示「有未保存的改动」
    ///    （2026-09-18 实测）。init 末尾把它置回 false。
    private var isInitializing = true

    /// 教室的编辑 / 新增 → **立即落盘**（用户 2026-09-23 要求「自动保存」）。
    /// ⚠️ 这是本项目里唯一不走 SaveHub 统一保存的板块：改一个格子就写盘，
    ///    不用等「停手 8 秒」的兜底，也不怕直接关掉 App 丢改动。
    ///    代价只是每次改动多一次 5 KB 级的写盘（拖动对换同理，实测无感）。
    ///    因此这里**不调 `markDirty`** —— 保存按钮不该为它亮起「有未保存的改动」。
    func scheduleSave() {
        guard !isInitializing else { return }   // 装载期不算用户编辑
        save()
    }

    func save() {
        do {
            let url = Self.fileURL()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(floors).write(to: url, options: .atomic)
        } catch {
            print("[ScheduleBar] 教室分布保存失败: \(error)")
        }
    }

    /// 读取本地数据；wasLegacy = 磁盘上还是旧格式（left / officeName / right）
    static func load() -> (floors: [ClassroomFloor], wasLegacy: Bool)? {
        guard let data = try? Data(contentsOf: fileURL()) else { return nil }
        guard let floors = try? JSONDecoder().decode([ClassroomFloor].self, from: data) else { return nil }
        let wasLegacy = data.range(of: Data("\"cells\"".utf8)) == nil
        return (floors, wasLegacy)
    }

    static func fileURL() -> URL {
        // 统一走 AppPaths：自检可用 SCHEDULEBAR_DATA_DIR 把数据目录重定向到
        // 临时目录 —— 所有 store 都必须支持，否则它在 init 里的迁移会写真实数据。
        AppPaths.file("classrooms.json")
    }
}
