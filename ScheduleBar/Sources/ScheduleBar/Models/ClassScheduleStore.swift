import Foundation
import SwiftUI

// MARK: - 全校班级课表：布局与数据（节次分组可增删，支持多班级切换）

/// 默认布局：上午 5 节 / 下午 4 节 / 晚自习 4 节
struct ClassGroup: Codable, Equatable {
    var title: String
    var periods: [String]
}

enum ClassLayout {
    /// 上午节数（默认 5 节）
    static let morningCount = 5
    /// 下午节数（默认 4 节）
    static let afternoonCount = 4
    /// 白天（上午+下午）总节数；晚自习的序号从这里往后顺延
    static var dayPeriodCount: Int { morningCount + afternoonCount }

    /// 默认布局：全表连续编号「第1节…第13节」（晚自习 = 第10~13节）
    static let defaultGroups: [ClassGroup] = [
        ClassGroup(title: "上午", periods: ["第1节", "第2节", "第3节", "第4节", "第5节"]),
        ClassGroup(title: "下午", periods: ["第6节", "第7节", "第8节", "第9节"]),
        ClassGroup(title: "晚自习", periods: ["第10节", "第11节", "第12节", "第13节"]),
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

    // MARK: 节次标签识别（统一「第N节」体系）

    /// "第3节" → 3；不匹配返回 nil
    static func numberedValue(_ s: String) -> Int? {
        guard s.hasPrefix("第"), s.hasSuffix("节"), s.count > 2 else { return nil }
        let mid = String(s.dropFirst().dropLast())
        return mid.allSatisfy { $0.isNumber } ? Int(mid) : nil
    }

    /// "晚1"/"晚12" → 1/12；"晚自习" 等含汉字的返回 nil
    static func eveningValue(_ s: String) -> Int? {
        guard s.hasPrefix("晚"), s.count > 1 else { return nil }
        let tail = String(s.dropFirst())
        return tail.allSatisfy { $0.isNumber } ? Int(tail) : nil
    }

    /// 中文数字 → 阿拉伯数字（一…十）
    static func chineseNumber(_ s: String) -> Int? {
        ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
         "六": 6, "七": 7, "八": 8, "九": 9, "十": 10][s]
    }

    /// 文件/历史里的节次标签 → 全表连续序号（1-based）；认不出返回 nil
    /// 支持："第5节" / "5" / "五" / "晚1"（晚自习按白天节数顺延）
    static func periodOrdinal(_ raw: String, dayPeriods: Int = ClassLayout.dayPeriodCount) -> Int? {
        let s = compact(raw)
        if let n = numberedValue(s) { return n }
        if !s.isEmpty, s.allSatisfy({ $0.isNumber }), let n = Int(s) { return n }
        if let n = chineseNumber(s) { return n }
        if let n = eveningValue(s) { return dayPeriods + n }
        return nil
    }

    /// 文件里的节次标签 → 应用内节次标签（统一「第N节」）
    static func periodLabel(from raw: String) -> String {
        let s = compact(raw)
        if numberedValue(s) != nil { return s }
        if let n = periodOrdinal(s) { return "第\(n)节" }
        return s
    }

    /// 应用内节次标签 → 文件标签（「第N节」→ N，与学校定稿文件一致）
    static func fileLabel(from label: String) -> String {
        if let n = numberedValue(label) { return "\(n)" }
        return label
    }

