import Foundation
import SwiftUI

// MARK: - 教师课表（教师 × 节次 × 周一~周天）
//
// 数据形态来自学校给的「课表定稿_长表.xlsx」这类文件：
//
//     姓名      | 节次      | 周一         | 周二 | … | 周天
//     丁灵      | 第1节课   | 初一-18 数学 |      |   |
//     丁灵      | 第2节课   | 初一-18 数学 |      |   |
//     …
//
// 即「一位教师占连续若干行（一行一节课），横向 7 天」的长表。
// 导入后按教师聚合成本模块的 `TeacherBlock`（节次 × 7 天的网格），
// 便于「查询教师 → 看他这一周的课」。
//
// 持久化 teacher_schedules.json。

struct TeacherBlock: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    /// 教师姓名（原样保留；成对出现的写法如「刘娇/尹海燕」也照存，模糊查询能命中其中任一个）
    var teacher: String
    /// 节次标签，如 "第1节课"…"第13节课"（顺序即显示顺序）
    var periods: [String]
    /// periods.count 行 × days.count 列的网格，空串 = 这节课没课
    var cells: [[String]]

    /// 一周 7 天（学校表里第 7 天写作「周天」）
    static let days = ["周一", "周二", "周三", "周四", "周五", "周六", "周天"]
    /// 默认节次：第1~13节课（与学校长表一致）
    static let defaultPeriods = (1...13).map { "第\($0)节课" }

    init(id: UUID = UUID(), teacher: String,
         periods: [String] = TeacherBlock.defaultPeriods,
         cells: [[String]] = []) {
        self.id = id
        self.teacher = teacher
        self.periods = periods
        self.cells = cells
        self.normalize()
    }

    // 旧版 / 手改过的 json 容错：字段缺失、行宽不齐都不报错
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        teacher = try c.decodeIfPresent(String.self, forKey: .teacher) ?? ""
        periods = try c.decodeIfPresent([String].self, forKey: .periods) ?? TeacherBlock.defaultPeriods
        cells = try c.decodeIfPresent([[String]].self, forKey: .cells) ?? []
        normalize()
    }

    /// 把网格补齐成「periods.count × 7」，多出来的列/行截掉
    mutating func normalize() {
        if periods.isEmpty { periods = TeacherBlock.defaultPeriods }
        let n = TeacherBlock.days.count
        if cells.count < periods.count {
            cells += Array(repeating: Array(repeating: "", count: n),
                           count: periods.count - cells.count)
        } else if cells.count > periods.count {
            cells = Array(cells.prefix(periods.count))
        }
        for i in cells.indices {
            if cells[i].count < n {
                cells[i] += Array(repeating: "", count: n - cells[i].count)
            } else if cells[i].count > n {
                cells[i] = Array(cells[i].prefix(n))
            }
        }
    }

    /// 有课的节数
    var lessonCount: Int {
        cells.reduce(0) { $0 + $1.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count }
    }

    /// 名字里用 `/` 分隔的成对教师（「刘娇/尹海燕」→ ["刘娇", "尹海燕"]）
    var aliases: [String] {
        teacher.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: 单元格文本的拆分与配色

    /// 「初一-18 数学」→ (班级: "初一-18", 科目: "数学")；没有空格时整串当科目。
    static func split(_ text: String) -> (room: String, subject: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return ("", "") }
        guard let sp = t.firstIndex(where: { $0 == " " || $0 == "\u{3000}" }) else {
            return ("", t)
        }
        let room = String(t[t.startIndex..<sp]).trimmingCharacters(in: .whitespaces)
        let subject = String(t[t.index(after: sp)...]).trimmingCharacters(in: .whitespaces)
        // 「早1 数学」这类：空格后为空则整体视为班级
        if subject.isEmpty { return ("", room) }
        return (room, subject)
    }

    /// 科目配色（尽量让同科目同色，扫一眼就能看出这一周是什么分布）。
    /// 返回 nil = 用默认灰。顺序有意义：先匹配更具体的（「班主任」不该命中「任」）。
    static func subjectColor(_ subject: String) -> Color? {
        let table: [(String, UInt32)] = [
            ("晚自习", 0x95A5A6), ("班主任", 0x2C3E50), ("班会", 0x34495E),
            ("语文", 0xE74C3C), ("数学", 0x3498DB), ("英语", 0x9B59B6),
            ("物理", 0x16A085), ("化学", 0xE67E22), ("生物", 0x27AE60),
            ("政治", 0xC0392B), ("历史", 0x8E44AD), ("地理", 0x2980B9),
            ("体育", 0xF39C12), ("音乐", 0xD35400), ("美术", 0x1ABC9C),
            ("信息", 0x7F8C8D), ("心理", 0xE84393),
            // 学校表里的简写：「心/班」「化单/物双」等
            ("心", 0xE84393), ("班", 0x34495E),
        ]
        let s = subject.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        for (key, hex) in table where s.contains(key) {
            return Color(hex: hex)
        }
        return nil
    }
}

final class TeacherScheduleStore: ObservableObject {
    static let shared = TeacherScheduleStore()

    @Published var teachers: [TeacherBlock] {
        didSet { scheduleSave() }
    }

    init() {
        teachers = TeacherScheduleStore.load() ?? []
        isInitializing = false   // 装载结束，之后的改动才算用户编辑
    }

