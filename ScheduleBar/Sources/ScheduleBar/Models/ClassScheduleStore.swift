import Foundation
import SwiftUI

// MARK: - 全校班级课表：布局与数据（节次分组可增删，支持多班级切换）

/// 默认布局：上午(1-4) / 下午(5-9) / 晚自习(晚1-晚4)
struct ClassGroup: Codable, Equatable {
    var title: String
    var periods: [String]
}

enum ClassLayout {
    static let defaultGroups: [ClassGroup] = [
        ClassGroup(title: "上午", periods: ["一", "二", "三", "四"]),
        ClassGroup(title: "下午", periods: ["五", "六", "七", "八", "九"]),
        ClassGroup(title: "晚自习", periods: ["晚1", "晚2", "晚3", "晚4"]),
    ]
    static let days = ["星期1", "星期2", "星期3", "星期4", "星期5", "周日"]

    /// 去掉换行/空格/HTML 实体：xlsx 里「星期」常写成竖排（星␊␊期␊␊一）
    static func compact(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&#10;", with: "")
           .replacingOccurrences(of: "&#13;", with: "")
           .replacingOccurrences(of: "&#9;", with: "")
           .replacingOccurrences(of: "\r", with: "")
           .replacingOccurrences(of: "\n", with: "")
           .replacingOccurrences(of: "\t", with: "")
           .replacingOccurrences(of: " ", with: "")
           .replacingOccurrences(of: "　", with: "")   // 全角空格
    }

    /// 文件里的节次标签 → 应用内标签（1..9 → 一..九；晚1..晚4 原样）
    static func periodLabel(from raw: String) -> String {
        let s = compact(raw)
        switch s {
        case "1": return "一"
        case "2": return "二"
        case "3": return "三"
        case "4": return "四"
        case "5": return "五"
        case "6": return "六"
        case "7": return "七"
        case "8": return "八"
        case "9": return "九"
        default:  return s
        }
    }

    /// 应用内节次标签 → 文件标签（一..九 → 1..9）
    static func fileLabel(from label: String) -> String {
        switch label {
        case "一": return "1"
        case "二": return "2"
        case "三": return "3"
        case "四": return "4"
        case "五": return "5"
        case "六": return "6"
        case "七": return "7"
        case "八": return "8"
        case "九": return "9"
        default:  return label
        }
    }

    /// 导出用的星期名（与列下标对应：0~4 = 周一~周五，5 = 周日）
    static let dayNames = ["星期一", "星期二", "星期三", "星期四", "星期五", "星期日"]

    /// 文件里的星期标签 → 列下标（周六返回 nil，表里没有周六列）
    static func dayIndex(from raw: String) -> Int? {
        let s = compact(raw)
        switch s {
        case "星期一", "周一", "礼拜一": return 0
        case "星期二", "周二", "礼拜二": return 1
        case "星期三", "周三", "礼拜三": return 2
        case "星期四", "周四", "礼拜四": return 3
        case "星期五", "周五", "礼拜五": return 4
        case "星期六", "周六", "礼拜六": return nil
        case "星期日", "星期天", "周日", "周天", "礼拜日": return 5
        default: return nil
        }
    }
}

/// 单个班级的课表数据
struct ClassData: Codable {
    var groups: [ClassGroup]
    var cells: [String: [String]]
}

/// 落盘结构：全部班级 + 默认班级
struct ClassBankData: Codable {
    var classes: [String]
    var defaultClass: String
    var bank: [String: ClassData]
}

// MARK: - 全校班级课表数据（当前班级用 groups/cells 暴露给视图，切班时自动存取）
final class ClassScheduleStore: ObservableObject {
    static let shared = ClassScheduleStore()

    /// 全部班级名（按导入顺序）
    @Published private(set) var classes: [String] = []
    /// 默认班级：App 打开时显示它
    @Published private(set) var defaultClass: String = ""
    /// 当前正在查看的班级
    @Published private(set) var current: String = ""

    /// 当前班级的分组 / 单元格（视图直接读它俩）
    @Published var groups: [ClassGroup] {
        didSet { scheduleSave() }
    }
    @Published var cells: [String: [String]] {
        didSet { scheduleSave() }
    }

    /// 所有班级的数据（不进视图，避免整表重绘）
    private var bank: [String: ClassData] = [:]

    private let saver = Debouncer()
    /// 正在切换班级 / 批量替换数据时为 true，屏蔽中途落盘
    private var loading = false

