import Foundation
import SwiftUI

// MARK: - 周次上下文：第1周开始日期 + 当前周计算（每周从周一开始）
// 持久化于 week.json（存 yyyy-MM-dd）。未设置时：把今天所在周视作第 1 周。

final class WeekStore: ObservableObject {
    static let shared = WeekStore()

    /// 用户设置的第 1 周开始日（存入时已对齐为当天所在周的周一）
    @Published var rawStart: Date? {
        didSet { scheduleSave() }
    }

    init() {
        self.rawStart = WeekStore.load() ?? WeekStore.defaultStart()
    }

    /// 内置默认：第 1 周开始日期（见 DefaultData.swift）
    static func defaultStart() -> Date? {
        formatter.date(from: DefaultData.firstWeekStart)
    }

    var isConfigured: Bool { rawStart != nil }

    /// 第 1 周的周一（若已设置）
    var firstWeekMonday: Date? {
        guard let raw = rawStart else { return nil }
        return alignedMonday(of: raw)
    }

    /// 当前是第几周（至少为 1；未设置时默认 1）
    var currentWeek: Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let monday = firstWeekMonday,
              let days = cal.dateComponents([.day], from: monday, to: today).day else {
            return 1
        }
        return max(1, days / 7 + 1)
    }

    /// 取日期所在周的周一（一周起点 = 周一）
    func alignedMonday(of date: Date) -> Date {
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        let wd = cal.component(.weekday, from: start)  // 1=周日 ... 7=周六
        let diff = (wd + 5) % 7                        // 距本周一的天数
        return cal.date(byAdding: .day, value: -diff, to: start) ?? start
    }

    func setStart(_ date: Date) {
        rawStart = alignedMonday(of: date)
    }

    func clear() {
        rawStart = nil
    }

    // MARK: 持久化
    /// 用户编辑 → 只标脏；真正的落盘由 SaveHub 统一负责
    /// （点「保存」/ ⌘S / 停手 8 秒 / 收起面板 / 退出前）。
    func scheduleSave() {
        SaveHub.shared.markDirty("当前周")
    }

    func save() {
        do {
            let url = Self.fileURL()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(rawStart.map(Self.formatter.string))
            try data.write(to: url, options: .atomic)
        } catch {
            print("[ScheduleBar] 周设置保存失败: \(error)")
        }
    }

    static func load() -> Date? {
        let url = fileURL()
        guard let data = try? Data(contentsOf: url),
              let str = try? JSONDecoder().decode(String.self, from: data) else { return nil }
        return formatter.date(from: str)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func fileURL() -> URL {
        // 统一走 AppPaths（自检可重定向到临时目录，绝不触碰真实数据）
        AppPaths.file("week.json")
    }
}