    // MARK: 查询（模糊：包含即命中）

    /// 姓名包含关键字即命中（忽略首尾空白）。
    /// 关键字为空 → 返回全部教师；「刘娇/尹海燕」这类成对写法，输入其中任一个都能命中。
    /// 结果一律按姓名升序（中文按拼音）—— 下拉单选与标签区共用同一顺序，找人不费眼。
    func search(_ keyword: String) -> [TeacherBlock] {
        let k = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let hits: [TeacherBlock]
        if k.isEmpty {
            hits = teachers
        } else {
            hits = teachers.filter { block in
                block.teacher.localizedCaseInsensitiveContains(k)
                    || block.aliases.contains { $0.localizedCaseInsensitiveContains(k) }
            }
        }
        return hits.sorted { TeacherScheduleStore.nameAscending($0.teacher, $1.teacher) }
    }

    /// 全部教师，按姓名升序（下拉列表用）
    var sortedByName: [TeacherBlock] {
        teachers.sorted { TeacherScheduleStore.nameAscending($0.teacher, $1.teacher) }
    }

    /// 姓名比较：中文按拼音（localizedStandardCompare），同名前缀短的在先
    static func nameAscending(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }

    func index(of id: UUID) -> Int? {
        teachers.firstIndex(where: { $0.id == id })
    }

    func teacher(_ id: UUID) -> TeacherBlock? {
        index(of: id).map { teachers[$0] }
    }

    /// 按姓名精确取（导入去重时用）
    func index(ofName name: String) -> Int? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return teachers.firstIndex(where: {
            $0.teacher.trimmingCharacters(in: .whitespacesAndNewlines) == n
        })
    }

    // MARK: 统计

    var teacherCount: Int { teachers.count }
    var lessonCount: Int { teachers.reduce(0) { $0 + $1.lessonCount } }

    // MARK: 编辑（全部登记撤销）

    /// 改一个格子（空串 = 清空这节课）
    func setCell(blockID: UUID, row: Int, col: Int, text: String) {
        guard let i = index(of: blockID),
              teachers[i].cells.indices.contains(row),
              teachers[i].cells[row].indices.contains(col) else { return }
        let old = teachers[i].cells[row][col]
        guard old != text else { return }
        // ⚠️ 快照必须在**改动之前**取：取成改后状态的话，撤销等于把新值再写一遍（退不回去）。
        let snapshot = teachers
        teachers[i].cells[row][col] = text
        UndoService.shared.register("编辑「\(teachers[i].teacher)」的课表") { [weak self] in
            self?.teachers = snapshot
        }
    }

    /// 新增一位教师（默认 13 节空表）
    func addTeacher(named name: String = "新教师") {
        var title = name
        var n = 2
        while index(ofName: title) != nil {          // 重名自动加序号
            title = "\(name)\(n)"
            n += 1
            if n > 99 { break }
        }
        let snapshot = teachers
        teachers.append(TeacherBlock(teacher: title))
        UndoService.shared.register("新建教师「\(title)」") { [weak self] in
            self?.teachers = snapshot
        }
    }

    func removeTeacher(_ id: UUID) {
        guard let i = index(of: id) else { return }
        let snapshot = teachers
        let name = teachers[i].teacher
        teachers.remove(at: i)
        UndoService.shared.register("删除教师「\(name)」") { [weak self] in
            self?.teachers = snapshot
        }
    }

    func renameTeacher(_ id: UUID, to name: String) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let i = index(of: id), teachers[i].teacher != t else { return }
        let snapshot = teachers
        let old = teachers[i].teacher
        teachers[i].teacher = t
        UndoService.shared.register("「\(old)」改名为「\(t)」") { [weak self] in
            self?.teachers = snapshot
        }
    }

    /// 导入 / 整体替换（撤销由调用方登记，便于把「导入」和「撤销」做成一次完整动作）
    func replaceAll(_ blocks: [TeacherBlock]) {
        teachers = blocks.map {
            var b = $0
            b.normalize()
            return b
        }
    }

    // MARK: 持久化（输入去抖 + 统一保存）
    /// 装载/规范化期间为 true —— 此时对属性的赋值不是「用户编辑」，不该让保存按钮亮起来。
    /// ⚠️ `@Published` 属性的 `didSet` 在 `init` 里**也会触发**，所以必须有这道闸门。
    private var isInitializing = true

    /// 用户编辑 → 只标脏；真正的落盘由 SaveHub 统一负责
    /// （点「保存」/ ⌘S / 停手 8 秒 / 收起面板 / 退出前）。
    func scheduleSave() {
        guard !isInitializing else { return }
        SaveHub.shared.markDirty("他人课表")
    }

    func save() {
        do {
            let url = Self.fileURL()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(teachers)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[ScheduleBar] 教师课表保存失败: \(error)")
        }
    }

    static func load() -> [TeacherBlock]? {
        guard let raw = try? Data(contentsOf: fileURL()) else { return nil }
        guard var list = try? JSONDecoder().decode([TeacherBlock].self, from: raw) else { return nil }
        for i in list.indices { list[i].normalize() }
        return list
    }

    static func fileURL() -> URL {
        // 统一走 AppPaths（自检可重定向到临时目录，绝不触碰真实数据）
        AppPaths.file("teacher_schedules.json")
    }
}
