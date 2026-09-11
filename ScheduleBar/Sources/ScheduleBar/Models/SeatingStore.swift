import Foundation
import SwiftUI

// MARK: - 班级学生座位安排 v2（一张完整大表 + 框选分组；Excel 式任意位置插行插列；待用栏；性别配色）
// 持久化 seating.json（v2 格式；旧版「多小组」数据自动迁移为「大表 + 分组区域」）

/// 格子坐标键 "r-c"
typealias CellKey = String

/// 分组区域：若干格子（可竖列、可方块、可任意连续形状）共用一个色块与组名
struct SeatRegion: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var cells: [CellKey]          // 成员格（已排序）
    var colorIndex: Int

    /// 包围盒（用于导出/显示顺序）
    var bounds: (minR: Int, minC: Int, maxR: Int, maxC: Int) {
        let ps = cells.compactMap { Self.parse($0) }
        guard !ps.isEmpty else { return (0, 0, 0, 0) }
        return (ps.map(\.0).min()!, ps.map(\.1).min()!, ps.map(\.0).max()!, ps.map(\.1).max()!)
    }

    static func parse(_ key: CellKey) -> (Int, Int)? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }
}

/// 矩形学生块（保留：导入 xlsx 解析仍以此表示，随后转换为大表 + 区域）
struct SeatGroup: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var seats: [[String]]

    init(id: UUID = UUID(), title: String, seats: [[String]]) {
        self.id = id
        self.title = title
        self.seats = seats
    }
}

/// 待用小组：小组整体放入待用栏后作为一个整体保存，可整体拖回座位
struct PoolGroup: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var names: [String]
    /// 原小组的列数（拖回座位时按同样形状还原；旧数据无此字段）
    var cols: Int? = nil
    /// 原小组的色块色号（拖回座位时沿用同一色块；旧数据无此字段）
    var colorIndex: Int? = nil
}

/// v2 持久化结构
struct SeatingDataV2: Codable {
    var version: Int
    var grid: [[String]]
    var regions: [SeatRegion]
    var pool: [String]
    var genders: [String: String]
    var poolGroups: [PoolGroup]?     // 可选：旧文件没有此字段
}

/// 旧版持久化结构（仅迁移用）
struct OldSeatingData: Codable {
    var groups: [SeatGroup]
    var pool: [String]
    var genders: [String: String]
}

/// 分组色板（同一小组 = 同一色块）
enum RegionPalette {
    static let hexes: [UInt32] = [
        0xE74C3C, 0x8E44AD, 0x2980B9, 0x27AE60, 0xE67E22,
        0x16A085, 0xD81B60, 0x5D6D7E, 0x9B59B6, 0x7F8C8D,
    ]
    static var count: Int { hexes.count }
    static func color(_ i: Int) -> Color {
        let n = hexes.count
        let idx = ((i % n) + n) % n
        return Color(hex: hexes[idx])
    }
}

final class SeatingStore: ObservableObject {
    static let shared = SeatingStore()

    /// 新建座次表默认 8×8
    static let defaultSize = 8

    /// 整张座位大表（行 × 列；空串 = 空位）
    @Published var grid: [[String]] { didSet { scheduleSave() } }
    /// 分组区域（每个区域一个色块 + 组名）
    @Published var regions: [SeatRegion] { didSet { scheduleSave() } }
    /// 待用栏（未安排座位的学生）
    @Published var pool: [String] { didSet { scheduleSave() } }
    /// 待用小组（小组整体放入待用栏后的整体，可再整体拖回座位）
    @Published var poolGroups: [PoolGroup] = [] { didSet { scheduleSave() } }
    /// 姓名 → 性别（"男" / "女"）
    @Published var genders: [String: String] { didSet { scheduleSave() } }
    /// 点选中的格子（用于组成小组）
    @Published var selection: Set<CellKey> = []
    /// 操作提示（移动失败等），界面短暂显示
    @Published var notice: String? = nil
    /// 视角：false = 教师视角（讲台在最下方），true = 学生视角（整表 180° 镜像，讲台在最上方）
    @Published var studentView: Bool {
        didSet { UserDefaults.standard.set(studentView, forKey: Self.viewKey) }
    }

    private static let viewKey = "seating.studentView"

    private let saver = Debouncer()
    private var loading = false

    var rows: Int { max(grid.count, 1) }
    var cols: Int { max(grid.first?.count ?? 0, 1) }

