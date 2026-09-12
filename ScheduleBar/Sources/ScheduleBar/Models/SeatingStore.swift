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

/// 讲台在表格内的位置：从「第 row 行、第 col 列」起，横向占 span 个格子。
/// 讲台左右两侧的格子仍是普通座位格（可以正常排座位）。
struct PodiumPlacement: Codable, Equatable {
    var row: Int
    var col: Int
    var span: Int

    func covers(_ key: CellKey) -> Bool {
        guard let (r, c) = SeatRegion.parse(key) else { return false }
        return r == row && c >= col && c < col + span
    }

    /// 与讲台同一行、但不在讲台范围内的格子（= 讲台左边 / 右边的座位）
    func isBeside(_ key: CellKey) -> Bool {
        guard let (r, c) = SeatRegion.parse(key) else { return false }
        return r == row && !(c >= col && c < col + span)
    }

    var compactLabel: String { "第\(row + 1)行 第\(col + 1)~\(col + span)列" }
}

/// v2 持久化结构
struct SeatingDataV2: Codable {
    var version: Int
    var grid: [[String]]
    var regions: [SeatRegion]
    var pool: [String]
    var genders: [String: String]
    var poolGroups: [PoolGroup]?     // 可选：旧文件没有此字段
    var podium: PodiumPlacement?     // 可选：旧文件没有此字段（nil = 表格内不显示讲台）
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

    /// 新建座次表默认 11×11（Excel 式大表；行列可任意插删）
    static let defaultSize = 11

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
    /// 讲台在**表格内**的位置（nil = 不显示讲台）。讲台左右两侧仍是普通座位格。
    @Published var podium: PodiumPlacement? = nil { didSet { scheduleSave() } }
    /// 点选中的格子（用于组成小组 / 框选整体移动）
    @Published var selection: Set<CellKey> = []
    /// 操作提示（移动失败等），界面短暂显示
    @Published var notice: String? = nil
    /// 视角：false = 教师视角（讲台在最下方），true = 学生视角（整表 180° 镜像，讲台在最上方）
    @Published var studentView: Bool {
        didSet { UserDefaults.standard.set(studentView, forKey: Self.viewKey) }
    }

    private static let viewKey = "seating.studentView"
    /// 当前数据格式版本。v3 = 表格默认 11×11 + 讲台放进表格。
    /// 一次性初始化**以数据文件里的 version 为准**（比 UserDefaults 开关可靠：
    /// 开关一旦被写脏就再也回不去，而 version 随文件走，且用户后续的调整会被尊重）。
    static let dataVersion = 3

    private let saver = Debouncer()
    private var loading = false

    var rows: Int { max(grid.count, 1) }
    var cols: Int { max(grid.first?.count ?? 0, 1) }

    init() {
        Self.seatLog("座位：SeatingStore 初始化开始")
        studentView = UserDefaults.standard.bool(forKey: Self.viewKey)
        /// 是否需要一次性初始化（表格至少 11×11 + 讲台放进表格）：旧数据文件 / 首次运行
        var needsBootstrap = true
        if let d = Self.loadV2() {
            grid = d.grid
            regions = d.regions
            pool = d.pool
            poolGroups = d.poolGroups ?? []
            genders = d.genders
            podium = d.podium
            needsBootstrap = d.version < Self.dataVersion
            Self.seatLog("座位：已加载 seating.json v\(d.version)（\(d.grid.count)×\(d.grid.first?.count ?? 0)，分组 \(d.regions.count)、待用 \(d.pool.count)、待用小组 \(poolGroups.count)、讲台 \(podium?.compactLabel ?? "无")）")
        } else if let old = Self.loadOld() {
            // 旧版「多小组」数据 → 自动迁移：所有小组从左到右铺进一张大表，每组一个区域
            let migrated = Self.migrate(old: old)
            grid = migrated.grid
            regions = migrated.regions
            pool = old.pool
            genders = old.genders
            podium = nil
            Self.seatLog("座位：旧数据已迁移（\(old.groups.count) 组 → 表 \(grid.count)×\(grid.first?.count ?? 0)，分组 \(regions.count)）")
        } else {
            grid = Self.emptyGrid(rows: Self.defaultSize, cols: Self.defaultSize)
            regions = []
            pool = []
            genders = [:]
            podium = nil
            Self.seatLog("座位：未找到 seating.json，使用默认 \(Self.defaultSize)×\(Self.defaultSize) 空表")
        }

        // ── 一次性初始化：表格撑到至少 11×11、讲台放进表格 ──
        // 只对「数据文件版本 < 3」跑，跑完 save() 把版本写成 3；
        // 之后用户自己删行/移出讲台都不会被重新塞回来。
        var boot: [String] = []
        if needsBootstrap {
            let oldSize = (rows, cols)
            if ensureAtLeast(rows: Self.defaultSize, cols: Self.defaultSize) {
                boot.append("表格 \(oldSize.0)×\(oldSize.1) → \(rows)×\(cols)")
            }
            if podium == nil, let a = findDefaultPodiumAnchor(span: 3) {
                loading = true
                podium = PodiumPlacement(row: a.0, col: a.1, span: 3)
                loading = false
                boot.append("讲台放入表格（\(podium?.compactLabel ?? "-")）")
            }
        }
        if !boot.isEmpty { seatLog("座位：一次性初始化 —— " + boot.joined(separator: "；")) }
        normalize()
        if needsBootstrap { save() }   // 无论有没有实际改动都要落盘（把 version 提到 3）
    }