    /// 统一节次：把历史命名（一 / 1 / 晚1 …）规整为「全表连续 第1节…第N节」，并同步迁移 cells 内容。
    /// · 已是「第N节」体系（含 placeholders）：保持分组结构，仅按显示顺序重新编号（压平跳号/重号）
    /// · 历史命名：按 上午5节 / 下午其余白天 / 晚自习 重新分组后再编号
    static func canonicalize(groups: [ClassGroup],
                             cells: [String: [String]],
                             placeholders: Set<String> = [])
        -> (groups: [ClassGroup], cells: [String: [String]]) {

        let all = groups.flatMap { $0.periods }
        guard !all.isEmpty else {
            var d: [String: [String]] = [:]
            for p in defaultGroups.flatMap({ $0.periods }) {
                d[p] = Array(repeating: "", count: days.count)
            }
            return (defaultGroups, d)
        }

        let alreadyNumbered = all.allSatisfy { numberedValue($0) != nil || placeholders.contains($0) }
        var newGroups: [ClassGroup]

        if alreadyNumbered {
            newGroups = groups.filter { !$0.periods.isEmpty }
        } else {
            // 按原分组标题归类（历史数据的 上午/下午/晚自习）
            func periods(of title: String) -> [String] {
                groups.first(where: { $0.title.contains(title) })?.periods ?? []
            }
            var am = periods(of: "上午")
            var pm = periods(of: "下午")
            var eve = groups.filter { $0.title.contains("晚") }.flatMap { $0.periods }
            var rest = groups.filter {
                !$0.title.contains("上午") && !$0.title.contains("下午") && !$0.title.contains("晚")
            }.flatMap { $0.periods }

            // 没有分组信息的老数据：按顺序前 5 节为上午
            if am.isEmpty && pm.isEmpty {
                let day = rest
                rest = []
                am = Array(day.prefix(morningCount))
                pm = Array(day.dropFirst(morningCount))
            }
            // 上午不足默认节数 → 从下午开头补足（例如旧默认 上午4/下午5 → 上午5/下午4）
            if am.count < morningCount && !pm.isEmpty {
                let need = min(morningCount - am.count, pm.count)
                am.append(contentsOf: pm.prefix(need))
                pm.removeFirst(need)
            }
            // 兜底：白天里以「晚X」命名的也归晚自习
            let stray = am.filter { eveningValue($0) != nil } + pm.filter { eveningValue($0) != nil }
            if !stray.isEmpty {
                am.removeAll { eveningValue($0) != nil }
                pm.removeAll { eveningValue($0) != nil }
                eve.insert(contentsOf: stray, at: 0)
            }
            pm.append(contentsOf: rest)

            var gs: [ClassGroup] = []
            if !am.isEmpty { gs.append(ClassGroup(title: "上午", periods: am)) }
            if !pm.isEmpty { gs.append(ClassGroup(title: "下午", periods: pm)) }
            if !eve.isEmpty { gs.append(ClassGroup(title: "晚自习", periods: eve)) }
            newGroups = gs.isEmpty ? defaultGroups : gs
        }

        // 重新编号（第1节…第N节）并迁移单元格内容
        var newCells: [String: [String]] = [:]
        var usedOld = Set<String>()
        var n = 0
        for i in newGroups.indices {
            for j in newGroups[i].periods.indices {
                let old = newGroups[i].periods[j]
                n += 1
                let label = "第\(n)节"
                newGroups[i].periods[j] = label
                if usedOld.contains(old) {
                    newCells[label] = Array(repeating: "", count: days.count)
                } else {
                    usedOld.insert(old)
                    newCells[label] = cells[old] ?? Array(repeating: "", count: days.count)
                }
            }
        }
        return (newGroups, newCells)
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
            // 迁移：历史节次命名（一/五/晚1…）→「全表连续 第N节」，并修正 上午/下午 分组（上午 5 节）
            var migrated = false
            var fixed: [String: ClassData] = [:]
            for (k, v) in d.bank {
                let m = Self.canonicalData(v)
                if m.groups != v.groups { migrated = true }
                fixed[k] = m
            }
            bank = fixed
            let pick: String = {
                if !d.defaultClass.isEmpty, fixed[d.defaultClass] != nil { return d.defaultClass }
                return d.classes.first ?? ""
            }()
            let cd = fixed[pick]
            current = pick
            groups = cd?.groups ?? ClassLayout.defaultGroups
            cells = cd?.cells ?? Self.emptyCells(for: ClassLayout.defaultGroups)
            if migrated { save() }   // 迁移结果立即落盘
        } else if let legacy = Self.loadLegacy() {
            // 老版本只有一个班级（class7.json）→ 迁移成一个班
            let name = "7班"
            let m = Self.canonicalData(legacy)
            classes = [name]
            defaultClass = name
            current = name
            bank = [name: m]
            groups = m.groups
            cells = m.cells
            save()
        } else {
            classes = []
            defaultClass = ""
            current = ""
            groups = ClassLayout.defaultGroups
            cells = Self.emptyCells(for: ClassLayout.defaultGroups)
        }
    }

    /// 把一份班级数据规整成标准节次体系（历史命名 → 第1节…第N节）
    static func canonicalData(_ d: ClassData) -> ClassData {
        let r = ClassLayout.canonicalize(groups: d.groups, cells: d.cells)
        return ClassData(groups: r.groups, cells: r.cells)
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
            map[n] = Self.canonicalData(data)   // 导入即规整为「第1节…第N节」
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
        // 班级课表的每次编辑都立即写入当前班级数据，避免切换班级或退出前丢失。
        save()
    }

    // MARK: - 单元格拖动对换（当前班级内）

    /// 拖动中的单元格来源（普通 var，不进 @Published：拖动过程中不刷新视图）
    var cellDragSource: ScheduleCellID?
    private var cellDragSnapshot: [String: [String]]?

    func beginCellDrag(_ period: String, _ day: Int) {
        guard let row = cells[period], row.indices.contains(day) else { return }
        cellDragSnapshot = cells
        cellDragSource = ScheduleCellID(period: period, day: day)
    }

    /// 把拖动来源格与目标格的课表内容对换
    func swapCellTo(_ period: String, _ day: Int) {
        guard let src = cellDragSource,
              !(src.period == period && src.day == day),
              var srcRow = cells[src.period], var dstRow = cells[period],
              srcRow.indices.contains(src.day), dstRow.indices.contains(day) else { return }
        if src.period == period {
            // ⚠️ 同一节次（同一行内不同星期）必须就地 swapAt：
            //    若沿用下面「两份拷贝互写再分别写回」的写法，两次赋值会落到同一个
            //    cells key 上，后一次把前一次覆盖，表现为「同排拖动变成覆盖而非对调」。
            srcRow.swapAt(src.day, day)
            cells[period] = srcRow
        } else {
            let tmp = srcRow[src.day]
            srcRow[src.day] = dstRow[day]
            dstRow[day] = tmp
            cells[src.period] = srcRow
            cells[period] = dstRow
        }
        // 交换后立即落盘：拖拽结束前即使窗口被关闭，也不会丢失位置调整。
        save()
        // 来源位置跟着被拖动的内容走，避免 dropEntered 连续触发时来回抖动
        cellDragSource = ScheduleCellID(period: period, day: day)
    }

    func finishCellDrag() {
        defer { cellDragSource = nil; cellDragSnapshot = nil }
        guard let snap = cellDragSnapshot, snap != cells else { return }
        UndoService.shared.register("调整课表位置") { [weak self] in
            guard let self else { return }
            self.cells = snap
            self.save()
        }
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
    /// 在某分组末尾添加节次：先占位，再统一重编号（全表连续「第1节…第N节」）
    func addPeriod(in groupIndex: Int) {
        guard groups.indices.contains(groupIndex) else { return }
        ensureClass()
        let snapGroups = groups, snapCells = cells
        let placeholder = "＿新节＿"
        var gs = groups
        gs[groupIndex].periods.append(placeholder)
        var cs = cells
        cs[placeholder] = Array(repeating: "", count: ClassLayout.days.count)

        let r = ClassLayout.canonicalize(groups: gs, cells: cs, placeholders: [placeholder])
        groups = r.groups
        cells = r.cells

        UndoService.shared.register("添加节次") { [weak self] in
            guard let self else { return }
            self.groups = snapGroups
            self.cells = snapCells
            self.save()
        }
    }

    /// 删除节次（连同其课表内容），随后统一重编号
    func removePeriod(_ label: String) {
        guard orderedPeriods.count > 1 else { return }
        let snapGroups = groups, snapCells = cells
        var gs = groups
        for i in gs.indices { gs[i].periods.removeAll { $0 == label } }
        var cs = cells
        cs.removeValue(forKey: label)

        let r = ClassLayout.canonicalize(groups: gs, cells: cs)
        groups = r.groups
        cells = r.cells

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

    /// 清空全部班级课表数据：所有班级与课表内容一并删除，仅保留「第1节…第N节 × 星期」的空表结构。
    func clearAllData() {
        loading = true
        classes = []
        defaultClass = ""
        current = ""
        bank = [:]
        groups = ClassLayout.defaultGroups
        cells = Self.emptyCells(for: ClassLayout.defaultGroups)
        loading = false
        save()
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
