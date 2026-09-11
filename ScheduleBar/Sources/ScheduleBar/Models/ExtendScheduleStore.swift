import Foundation
import SwiftUI

// MARK: - 延时 & 监考 卡片（行式表格：周次/班级/节次/姓名/科目）

/// 单个子表（如 周二延时）：分组 + 标题 + 表头 + 数据行
/// kind 是稳定分组标记（"delay"=延时 / "exam"=监考）：标题可随意改名，分组不受影响
struct ExtendBlock: Identifiable, Codable {
    let id: UUID
    var title: String
    var kind: String?      // 旧数据无此字段 → 加载时按标题迁移
    var header: [String]
    var rows: [[String]]

    init(id: UUID = UUID(), title: String, kind: String? = nil,
         header: [String], rows: [[String]]) {
        self.id = id
        self.title = title
        self.kind = kind
        self.header = header
        self.rows = rows
    }

    /// 旧数据迁移：无 kind 时按标题判断（含「监考」→ exam，否则 delay）
    func withMigratedKind() -> ExtendBlock {
        var b = self
        if b.kind == nil {
            b.kind = b.title.contains("监考") ? "exam" : "delay"
        }
        return b
    }
}

/// 延时列主题色：按列位置取色（改名后颜色依然稳定）
let extendDelayPalette: [Color] = [
    Color(hex: 0x2FA37C),   // 绿（原周二）
    Color(hex: 0x3498DB),   // 蓝（原周四）
    Color(hex: 0x9B59B6),   // 紫（原周五）
    Color(hex: 0x16A085),   // 青
    Color(hex: 0xE67E22),   // 橙
    Color(hex: 0x2980B9),   // 钢蓝
]
/// 监考块主题色（橙）
let extendExamAccent: Color = Color(hex: 0xE67E22)

/// 延时 & 监考 数据（一个卡片里的多个子表）
final class ExtendScheduleStore: ObservableObject {
    static let shared = ExtendScheduleStore()

    @Published var blocks: [ExtendBlock]

    init() {
        // 加载已保存数据；没有则用默认示例。随后剔除「空周次」占位行，并为旧数据补 kind 分组标记
        self.blocks = (ExtendScheduleStore.load() ?? ExtendScheduleStore.resolveDefaultBlocks())
            .map { $0.withMigratedKind().removingEmptyRows() }
    }

    /// 清空全部延时&监考子表：保留「周二延时 / 周四延时 / 周五延时 / 周日监考」
    /// 四张面板骨架（表头保留），行内容全部清空，便于他人直接双击填写。
    func clearAll() {
        let snap = blocks
        blocks = ExtendScheduleStore.defaultBlocks()
        save()
        UndoService.shared.register("清空延时&监考数据") { [weak self] in
            guard let self else { return }
            self.blocks = snap
            self.save()
        }
    }

    func save() {
        do {
            let url = Self.fileURL()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(blocks)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[ScheduleBar] 延时/监考保存失败: \(error)")
        }
    }

    static func load() -> [ExtendBlock]? {
        let url = fileURL()
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([ExtendBlock].self, from: data)
    }

    static func fileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("ScheduleBar", isDirectory: true)
                  .appendingPathComponent("extend.json")
    }

    // MARK: - 预填示例开关（默认关闭，发布给其他人时不应预填真实数据）
    // true = 沿用旧的「周二延时/周四延时/周五延时/周日监考」4 张示例表
    // false = 仍保留这 4 张空骨架（标题+表头，行数为 0），便于对方双击编辑填写
    static let includeSampleData: Bool = false

    /// 发布版默认：4 张空骨架（标题+表头，0 行）；本地已有 extend.json 的仍以本地为准
    static func defaultBlocks() -> [ExtendBlock] {
        let delayHeader = ["第几周", "班级", "节次"]
        let 监考Header = ["第几周", "班级", "考试科目", "姓名"]
        return [
            ExtendBlock(title: "周二延时", kind: "delay", header: delayHeader, rows: []),
            ExtendBlock(title: "周四延时", kind: "delay", header: delayHeader, rows: []),
            ExtendBlock(title: "周五延时", kind: "delay", header: delayHeader, rows: []),
            ExtendBlock(title: "周日监考", kind: "exam", header: 监考Header, rows: []),
        ]
    }

    // 开发期：true 时恢复 4 张示例数据（含真实姓名）
    static func sampleBlocks() -> [ExtendBlock] {
        let delayHeader = ["第几周", "班级", "节次"]
        let 监考Header = ["第几周", "班级", "考试科目", "姓名"]

        let 延时周二 = ExtendBlock(title: "周二延时", kind: "delay", header: delayHeader, rows: [
            ["1", "7", "8节"], ["1", "8", "9节"],
            ["3", "8", "8节"], ["7", "7", "9节"],
            ["8", "7", "8节"], ["8", "7", "9节"],
            ["9", "7", "9节"], ["10", "8", "8节"],
            ["11", "7", "8节"], ["14", "8", "9节"],
            ["18", "7", "9节"], ["20", "8", "8节"],
        ])

        let 延时周四 = ExtendBlock(title: "周四延时", kind: "delay", header: delayHeader, rows: [
            ["1", "8", ""], ["2", "7", ""],
            ["6", "7", ""], ["7", "8", ""],
            ["8", "7", ""], ["13", "8", ""],
            ["15", "8", ""], ["19", "8", ""],
            ["20", "7", ""],
        ])

        let 延时周五 = ExtendBlock(title: "周五延时", kind: "delay", header: delayHeader, rows: [
            ["1", "7", ""], ["3", "8", ""],
            ["6", "7", ""], ["14", "7", ""],
            ["15", "7", ""], ["17", "7", ""],
            ["19", "8", ""],
        ])

        let 监考 = ExtendBlock(title: "周日监考", kind: "exam", header: 监考Header, rows: [
            ["1", "4", "数学", "林科"], ["7", "4", "数学", "林科"],
            ["9", "4", "语文+历史", "林科"], ["11", "4", "数学", "林科"],
        ])

        return [延时周二, 延时周四, 延时周五, 监考]
    }

    // dev 入口：本机调试若需要示例数据，改 includeSampleData = true
    private static func resolveDefaultBlocks() -> [ExtendBlock] {
        includeSampleData ? sampleBlocks() : defaultBlocks()
    }
}

// MARK: - 空周次清洗
extension ExtendBlock {
    /// 剔除「空周次」行：除第 1 列（周次）之外全部为空格 → 视为该周没有安排，删除。
    /// 例如 ["1", "", ""] 会被删除；["1", "8", ""]（有班级、节次空）保留。
    func removingEmptyRows() -> ExtendBlock {
        var b = self
        b.rows = b.rows.filter { row in
            guard row.count > 1 else { return false }   // 只有一列（周次）且无内容 → 删
            return !row.dropFirst().allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        return b
    }
}
