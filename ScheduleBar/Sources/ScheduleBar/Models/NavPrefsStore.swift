import Foundation
import SwiftUI

// MARK: - 左侧导航偏好（顺序 + 隐藏）
// 持久化 nav_prefs.json；新板块首次启动自动追加到末尾。

struct NavPrefsData: Codable {
    var order: [String]
    var hidden: [String]
}

final class NavPrefsStore: ObservableObject {
    static let shared = NavPrefsStore()

    @Published var order: [String] {   // PanelTab.rawValue 的顺序
        didSet { scheduleSave() }
    }
    @Published var hidden: Set<String> {
        didSet { scheduleSave() }
    }

    private init() {
        let all = PanelTab.allCases.map { $0.rawValue }
        let loaded = NavPrefsStore.load()

        // 旧版本保存的是旧标题；若旧顺序无法匹配新标题，则直接采用本版规定的默认顺序。
        // 这样升级后不会按 enum 声明顺序错排，也不会丢失新板块。
        let renameMap: [String: String] = [
            "延时 & 监考": "延时监考",
            "办公室工位布局": "教师工位",
            "教室分布": "教室布局",
            "年级师资安排": "年级师资",
            "班级学生座位安排": "学生座位",
            "重庆校历": "校历日历",
            "提醒设置": "日程提醒"
        ]
        let loadedOrder = (loaded?.order ?? []).map { renameMap[$0] ?? $0 }
        var ord = loadedOrder.filter { all.contains($0) }
        if ord.isEmpty {
            ord = DefaultData.navOrder.filter { all.contains($0) }
        }
        for t in all where !ord.contains(t) { ord.append(t) }   // 新增板块补到末尾
        self.order = ord
        let loadedHidden = (loaded?.hidden ?? []).map { renameMap[$0] ?? $0 }
        self.hidden = Set(loadedHidden.filter { all.contains($0) })
    }

    // MARK: 查询
    var visibleTabs: [PanelTab] {
        order.compactMap { PanelTab(rawValue: $0) }.filter { !hidden.contains($0.rawValue) }
    }
    var hiddenTabs: [PanelTab] {
        order.compactMap { PanelTab(rawValue: $0) }.filter { hidden.contains($0.rawValue) }
    }
    func isHidden(_ tab: PanelTab) -> Bool { hidden.contains(tab.rawValue) }

    // MARK: 隐藏 / 显示
    func hide(_ tab: PanelTab) {
        let snapOrder = order, snapHidden = hidden
        hidden.insert(tab.rawValue)
        // 隐藏后统一把隐藏项挪到顺序末尾，重新显示时出现在最后
        order = visibleTabs.map { $0.rawValue } + hiddenTabs.map { $0.rawValue }
        UndoService.shared.register("隐藏「\(tab.rawValue)」板块") { [weak self] in
            guard let self else { return }
            self.order = snapOrder
            self.hidden = snapHidden
            self.scheduleSave()   // didSet 其实已经标脏，这里显式调用是为了可读性
        }
    }
    func show(_ tab: PanelTab) {
        hidden.remove(tab.rawValue)
    }
    func showAll() {
        hidden.removeAll()
    }

    // MARK: 拖拽排序（在可见列表内换位）
    func moveVisible(from: Int, to: Int) {
        var vis = visibleTabs
        guard vis.indices.contains(from) else { return }
        let item = vis.remove(at: from)
        var target = to > from ? to - 1 : to
        target = max(0, min(vis.count, target))
        vis.insert(item, at: target)
        order = vis.map { $0.rawValue } + hiddenTabs.map { $0.rawValue }
    }

    // MARK: 持久化
    /// 用户编辑 → 只标脏；真正的落盘由 SaveHub 统一负责
    /// （点「保存」/ ⌘S / 停手 8 秒 / 收起面板 / 退出前）。
    func scheduleSave() {
        SaveHub.shared.markDirty("导航排序")
    }

    func save() {
        do {
            let url = Self.fileURL()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(NavPrefsData(order: order, hidden: Array(hidden)))
            try data.write(to: url, options: .atomic)
        } catch {
            print("[ScheduleBar] 导航偏好保存失败: \(error)")
        }
    }

    static func load() -> NavPrefsData? {
        guard let data = try? Data(contentsOf: fileURL()) else { return nil }
        return try? JSONDecoder().decode(NavPrefsData.self, from: data)
    }

    static func fileURL() -> URL {
        // 统一走 AppPaths（自检可重定向到临时目录，绝不触碰真实数据）
        AppPaths.file("nav_prefs.json")
    }
}
