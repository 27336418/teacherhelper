import Foundation
import SwiftUI

// MARK: - 教室分布（按层展示：左翼 5 间 + 中间办公室 + 右翼 5 间；可编辑）
// 数据来自「教室分布.xlsx」；持久化 classrooms.json。

struct ClassroomSide: Codable, Equatable {
    var klass: String     // 班级（如 19班），可空
    var room: String      // 房间号（如 X401）
    var color: String?    // 自定义颜色 hex（如 "E74C3C"），nil=默认
}

/// 楼层内附加的一行教室（走廊另一侧 / 额外一排），不含办公室
struct ClassroomRow: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var blocks: [ClassroomSide]
}

struct ClassroomFloor: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String                  // 层名（如 X栋4楼）
    var left: [ClassroomSide]          // 左翼 5
    var officeName: String             // 中间办公室标签
    var officeRoom: String             // 中间办公室房号
    var right: [ClassroomSide]         // 右翼 5
    var officeColor: String?           // 中间办公室自定义颜色，nil=默认
    var extraRows: [ClassroomRow]      // 附加行（可增删）

    // 旧 classrooms.json 没有 extraRows，需要自定义解码兜底
    enum CodingKeys: String, CodingKey {
        case id, title, left, officeName, officeRoom, right, officeColor, extraRows
    }

    init(id: UUID = UUID(),
         title: String,
         left: [ClassroomSide],
         officeName: String,
         officeRoom: String,
         right: [ClassroomSide],
         officeColor: String? = nil,
         extraRows: [ClassroomRow] = []) {
        self.id = id
        self.title = title
        self.left = left
        self.officeName = officeName
        self.officeRoom = officeRoom
        self.right = right
        self.officeColor = officeColor
        self.extraRows = extraRows
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.title = try c.decode(String.self, forKey: .title)
        self.left = try c.decodeIfPresent([ClassroomSide].self, forKey: .left) ?? []
        self.officeName = try c.decodeIfPresent(String.self, forKey: .officeName) ?? ""
        self.officeRoom = try c.decodeIfPresent(String.self, forKey: .officeRoom) ?? ""
        self.right = try c.decodeIfPresent([ClassroomSide].self, forKey: .right) ?? []
        self.officeColor = try c.decodeIfPresent(String.self, forKey: .officeColor)
        self.extraRows = try c.decodeIfPresent([ClassroomRow].self, forKey: .extraRows) ?? []
    }

    /// 该层一行的教室数量（用于新增附加行时对齐宽度）
    var rowWidth: Int { max(1, left.count + right.count) }
}

final class ClassroomStore: ObservableObject {
    static let shared = ClassroomStore()

    @Published var floors: [ClassroomFloor] {
        didSet { save() }
    }

    init() {
        self.floors = ClassroomStore.load() ?? ClassroomStore.defaults()
    }

    func addFloor() {
        let empty = (0..<5).map { _ in ClassroomSide(klass: "", room: "") }
        floors.append(ClassroomFloor(title: "新楼层", left: empty,
                                     officeName: "教师办公室", officeRoom: "",
                                     right: empty))
    }
    func removeFloor(_ id: UUID) {
        let snap = floors
        let title = floors.first(where: { $0.id == id })?.title ?? ""
        floors.removeAll { $0.id == id }
        UndoService.shared.register("删除\(title.isEmpty ? "楼层" : "「\(title)」")") { [weak self] in
            guard let self else { return }
            self.floors = snap
            self.save()
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
        func side(_ k: String, _ r: String) -> ClassroomSide { ClassroomSide(klass: k, room: r) }
        return [
            ClassroomFloor(
                title: "X栋4楼",
                left: [side("19班", "X401"), side("23班", "X402"), side("24班", "X403"), side("25班", "X404"), side("22班", "X405")],
                officeName: "教师办公室（15人）", officeRoom: "X406",
                right: [side("26班", "X407"), side("27班", "X408"), side("28班", "X409"), side("29班", "X410"), side("30班", "X411")]
            ),
            ClassroomFloor(
                title: "X栋5楼",
                left: [side("21班", "X501"), side("20班", "X502"), side("18班", "X503"), side("17班", "X504"), side("16班", "X505")],
                officeName: "教师办公室（15人）", officeRoom: "X506",
                right: [side("15班", "X507"), side("14班", "X508"), side("13班", "X509"), side("12班", "X510"), side("11班", "X511")]
            ),
            ClassroomFloor(
                title: "S栋5楼",
                left: [side("1班", "S501"), side("2班", "S502"), side("3班", "S503"), side("4班", "S504"), side("5班", "S505")],
                officeName: "教师办公室（15人）", officeRoom: "S507",
                right: [side("6班", "S508"), side("8班", "S509"), side("10班", "S510"), side("9班", "S511"), side("7班", "S512")]
            ),
        ]
    }

    // MARK: 持久化
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

    static func load() -> [ClassroomFloor]? {
        guard let data = try? Data(contentsOf: fileURL()) else { return nil }
        return try? JSONDecoder().decode([ClassroomFloor].self, from: data)
    }

    static func fileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ScheduleBar", isDirectory: true)
                  .appendingPathComponent("classrooms.json")
    }
}