    static func emptyGrid(rows: Int, cols: Int) -> [[String]] {
        Array(repeating: Array(repeating: "", count: max(cols, 1)), count: max(rows, 1))
    }

    static func key(_ r: Int, _ c: Int) -> CellKey { "\(r)-\(c)" }
    static func parse(_ key: CellKey) -> (Int, Int)? { SeatRegion.parse(key) }

    /// Excel 式列号：0→A、25→Z、26→AA…
    static func columnLabel(_ index: Int) -> String {
        var n = max(index, 0)
        var s = ""
        repeat {
            let r = n % 26
            s = String(UnicodeScalar(UInt8(65 + r))) + s
            n = n / 26 - 1
        } while n >= 0
        return s
    }

    // MARK: - 格子读写

    func name(at key: CellKey) -> String? {
        guard let (r, c) = Self.parse(key), grid.indices.contains(r), grid[r].indices.contains(c) else { return nil }
        return grid[r][c]
    }

    func setCell(_ key: CellKey, _ name: String) {
        guard let (r, c) = Self.parse(key), grid.indices.contains(r), grid[r].indices.contains(c) else { return }
        guard !isPodium(key) else { seatLog("座位：\(key) 是讲台位置，不能写学生"); return }
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
        if var p = podium, p.row >= i { p.row += 1; podium = p }   // 讲台随行号下移
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
        if var p = podium, p.col >= i { p.col += 1; podium = clampPodium(p) }   // 讲台随列号右移
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
        // 讲台：所在行被删 → 自动另找一块空行；否则整体上移一行
        var podiumNote = ""
        if let p = podium {
            if p.row == index {
                podium = nil
                if let a = findDefaultPodiumAnchor(span: p.span) {
                    podium = PodiumPlacement(row: a.0, col: a.1, span: p.span)
                    podiumNote = "，讲台自动改放到 \(podium?.compactLabel ?? "-")"
                } else {
                    podiumNote = "，讲台因原行被删且无空行可放 → 已移出表格"
                }
            } else if p.row > index {
                podium = PodiumPlacement(row: p.row - 1, col: p.col, span: p.span)
            }
        }
        loading = false
        pool.append(contentsOf: removed)
        registerUndo("删除第\(index + 1)行", snap)
        seatLog("座位：删除第\(index + 1)行（\(removed.count) 人回待用栏）\(podiumNote)")
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
        // 讲台：删到讲台覆盖的列 → 变窄一格（不足 2 格则移出）；否则左侧被删则左移
        var podiumNote = ""
        if let p = podium {
            if index >= p.col, index < p.col + p.span {
                let narrowed = p.span - 1
                if narrowed < 2 {
                    podium = nil
                    podiumNote = "，讲台因宽度不足 2 格已移出表格"
                } else {
                    podium = clampPodium(PodiumPlacement(row: p.row, col: p.col, span: narrowed))
                    podiumNote = "，讲台变窄为 \(narrowed) 格"
                }
            } else if index < p.col {
                podium = clampPodium(PodiumPlacement(row: p.row, col: p.col - 1, span: p.span))
            }
        }
        loading = false
        pool.append(contentsOf: removed)
        registerUndo("删除第\(index + 1)列", snap)
        seatLog("座位：删除第\(index + 1)列（\(removed.count) 人回待用栏）\(podiumNote)")
    }

