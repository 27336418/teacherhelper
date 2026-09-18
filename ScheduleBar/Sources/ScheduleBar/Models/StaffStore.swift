import Foundation
import SwiftUI

// MARK: - 年级师资安排（班级 × 科目矩阵；行/列可增删、单元格与表头可编辑）
// 数据来自「师资安排.xlsx」；持久化 staff.json。

struct StaffRow: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var cells: [String]     // 与 store.headers 一一对应
    /// 单元格自定义颜色："列下标" → hex（如 ["3": "E74C3C"]）；无 = 默认灰。
    /// 颜色跟着「行」走，所以排序、上下移动不会错位；删列时键会整体左移（见 removeColumn）。
    var colors: [String: String] = [:]

    init(id: UUID = UUID(), cells: [String], colors: [String: String] = [:]) {
        self.id = id
        self.cells = cells
        self.colors = colors
    }

    // 旧版 staff.json 没有 colors 字段 → 缺省为空字典（不报错、不需要数据版本号迁移）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        cells = try c.decodeIfPresent([String].self, forKey: .cells) ?? []
        colors = try c.decodeIfPresent([String: String].self, forKey: .colors) ?? [:]
    }
}

/// 存储格式：{"headers": [...], "rows": [...]}；旧版纯 [StaffRow] 自动迁移
struct StaffData: Codable {
    var headers: [String]
    var rows: [StaffRow]
}

final class StaffStore: ObservableObject {
    static let shared = StaffStore()

    static let defaultHeaders = ["班级", "班主任", "班型", "语文", "英语", "政治", "历史", "数学", "物理", "化学", "体育"]

    @Published var headers: [String] {
        didSet { scheduleSave() }
    }
    @Published var rows: [StaffRow] {
        didSet { scheduleSave() }
    }


    init() {
        let data = StaffStore.load()
        self.headers = data?.headers ?? StaffStore.defaultHeaders
        // 发布版本默认空：若开发者临时开启 `includeSampleData` 才预填示例。
        self.rows = data?.rows ?? StaffStore.resolveDefaultRows()
        isInitializing = false   // 装载结束，之后的改动才算用户编辑
    }

    // MARK: 行增删
    func addRow() {
        rows.append(StaffRow(cells: Array(repeating: "", count: headers.count)))
    }
    func removeRow(_ id: UUID) {
        let snap = rows
        let name = rows.first(where: { $0.id == id })?.cells.first ?? ""
        rows.removeAll { $0.id == id }
        UndoService.shared.register("删除班级行\(name.isEmpty ? "" : "「\(name)」")") { [weak self] in
            guard let self else { return }
            self.rows = snap
            self.scheduleSave()
        }
    }

    // MARK: 列增删
    func addColumn() {
        var n = headers.count
        var name = "科目\(n)"
        while headers.contains(name) {
            n += 1
            name = "科目\(n)"
        }
        headers.append(name)
        for i in rows.indices { rows[i].cells.append("") }
    }
    func removeColumn(_ index: Int) {
        guard headers.count > 1, index < headers.count else { return }
        let snapHeaders = headers, snapRows = rows
        let removed = headers[index]
        headers.remove(at: index)
        for i in rows.indices where index < rows[i].cells.count {
            rows[i].cells.remove(at: index)
        }
        // 颜色键跟着列下标左移：被删列的颜色丢弃，右侧各列减一
        for i in rows.indices {
            var shifted: [String: String] = [:]
            for (k, v) in rows[i].colors {
                guard let n = Int(k) else { continue }
                if n < index { shifted[k] = v }
                else if n > index { shifted["\(n - 1)"] = v }
            }
            rows[i].colors = shifted
        }
        UndoService.shared.register("删除列「\(removed)」") { [weak self] in
            guard let self else { return }
            self.headers = snapHeaders
            self.rows = snapRows
            self.scheduleSave()
        }
    }

    func renameColumn(_ index: Int, _ name: String) {
        guard headers.indices.contains(index) else { return }
        headers[index] = name
    }

    // MARK: 单元格颜色（默认灰；右键调色板）
    /// 某格的自定义颜色（未设置 = nil = 默认灰）
    func color(rowID: UUID, col: Int) -> String? {
        rows.first { $0.id == rowID }?.colors["\(col)"]
    }

    /// 设置/清除单格颜色（nil 或空串 = 恢复默认灰）
    func setColor(_ hex: String?, rowID: UUID, col: Int) {
        guard let i = rows.firstIndex(where: { $0.id == rowID }) else { return }
        let snap = rows
        applyColor(hex, index: i, col: col)
        UndoService.shared.register(hex == nil ? "清除单元格颜色" : "设置单元格颜色") { [weak self] in
            guard let self else { return }
            self.rows = snap
            self.scheduleSave()
        }
    }

