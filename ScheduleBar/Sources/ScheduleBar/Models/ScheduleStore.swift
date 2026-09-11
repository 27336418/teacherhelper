import Foundation
import SwiftUI

// MARK: - 个人课表数据模型（上午/下午/晚自习 分组，节次可增删；持久化 personal.json）

/// 一个时段分组（上午 / 下午 / 晚自习）
struct PersonalGroup: Codable, Equatable {
    var title: String
    var periods: [String]
}

/// 存储格式：{"groups": [...], "grid": [[...]]}
/// grid 行序与 groups.flatMap{ $0.periods } 一一对应
struct PersonalData: Codable {
    var groups: [PersonalGroup]
    var grid: [[String]]
}

/// 个人课表存储（6 天；周一~周五 + 周日）
/// 单元格内容为班级/巡班文本，如 "7"、"8"、"巡1-15班"、"8班+巡16-30"
final class ScheduleStore: ObservableObject {
    static let shared = ScheduleStore()

    // 列：星期（6 天；周六已移除，顺序：周一→周五，然后周日）
    static let days = ["周一", "周二", "周三", "周四", "周五", "周日"]

    /// 默认布局：上午 5 节 + 下午 4 节 + 晚自习 4 节
    static let defaultGroups: [PersonalGroup] = [
        PersonalGroup(title: "上午", periods: ["第1节", "第2节", "第3节", "第4节", "第5节"]),
        PersonalGroup(title: "下午", periods: ["第6节", "第7节", "第8节", "第9节"]),
        PersonalGroup(title: "晚自习", periods: ["晚1", "晚2", "晚3", "晚4"]),
    ]

    /// 旧版（无分组）默认节次，仅用于迁移历史数据
    private static let legacyPeriods = [
        "早自习", "第1节", "第2节", "第3节", "第4节", "第5节",
        "第6节", "第7节", "第8节", "第9节", "晚自习"
    ]

    @Published var groups: [PersonalGroup] {
        didSet { scheduleSave() }
    }
    @Published var grid: [[String]] {
        didSet { scheduleSave() }
    }

    private let saver = Debouncer()

    init() {
        let data = ScheduleStore.load()
        // 兜底：没有本地数据、或本地数据节次为空（旧版清空过）→ 用默认布局，
        // 保证个人课表任何情况下都「有节次的空表」，可以直接双击填写。
        let gs: [PersonalGroup]
        if let g = data?.groups, !g.isEmpty, !g.allSatisfy({ $0.periods.isEmpty }) {
            gs = g
        } else {
            gs = ScheduleStore.defaultGroups
        }
        self.groups = gs
        self.grid = ScheduleStore.normalizeGrid(data?.grid ?? [], periods: gs.flatMap { $0.periods })
        // 修正历史错位：保证「第N节」/「晚N」按显示顺序连续编号
        renumberPeriods()
    }

    static func emptyGrid(periods: [String]) -> [[String]] {
        Array(repeating: Array(repeating: "", count: days.count), count: periods.count)
    }

    /// 把任意行列数的网格归一到给定节次数量（列不足补空、超出截断；行同理）
    static func normalizeGrid(_ grid: [[String]], periods: [String]) -> [[String]] {
        var out: [[String]] = grid.map { row in
            var r = Array(row.prefix(days.count))
            if r.count < days.count {
                r.append(contentsOf: Array(repeating: "", count: days.count - r.count))
            }
            return r
        }
        if out.count < periods.count {
            out.append(contentsOf: Array(repeating: Array(repeating: "", count: days.count),
                                         count: periods.count - out.count))
        }
        if out.count > periods.count { out = Array(out.prefix(periods.count)) }
        return out
    }

    // MARK: 派生数据
    /// 全部节次（按分组顺序展开）
    var orderedPeriods: [String] { groups.flatMap { $0.periods } }
    /// 兼容旧引用（导入 / 导出等）
    var periods: [String] { orderedPeriods }

    /// 节次 → grid 行下标
    func flatIndex(of period: String) -> Int? {
        var i = 0
        for g in groups {
            if let k = g.periods.firstIndex(of: period) { return i + k }
            i += g.periods.count
        }
        return nil
    }

    func cell(_ period: String, _ day: Int) -> String {
        guard let r = flatIndex(of: period), r < grid.count, day < grid[r].count else { return "" }
        return grid[r][day]
    }

    func setCell(_ period: String, _ day: Int, _ value: String) {
        guard let r = flatIndex(of: period), r < grid.count, day < grid[r].count else { return }
        grid[r][day] = value
        save()
    }

    // MARK: 单元格拖动对换（同一张个人课表内）