    init() {
        Self.seatLog("座位：SeatingStore 初始化开始")
        studentView = UserDefaults.standard.bool(forKey: Self.viewKey)
        if let d = Self.loadV2() {
            grid = d.grid
            regions = d.regions
            pool = d.pool
            poolGroups = d.poolGroups ?? []
            genders = d.genders
            Self.seatLog("座位：已加载 seating.json v2（\(d.grid.count)×\(d.grid.first?.count ?? 0)，分组 \(d.regions.count)、待用 \(d.pool.count)、待用小组 \(poolGroups.count)）")
        } else if let old = Self.loadOld() {
            // 旧版「多小组」数据 → 自动迁移：所有小组从左到右铺进一张大表，每组一个区域
            let migrated = Self.migrate(old: old)
            grid = migrated.grid
            regions = migrated.regions
            pool = old.pool
            genders = old.genders
            Self.seatLog("座位：旧数据已迁移（\(old.groups.count) 组 → 表 \(grid.count)×\(grid.first?.count ?? 0)，分组 \(regions.count)）")
        } else {
            grid = Self.emptyGrid(rows: Self.defaultSize, cols: Self.defaultSize)
            regions = []
            pool = []
            genders = [:]
            Self.seatLog("座位：未找到 seating.json，使用默认 8×8 空表")
        }
        normalize()
    }

    static func emptyGrid(rows: Int, cols: Int) -> [[String]] {
        Array(repeating: Array(repeating: "", count: max(cols, 1)), count: max(rows, 1))
    }

    static func key(_ r: Int, _ c: Int) -> CellKey { "\(r)-\(c)" }
    static func parse(_ key: CellKey) -> (Int, Int)? { SeatRegion.parse(key) }

    // MARK: - 格子读写

    func name(at key: CellKey) -> String? {
        guard let (r, c) = Self.parse(key), grid.indices.contains(r), grid[r].indices.contains(c) else { return nil }
        return grid[r][c]
    }

    func setCell(_ key: CellKey, _ name: String) {
        guard let (r, c) = Self.parse(key), grid.indices.contains(r), grid[r].indices.contains(c) else { return }
        grid[r][c] = name
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { removeFromPool(matching: n) }
    }

    // MARK: - Excel 式插入 / 删除行列（任意位置）

    /// 在第 index 行上方插入一行（index = rows 表示追加到末尾）
    func insertRow(at index: Int) {
        let i = min(max(index, 0), rows)
        loading = true
        grid.insert(Array(repeating: "", count: cols), at: i)
        regions = regions.map { rg in
            var rg = rg
            rg.cells = rg.cells.map { k in
                guard let (r, c) = Self.parse(k), r >= i else { return k }
                return Self.key(r + 1, c)
            }
            return rg
        }
        loading = false
    }

    /// 在第 index 列左侧插入一列（index = cols 表示追加到末尾）
    func insertColumn(at index: Int) {
        let i = min(max(index, 0), cols)
        loading = true
        for r in grid.indices { grid[r].insert("", at: i) }
        regions = regions.map { rg in
            var rg = rg
            rg.cells = rg.cells.map { k in
                guard let (r, c) = Self.parse(k), c >= i else { return k }
                return Self.key(r, c + 1)
            }
            return rg
        }
        loading = false
    }

    /// 删除第 index 行（学生回到待用栏；⌘Z 可撤销）
    func removeRow(_ index: Int) {
        guard grid.indices.contains(index), rows > 1 else { return }
        let snap = snapshot()
        let removed = grid[index].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        loading = true
        grid.remove(at: index)
        regions = regions.compactMap { rg in
            var rg = rg
            var kept: [CellKey] = []
            for k in rg.cells {
                guard let (r, c) = Self.parse(k) else { continue }
                if r == index { continue }
                kept.append(r > index ? Self.key(r - 1, c) : k)
            }
            guard !kept.isEmpty else { return nil }
            rg.cells = kept.sorted()
            return rg
        }
        loading = false
        pool.append(contentsOf: removed)
        registerUndo("删除第\(index + 1)行", snap)
    }

    /// 删除第 index 列（学生回到待用栏；⌘Z 可撤销）
    func removeColumn(_ index: Int) {
        guard cols > 1, grid.allSatisfy({ $0.indices.contains(index) }) else { return }
        let snap = snapshot()
        var removed: [String] = []
        loading = true
        for r in grid.indices {
            let n = grid[r][index]
            if !n.trimmingCharacters(in: .whitespaces).isEmpty { removed.append(n) }
            grid[r].remove(at: index)
        }
        regions = regions.compactMap { rg in
            var rg = rg
            var kept: [CellKey] = []
            for k in rg.cells {
                guard let (r, c) = Self.parse(k) else { continue }
                if c == index { continue }
                kept.append(c > index ? Self.key(r, c - 1) : k)
            }
            guard !kept.isEmpty else { return nil }
            rg.cells = kept.sorted()
            return rg
        }
        loading = false
        pool.append(contentsOf: removed)
        registerUndo("删除第\(index + 1)列", snap)
    }

    // MARK: - 分组（框选 → 色块区域）

    func region(at key: CellKey) -> SeatRegion? {
        regions.first { $0.cells.contains(key) }
    }