    // MARK: - 讲台（放在表格里面；讲台左边 / 右边的格子照常排座位）

    /// 讲台覆盖的所有格子（用于禁止放学生、禁止小组压上去）
    var podiumCells: Set<CellKey> {
        guard let p = podium else { return [] }
        var s: Set<CellKey> = []
        for c in p.col..<(p.col + p.span)
        where grid.indices.contains(p.row) && grid[p.row].indices.contains(c) {
            s.insert(Self.key(p.row, c))
        }
        return s
    }

    func isPodium(_ key: CellKey) -> Bool { podium?.covers(key) ?? false }

    /// 把讲台位置收进表格范围内
    private func clampPodium(_ p: PodiumPlacement) -> PodiumPlacement {
        var q = p
        q.span = min(max(q.span, 2), max(cols, 2))
        q.col = min(max(q.col, 0), max(cols - q.span, 0))
        q.row = min(max(q.row, 0), rows - 1)
        return q
    }

    /// 该位置被学生占着 → 讲台不能放过去（避免把学生压没）
    private func blockedUnderPodium(_ p: PodiumPlacement) -> [CellKey] {
        (p.col..<(p.col + p.span)).compactMap { c in
            let k = Self.key(p.row, c)
            let n = name(at: k) ?? ""
            return n.trimmingCharacters(in: .whitespaces).isEmpty ? nil : k
        }
    }

    /// 统一的讲台落位入口：先校验（压到学生就拒绝），再写入 + 登记撤销
    @discardableResult
    private func applyPodium(_ p: PodiumPlacement, label: String) -> Bool {
        let q = clampPodium(p)
        let blocked = blockedUnderPodium(q)
        guard blocked.isEmpty else {
            setNotice("讲台放不下：\(q.compactLabel) 有 \(blocked.count) 个座位已有学生，请先把学生移开")
            seatLog("座位：\(label)失败 —— 目标 \(q.compactLabel) 有学生 \(blocked.joined(separator: "、"))")
            return false
        }
        let snap = snapshot()
        loading = true
        podium = q
        loading = false
        registerUndo(label, snap)
        seatLog("座位：\(label) → \(q.compactLabel)（左右两侧仍可排座位）")
        return true
    }

    /// 拖动讲台：落点格作为讲台中心
    @discardableResult
    func movePodium(to key: CellKey) -> Bool {
        guard let (r, c) = Self.parse(key) else { return false }
        let span = podium?.span ?? 3
        let newCol = min(max(c - span / 2, 0), max(cols - span, 0))
        let sameRow = podium?.row == min(max(r, 0), rows - 1)
        let sameCol = podium?.col == newCol
        guard !(sameRow && sameCol) else { return false }
        return applyPodium(PodiumPlacement(row: r, col: newCol, span: span), label: "拖动讲台")
    }

    /// 讲台居中（同一行左右各留尽可能相等的座位）
    func centerPodium() {
        guard let p = podium else { return }
        let c = max((cols - p.span) / 2, 0)
        guard c != p.col else { return }
        _ = applyPodium(PodiumPlacement(row: p.row, col: c, span: p.span), label: "讲台居中")
    }

    /// 讲台移到最上一行 / 最下一行
    func podiumToEdge(top: Bool) {
        guard let p = podium else { return }
        _ = applyPodium(PodiumPlacement(row: top ? 0 : rows - 1, col: p.col, span: p.span),
                        label: top ? "讲台移到最上一行" : "讲台移到最下一行")
    }

    /// 调整讲台宽度（占几格）
    func setPodiumSpan(_ span: Int) {
        guard let p = podium else { return }
        _ = applyPodium(PodiumPlacement(row: p.row, col: p.col, span: span), label: "讲台宽度改为 \(span) 格")
    }