    init() {
        if let d = Self.loadBank() {
            classes = d.classes
            defaultClass = d.defaultClass
            bank = d.bank
            let pick: String = {
                if !d.defaultClass.isEmpty, d.bank[d.defaultClass] != nil { return d.defaultClass }
                return d.classes.first ?? ""
            }()
            let cd = d.bank[pick]
            current = pick
            groups = cd?.groups ?? ClassLayout.defaultGroups
            cells = cd?.cells ?? Self.emptyCells(for: ClassLayout.defaultGroups)
        } else if let legacy = Self.loadLegacy() {
            // 老版本只有一个班级（class7.json）→ 迁移成一个班
            let name = "7班"
            classes = [name]
            defaultClass = name
            current = name
            bank = [name: legacy]
            groups = legacy.groups
            cells = legacy.cells
            save()
        } else {
            classes = []
            defaultClass = ""
            current = ""
            groups = ClassLayout.defaultGroups
            cells = Self.emptyCells(for: ClassLayout.defaultGroups)
        }
    }

    // MARK: - 班级切换 / 管理

    /// 切换当前班级
    func select(_ name: String) {
        guard name != current, bank[name] != nil || classes.contains(name) else { return }
        flushCurrent()
        applyCurrent(name)
        save()
    }

    /// 设为默认班级（下次打开 App 直接显示它）
    func setDefault(_ name: String? = nil) {
        let n = (name ?? current).trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        defaultClass = n
        save()
    }