    func region(id: UUID) -> SeatRegion? {
        regions.first { $0.id == id }
    }

    /// 用点选的格子创建小组（默认名「第N小组」，颜色取当前最少使用的色号）
    func createRegion(from keys: Set<CellKey>) {
        guard !keys.isEmpty else { return }
        let snap = snapshot()
        var usage: [Int: Int] = [:]
        for rg in regions { usage[rg.colorIndex, default: 0] += 1 }
        let colorIndex = (0..<RegionPalette.count).min { usage[$0, default: 0] < usage[$1, default: 0] } ?? 0
        let title = "第\(regions.count + 1)小组"
        let region = SeatRegion(id: UUID(), title: title, cells: keys.sorted(), colorIndex: colorIndex)
        regions.append(region)
        selection = []
        registerUndo("创建\(title)", snap)
    }

    func renameRegion(id: UUID, _ title: String) {
        guard let i = regions.firstIndex(where: { $0.id == id }) else { return }
        seatLog("座位：小组改名「\(regions[i].title)」→「\(title)」")
        regions[i].title = title
    }

    /// 解散小组（学生留在原座位，只去掉色块）
    func dissolveRegion(id: UUID) {
        guard let i = regions.firstIndex(where: { $0.id == id }) else { return }
        let snap = snapshot()
        let title = regions[i].title
        regions.remove(at: i)
        registerUndo("解散\(title)", snap)
    }

    /// 整体移动小组：抓着的格子对齐到目标格，整块平移（组内学生一起走）。
    /// 越界或与其他小组重叠 → 拒绝并给出提示。
    @discardableResult
    func moveRegion(id: UUID, grab: CellKey, to target: CellKey) -> Bool {
        guard let rg = region(id: id),
              let g = Self.parse(grab), let t = Self.parse(target) else { return false }
        let dr = t.0 - g.0, dc = t.1 - g.1
        guard dr != 0 || dc != 0 else { return false }

        let member = rg.cells.compactMap { Self.parse($0) }
        var newCells: [CellKey] = []
        for (r, c) in member {
            let nr = r + dr, nc = c + dc
            guard grid.indices.contains(nr), grid[nr].indices.contains(nc) else {
                setNotice("整体移动失败：会移出表格边界")
                seatLog("座位：「\(rg.title)」整体移动失败：移出表格边界")
                return false
            }
        }
        let others = Set(regions.filter { $0.id != id }.flatMap { $0.cells })
        for (r, c) in member {
            let k = Self.key(r + dr, c + dc)
            guard !others.contains(k) else {
                setNotice("整体移动失败：与「\(region(at: k)?.title ?? "其他小组")」重叠")
                seatLog("座位：「\(rg.title)」整体移动失败：与其他小组重叠")
                return false
            }
            newCells.append(k)
        }

        let snap = snapshot()
        loading = true
        // 学生随组平移：先摘出原格学生 → 清空原格 → 写入新格
        var carried: [(CellKey, String)] = []
        for k in rg.cells {
            let n = name(at: k) ?? ""
            if let (r, c) = Self.parse(k) { grid[r][c] = "" }
            if !n.trimmingCharacters(in: .whitespaces).isEmpty { carried.append((k, n)) }
        }
        let offset: [CellKey: CellKey] = Dictionary(uniqueKeysWithValues: zip(rg.cells, newCells))
        for (oldKey, n) in carried {
            if let nk = offset[oldKey], let (r, c) = Self.parse(nk) { grid[r][c] = n }
        }
        if let i = regions.firstIndex(where: { $0.id == id }) {
            regions[i].cells = newCells.sorted()
        }
        loading = false
        seatLog("座位：「\(rg.title)」（组名不变）整体移动到 (\(newCells.first ?? "-"))，携带 \(carried.count) 名学生")
        registerUndo("整体移动\(rg.title)", snap)
        return true
    }