    /// 从表格里移除讲台（数据不动）
    func removePodium() {
        guard let p = podium else { return }
        let snap = snapshot()
        loading = true
        podium = nil
        loading = false
        registerUndo("移出讲台", snap)
        seatLog("座位：讲台已移出表格（原 \(p.compactLabel)）")
    }

    /// 把讲台放进表格：优先最下面一行、居中；放不下就往上找一整条空行
    @discardableResult
    func addPodium(span: Int = 3) -> Bool {
        guard podium == nil else { return false }
        guard let a = findDefaultPodiumAnchor(span: span) else {
            setNotice("表格里找不到连续 \(span) 格的空行放讲台，请先腾出空位")
            seatLog("座位：放入讲台失败 —— 没有连续 \(span) 格的空行")
            return false
        }
        let snap = snapshot()
        loading = true
        podium = PodiumPlacement(row: a.0, col: a.1, span: min(span, cols))
        loading = false
        registerUndo("放入讲台", snap)
        seatLog("座位：讲台已放入表格 \(podium?.compactLabel ?? "-")")
        return true
    }

    /// 从最后一行往上找一条「连续 span 格全空」的横带，优先居中
    private func findDefaultPodiumAnchor(span: Int) -> (Int, Int)? {
        let w = min(max(span, 2), cols)
        var r = rows - 1
        while r >= 0 {
            let center = max((cols - w) / 2, 0)
            var order: [Int] = [center]
            if cols - w >= 0 {
                for c in 0...(cols - w) where c != center { order.append(c) }
            }
            for c in order where isBlankSeatRun(row: r, col: c, width: w) { return (r, c) }
            r -= 1
        }
        return nil
    }

    /// 该行这一段是否整段可用（空格子 + 不属于任何小组 + 不与讲台重叠）
    private func isBlankSeatRun(row: Int, col: Int, width: Int) -> Bool {
        guard row >= 0, row < rows, col >= 0, col + width <= cols else { return false }
        let occupied = Set(regions.flatMap { $0.cells })
        for c in col..<(col + width) {
            let k = Self.key(row, c)
            if occupied.contains(k) { return false }
            if isPodium(k) { return false }
            if !grid[row][c].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        }
        return true
    }

    // MARK: - 框选（Excel 式矩形选择）与「框选整体移动」

    /// 选中以 a、b 为对角的矩形区域（讲台格子自动跳过）
    func selectRect(from a: CellKey, to b: CellKey) {
        guard let (ar, ac) = Self.parse(a), let (br, bc) = Self.parse(b) else { return }
        var keys: Set<CellKey> = []
        for r in min(ar, br)...max(ar, br) {
            for c in min(ac, bc)...max(ac, bc) {
                guard grid.indices.contains(r), grid[r].indices.contains(c) else { continue }
                let k = Self.key(r, c)
                if isPodium(k) { continue }
                keys.insert(k)
            }
        }
        selection = keys
        seatLog("座位：框选 \(a) → \(b)，选中 \(keys.count) 格")
    }

