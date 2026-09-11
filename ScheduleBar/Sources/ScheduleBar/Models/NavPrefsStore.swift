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
        didSet { save() }
    }
    @Published var hidden: Set<String> {
        didSet { save() }
    }

    private init() {
        let all = PanelTab.allCases.map { $0.rawValue }
        let loaded = NavPrefsStore.load()

        var ord = (loaded?.order ?? DefaultData.navOrder).filter { all.contains($0) }
        for t in all where !ord.contains(t) { ord.append(t) }   // 新增板块补到末尾

        self.order = ord
        self.hidden = Set((loaded?.hidden ?? DefaultData.navHidden).filter { all.contains($0) })
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
            self.save()
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
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("ScheduleBar", isDirectory: true)
                  .appendingPathComponent("nav_prefs.json")
    }
}