    /// 把「内容等于 text 的所有格子」一起设色 —— 与单击高亮同一套分组语义
    /// （点某个姓名/班型看到的是哪些格，这里就一次改哪些格）。nil = 清除。
    func setColorForAllCells(text: String, hex: String?) {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let snap = rows
        for i in rows.indices {
            for c in rows[i].cells.indices where Self.matches(rows[i].cells[c], key) {
                applyColor(hex, index: i, col: c)
            }
        }
        UndoService.shared.register(hex == nil ? "清除「\(key)」全部颜色" : "批量设置「\(key)」颜色") { [weak self] in
            guard let self else { return }
            self.rows = snap
            self.scheduleSave()
        }
    }

    func clearAllColors() {
        guard rows.contains(where: { !$0.colors.isEmpty }) else { return }
        let snap = rows
        for i in rows.indices { rows[i].colors = [:] }
        UndoService.shared.register("清除师资整表颜色") { [weak self] in
            guard let self else { return }
            self.rows = snap
            self.scheduleSave()
        }
    }

    private func applyColor(_ hex: String?, index i: Int, col: Int) {
        let key = "\(col)"
        if let hex, !hex.isEmpty { rows[i].colors[key] = hex }
        else { rows[i].colors.removeValue(forKey: key) }
    }

    /// 忽略大小写/首尾空格的同名判定（姓名、班型共用）
    static func matches(_ cell: String, _ key: String) -> Bool {
        let t = cell.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t.localizedCaseInsensitiveCompare(key) == .orderedSame
    }

    func clear() {
        let snapHeaders = headers, snapRows = rows
        // 「清空」= 移除全部行（保留表头），便于他人直接双击编辑填写
        headers = StaffStore.defaultHeaders
        rows = []
        scheduleSave()
        UndoService.shared.register("清空师资安排") { [weak self] in
            guard let self else { return }
            self.headers = snapHeaders
            self.rows = snapRows
            self.scheduleSave()
        }
    }

    // MARK: 默认数据（已清空：发布给其他人时默认不预填任何行，仅保留表头，
    // 对方点击工具栏「加行」即可填写；本地已有 staff.json 的仍以本地为准）
    static func defaults() -> [StaffRow] { []
    }

    // 仅供开发期使用的「示例数据」开关。默认 false；true 时恢复 30 条师资示例，
    // 方便开发者本地体验，不参与发布。
    static let includeSampleData: Bool = false
    static func sampleData() -> [StaffRow] {
        let data: [[String]] = [
            ["1", "陈永珍", "联招班", "陈永珍", "毛瑶瑶", "王顺娜", "宁和平", "喻子格", "柳叶", "王路曦", "王加鹏"],
            ["2", "易海燕", "联招班", "陈永珍", "陈雯雯", "周伟", "宁和平", "易海燕", "柳叶", "曹人予", "王加鹏"],
            ["3", "谭海连", "冲刺1", "王欢欢", "官连浇", "谭超", "张钊然", "谭海连", "柳叶", "蒙真真", "熊文超"],
            ["4", "潘桃", "联招班", "王欢欢", "李增红", "余燕", "赖炳霖", "潘桃", "高兴", "于冰凌", "王加鹏"],
            ["5", "陈雯雯", "联招班", "柯娜娜", "陈雯雯", "余燕", "赖炳霖", "罗鑫", "高兴", "蒙真真", "梁雪峰"],
            ["6", "余燕", "联招班", "李炎鸿", "李圆圆", "余燕", "高筱杰", "刘庆超", "陈坤权", "罗勇", "熊文超"],
            ["7", "林科", "冲刺3", "于理想", "邓雨蒙", "余燕", "赖炳霖", "林科", "陈乐怡", "蒙真真", "王加鹏"],
            ["8", "邓雨蒙", "联招班", "刘璐", "邓雨蒙", "王顺娜", "高筱杰", "林科", "王淑慧", "李晨曦", "熊文超"],
            ["9", "罗鑫", "体育班", "赵悦婷", "蔡亚男", "周伟", "赖炳霖", "罗鑫", "鞠在东", "于冰凌", "熊文超"],
            ["10", "赵悦婷", "联招班", "赵悦婷", "官连浇", "陈婷", "张钊然", "鲍思敏", "王淑慧", "李晨曦", "吴博"],
            ["11", "李琳", "冲刺1", "李炎鸿", "李雨阳", "王顺娜", "詹道亮", "李琳", "高兴", "王雪梅", "吴博"],
            ["12", "魏静宜", "联招班", "魏静宜", "黄小桐", "范镔玲", "宁和平", "李琳", "鞠在东", "顾军", "梁雪峰"],
            ["13", "詹道亮", "冲刺1", "石玉霞", "刘莉名", "陈婷", "詹道亮", "易海燕", "陈坤权", "蒋颖", "梁雪峰"],
            ["14", "石玉霞", "联招班", "石玉霞", "蔡亚男", "张强", "高筱杰", "孙正", "陈乐怡", "顾军", "郑静洋"],
            ["15", "鲍思敏", "联招班", "骆金辉", "李圆圆", "张强", "詹道亮", "鲍思敏", "陈乐怡", "王路曦", "郑静洋"],
            ["16", "刘莉名", "联招班", "魏静宜", "刘莉名", "谭超", "詹道亮", "刘庆超", "刘东梅", "罗勇", "郑静洋"],
            ["17", "李记", "冲刺2", "刘璐", "袁欣茹", "范镔玲", "詹道亮", "李记", "王淑慧", "张苑林", "任杰"],
            ["18", "于理想", "联招班", "于理想", "李雨阳", "王顺娜", "宁和平", "李记", "刘东梅", "王雪梅", "刘露"],
            ["19", "柯娜娜", "冲刺3", "柯娜娜", "毛瑶瑶", "陈婷", "赖炳霖", "王丹虹", "鞠在东", "张苑林", "郑静洋"],
            ["20", "张静", "冲刺1", "张竞丹", "张静", "周伟", "高筱杰", "潘桃", "刘东梅", "李晨曦", "熊文超"],
            ["21", "石桃", "冲刺2", "罗宇婷", "石桃", "王顺娜", "张钊然", "孙正", "聂思源", "曹人予", "王加鹏"],
            ["22", "罗宇婷", "联招班", "罗宇婷", "石桃", "周伟", "宁和平", "李丹", "聂思源", "王雪梅", "梁雪峰"],
            ["23", "朱先明", "冲刺3", "骆金辉", "黄小桐", "张强", "高筱杰", "朱先明", "李毅", "于冰凌", "刘露"],
            ["24", "聂思源", "冲刺3", "王倩", "季富容", "张强", "张钊然", "李诗语", "聂思源", "曹人予", "梁雪峰"],
            ["25", "周伟", "冲刺3", "杜著洋", "周濛", "周伟", "刘梦涵", "喻子格", "李毅", "王路曦", "任杰"],
            ["26", "巫松", "联招班", "杜著洋", "袁欣茹", "陈婷", "刘梦涵", "谭海连", "巫松", "张苑林", "任杰"],
            ["27", "谭超", "冲刺1", "冯鑫", "陆遥", "谭超", "刘梦涵", "李丹", "巫松", "顾军", "郑静洋"],
            ["28", "陆遥", "联招班", "冯鑫", "陆遥", "谭超", "刘梦涵", "王丹虹", "李毅", "蒋颖", "任杰"],
            ["29", "张竞丹", "联招班", "张竞丹", "张静", "陈婷", "刘梦涵", "朱先明", "陈坤权", "张勇", "任杰"],
            ["30", "李诗语", "联招班", "王倩", "季富容", "谭超", "张钊然", "李诗语", "巫松", "蒋颖", "吴博"],
        ]
        return data.map { StaffRow(cells: $0) }
    }