    /// 新建一个空班级并切换过去
    @discardableResult
    func newClass(named raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "新班级" }
        if bank[name] != nil {
            var i = 2
            while bank["\(name)\(i)"] != nil { i += 1 }
            name = "\(name)\(i)"
        }
        flushCurrent()
        bank[name] = ClassData(groups: ClassLayout.defaultGroups,
                               cells: Self.emptyCells(for: ClassLayout.defaultGroups))
        classes.append(name)
        if defaultClass.isEmpty { defaultClass = name }
        applyCurrent(name)
        save()
        return name
    }

    /// 删除当前班级
    func removeCurrent() {
        let name = current
        guard !name.isEmpty, classes.count >= 1 else { return }
        let snapClasses = classes, snapDefault = defaultClass, snapBank = bank, snapCurrent = current
        bank.removeValue(forKey: name)
        classes.removeAll { $0 == name }
        if defaultClass == name { defaultClass = classes.first ?? "" }
        let next = classes.first ?? ""
        applyCurrent(next)
        save()
        UndoService.shared.register("删除班级「\(name)」") { [weak self] in
            guard let self else { return }
            self.classes = snapClasses
            self.defaultClass = snapDefault
            self.bank = snapBank
            self.applyCurrent(snapCurrent)
            self.save()
        }
    }

    /// 批量替换全部班级（导入全校课表时用）
    func replaceAll(_ entries: [(name: String, data: ClassData)], selectClass: String? = nil) {
        var map: [String: ClassData] = [:]
        var order: [String] = []
        for (rawName, data) in entries {
            let n = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !n.isEmpty else { continue }
            if map[n] == nil { order.append(n) }
            map[n] = data
        }
        guard !order.isEmpty else { return }

        let snapClasses = classes, snapDefault = defaultClass, snapBank = bank, snapCurrent = current
        let pick: String = {
            if let s = selectClass, map[s] != nil { return s }
            if !defaultClass.isEmpty, map[defaultClass] != nil { return defaultClass }
            return order.first!
        }()

        bank = map
        classes = order
        defaultClass = pick
        applyCurrent(pick)
        save()

        UndoService.shared.register("导入全校班级课表") { [weak self] in
            guard let self else { return }
            self.classes = snapClasses
            self.defaultClass = snapDefault
            self.bank = snapBank
            self.applyCurrent(snapCurrent)
            self.save()
        }
    }

    /// 若还没有任何班级，自动建一个（保证直接输入也能用）
    @discardableResult
    func ensureClass() -> String {
        if current.isEmpty { return newClass(named: "班级1") }
        return current
    }

    // MARK: - 内部：当前班级存取

    private func flushCurrent() {
        guard !current.isEmpty, !loading else { return }
        bank[current] = ClassData(groups: groups, cells: cells)
    }

    private func applyCurrent(_ name: String) {
        loading = true
        let d = bank[name] ?? ClassData(groups: ClassLayout.defaultGroups,
                                        cells: Self.emptyCells(for: ClassLayout.defaultGroups))
        groups = d.groups
        cells = d.cells
        current = name
        loading = false
    }

    // MARK: - 单元格

    static func emptyCells(for groups: [ClassGroup]) -> [String: [String]] {
        var d: [String: [String]] = [:]
        for p in groups.flatMap({ $0.periods }) {
            d[p] = Array(repeating: "", count: ClassLayout.days.count)
        }
        return d
    }

    /// 全部节次（按分组顺序）
    var orderedPeriods: [String] {
        groups.flatMap { $0.periods }
    }

    func cell(_ period: String, _ day: Int) -> String {
        cells[period]?[day] ?? ""
    }

    func setCell(_ period: String, _ day: Int, _ value: String) {
        ensureClass()
        if cells[period] == nil {
            cells[period] = Array(repeating: "", count: ClassLayout.days.count)
        }
        cells[period]?[day] = value
    }

    /// 导出全校：行=节次、列=班级、按星期分块（与「定稿」文件同构，可再导回）
    func wholeSchoolRows() -> [[String]] {
        flushCurrent()
        let names = classes
        let periods = orderedPeriods
        var rows: [[String]] = [["星期", "节次"] + names]
        for (dIdx, dayName) in ClassLayout.dayNames.enumerated() {
            for (pIdx, p) in periods.enumerated() {
                var row: [String] = [pIdx == 0 ? dayName : "", ClassLayout.fileLabel(from: p)]
                for n in names {
                    let arr = bank[n]?.cells[p] ?? []
                    row.append(dIdx < arr.count ? arr[dIdx] : "")
                }
                rows.append(row)
            }
        }
        return rows
    }

    // MARK: 节次增删
    /// 在某分组末尾添加节次（自动生成不重复标签）
    func addPeriod(in groupIndex: Int) {
        guard groups.indices.contains(groupIndex) else { return }
        ensureClass()
        var n = orderedPeriods.count
        var label = "节次\(n)"
        while orderedPeriods.contains(label) {
            n += 1
            label = "节次\(n)"
        }
        groups[groupIndex].periods.append(label)
        cells[label] = Array(repeating: "", count: ClassLayout.days.count)
    }

    /// 删除节次（连同其课表内容）
    func removePeriod(_ label: String) {
        guard orderedPeriods.count > 1 else { return }
        let snapGroups = groups, snapCells = cells
        for i in groups.indices {
            groups[i].periods.removeAll { $0 == label }
        }
        cells.removeValue(forKey: label)
        UndoService.shared.register("删除节次「\(label)」") { [weak self] in
            guard let self else { return }
            self.groups = snapGroups
            self.cells = snapCells
            self.save()
        }
    }

    func clear() {
        let snapGroups = groups, snapCells = cells
        groups = ClassLayout.defaultGroups
        cells = Self.emptyCells(for: groups)
        save()
        UndoService.shared.register("重置班级课表") { [weak self] in
            guard let self else { return }
            self.groups = snapGroups
            self.cells = snapCells
            self.save()
        }
    }

    // MARK: - 持久化（输入去抖）
    func scheduleSave() {
        guard !loading else { return }
        saver.schedule { self.save() }
    }

    func save() {
        flushCurrent()
        do {
            let url = Self.fileURL()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let payload = ClassBankData(classes: classes, defaultClass: defaultClass, bank: bank)
            let data = try JSONEncoder().encode(payload)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[ScheduleBar] 班级课表保存失败: \(error)")
        }
    }

    /// 新格式：classes.json（多班级）
    static func loadBank() -> ClassBankData? {
        let url = fileURL()
        guard let raw = try? Data(contentsOf: url),
              let d = try? JSONDecoder().decode(ClassBankData.self, from: raw) else { return nil }
        var out = d
        var fixed: [String: ClassData] = [:]
        for (k, v) in d.bank { fixed[k] = normalize(v) }
        out.bank = fixed
        out.classes = d.classes.filter { fixed[$0] != nil }
        return out
    }

    /// 旧格式：class7.json（单班）
    static func loadLegacy() -> ClassData? {
        let url = legacyFileURL()
        guard let raw = try? Data(contentsOf: url) else { return nil }
        if let d = try? JSONDecoder().decode(ClassData.self, from: raw) {
            return normalize(d)
        }
        if let dict = try? JSONDecoder().decode([String: [String]].self, from: raw) {
            return normalize(ClassData(groups: ClassLayout.defaultGroups, cells: dict))
        }
        return nil
    }

    private static func normalize(_ d: ClassData) -> ClassData {
        var out = d
        if out.groups.isEmpty { out.groups = ClassLayout.defaultGroups }
        let n = ClassLayout.days.count
        for (k, arr) in out.cells {
            var a = arr
            if a.count < n { a.append(contentsOf: Array(repeating: "", count: n - a.count)) }
            if a.count > n { a = Array(a.prefix(n)) }
            out.cells[k] = a
        }
        // 分组里有、cells 里没有的节次补空行
        for p in out.groups.flatMap({ $0.periods }) where out.cells[p] == nil {
            out.cells[p] = Array(repeating: "", count: n)
        }
        return out
    }

    static func fileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("ScheduleBar", isDirectory: true)
                  .appendingPathComponent("classes.json")
    }

    static func legacyFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("ScheduleBar", isDirectory: true)
                  .appendingPathComponent("class7.json")
    }
}