    /// 拖动中的单元格来源（普通 var，不进 @Published：拖动过程中不刷新视图）
    var cellDragSource: ScheduleCellID?
    private var cellDragSnapshot: [[String]]?

    func beginCellDrag(_ period: String, _ day: Int) {
        guard let r = flatIndex(of: period), r < grid.count, day < grid[r].count else { return }
        cellDragSnapshot = grid
        cellDragSource = ScheduleCellID(period: period, day: day)
    }

    /// 把拖动来源格与目标格的课表内容对换
    func swapCellTo(_ period: String, _ day: Int) {
        guard let src = cellDragSource,
              let sr = flatIndex(of: src.period), let dr = flatIndex(of: period),
              sr < grid.count, dr < grid.count,
              grid[sr].indices.contains(src.day), grid[dr].indices.contains(day),
              !(sr == dr && src.day == day) else { return }
        let tmp = grid[sr][src.day]
        grid[sr][src.day] = grid[dr][day]
        grid[dr][day] = tmp
        save()
        // 来源位置跟着被拖动的内容走，避免 dropEntered 连续触发时来回抖动
        cellDragSource = ScheduleCellID(period: period, day: day)
    }

    func finishCellDrag() {
        defer { cellDragSource = nil; cellDragSnapshot = nil }
        guard let snap = cellDragSnapshot, snap != grid else { return }
        UndoService.shared.register("调整课表位置") { [weak self] in
            guard let self else { return }
            self.grid = snap
            self.save()
        }
    }

    // MARK: 节次增删（在某个时段内）
    func addPeriod(in groupIndex: Int) {
        guard groups.indices.contains(groupIndex) else { return }
        // 根据组名选择新节次标签模板：「上午/下午」用「第N节」，「晚自习」用「晚N」
        let isEvening = groups[groupIndex].title.contains("晚")
        let label: String
        if isEvening {
            let nums = groups[groupIndex].periods.compactMap { Self.eveningNumber($0) }
            label = "晚\((nums.max() ?? 0) + 1)"
        } else {
            let nums = groups[groupIndex].periods.compactMap { Self.numberedPart($0) }
            label = "第\((nums.max() ?? 0) + 1)节"
        }
        // 末尾追加新节次
        groups[groupIndex].periods.append(label)
        // 在 grid 末尾（若该组内没有其它已存在的 grid 行则整体尾部插入，否则按 flat 位置插）
        let flat = groups[0..<groupIndex].reduce(0) { $0 + $1.periods.count } + (groups[groupIndex].periods.count - 1)
        let row = Array(repeating: "", count: Self.days.count)
        if flat <= grid.count { grid.insert(row, at: flat) } else { grid.append(row) }
        // 重新编号：保证所有「第N节」/「晚N」节次按显示顺序连续
        renumberPeriods()
    }

    func removePeriod(_ label: String) {
        guard orderedPeriods.count > 1 else { return }
        let snapGroups = groups, snapGrid = grid
        let flat = flatIndex(of: label)
        for i in groups.indices { groups[i].periods.removeAll { $0 == label } }
        if let f = flat, f < grid.count { grid.remove(at: f) }
        // 删除后重新编号，让后续节次顺序保持连续
        renumberPeriods()
        UndoService.shared.register("删除节次「\(label)」") { [weak self] in
            guard let self else { return }
            self.groups = snapGroups
            self.grid = snapGrid
            self.save()
        }
    }

    /// 重新编号所有「第N节」/「晚N」节次：按显示顺序重新填充连续编号；
    /// 自定义名称（如「早自习」「晚自习」「课间」等）保持原样不动。
    func renumberPeriods() {
        var dayCounter = 0
        var eveCounter = 0
        for i in groups.indices {
            for j in groups[i].periods.indices {
                let p = groups[i].periods[j]
                if Self.numberedPart(p) != nil {
                    dayCounter += 1
                    groups[i].periods[j] = "第\(dayCounter)节"
                } else if Self.eveningNumber(p) != nil {
                    eveCounter += 1
                    groups[i].periods[j] = "晚\(eveCounter)"
                }
            }
        }
    }

    /// "第3节"/"第10节" → 3/10；不匹配返回 nil
    private static func numberedPart(_ s: String) -> Int? {
        guard s.hasPrefix("第"), s.hasSuffix("节"), s.count > 2 else { return nil }
        return sectionNumber(s)
    }

    /// "晚1"/"晚12" → 1/12；"晚自习" 等含汉字的返回 nil
    private static func eveningNumber(_ s: String) -> Int? {
        guard s.hasPrefix("晚"), s.count > 1 else { return nil }
        let tail = String(s.dropFirst())
        return tail.allSatisfy { $0.isNumber } ? sectionNumber(tail) : nil
    }