    private func setNotice(_ s: String) {
        notice = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.notice == s { self?.notice = nil }
        }
    }

    // MARK: - 批量操作（对点选中的多个格子）

    /// 批量设置选中格子里学生的性别
    func batchSetGender(_ g: String?) {
        for key in selection {
            if let n = name(at: key), !n.trimmingCharacters(in: .whitespaces).isEmpty {
                setGender(n, g)
            }
        }
    }

    /// 批量把选中格子的学生移到待用栏（⌘Z 可撤销）
    func batchToPool() {
        let keys = selection.sorted()
        guard !keys.isEmpty else { return }
        let snap = snapshot()
        loading = true
        for k in keys {
            let n = name(at: k) ?? ""
            guard !n.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            setCellRaw(k, "")
            if !poolContains(n) { pool.append(n) }
        }
        loading = false
        selection = []
        registerUndo("选中项移到待用栏", snap)
    }

    /// 批量清空选中座位（学生不进待用栏，直接清除）
    func batchClear() {
        let keys = selection.sorted()
        guard !keys.isEmpty else { return }
        let snap = snapshot()
        loading = true
        for k in keys { setCellRaw(k, "") }
        loading = false
        selection = []
        registerUndo("清空选中座位", snap)
    }

    // MARK: - 整组轮换（每个小组的学生整体向后轮换一格；最后组回到第一组）

    func rotateRegions() {
        guard regions.count >= 2 else { return }
        let snap = snapshot()
        loading = true
        var payloads: [[String]] = regions.map { rg in
            rg.cells.compactMap { k in
                let n = name(at: k) ?? ""
                if let (r, c) = Self.parse(k) { grid[r][c] = "" }
                return n.trimmingCharacters(in: .whitespaces).isEmpty ? nil : n
            }
        }
        let first = payloads[0]
        payloads.removeFirst()
        payloads.append(first)      // 向后轮换：第一组 → 末尾
        var overflow: [String] = []
        for i in regions.indices {
            let cells = regions[i].cells
            let payload = payloads[i]
            for (j, k) in cells.enumerated() {
                if j < payload.count, let (r, c) = Self.parse(k) { grid[r][c] = payload[j] }
            }
            if payload.count > cells.count {
                overflow.append(contentsOf: payload.suffix(payload.count - cells.count))
            }
        }
        loading = false
        if !overflow.isEmpty { pool.append(contentsOf: overflow) }
        save()
        registerUndo("整组轮换", snap)
    }

    // MARK: - 座位 / 待用栏 互斥去重

    /// 把某个姓名从所有座位上清空（该学生被放回待用栏时调用）
    func removeNameFromGrid(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        for r in grid.indices {
            for c in grid[r].indices
            where grid[r][c].trimmingCharacters(in: .whitespacesAndNewlines) == n {
                grid[r][c] = ""
            }
        }
    }

    private func removeFromPool(matching name: String) {
        if let i = pool.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == name }) {
            pool.remove(at: i)
        }
    }

    private func poolContains(_ name: String) -> Bool {
        pool.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == name }
    }

    // MARK: - 人数统计

    var seatedCount: Int {
        grid.reduce(0) { $0 + $1.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count }
    }

    var totalCount: Int { seatedCount + pool.count + poolGroups.reduce(0) { $0 + $1.names.count } }

    // MARK: - 待用栏

    func addToPool(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        removeNameFromGrid(n)
        guard !poolContains(n) else { return }
        pool.append(n)
    }

    func removeFromPool(at index: Int) {
        guard pool.indices.contains(index) else { return }
        let snapPool = pool
        pool.remove(at: index)
        UndoService.shared.register("移除待用学生") { [weak self] in
            guard let self else { return }
            self.pool = snapPool
            self.save()
        }
    }

    /// 批量移除待用栏学生（选中多个后右键移除；⌘Z 可撤销）
    func removeFromPool(names: [String]) {
        let targets = Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        let snapPool = pool
        let newPool = pool.filter { !targets.contains($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard newPool.count != pool.count else { return }
        loading = true
        pool = newPool
        loading = false
        save()
        UndoService.shared.register("移除 \(snapPool.count - newPool.count) 个待用学生") { [weak self] in
            guard let self else { return }
            self.pool = snapPool
            self.poolGroups = self.poolGroups
            self.save()
        }
    }

    // MARK: - 待用小组（小组整体放入 / 整体拖出）

    /// 小组整体放入待用栏：组内学生全部撤到待用栏，作为「待用小组」整体保存；
    /// 色块区域一并移除，腾空位置便于其他小组整体移动过来
    func regionToPool(id: UUID) {
        guard let rg = region(id: id) else { return }
        var names: [String] = []
        let snap = snapshot()
        loading = true
        for k in rg.cells {
            guard let (r, c) = Self.parse(k) else { continue }
            let n = grid[r][c].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !n.isEmpty else { continue }
            grid[r][c] = ""
            if !names.contains(n) { names.append(n) }
        }
        let bounds = rg.bounds
        let cols = max(1, bounds.maxC - bounds.minC + 1)
        regions.removeAll { $0.id == id }   // 撤掉色块区域，腾空位置
        if !names.isEmpty {
            poolGroups.append(PoolGroup(id: UUID(), title: rg.title, names: names,
                                       cols: cols, colorIndex: rg.colorIndex))
        }
        loading = false
        save()
        seatLog("座位：「\(rg.title)」整体放入待用栏（\(names.count) 人 → 待用小组，区域已腾空）")
        registerUndo("「\(rg.title)」整体放入待用栏", snap)
    }

    // MARK: - 待用小组拖回座位

    /// 待用小组整体拖回座位：
    /// - 落到已有小组色块上 → 按顺序填进该区域（原有行为）
    /// - 落到空白处 → 直接按原形状新建色块放好；位置被占则自动让到后面的空白，
    ///   空间不够时整张表自动补行补列
    func poolGroupToRegion(groupID: UUID, anchor key: CellKey) {
        guard let gi = poolGroups.firstIndex(where: { $0.id == groupID }) else { return }
        guard let (ar, ac) = Self.parse(key) else { return }
        let pg = poolGroups[gi]

        // 1) 落在已有小组上：沿用该区域
        if let rg = region(at: key) {
            let snap = snapshot()
            loading = true
            for k in rg.cells {
                guard let (r, c) = Self.parse(k) else { continue }
                let old = grid[r][c].trimmingCharacters(in: .whitespacesAndNewlines)
                if !old.isEmpty { grid[r][c] = ""; if !pool.contains(old) { pool.append(old) } }
            }
            var carried = pg.names
            for k in rg.cells {
                guard !carried.isEmpty, let (r, c) = Self.parse(k) else { continue }
                grid[r][c] = carried.removeFirst()
            }
            for n in carried where !pool.contains(n) { pool.append(n) }
            poolGroups.remove(at: gi)
            loading = false
            save()
            seatLog("座位：「\(rg.title)」整体从待用拖出（区域 \(rg.cells.count) 格，余 \(carried.count) 人回待用）")
            registerUndo("「\(rg.title)」整体从待用拖出", snap)
            return
        }

        // 2) 落在空白处：直接放回
        placePoolGroupOnBlank(poolIndex: gi, anchor: (ar, ac))
    }

    /// 把待用小组按原形状放到空白处；放不下就自动往后找位置，必要时补行补列
    private func placePoolGroupOnBlank(poolIndex gi: Int, anchor: (Int, Int)) {
        let pg = poolGroups[gi]
        let names = pg.names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else {
            poolGroups.remove(at: gi)
            save()
            return
        }
        let w = max(1, min(pg.cols ?? Self.guessCols(count: names.count), names.count))
        let h = (names.count + w - 1) / w
        let title = pg.title.isEmpty ? "第\(regions.count + 1)小组" : pg.title
        let colorIndex = pg.colorIndex ?? nextColorIndex()

        let snap = snapshot()

        // 找一块完全空白的矩形（从落点开始按行主序往后找；表不够大就自动补行补列）
        let origin = findBlankOrigin(anchor: anchor, height: h, width: w)

        loading = true
        // 姓名按行主序写入
        var placed: [CellKey] = []
        for (i, n) in names.enumerated() {
            let r = origin.0 + i / w, c = origin.1 + i % w
            grid[r][c] = n
            placed.append(Self.key(r, c))
        }
        regions.append(SeatRegion(id: UUID(), title: title,
                                  cells: placed.sorted(), colorIndex: colorIndex))
        poolGroups.remove(at: gi)
        loading = false
        save()
        let moved = origin.0 > anchor.0 || origin.1 > anchor.1
        seatLog("座位：「\(title)」从待用栏整体放回空白处 \(origin.0 + 1)行\(origin.1 + 1)列（\(names.count) 人\(moved ? "，原落点已被占用" : "")）")
        registerUndo("「\(title)」放回座位", snap)
    }

    /// 自动挑选一个可用色号（用得最少的）
    private func nextColorIndex() -> Int {
        var usage: [Int: Int] = [:]
        for rg in regions { usage[rg.colorIndex, default: 0] += 1 }
        return (0..<RegionPalette.count).min { usage[$0, default: 0] < usage[$1, default: 0] } ?? 0
    }

    /// 旧数据没有记录列数时的兜底形状：2 人一行，最多 3 列
    static func guessCols(count: Int) -> Int {
        if count <= 2 { return max(1, count) }
        if count % 3 == 0 { return 3 }
        if count % 2 == 0 { return 2 }
        return 3
    }

    /// 从 anchor 起按行主序找一块 height×width 的空白区域（会自动补行补列）
    private func findBlankOrigin(anchor: (Int, Int), height: Int, width: Int) -> (Int, Int) {
        var r = max(0, anchor.0)
        while true {
            var c = (r == anchor.0) ? max(0, anchor.1) : 0
            while c + width <= cols {
                if isBlankRect(row: r, col: c, height: height, width: width) { return (r, c) }
                c += 1
            }
            r += 1
            // 保证 (r, r+height) 与 c=0..width 都在表内
            ensureCapacity(rows: r + height, cols: max(cols, width))
        }
    }

    /// 该矩形是否完全空白（既不属于任何小组，也没有其他学生）
    private func isBlankRect(row r0: Int, col c0: Int, height: Int, width: Int) -> Bool {
        guard r0 >= 0, c0 >= 0, r0 + height <= rows, c0 + width <= cols else { return false }
        let occupied = Set(regions.flatMap { $0.cells })
        for r in r0..<(r0 + height) {
            for c in c0..<(c0 + width) {
                if occupied.contains(Self.key(r, c)) { return false }
                if !grid[r][c].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
            }
        }
        return true
    }

    /// 需要时补齐行列（只在右侧补列、在底部补行，已有坐标不受影响）
    private func ensureCapacity(rows needRows: Int, cols needCols: Int) {
        if needCols > cols {
            loading = true
            let add = needCols - cols
            for r in grid.indices {
                grid[r].append(contentsOf: Array(repeating: "", count: add))
            }
            loading = false
        }
        while rows < needRows {
            loading = true
            grid.append(Array(repeating: "", count: cols))
            loading = false
        }
    }

    /// 待用小组拆成个人（每个学生单独一条，便于逐个安排）
    func explodePoolGroup(id: UUID) {
        guard let gi = poolGroups.firstIndex(where: { $0.id == id }) else { return }
        let names = poolGroups[gi].names
        poolGroups.remove(at: gi)
        for n in names where !poolContains(n) { pool.append(n) }
        save()
    }

    /// 移除一个待用小组（⌘Z 可撤销）
    func removePoolGroup(id: UUID) {
        guard let gi = poolGroups.firstIndex(where: { $0.id == id }) else { return }
        let snapGroup = poolGroups[gi]
        let snapPool = pool
        poolGroups.remove(at: gi)
        UndoService.shared.register("移除待用小组「\(snapGroup.title)」") { [weak self] in
            guard let self else { return }
            self.poolGroups.insert(snapGroup, at: min(gi, self.poolGroups.count))
            self.pool = snapPool
            self.save()
        }
    }

    /// 一键全部待用：把所有座位上的学生撤下来，全部放进待用栏（⌘Z 可撤销）
    func allToPool() {        guard seatedCount > 0 else { return }
        let snap = snapshot()
        var names: [String] = []
        loading = true
        for r in grid.indices {
            for c in grid[r].indices {
                let n = grid[r][c].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !n.isEmpty else { continue }
                grid[r][c] = ""
                names.append(n)
            }
        }
        loading = false
        var newPool = pool
        for n in names where !newPool.contains(n) { newPool.append(n) }
        pool = newPool
        save()
        registerUndo("全部转待用", snap)
    }

    // MARK: - 性别

    func gender(of name: String) -> String? { genders[name] }

    /// 清空全部座位数据：保留一张空 8×8 大表（便于直接双击填写），
    /// 同时清空分组色块 / 待用栏 / 待用小组 / 性别标注。
    func clearAll() {
        loading = true
        grid = SeatingStore.emptyGrid(rows: SeatingStore.defaultSize, cols: SeatingStore.defaultSize)
        regions = []
        pool = []
        poolGroups = []
        genders = [:]
        selection = []
        loading = false
        save()
        seatLog("座位：已清空全部数据（保留 8×8 空表结构）")
    }

    func setGender(_ name: String, _ g: String?) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        if let g, !g.isEmpty { genders[n] = g } else { genders.removeValue(forKey: n) }
    }

    // MARK: - 拖拽落点处理

    /// 载荷：cell|r-c（拖学生） / pool|index / poolgroup|<uuid>（拖待用小组） / region|<uuid>|r-c（⌘ 拖整组）
    static func payload(cell key: CellKey) -> String { "cell|\(key)" }
    static func payload(pool index: Int) -> String { "pool|\(index)" }
    static func payload(poolGroup id: UUID) -> String { "poolgroup|\(id.uuidString)" }
    static func payload(region id: UUID, grab key: CellKey) -> String { "region|\(id.uuidString)|\(key)" }

    func handleDrop(_ payload: String, toKey dst: CellKey?) {
        let parts = payload.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return }
        let snap = snapshot()

        func commit(_ label: String) {
            UndoService.shared.register(label) { [weak self] in
                guard let self else { return }
                self.restore(snap)
            }
        }

        switch parts[0] {
        case "cell":
            guard let src = parts.count >= 2 ? parts[1] : nil,
                  let moving = name(at: src),
                  !moving.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            if let dst {
                let displaced = name(at: dst) ?? ""
                setCellRaw(src, displaced)
                setCellRaw(dst, moving)
                commit("对换座位")
            } else {
                setCellRaw(src, "")
                if !poolContains(moving) { pool.append(moving) }
                commit("移到待用栏")
            }
        case "pool":
            guard let idx = Int(parts[1]), pool.indices.contains(idx) else { return }
            let moving = pool[idx]
            if let dst {
                let displaced = name(at: dst) ?? ""
                pool.remove(at: idx)
                removeNameFromGrid(moving)
                setCellRaw(dst, moving)
                let d = displaced.trimmingCharacters(in: .whitespacesAndNewlines)
                if !d.isEmpty, !poolContains(d) { pool.append(d) }
            } else {
                pool.remove(at: idx)
                pool.append(moving)
            }
            commit("安排座位")
        case "poolgroup":
            // 待用小组整体拖回座位：按顺序填进落点所在的小组区域
            guard parts.count >= 2, let gid = UUID(uuidString: parts[1]), let dstKey = dst else { return }
            poolGroupToRegion(groupID: gid, anchor: dstKey)
        case "region":
            guard parts.count >= 3,
                  let rid = UUID(uuidString: parts[1]),
                  let grabKey = parts.count >= 3 ? parts[2] : nil else { return }
            if let dstKey = dst {
                _ = moveRegion(id: rid, grab: grabKey, to: dstKey)
            } else {
                // 拖到待用栏（无落点格）→ 小组整体放入待用栏
                regionToPool(id: rid)
            }
        default:
            break
        }
    }

    /// 只写格子，不动待用栏（对换等内部操作使用）
    private func setCellRaw(_ key: CellKey, _ name: String) {
        guard let (r, c) = Self.parse(key), grid.indices.contains(r), grid[r].indices.contains(c) else { return }
        grid[r][c] = name
    }

    // MARK: - 批量替换（导入 xlsx）：矩形块从左到右铺进一张大表，每组一个区域

    func replaceAll(groups newGroups: [SeatGroup], pool newPool: [String], genders newGenders: [String: String]) {
        let snap = snapshot()
        var cleanPool: [String] = []
        for n in newPool {
            let t = n.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !cleanPool.contains(t) else { continue }
            cleanPool.append(t)
        }
        let maxRows = max(newGroups.map { $0.seats.count }.max() ?? 0, Self.defaultSize)
        let totalCols = max(newGroups.reduce(0) { $0 + ($1.seats.map(\.count).max() ?? 0) }, Self.defaultSize)
        var newGrid = Self.emptyGrid(rows: maxRows, cols: totalCols)
        var newRegions: [SeatRegion] = []
        var colOffset = 0
        for (i, g) in newGroups.enumerated() {
            var cells: [CellKey] = []
            for r in g.seats.indices {
                for c in g.seats[r].indices {
                    let n = g.seats[r][c].trimmingCharacters(in: .whitespaces)
                    newGrid[r][colOffset + c] = n
                    cells.append(Self.key(r, colOffset + c))
                }
            }
            newRegions.append(SeatRegion(id: UUID(), title: g.title,
                                         cells: cells.sorted(), colorIndex: i % RegionPalette.count))
            colOffset += max(g.seats.map(\.count).max() ?? 0, 0)
        }
        // 待用栏优先：座位里与待用栏同名的清掉
        let poolSet = Set(cleanPool)
        for r in newGrid.indices {
            for c in newGrid[r].indices where poolSet.contains(newGrid[r][c]) {
                newGrid[r][c] = ""
            }
        }
        loading = true
        grid = newGrid
        regions = newRegions
        pool = cleanPool
        genders = newGenders
        loading = false
        save()
        UndoService.shared.register("导入座位安排") { [weak self] in
            guard let self else { return }
            self.restore(snap)
        }
    }

    /// 从「学生信息」导入名单（全部放进待用栏）
    func importRoster(names: [String], genders gs: [String: String]) {
        guard !names.isEmpty else { return }
        let snapPool = pool, snapGenders = genders
        for raw in names {
            let n = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !n.isEmpty else { continue }
            removeNameFromGrid(n)
            if !poolContains(n) { pool.append(n) }
        }
        for (k, v) in gs { genders[k] = v }
        UndoService.shared.register("导入学生名单") { [weak self] in
            guard let self else { return }
            self.pool = snapPool
            self.genders = snapGenders
            self.save()
        }
    }

    /// 启动自检：待用栏去重、座位与待用栏同名清理
    func normalize() {
        var cleanPool: [String] = []
        for n in pool {
            let t = n.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if !cleanPool.contains(t) { cleanPool.append(t) }
        }
        var changed = cleanPool != pool
        if changed {
            loading = true
            pool = cleanPool
            loading = false
        }
        let poolSet = Set(cleanPool)
        for r in grid.indices {
            for c in grid[r].indices {
                let t = grid[r][c].trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty, poolSet.contains(t) {
                    grid[r][c] = ""
                    changed = true
                }
            }
        }
        // 区域坐标越界清理（行列被删过等历史原因）
        var fixedRegions: [SeatRegion] = []
        var regionChanged = false
        for var rg in regions {
            let kept = rg.cells.filter { k in
                guard let (r, c) = Self.parse(k), grid.indices.contains(r), grid[r].indices.contains(c) else { return false }
                return true
            }
            if kept.count != rg.cells.count { regionChanged = true }
            rg.cells = kept.sorted()
            if !kept.isEmpty { fixedRegions.append(rg) }
        }
        if regionChanged {
            loading = true
            regions = fixedRegions
            loading = false
            changed = true
        }
        seatLog("座位自检：待用 \(cleanPool.count) 人 / 在座 \(seatedCount) 人，需修正=\(changed)")
        if changed {
            save()
            seatLog("座位自检：已自动清理重复姓名 / 无效区域")
        }
    }

    // MARK: - 撤销快照

    private typealias Snap = (grid: [[String]], regions: [SeatRegion], pool: [String], poolGroups: [PoolGroup])
    private func snapshot() -> Snap { (grid, regions, pool, poolGroups) }
    private func restore(_ s: Snap) {
        loading = true
        grid = s.grid
        regions = s.regions
        pool = s.pool
        poolGroups = s.poolGroups
        loading = false
        save()
    }
    private func registerUndo(_ label: String, _ s: Snap) {
        UndoService.shared.register(label) { [weak self] in
            guard let self else { return }
            self.restore(s)
        }
    }

    // MARK: - 持久化

    func scheduleSave() {
        guard !loading else { return }
        saver.schedule { self.save() }
    }

    func save() {
        loading = true
        deduplicate()
        loading = false
        do {
            let url = Self.fileURL()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(
                SeatingDataV2(version: 2, grid: grid, regions: regions, pool: pool,
                              genders: genders, poolGroups: poolGroups)
            )
            try data.write(to: url, options: .atomic)
        } catch {
            print("[ScheduleBar] 座位安排保存失败: \(error)")
            seatLog("座位保存失败：\(error.localizedDescription)")
        }
    }

    /// 落盘前防御性收敛：待用栏去重、座位不与待用栏同名
    private func deduplicate() {
        var cleanPool: [String] = []
        for n in pool {
            let t = n.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !cleanPool.contains(t) else { continue }
            cleanPool.append(t)
        }
        let poolSet = Set(cleanPool)
        for r in grid.indices {
            for c in grid[r].indices {
                let t = grid[r][c].trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty, poolSet.contains(t) { grid[r][c] = "" }
            }
        }
        pool = cleanPool
    }

    static func loadV2() -> SeatingDataV2? {
        guard let data = try? Data(contentsOf: fileURL()) else { return nil }
        return try? JSONDecoder().decode(SeatingDataV2.self, from: data)
    }

    static func loadOld() -> OldSeatingData? {
        guard let data = try? Data(contentsOf: fileURL()) else { return nil }
        return try? JSONDecoder().decode(OldSeatingData.self, from: data)
    }

    /// 旧版多小组 → 大表 + 区域（从左到右依次铺开，表格至少 8×8）
    static func migrate(old: OldSeatingData) -> (grid: [[String]], regions: [SeatRegion]) {
        let maxRows = max(old.groups.map { $0.seats.count }.max() ?? 0, defaultSize)
        let totalCols = max(old.groups.reduce(0) { $0 + ($1.seats.map(\.count).max() ?? 0) }, defaultSize)
        var grid = emptyGrid(rows: maxRows, cols: totalCols)
        var regions: [SeatRegion] = []
        var colOffset = 0
        for (i, g) in old.groups.enumerated() {
            var cells: [CellKey] = []
            for r in g.seats.indices {
                for c in g.seats[r].indices {
                    let n = g.seats[r][c].trimmingCharacters(in: .whitespaces)
                    grid[r][colOffset + c] = n
                    cells.append(key(r, colOffset + c))
                }
            }
            regions.append(SeatRegion(id: UUID(), title: g.title,
                                      cells: cells.sorted(), colorIndex: i % RegionPalette.count))
            colOffset += max(g.seats.map(\.count).max() ?? 0, 0)
        }
        return (grid, regions)
    }

    static func fileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("ScheduleBar", isDirectory: true)
                  .appendingPathComponent("seating.json")
    }

    // MARK: - 日志

    func seatLog(_ s: String) { Self.seatLog(s) }

    static func seatLog(_ s: String) {
        let dir = NSHomeDirectory() + "/Library/Logs"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/教师助手.log"
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let data = "[\(f.string(from: Date()))] \(s)\n".data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: path), let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

// MARK: - 性别配色（与学生信息一致：男蓝 / 女粉）
enum SeatGenderStyle {
    static func color(_ gender: String?) -> Color {
        switch gender {
        case "男": return Color(hex: 0x2E86C1)
        case "女": return Color(hex: 0xD81B60)
        default:   return Color.primary
        }
    }
    static func background(_ gender: String?) -> Color? {
        switch gender {
        case "男": return Color(hex: 0x2E86C1).opacity(0.18)
        case "女": return Color(hex: 0xD81B60).opacity(0.16)
        default:   return nil
        }
    }
}
