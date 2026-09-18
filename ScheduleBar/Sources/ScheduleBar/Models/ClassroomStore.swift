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

    func setDropTarget(floorID: UUID, rowID: UUID?, index: Int) {
        let t = ClassroomDropTarget(floorID: floorID, rowID: rowID, index: index)
        if dropTarget != t { dropTarget = t }
    }

    func clearDropTarget() {
        if dropTarget != nil { dropTarget = nil }
    }

    init() {
        let loaded = ClassroomStore.load()
        self.floors = loaded?.floors ?? ClassroomStore.defaults()
        // 旧格式（left / officeName / right）在内存里已迁移成平铺 cells，这里顺手落盘成新格式
        if loaded?.wasLegacy == true { save() }
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

    /// 把拖动来源与目标位置的格子对换
    func swapTo(floorID: UUID, rowID: UUID?, index: Int) {
        guard var src = dragSource, src.index != index else { return }
        guard let f = floors.firstIndex(where: { $0.id == floorID }) else { return }
        // 仅支持同一层内的对换（同层主行 ↔ 主行，或同一附加行内）
        guard src.floorID == floorID else { return }

        if src.rowID == nil && rowID == nil {
            guard floors[f].cells.indices.contains(src.index),
                  floors[f].cells.indices.contains(index) else { return }
            floors[f].cells.swapAt(src.index, index)
            src.index = index
            dragSource = src
        } else if let rid = rowID, src.rowID == rid {
            guard let r = floors[f].extraRows.firstIndex(where: { $0.id == rid }),
                  floors[f].extraRows[r].cells.indices.contains(src.index),
                  floors[f].extraRows[r].cells.indices.contains(index) else { return }
            floors[f].extraRows[r].cells.swapAt(src.index, index)
            src.index = index
            dragSource = src
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
    /// 用户编辑 → 只标脏；真正的落盘由 SaveHub 统一负责
    /// （点「保存」/ ⌘S / 停手 8 秒 / 收起面板 / 退出前）。
    func scheduleSave() {
        SaveHub.shared.markDirty("教室布局")
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
