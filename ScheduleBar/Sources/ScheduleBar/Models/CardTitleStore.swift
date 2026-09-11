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
            "nav_个人课表": "个人课表",
            "nav_班级课表": "全校班级课表",
            "nav_延时 & 监考": "延时 & 监考",
            "nav_办公室工位布局": "办公室工位布局",
            "nav_教室分布": "教室分布",
            "nav_年级师资安排": "年级师资安排",
            "nav_学生信息": "学生信息",
            "nav_重庆校历": "重庆校历",
            "nav_提醒设置": "提醒设置",
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
            return Self.defaults[key] ?? key
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
        save()
    }

    // MARK: 持久化
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
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        return base.appendingPathComponent("ScheduleBar", isDirectory: true)
                  .appendingPathComponent("titles.json")
    }
}
