import Foundation
import SwiftUI

// MARK: - 学生信息（表头动态；行可增删、单元格双击编辑；支持导入导出 xlsx）
// 持久化 students.json；无本地数据时加载 StudentDefaultData（来自「学生信息.xlsx」）。

struct StudentRow: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var cells: [String]      // 与 store.headers 一一对应
}

/// 存储格式：{"headers": [...], "rows": [...]}；旧版纯 [StudentRow] 自动迁移
struct StudentData: Codable {
    var headers: [String]
    var rows: [StudentRow]
}

final class StudentStore: ObservableObject {
    static let shared = StudentStore()

    @Published var headers: [String] {
        didSet { scheduleSave() }
    }
    @Published var rows: [StudentRow] {
        didSet { scheduleSave() }
    }


    init() {
        let data = StudentStore.load()
        self.headers = data?.headers ?? StudentDefaultData.headers
        self.rows = data?.rows ?? StudentStore.defaults()
    }

    // MARK: 默认数据
    static func defaults() -> [StudentRow] {
        StudentDefaultData.rows.map { StudentRow(cells: $0) }
    }

    // MARK: 行增删
    func addRow() {
        rows.append(StudentRow(cells: Array(repeating: "", count: headers.count)))
    }
    func removeRow(_ id: UUID) {
        let snap = rows
        // 取被删行姓名用于撤销提示
        let name = rows.first(where: { $0.id == id })?.cells.first ?? ""
        rows.removeAll { $0.id == id }
        UndoService.shared.register("删除学生\(name.isEmpty ? "" : "「\(name)」")") { [weak self] in
            guard let self else { return }
            self.rows = snap
            self.scheduleSave()
        }
    }

    // MARK: 列增删 / 改名
    func addColumn() {
        var n = headers.count + 1
        var name = "列\(n)"
        while headers.contains(name) {
            n += 1
            name = "列\(n)"
        }
        headers.append(name)
        for i in rows.indices { rows[i].cells.append("") }
    }
    func removeColumn(_ index: Int) {
        guard headers.count > 1, headers.indices.contains(index),
              !isProtectedColumn(index) else { return }   // 姓名 / 身份证列禁删
        let snapHeaders = headers, snapRows = rows
        let removed = headers[index]
        headers.remove(at: index)
        for i in rows.indices where index < rows[i].cells.count {
            rows[i].cells.remove(at: index)
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

    /// 「姓名」列下标（没有则返回 nil）
    var nameColumn: Int? {
        headers.firstIndex { $0 == "姓名" }
    }

    /// 「性别」列下标
    var genderColumn: Int? {
        headers.firstIndex { $0 == "性别" }
    }

    /// 「身份证…」列下标（匹配身份证/身份证号码/身份证号 等命名）
    var idCardColumn: Int? {
        headers.firstIndex { $0.contains("身份证") }
    }

    /// 关键列（姓名 / 身份证）禁止删除，防止误操作丢失主键数据
    func isProtectedColumn(_ index: Int) -> Bool {
        guard headers.indices.contains(index) else { return false }
        let h = headers[index]
        return h == "姓名" || h.contains("身份证")
    }

    /// 按姓名（若无姓名列则按整行）模糊查询
    func filtered(keyword: String) -> [StudentRow] {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return rows }
        if let n = nameColumn {
            return rows.filter { n < $0.cells.count && $0.cells[n].localizedCaseInsensitiveContains(kw) }
        }
        return rows.filter { row in row.cells.contains { $0.localizedCaseInsensitiveContains(kw) } }
    }

    func clear() {
        let snapHeaders = headers, snapRows = rows
        headers = StudentDefaultData.headers
        rows = StudentStore.defaults()
        scheduleSave()
        UndoService.shared.register("重置学生信息") { [weak self] in
            guard let self else { return }
            self.headers = snapHeaders
            self.rows = snapRows
            self.scheduleSave()
        }
    }

    // MARK: 持久化（输入去抖）
    /// 用户编辑 → 只标脏；真正的落盘由 SaveHub 统一负责
    /// （点「保存」/ ⌘S / 停手 8 秒 / 收起面板 / 退出前）。
    func scheduleSave() {
        SaveHub.shared.markDirty("学生信息")
    }

    func save() {
        do {
            let url = Self.fileURL()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(StudentData(headers: headers, rows: rows))
            try data.write(to: url, options: .atomic)
        } catch {
            print("[ScheduleBar] 学生信息保存失败: \(error)")
        }
    }

    /// 加载并迁移：新格式 {"headers","rows"}；旧格式纯 [StudentRow]
    static func load() -> StudentData? {
        let url = fileURL()
        guard let raw = try? Data(contentsOf: url) else { return nil }
        if let d = try? JSONDecoder().decode(StudentData.self, from: raw) {
            return normalize(d)
        }
        if let rows = try? JSONDecoder().decode([StudentRow].self, from: raw) {
            return normalize(StudentData(headers: StudentDefaultData.headers, rows: rows))
        }
        return nil
    }

    /// 行单元格数与表头对齐
    private static func normalize(_ d: StudentData) -> StudentData {
        var out = d
        if out.headers.isEmpty { out.headers = StudentDefaultData.headers }
        let width = out.headers.count
        for i in out.rows.indices {
            var c = out.rows[i].cells
            if c.count < width { c.append(contentsOf: Array(repeating: "", count: width - c.count)) }
            if c.count > width { c = Array(c.prefix(width)) }
            out.rows[i].cells = c
        }
        return out
    }

    static func fileURL() -> URL {
        // 统一走 AppPaths：自检可用 SCHEDULEBAR_DATA_DIR 把数据目录重定向到
        // 临时目录 —— 所有 store 都必须支持，否则它在 init 里的迁移会写真实数据。
        AppPaths.file("students.json")
    }
}