    func clear() {
        let snapGroups = groups, snapGrid = grid
        groups = ScheduleStore.defaultGroups
        grid = ScheduleStore.emptyGrid(periods: orderedPeriods)
        save()
        UndoService.shared.register("重置个人课表") { [weak self] in
            guard let self else { return }
            self.groups = snapGroups
            self.grid = snapGrid
            self.save()
        }
    }

    // MARK: 持久化（JSON，存于 Application Support/ScheduleBar；输入去抖）
    func scheduleSave() {
        saver.schedule { self.save() }
    }

    func save() {
        do {
            let url = Self.fileURL()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(PersonalData(groups: groups, grid: grid))
            try data.write(to: url, options: .atomic)
        } catch {
            print("[ScheduleBar] 保存失败: \(error)")
        }
    }

    // MARK: 加载与迁移
    static func load() -> PersonalData? {
        let url = fileURL()
        guard let raw = try? Data(contentsOf: url) else { return nil }

        // 新格式：{"groups","grid"}
        if let d = try? JSONDecoder().decode(PersonalData.self, from: raw), !d.groups.isEmpty {
            return normalize(d)
        }
        // 中间格式：{"periods","grid"} → 按名称归入 上午/下午/晚自习
        if let d = try? JSONDecoder().decode([String: [[String]]].self, from: raw),
           let oldPeriods = d["periods"]?.compactMap({ $0.first }),
           let oldGrid = d["grid"], !oldPeriods.isEmpty {
            return normalize(regroup(periods: oldPeriods, grid: oldGrid))
        }
        // 最旧格式：纯 [[String]]（7 列时去掉周六）
        if var rows = try? JSONDecoder().decode([[String]].self, from: raw) {
            if rows.first?.count == 7 {
                for i in rows.indices where rows[i].count == 7 { rows[i].remove(at: 5) }
            }
            let oldPeriods = rows.count == legacyPeriods.count
                ? legacyPeriods
                : (0..<rows.count).map { "第\($0 + 1)节" }
            return normalize(regroup(periods: oldPeriods, grid: rows))
        }
        return nil
    }

    /// 把扁平节次按名称分入 上午/下午/晚自习，并同步重排 grid 行
    private static func regroup(periods: [String], grid: [[String]]) -> PersonalData {
        let pairs: [(String, [String])] = periods.enumerated().map { i, p in
            (p, i < grid.count ? grid[i] : Array(repeating: "", count: days.count))
        }
        var early: [(String, [String])] = []
        var am: [(String, [String])] = []
        var pm: [(String, [String])] = []
        var ev: [(String, [String])] = []
        for pair in pairs {
            let p = pair.0
            if p.contains("晚") {
                ev.append(pair)
            } else if let n = sectionNumber(p) {
                if n <= 5 { am.append(pair) } else { pm.append(pair) }
            } else if p.contains("早") {
                early.append(pair)
            } else {
                am.append(pair)
            }
        }
        let ordered = early + am + pm + ev
        var out: [PersonalGroup] = [
            PersonalGroup(title: "上午", periods: (early + am).map { $0.0 }),
            PersonalGroup(title: "下午", periods: pm.map { $0.0 }),
            PersonalGroup(title: "晚自习", periods: ev.map { $0.0 }),
        ]
        out = out.filter { !$0.periods.isEmpty }
        if out.isEmpty { out = defaultGroups }
        return PersonalData(groups: out, grid: ordered.map { $0.1 })
    }

    /// "第3节" → 3
    private static func sectionNumber(_ s: String) -> Int? {
        let digits = s.compactMap { $0.isNumber ? Int(String($0)) : nil }
        guard !digits.isEmpty else { return nil }
        return digits.reduce(0) { $0 * 10 + $1 }
    }

    /// 行列数归一（防止手工改动导致越界）
    private static func normalize(_ d: PersonalData) -> PersonalData {
        var out = d
        if out.groups.isEmpty { out.groups = defaultGroups }
        let flat = out.groups.flatMap { $0.periods }
        out.grid = out.grid.map { row in
            var r = row
            if r.count < days.count { r.append(contentsOf: Array(repeating: "", count: days.count - r.count)) }
            if r.count > days.count { r = Array(r.prefix(days.count)) }
            return r
        }
        if out.grid.count < flat.count {
            out.grid.append(contentsOf: Array(repeating: Array(repeating: "", count: days.count),
                                              count: flat.count - out.grid.count))
        }
        if out.grid.count > flat.count { out.grid = Array(out.grid.prefix(flat.count)) }
        return out
    }

    static func fileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("ScheduleBar", isDirectory: true)
                  .appendingPathComponent("personal.json")
    }
}
