import Foundation
import SwiftUI

// MARK: - 办公室工位布局（多间办公室，每间 = 标题 + 左门/右门 + 4 列座位 × N 行；可编辑）
// 持久化 offices.json。

struct OfficeBlock: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var seats: [[String]]        // 行 × 动态列数座位（旧数据默认 4 列）
    var seatColors: [String: String] = [:]   // "行-列" → 自定义颜色 hex（如 "2-3" → "3498DB"）

    init(id: UUID = UUID(), title: String, seats: [[String]],
         seatColors: [String: String] = [:]) {
        self.id = id
        self.title = title
        self.seats = seats
        self.seatColors = seatColors
    }

    // 旧版 offices.json 无 seatColors 字段 → 默认空字典
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        seats = try c.decode([[String]].self, forKey: .seats)
        seatColors = try c.decodeIfPresent([String: String].self, forKey: .seatColors) ?? [:]
    }

    /// 某座位的自定义颜色（无则 nil）
    func seatColor(row r: Int, col c: Int) -> String? {
        seatColors["\(r)-\(c)"]
    }

    mutating func setSeatColor(_ hex: String?, row r: Int, col c: Int) {
        let key = "\(r)-\(c)"
        if let hex, !hex.isEmpty {
            seatColors[key] = hex
        } else {
            seatColors.removeValue(forKey: key)
        }
    }
}

final class OfficeLayoutStore: ObservableObject {
    static let shared = OfficeLayoutStore()

    @Published var offices: [OfficeBlock] {
        didSet { scheduleSave() }
    }

    /// 工位视图：false = 教师视角，true = 学生视角（整张办公室工位表 180° 镜像）
    @Published var studentView: Bool {
        didSet { UserDefaults.standard.set(studentView, forKey: Self.viewKey) }
    }
    /// 是否显示办公室左右门标识
    @Published var showDoors: Bool {
        didSet { UserDefaults.standard.set(showDoors, forKey: Self.doorsKey) }
    }
    private static let viewKey = "office.studentView"
    private static let doorsKey = "office.showDoors"

    /// 拖动来源：仅记录「从哪里拖」，落点由 drop 时传入；单次 drop 只换一次，可逆、可重拖。
    private var dragOrigin: (officeID: UUID, row: Int, col: Int)?
    private var dragSnapshot: [OfficeBlock]?

    /// 当前 drop 高亮目标（仅 hover 视觉反馈，不改数据）；格式 (officeID, row, col)
    struct SeatTarget: Equatable { let officeID: UUID; let row: Int; let col: Int }
    @Published var dropHighlight: SeatTarget? = nil

    init() {
        self.studentView = UserDefaults.standard.bool(forKey: Self.viewKey)
        self.showDoors = UserDefaults.standard.object(forKey: Self.doorsKey) as? Bool ?? true
        self.offices = OfficeLayoutStore.load() ?? OfficeLayoutStore.defaults()
        isInitializing = false   // 装载结束，之后的改动才算用户编辑
    }

    // MARK: 工位拖动对换
    func beginSeatDrag(officeID: UUID, row: Int, col: Int) {
        guard let office = offices.first(where: { $0.id == officeID }),
              office.seats.indices.contains(row), office.seats[row].indices.contains(col) else { return }
        dragSnapshot = offices
        dragOrigin = (officeID, row, col)
        dropHighlight = nil
    }

    /// 拖动经过时的高亮。**必须去重**：dropUpdated 在拖动过程中每帧都会调用，
    /// 无脑赋值会让 @Published 连续变化 → 整页反复重绘 → 拖拽会话容易被打断（松手不落地）。
    func setDropHighlight(officeID: UUID, row: Int, col: Int) {
        let t = SeatTarget(officeID: officeID, row: row, col: col)
        if dropHighlight != t { dropHighlight = t }
    }

    func clearDropHighlight() {
        dropHighlight = nil
    }

    /// 将「拖动来源工位」与「目标工位」的姓名/颜色一次性对换（在 performDrop 时调用，保证确定性，
    /// 单次 drop 只换一次，松开即提交 → 撤销可靠、可重复拖动对换）。
    func swapSeatTo(officeID: UUID, row: Int, col: Int) {
        guard let origin = dragOrigin,
              let srcOffice = offices.firstIndex(where: { $0.id == origin.officeID }),
              let dstOffice = offices.firstIndex(where: { $0.id == officeID }),
              offices[srcOffice].seats.indices.contains(origin.row),
              offices[srcOffice].seats[origin.row].indices.contains(origin.col),
              offices[dstOffice].seats.indices.contains(row),
              offices[dstOffice].seats[row].indices.contains(col),
              !(origin.officeID == officeID && origin.row == row && origin.col == col) else { return }

        let srcKey = "\(origin.row)-\(origin.col)"
        let dstKey = "\(row)-\(col)"
        let srcText = offices[srcOffice].seats[origin.row][origin.col]
        let dstText = offices[dstOffice].seats[row][col]
        let srcColor = offices[srcOffice].seatColors[srcKey]
        let dstColor = offices[dstOffice].seatColors[dstKey]

        offices[srcOffice].seats[origin.row][origin.col] = dstText
        offices[dstOffice].seats[row][col] = srcText
        setColor(srcColor, officeIndex: dstOffice, key: dstKey)
        setColor(dstColor, officeIndex: srcOffice, key: srcKey)
    }

