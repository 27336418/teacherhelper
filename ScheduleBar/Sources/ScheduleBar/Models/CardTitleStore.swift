import Foundation
import SwiftUI

// MARK: - 卡片标题存储（个人课表 / 7班课表 / 延时&监考 三张卡可双击改名）
// 独立存于 titles.json，不改动各课表原本的 JSON 结构，避免迁移兼容问题。

final class CardTitleStore: ObservableObject {
    static let shared = CardTitleStore()

    /// 卡片键 → 默认标题：内置名称 + 用户当前已改好的名称（DefaultData.titles）
    static let defaults: [String: String] = {
        var d: [String: String] = [
            "personal": "个人课表",
            "class": "全校班级课表",
            "extend": "延时 & 监考",
            // 左侧导航条目（双击可改名）—— key 为 "nav_" + PanelTab.rawValue
            "nav_personal": "个人课表",
            "nav_class": "班级课表",
            "nav_extend": "延时 & 监考",
            "nav_office": "办公室工位布局",
            "nav_classroom": "教室分布",
            "nav_staff": "年级师资安排",
            "nav_student": "学生信息",
            "nav_seating": "班级学生座位安排",
            "nav_班级学生座位安排": "班级学生座位安排",
            "nav_calendar": "重庆校历",
            "nav_reminder": "提醒设置",
            "nav_延时 & 监考": "延时 & 监考",
            "nav_办公室工位布局": "办公室工位布局",
            "nav_教室分布": "教室分布",
            "nav_年级师资安排": "年级师资安排",
            "nav_重庆校历": "重庆校历",
            "nav_提醒设置": "提醒设置",
            // 当前导航使用 PanelTab.rawValue 作为 key；这些键必须有默认标题，
            // 否则找不到旧数据时会把完整 key（例如 nav_延时监考）直接显示出来。
            "nav_个人课表": "个人课表",
            "nav_班级课表": "班级课表",
            "nav_延时监考": "延时监考",
            "nav_学生信息": "学生信息",
            "nav_学生座位": "学生座位",
            "nav_日程提醒": "日程提醒",
            "nav_校历日历": "校历日历",
            "nav_年级师资": "年级师资",
            "nav_教师工位": "教师工位",
            "nav_教室布局": "教室布局",
            // 新增卡片标题
            "office": "办公室工位布局",
            "classroom": "教室分布",
            "staff": "年级师资安排",
            "student": "学生信息",
            "seating": "班级学生座位安排",
        ]
        // 当前正在使用的名称（含中文导航键）作为默认，保证全新安装也是这套名字
        for (k, v) in DefaultData.titles where !v.isEmpty { d[k] = v }
        return d
    }()

    @Published var titles: [String: String]

    init() {
        self.titles = CardTitleStore.load()
    }

    /// 取标题；未改名/为空时回退默认名
    func title(for key: String) -> String {
        guard let t = titles[key], !t.isEmpty else {
            return Self.defaults[key] ?? key.replacingOccurrences(of: "nav_", with: "")
        }
        // 兼容早期版本误把导航键本身保存/显示出来的情况：
        // nav_个人课表 → 个人课表，避免升级后左侧出现 nav_ 前缀。
        if t.hasPrefix("nav_") {
            return String(t.dropFirst(4))
        }
        return t
    }

    func set(_ key: String, _ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            titles.removeValue(forKey: key)   // 清空 = 还原默认名
        } else {
            titles[key] = trimmed
        }
        scheduleSave()
    }

    // MARK: 持久化
    /// 用户编辑 → 只标脏；真正的落盘由 SaveHub 统一负责
    /// （点「保存」/ ⌘S / 停手 8 秒 / 收起面板 / 退出前）。
    func scheduleSave() {
        SaveHub.shared.markDirty("板块标题")
    }

    func save() {
        do {
            let url = Self.fileURL()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(titles)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[ScheduleBar] 卡片标题保存失败: \(error)")
        }
    }

    static func load() -> [String: String] {
        let url = fileURL()
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    static func fileURL() -> URL {
        // 统一走 AppPaths（自检可重定向到临时目录，绝不触碰真实数据）
        AppPaths.file("titles.json")
    }
}