    /// 框选整体移动：抓着 grab 格，把**整个选区**按同样的偏移搬到 target；
    /// 学生一起走；完全落在选区里的小组连色块一起平移。
    /// 越界 / 撞讲台 / 目标格已有人 / 目标格属于别的小组 → 拒绝并提示。
    @discardableResult
    func moveSelection(grab: CellKey, to target: CellKey) -> Bool {
        guard selection.count > 1, selection.contains(grab),
              let g = Self.parse(grab), let t = Self.parse(target) else { return false }
        let dr = t.0 - g.0, dc = t.1 - g.1
        guard dr != 0 || dc != 0 else { return false }
        let moved = Set(selection)

        // ① 每个源格都要算出一个合法的目标格
        var dest: [CellKey: CellKey] = [:]
        for k in moved {
            guard let (r, c) = Self.parse(k) else { continue }
            let nr = r + dr, nc = c + dc
            guard grid.indices.contains(nr), grid[nr].indices.contains(nc) else {
                setNotice("整体移动失败：会移出表格边界")
                seatLog("座位：框选整体移动失败 —— 会移出表格边界")
                return false
            }
            if isPodium(Self.key(nr, nc)) {
                setNotice("整体移动失败：目标位置是讲台")
                seatLog("座位：框选整体移动失败 —— 撞上讲台")
                return false
            }
            dest[k] = Self.key(nr, nc)
        }

        // ② 选区里「整组都在」的小组才跟着平移；只落进一小部分的小组不动 → 目标格不能压到它们
        let movingRegionIDs = Set(regions.filter {
            !$0.cells.isEmpty && $0.cells.allSatisfy { moved.contains($0) }
        }.map(\.id))
        let outside = Set(dest.values).subtracting(moved)
        for k in outside {
            let n = name(at: k) ?? ""
            if !n.trimmingCharacters(in: .whitespaces).isEmpty {
                setNotice("整体移动失败：\(k) 已有学生「\(n)」，请先移到空位")
                seatLog("座位：框选整体移动失败 —— 目标 \(k) 已有学生「\(n)」")
                return false
            }
            if let rg = region(at: k), !movingRegionIDs.contains(rg.id) {
                setNotice("整体移动失败：目标位置与小组「\(rg.title)」重叠")
                seatLog("座位：框选整体移动失败 —— 目标 \(k) 与小组「\(rg.title)」重叠")
                return false
            }
        }

        let snap = snapshot()
        loading = true
        var carried: [(CellKey, String)] = []
        for k in moved {
            let n = name(at: k) ?? ""
            if !n.trimmingCharacters(in: .whitespaces).isEmpty { carried.append((k, n)) }
            setCellRaw(k, "")
        }
        for (k, n) in carried { if let nk = dest[k] { setCellRaw(nk, n) } }
        var movedTitles: [String] = []
        for i in regions.indices where movingRegionIDs.contains(regions[i].id) {
            movedTitles.append(regions[i].title)
            regions[i].cells = regions[i].cells.compactMap { dest[$0] }.sorted()
        }
        loading = false
        selection = Set(dest.values)
        seatLog("座位：框选整体移动 \(moved.count) 格（下移 \(dr) 行、右移 \(dc) 列），携带 \(carried.count) 名学生"
                + (movedTitles.isEmpty ? "" : "；小组「\(movedTitles.joined(separator: "、"))」连色块一起移动"))
        registerUndo("框选整体移动", snap)
        return true
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
        // 先把这些格子从原有小组里摘出来（并清掉被摘空的小组）：
        // 否则一个格子会同时属于两个小组 —— 色块显示混乱、⌘拖整组时也会拖错组。
        var detached = 0
        for i in regions.indices {
            let old = regions[i].cells
            let left = old.filter { !keys.contains($0) }
            detached += old.count - left.count
            regions[i].cells = left
        }
        regions.removeAll { $0.cells.isEmpty }
        if detached > 0 { seatLog("座位：新小组先从原有小组移出 \(detached) 格（避免一格同属两组）") }
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
        seatLog("座位：已解散小组「\(title)」（学生留在原位；剩余小组 \(regions.count) 个）")
    }

    /// 选中项里属于小组的格子（「取消分组」按钮据此显隐与计数）
    var selectionGroupCells: Set<CellKey> {
        Set(selection.filter { region(at: $0) != nil })
    }

    /// 取消分组：把当前选中的格子从所在小组里移出（学生留在原位）。⌘Z 可撤销。
    @discardableResult
    func ungroupSelection() -> Int { removeFromRegions(keys: selection) }