    func finishSeatDrag() {
        defer { dragOrigin = nil; dragSnapshot = nil }
        guard let snap = dragSnapshot, snap != offices else { return }
        UndoService.shared.register("调整工位位置") { [weak self] in
            guard let self else { return }
            self.offices = snap
            self.scheduleSave()
        }
    }

    /// 拖动被外部打断（切走 App / 窗口失去 key / 面板收起）时清掉拖动状态与高亮。
    /// 只复位状态，不改任何工位内容、不登记撤销。
    /// - Returns: 之前是否真的有一次未完成的拖动
    @discardableResult
    func cancelSeatDrag() -> Bool {
        let had = dragOrigin != nil
        dragOrigin = nil
        dragSnapshot = nil
        dropHighlight = nil
        return had
    }

    private func setColor(_ color: String?, officeIndex: Int, key: String) {
        if let color, !color.isEmpty {
            offices[officeIndex].seatColors[key] = color
        } else {
            offices[officeIndex].seatColors.removeValue(forKey: key)
        }
    }

    static let seatColumns = 4

    func addOffice() {
        offices.append(OfficeBlock(title: "新办公室", seats: Array(repeating: Array(repeating: "", count: Self.seatColumns), count: 4)))
    }
    func removeOffice(_ id: UUID) {
        let snap = offices
        let title = offices.first(where: { $0.id == id })?.title ?? ""
        offices.removeAll { $0.id == id }
        UndoService.shared.register("删除\(title.isEmpty ? "办公室" : "「\(title)」")") { [weak self] in
            guard let self else { return }
            self.offices = snap
            self.scheduleSave()
        }
    }
    func addRow(_ officeID: UUID) {
        guard let i = offices.firstIndex(where: { $0.id == officeID }) else { return }
        let columns = max(1, offices[i].seats.map(\.count).max() ?? Self.seatColumns)
        offices[i].seats.append(Array(repeating: "", count: columns))
    }

    /// 在办公室右侧增加一列，并保留既有座位颜色。
    func addColumn(_ officeID: UUID) {
        guard let i = offices.firstIndex(where: { $0.id == officeID }) else { return }
        let columns = max(1, offices[i].seats.map(\.count).max() ?? Self.seatColumns)
        let snap = offices
        for r in offices[i].seats.indices {
            while offices[i].seats[r].count < columns { offices[i].seats[r].append("") }
            offices[i].seats[r].append("")
        }
        UndoService.shared.register("增加工位列") { [weak self] in
            guard let self else { return }
            self.offices = snap
            self.scheduleSave()
        }
    }

    /// 删除指定列；至少保留一列，删除后重排颜色坐标。
    func removeColumn(_ officeID: UUID, _ c: Int) {
        guard let i = offices.firstIndex(where: { $0.id == officeID }) else { return }
        let columns = offices[i].seats.map(\.count).max() ?? 0
        guard columns > 1, c >= 0, c < columns else { return }
        let snap = offices
        for r in offices[i].seats.indices {
            while offices[i].seats[r].count < columns { offices[i].seats[r].append("") }
            offices[i].seats[r].remove(at: c)
        }
        var colors: [String: String] = [:]
        for (key, hex) in offices[i].seatColors {
            let parts = key.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 2 else { continue }
            let row = parts[0], col = parts[1]
            if col < c { colors[key] = hex }
            else if col > c { colors["\(row)-\(col - 1)"] = hex }
        }
        offices[i].seatColors = colors
        UndoService.shared.register("删除工位列") { [weak self] in
            guard let self else { return }
            self.offices = snap
            self.scheduleSave()
        }
    }

    func removeRow(_ officeID: UUID, _ r: Int) {
        guard let i = offices.firstIndex(where: { $0.id == officeID }),
              offices[i].seats.count > 1 else { return }
        let snap = offices
        offices[i].seats.remove(at: r)
        UndoService.shared.register("删除工位行") { [weak self] in
            guard let self else { return }
            self.offices = snap
            self.scheduleSave()
        }
    }

