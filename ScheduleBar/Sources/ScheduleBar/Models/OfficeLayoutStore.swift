import Foundation
import SwiftUI

// MARK: - 办公室工位布局（多间办公室，每间 = 标题 + 左门/右门 + 4 列座位 × N 行；可编辑）
// 持久化 offices.json。

struct OfficeBlock: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var seats: [[String]]        // 行 × 动态列数座位（旧数据默认 4 列）
    var seatColors: [String: String] = [:]   // "行-列" → 自定义颜色 hex（如 "2-3" → "3498DB"）
    /// 所属楼层（空字符串 = 未分组）。**旧数据没有这个字段** → decodeIfPresent 兼容成未分组。
    /// 楼层不单独存盘、也没有独立的楼层表：楼层 = 卡片上的一个标签，
    /// 楼层顺序 = 卡片顺序（首次出现的先后），所以拖动卡片就能同时调整
    /// 「楼层内顺序」「跨楼层」和「楼层的先后」。
    var floor: String = ""

    init(id: UUID = UUID(), title: String, seats: [[String]],
         seatColors: [String: String] = [:], floor: String = "") {
        self.id = id
        self.title = title
        self.seats = seats
        self.seatColors = seatColors
        self.floor = floor
    }

    // 旧版 offices.json 无 seatColors / floor 字段 → 默认空
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        seats = try c.decode([[String]].self, forKey: .seats)
        seatColors = try c.decodeIfPresent([String: String].self, forKey: .seatColors) ?? [:]
        floor = (try c.decodeIfPresent(String.self, forKey: .floor) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 楼层显示名（未分组用「未分组」）
    var floorLabel: String { floor.isEmpty ? "未分组" : floor }

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

    /// 实际人数：空白与固定设施（水池）不计入
    var headcount: Int {
        seats.flatMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "水池" }
            .count
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

    // MARK: 整张卡片拖动（卡片式整体拖动：换位置 / 换楼层）
    /// 正在被拖动的卡片（用于把来源卡片画淡一点）；拖动开始时赋值一次，全程不变。
    @Published private(set) var cardDragSourceID: UUID? = nil
    /// 当前悬停的「落点卡片」（整张卡片高亮）
    @Published var cardDropTarget: UUID? = nil
    /// 当前悬停的「落点楼层标题」（把卡片挪到该楼层末尾）
    @Published var floorDropTarget: String? = nil
    /// 卡片拖动快照（松手时与现状比对，变了才登记撤销）
    private var cardOrigin: UUID?
    private var cardSnapshot: [OfficeBlock]?

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

    // MARK: 整张卡片拖动（卡片式整体拖动）
    // 与学生座位/工位的「格子对换」同一套约定（见 DragSwapSupport.swift）：
    //   拿起 → 只登记来源 + 快照；经过 → 只改高亮（@Published 必须去重，否则整页反复重绘、
    //   拖拽会话被打断）；松手 → **同步**改一次数据 + 登记撤销。

    func beginCardDrag(_ id: UUID) {
        guard offices.contains(where: { $0.id == id }) else { return }
        cardSnapshot = offices
        cardOrigin = id
        cardDropTarget = nil
        floorDropTarget = nil
        cardDragSourceID = id
    }

    /// 悬停高亮（必须去重：dropUpdated 每帧都会调用）
    func setCardDropTarget(_ id: UUID?) {
        if cardDropTarget != id { cardDropTarget = id }
        if floorDropTarget != nil { floorDropTarget = nil }
    }

    func setFloorDropTarget(_ floor: String?) {
        if floorDropTarget != floor { floorDropTarget = floor }
        if cardDropTarget != nil { cardDropTarget = nil }
    }

    func clearCardDropTargets() {
        if cardDropTarget != nil { cardDropTarget = nil }
        if floorDropTarget != nil { floorDropTarget = nil }
    }

    /// 落点 = 某张卡片：把拖动卡插到该卡片的位置（并跟随它的楼层）。
    /// 「插到目标之前」在上下两个方向拖动时结果都确定，不会出现来回跳。
    func moveCard(_ id: UUID, to targetID: UUID) {
        guard id != targetID,
              let from = offices.firstIndex(where: { $0.id == id }),
              let targetIdx = offices.firstIndex(where: { $0.id == targetID }) else { return }
        let fromTitle = offices[from].title
        let targetTitle = offices[targetIdx].title
        var moved = offices.remove(at: from)
        let at = offices.firstIndex(where: { $0.id == targetID }) ?? min(from, offices.count)
        if at < offices.count { moved.floor = offices[at].floor }   // 落到哪一层就是哪一层
        offices.insert(moved, at: at)
        DragSessionGuard.log("办公室卡片：「\(fromTitle)」插到「\(targetTitle)」之前（第 \(from) → \(at) 位，楼层=\(moved.floor.isEmpty ? "未分组" : moved.floor)）")
    }

    /// 落点 = 楼层标题：把卡片挪到该楼层末尾（楼层为空串 = 未分组）
    func moveCard(_ id: UUID, toFloor floor: String) {
        guard let from = offices.firstIndex(where: { $0.id == id }) else { return }
        let title = offices[from].title
        var moved = offices.remove(at: from)
        moved.floor = floor
        let insertAt = offices.lastIndex(where: { $0.floor == floor }).map { $0 + 1 } ?? offices.count
        offices.insert(moved, at: min(insertAt, offices.count))
        DragSessionGuard.log("办公室卡片：把「\(title)」挪到「\(floor.isEmpty ? "未分组" : floor)」末尾（第 \(from) → \(min(insertAt, offices.count)) 位）")
    }

    /// 松手：与快照比对，真的变了才登记撤销
    func finishCardDrag() {
        defer { cardOrigin = nil; cardSnapshot = nil; cardDragSourceID = nil }
        guard let snap = cardSnapshot, snap != offices else { return }
        UndoService.shared.register("移动办公室卡片") { [weak self] in
            guard let self else { return }
            self.offices = snap
            self.scheduleSave()
        }
    }

    /// 拖动被外部打断（切走 App / 面板收起）→ 只复位状态，不动数据、不登记撤销
    @discardableResult
    func cancelCardDrag() -> Bool {
        let had = cardOrigin != nil
        cardOrigin = nil
        cardSnapshot = nil
        cardDragSourceID = nil
        cardDropTarget = nil
        floorDropTarget = nil
        return had
    }

    static let seatColumns = 4

    /// 新建一间办公室（可指定楼层）；登记撤销，和「删除办公室」对等
    func addOffice(floor: String = "") {
        let snap = offices
        appendOffice(floor: floor)
        registerFloorUndo("新建办公室", snapshot: snap)
    }

    /// 只追加、**不登记撤销**：供 addFloor 这类「自己已经登记过撤销」的流程复用，
    /// 否则一次新建楼层会压进两条撤销记录，撤销一次只退回一半。
    private func appendOffice(floor: String) {
        offices.append(OfficeBlock(title: "新办公室",
                                   seats: Array(repeating: Array(repeating: "", count: Self.seatColumns), count: 4),
                                   floor: floor))
    }

    // MARK: 楼层（不单独存盘，完全由每张卡片的 floor 字段推导）
    // 好处：楼层顺序 = 卡片顺序 = 用户拖出来的顺序，不需要维护第二份数据、
    //       也不会有「楼层表和卡片对不上」的同步问题。

    /// 楼层列表：按卡片顺序取首次出现的楼层（拖动卡片即可改楼层先后）。
    /// 全都没楼层时返回 [""]（视图据此走「不显示楼层标题」的原有样子）。
    var floorNames: [String] {
        var seen: [String] = []
        for o in offices where !seen.contains(o.floor) { seen.append(o.floor) }
        return seen.isEmpty ? [""] : seen
    }

    /// 是否已经有卡片设了楼层 → 视图开始按楼层分组显示
    var hasFloors: Bool { offices.contains { !$0.floor.isEmpty } }

    func offices(inFloor floor: String) -> [OfficeBlock] {
        offices.filter { $0.floor == floor }
    }

    func headcount(inFloor floor: String) -> Int {
        offices(inFloor: floor).reduce(0) { $0 + $1.headcount }
    }

    /// 全部办公室人数之和（空白与「水池」不计入，由 OfficeBlock.headcount 定义）
    var totalHeadcount: Int {
        offices.reduce(0) { $0 + $1.headcount }
    }

    /// 新建楼层：把指定卡片挪进新楼层；没有指定卡片就追加一间新办公室
    /// （楼层靠卡片存在 —— 不保留「一间办公室都没有的空楼层」）
    func addFloor(named name: String, assigning id: UUID? = nil) {
        let floor = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !floor.isEmpty else { return }
        let snap = offices
        if let id, offices.contains(where: { $0.id == id }) {
            applyFloor(id, to: floor)
        } else {
            appendOffice(floor: floor)   // 不登记撤销：本方法末尾统一登记，避免压两条
        }
        registerFloorUndo("新建楼层「\(floor)」", snapshot: snap)
    }

    /// 把某张卡片改到指定楼层（挪到该楼层末尾）
    func setFloor(_ id: UUID, to floor: String) {
        let snap = offices
        applyFloor(id, to: floor)
        registerFloorUndo("调整楼层", snapshot: snap)
    }

    private func applyFloor(_ id: UUID, to floor: String) {
        guard let i = offices.firstIndex(where: { $0.id == id }), offices[i].floor != floor else { return }
        var moved = offices.remove(at: i)
        moved.floor = floor
        let at = offices.lastIndex(where: { $0.floor == floor }).map { $0 + 1 } ?? offices.count
        offices.insert(moved, at: min(at, offices.count))
    }

    /// 楼层改名（该楼层下所有卡片一起改）
    func renameFloor(_ old: String, to new: String) {
        let name = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != old, offices.contains(where: { $0.floor == old }) else { return }
        let snap = offices
        for i in offices.indices where offices[i].floor == old { offices[i].floor = name }
        registerFloorUndo("楼层改名", snapshot: snap)
    }

    /// 移出楼层：该楼层的卡片全部回到「未分组」，一间办公室都不删
    func clearFloor(_ floor: String) {
        guard !floor.isEmpty, offices.contains(where: { $0.floor == floor }) else { return }
        let snap = offices
        for i in offices.indices where offices[i].floor == floor { offices[i].floor = "" }
        registerFloorUndo("移出楼层", snapshot: snap)
    }

    /// 删除楼层 = 删掉该楼层下的所有办公室（整层一次撤销可完整恢复）
    func deleteFloor(_ floor: String) {
        guard !floor.isEmpty else { return }
        let victims = offices.filter { $0.floor == floor }
        guard !victims.isEmpty else { return }
        let snap = offices
        offices.removeAll { $0.floor == floor }
        registerFloorUndo("删除楼层「\(floor)」（\(victims.count) 间办公室）", snapshot: snap)
    }

    /// 楼层整体上移 / 下移（delta = -1 / +1）：该楼层的卡片整块与相邻楼层换位
    func moveFloor(_ floor: String, by delta: Int) {
        var order = floorNames
        guard let i = order.firstIndex(of: floor) else { return }
        let j = i + delta
        guard order.indices.contains(j), order[i] != order[j] else { return }
        order.swapAt(i, j)
        let snap = offices
        var buckets: [String: [OfficeBlock]] = [:]
        for o in offices { buckets[o.floor, default: []].append(o) }
        offices = order.flatMap { buckets[$0] ?? [] }
        registerFloorUndo("移动楼层", snapshot: snap)
    }

    private func registerFloorUndo(_ name: String, snapshot: [OfficeBlock]) {
        guard snapshot != offices else { return }
        UndoService.shared.register(name) { [weak self] in
            guard let self else { return }
            self.offices = snapshot
            self.scheduleSave()
        }
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