    /// 把指定格子从它们所属的小组里移出；某个小组被移空 → 自动解散该组。
    /// - Returns: 实际移出的格子数（0 = 这些格子本来就不在任何小组里）
    @discardableResult
    func removeFromRegions(keys: Set<CellKey>) -> Int {
        let targets = keys.filter { region(at: $0) != nil }
        guard !targets.isEmpty else {
            seatLog("座位：取消分组 —— 选中的 \(keys.count) 格都不属于任何小组，无需处理")
            return 0
        }
        let snap = snapshot()
        var changed: [String] = []
        var dissolved: [String] = []
        for i in regions.indices.reversed() {
            let old = regions[i].cells
            let left = old.filter { !targets.contains($0) }
            guard left.count != old.count else { continue }
            changed.append(regions[i].title)
            if left.isEmpty {
                dissolved.append(regions[i].title)
                regions.remove(at: i)
            } else {
                regions[i].cells = left
            }
        }
        selection = []
        registerUndo("取消分组（\(targets.count) 格）", snap)
        seatLog("座位：取消分组 —— 从「\(changed.joined(separator: "、"))」移出 \(targets.count) 格"
                + (dissolved.isEmpty ? "" : "；「\(dissolved.joined(separator: "、"))」被移空 → 自动解散"))
        return targets.count
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
        let others = Set(regions.filter { $0.id != id }.flatMap { $0.cells }).union(podiumCells)
        for (r, c) in member {
            let k = Self.key(r + dr, c + dc)
            guard !others.contains(k) else {
                let hitPodium = isPodium(k)
                setNotice(hitPodium ? "整体移动失败：目标位置是讲台"
                                    : "整体移动失败：与「\(region(at: k)?.title ?? "其他小组")」重叠")
                seatLog("座位：「\(rg.title)」整体移动失败：\(hitPodium ? "撞上讲台" : "与其他小组重叠")")
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
        guard !isPodium(key) else {
            setNotice("讲台位置不能放学生")
            seatLog("座位：待用小组落到讲台格 \(key) → 拒绝")
            return
        }
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

    /// 该矩形是否完全空白（不属于任何小组、没有其他学生、也不压在讲台上）
    private func isBlankRect(row r0: Int, col c0: Int, height: Int, width: Int) -> Bool {
        guard r0 >= 0, c0 >= 0, r0 + height <= rows, c0 + width <= cols else { return false }
        let occupied = Set(regions.flatMap { $0.cells })
        for r in r0..<(r0 + height) {
            for c in c0..<(c0 + width) {
                let k = Self.key(r, c)
                if occupied.contains(k) { return false }
                if isPodium(k) { return false }
                if !grid[r][c].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
            }
        }
        return true
    }

    /// 需要时补齐行列（只在右侧补列、在底部补行，已有坐标不受影响）
    private func ensureCapacity(rows needRows: Int, cols needCols: Int) {
        _ = ensureAtLeast(rows: needRows, cols: needCols)
    }

    /// 把表格撑到「至少 needRows × needCols」（只增不减，已有坐标不受影响）
    /// - Returns: 是否真的变大了
    @discardableResult
    private func ensureAtLeast(rows needRows: Int, cols needCols: Int) -> Bool {
        var changed = false
        if needCols > cols {
            loading = true
            let add = needCols - cols
            for r in grid.indices {
                grid[r].append(contentsOf: Array(repeating: "", count: add))
            }
            loading = false
            changed = true
        }
        while rows < needRows {
            loading = true
            grid.append(Array(repeating: "", count: cols))
            loading = false
            changed = true
        }
        return changed
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

    /// 清空全部座位数据：保留一张空 11×11 大表（便于直接双击填写）+ 表格内默认讲台，
    /// 同时清空分组色块 / 待用栏 / 待用小组 / 性别标注。
    func clearAll() {
        loading = true
        grid = SeatingStore.emptyGrid(rows: SeatingStore.defaultSize, cols: SeatingStore.defaultSize)
        regions = []
        pool = []
        poolGroups = []
        genders = [:]
        selection = []
        podium = nil
        if let a = findDefaultPodiumAnchor(span: 3) {
            podium = PodiumPlacement(row: a.0, col: a.1, span: 3)
        }
        loading = false
        save()
        seatLog("座位：已清空全部数据（保留 \(SeatingStore.defaultSize)×\(SeatingStore.defaultSize) 空表 + 讲台 \(podium?.compactLabel ?? "无")）")
    }

    func setGender(_ name: String, _ g: String?) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        if let g, !g.isEmpty { genders[n] = g } else { genders.removeValue(forKey: n) }
    }

    // MARK: - 拖拽落点处理

    /// 载荷：
    /// - `cell|r-c`            拖学生对换（单格）
    /// - `selblock|r-c`        框选多格后整块移动（r-c = 抓着的那一格）
    /// - `marquee|r-c`         从空格子起手拖到另一格 = 矩形框选
    /// - `pool|index`          待用栏里的学生
    /// - `poolgroup|<uuid>`    待用小组整体
    /// - `region|<uuid>|r-c`   ⌘ 拖整组
    /// - `podium`              讲台（在表格内，可拖着换行换列）
    static func payload(cell key: CellKey) -> String { "cell|\(key)" }
    static func payload(selection grab: CellKey) -> String { "selblock|\(grab)" }
    static func payload(marquee anchor: CellKey) -> String { "marquee|\(anchor)" }
    static func payload(pool index: Int) -> String { "pool|\(index)" }
    static func payload(poolGroup id: UUID) -> String { "poolgroup|\(id.uuidString)" }
    static func payload(region id: UUID, grab key: CellKey) -> String { "region|\(id.uuidString)|\(key)" }
    static let payloadPodium = "podium"

    func handleDrop(_ payload: String, toKey dst: CellKey?) {
        // 讲台（单 token，没有 "|"）
        if payload == Self.payloadPodium {
            guard let dstKey = dst else { return }
            _ = movePodium(to: dstKey)
            return
        }
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
                if isPodium(dst) {
                    setNotice("讲台位置不能放学生")
                    seatLog("座位：拖学生到讲台格 \(dst) → 拒绝")
                    return
                }
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
                if isPodium(dst) {
                    setNotice("讲台位置不能放学生")
                    seatLog("座位：从待用栏拖到讲台格 \(dst) → 拒绝")
                    return
                }
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
        case "selblock":
            guard parts.count >= 2 else { return }
            if let dstKey = dst {
                _ = moveSelection(grab: parts[1], to: dstKey)
            } else {
                // 框选整体拖到待用栏 → 选区里的学生全部撤下待用
                batchToPool()
            }
        case "marquee":
            guard parts.count >= 2, let dstKey = dst else { return }
            selectRect(from: parts[1], to: dstKey)
        case "podium":
            guard let dstKey = dst else { return }
            _ = movePodium(to: dstKey)
        default:
            break
        }
    }

    /// 只写格子，不动待用栏（对换等内部操作使用）
    private func setCellRaw(_ key: CellKey, _ name: String) {
        guard let (r, c) = Self.parse(key), grid.indices.contains(r), grid[r].indices.contains(c) else { return }
        guard !isPodium(key) else { return }   // 讲台格子永远不写学生
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
        podium = nil
        loading = false
        // 导入后把讲台放回表格（只挑一整条空行，绝不会压到刚导入的学生）
        if let a = findDefaultPodiumAnchor(span: 3) {
            loading = true
            podium = PodiumPlacement(row: a.0, col: a.1, span: 3)
            loading = false
        }
        save()
        seatLog("座位：导入完成 → 表 \(rows)×\(cols)，讲台 \(podium?.compactLabel ?? "无")")
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
        // 讲台越界清理（行列被删过等历史原因）
        if let p = podium {
            let q = clampPodium(p)
            if q != p {
                loading = true
                podium = q
                loading = false
                changed = true
                seatLog("座位自检：讲台位置已收进表格范围（\(p.compactLabel) → \(q.compactLabel)）")
            }
        }
        seatLog("座位自检：待用 \(cleanPool.count) 人 / 在座 \(seatedCount) 人 / 讲台 \(podium?.compactLabel ?? "无")，需修正=\(changed)")
        if changed {
            save()
            seatLog("座位自检：已自动清理重复姓名 / 无效区域")
        }
    }

    // MARK: - 撤销快照

    private typealias Snap = (grid: [[String]], regions: [SeatRegion], pool: [String],
                              poolGroups: [PoolGroup], podium: PodiumPlacement?)
    private func snapshot() -> Snap { (grid, regions, pool, poolGroups, podium) }
    private func restore(_ s: Snap) {
        loading = true
        grid = s.grid
        regions = s.regions
        pool = s.pool
        poolGroups = s.poolGroups
        podium = s.podium
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
                SeatingDataV2(version: Self.dataVersion, grid: grid, regions: regions, pool: pool,
                              genders: genders, poolGroups: poolGroups, podium: podium)
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
        // 自检用：SCHEDULEBAR_DATA_DIR 可把数据目录重定向到临时目录（绝不触碰真实数据）
        if let dir = ProcessInfo.processInfo.environment["SCHEDULEBAR_DATA_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
                .appendingPathComponent("seating.json")
        }
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