    /// 清空所有办公室的姓名（保留办公室数量与行列结构，便于直接双击填写）
    func clearSeats() {
        var arr = offices
        for i in arr.indices {
            for r in arr[i].seats.indices {
                for c in arr[i].seats[r].indices {
                    arr[i].seats[r][c] = ""
                }
            }
            arr[i].seatColors = [:]
        }
        offices = arr
    }

    // MARK: 默认数据（已固化为当前填写的数据，见 DefaultData.swift）
    static func defaults() -> [OfficeBlock] {
        return DefaultData.offices
    }

    // 早期预置数据（保留备用）
    static func presetOffices() -> [OfficeBlock] {
        [
            OfficeBlock(title: "X406办公室", seats: [
                ["12李诗语", "8冯鑫", "4王倩", "1柯娜娜"],
                ["13季富容", "9巫松", "5李丹", "2张竞丹"],
                ["14邓瑞珍", "10谭超", "6罗宇婷", "3朱先明"],
                ["15陆遥", "11周伟", "7聂思源", "水池"],
            ]),
            OfficeBlock(title: "初三S507办公室工位图", seats: [
                ["12陈永珍", "8邓雨蒙", "4李炎鸿", "1余燕"],
                ["13赵悦婷", "9陈雯雯", "5罗鑫", "2林科"],
                ["14李圆圆", "10易海燕", "6谭海连", "3王欢欢"],
                ["15官连浇", "11潘桃", "7刘庆超", "水池"],
            ]),
            OfficeBlock(title: "初三X506办公室工位图", seats: [
                ["12蔡亚南", "8魏静宜", "4詹道亮", "1于理想"],
                ["13袁欣茹", "9鲍思敏", "5刘璐", "2石玉霞"],
                ["14李琳", "10石桃", "6李雨阳", "3张静"],
                ["15李记", "11刘莉名", "7孙正", "水池"],
            ]),
            OfficeBlock(title: "初三z506办公室工位图", seats: [
                ["", "5代课周濛", "9陈乐怡", "13王淑慧"],
                ["2柳叶", "6刘梦涵", "10高兴", "14高筱杰"],
                ["3赖炳霖", "7王顺娜", "11刘东梅", "15张钊然"],
                ["4冉钦产假", "8范镔玲", "12陈坤权", "陈婷"],
            ]),
            OfficeBlock(title: "初三X406办公室工位图", seats: [
                ["1张苑琳", "杜著洋", "", "罗勇"],
                ["顾军", "6李晨曦", "", "13李毅"],
                ["3鞠在东", "蒋颖", "曹人予", "14于冰凌"],
                ["4王路曦", "", "水池", "15王雪梅"],
            ]),
            OfficeBlock(title: "初三Z505办公室工位图", seats: [
                ["1（空）", "5（陈方蕤）", "", ""],
                ["2王丹虹", "6俞子格", "", ""],
                ["3黄小桐", "", "", ""],
                ["4骆金辉", "8毛瑶瑶", "", ""],
            ]),
        ]
    }

    // MARK: 持久化
    /// 装载/规范化期间为 true —— 此时对属性的赋值不是「用户编辑」，不该让保存按钮亮起来。
    /// ⚠️ `@Published` 属性的 `didSet` 在 `init` 里**也会触发**（赋值走的是属性包装器的
    ///    setter，不是纯初始化路径），所以必须有这道闸门：否则 App 一启动就有
    ///    「个人课表 / 学生座位 / 当前周」三个板块显示「有未保存的改动」
    ///    （2026-09-18 实测）。init 末尾把它置回 false。
    private var isInitializing = true

    /// 用户编辑 → 只标脏；真正的落盘由 SaveHub 统一负责
    /// （点「保存」/ ⌘S / 停手 8 秒 / 收起面板 / 退出前）。
    func scheduleSave() {
        guard !isInitializing else { return }   // 装载期不算用户编辑
        SaveHub.shared.markDirty("教师工位")
    }

    func save() {
        do {
            let url = Self.fileURL()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(offices).write(to: url, options: .atomic)
        } catch {
            print("[ScheduleBar] 工位保存失败: \(error)")
        }
    }

    static func load() -> [OfficeBlock]? {
        guard let data = try? Data(contentsOf: fileURL()) else { return nil }
        return try? JSONDecoder().decode([OfficeBlock].self, from: data)
    }

    static func fileURL() -> URL {
        // 统一走 AppPaths：自检可用 SCHEDULEBAR_DATA_DIR 把数据目录重定向到
        // 临时目录 —— 所有 store 都必须支持，否则它在 init 里的迁移会写真实数据。
        AppPaths.file("offices.json")
    }
}