    // dev 入口：本机调试时若需要 30 行示例数据，可改 includeSampleData = true
    private static func resolveDefaultRows() -> [StaffRow] {
        includeSampleData ? sampleData() : []
    }

    // MARK: 持久化（输入去抖）
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
        SaveHub.shared.markDirty("年级师资")
    }

    func save() {
        do {
            let url = Self.fileURL()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(StaffData(headers: headers, rows: rows))
            try data.write(to: url, options: .atomic)
        } catch {
            print("[ScheduleBar] 师资保存失败: \(error)")
        }
    }

    /// 加载并迁移：新格式 {"headers","rows"}；旧格式纯 [StaffRow]
    static func load() -> StaffData? {
        let url = fileURL()
        guard let raw = try? Data(contentsOf: url) else { return nil }

        if let d = try? JSONDecoder().decode(StaffData.self, from: raw) {
            return normalize(d)
        }
        if let rows = try? JSONDecoder().decode([StaffRow].self, from: raw) {
            return normalize(StaffData(headers: defaultHeaders, rows: rows))
        }
        return nil
    }

    /// 行单元格数与表头对齐（顺带丢弃越界的颜色键）
    private static func normalize(_ d: StaffData) -> StaffData {
        var out = d
        if out.headers.isEmpty { out.headers = defaultHeaders }
        for i in out.rows.indices {
            var c = out.rows[i].cells
            if c.count < out.headers.count {
                c.append(contentsOf: Array(repeating: "", count: out.headers.count - c.count))
            }
            if c.count > out.headers.count { c = Array(c.prefix(out.headers.count)) }
            out.rows[i].cells = c
            out.rows[i].colors = out.rows[i].colors.filter { k, _ in
                guard let n = Int(k) else { return false }
                return n >= 0 && n < out.headers.count
            }
        }
        return out
    }

    static func fileURL() -> URL {
        // 统一走 AppPaths：自检可用 SCHEDULEBAR_DATA_DIR 把数据目录重定向到
        // 临时目录 —— 所有 store 都必须支持，否则它在 init 里的迁移会写真实数据。
        AppPaths.file("staff.json")
    }
}
