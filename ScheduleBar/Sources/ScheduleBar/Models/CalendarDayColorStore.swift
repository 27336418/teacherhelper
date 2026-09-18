import Foundation
import SwiftUI

// MARK: - 校历单日自定义颜色（右键换色；键 = yyyy-MM-dd；持久化 calendar_day_colors.json）
final class CalendarDayColorStore: ObservableObject {
    static let shared = CalendarDayColorStore()

    @Published var colors: [String: String] = [:] {   // 日期 → hex（如 "2026-09-10" → "E74C3C"）
        didSet { scheduleSave() }
    }

    private init() {
        load()
        isInitializing = false   // 装载结束，之后的改动才算用户编辑
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func key(for date: Date) -> String { formatter.string(from: date) }

    func color(for date: Date) -> String? {
        colors[Self.key(for: date)]
    }

    func setColor(_ hex: String?, for date: Date) {
        let key = Self.key(for: date)
        if let hex, !hex.isEmpty {
            colors[key] = hex
        } else {
            colors.removeValue(forKey: key)
        }
    }

    // MARK: 持久化
    private static var fileURL: URL {
        // 统一走 AppPaths：自检可用 SCHEDULEBAR_DATA_DIR 把数据目录重定向到
        // 临时目录 —— 所有 store 都必须支持，否则它在 init 里的迁移会写真实数据。
        AppPaths.file("calendar_day_colors.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            // 没有本地数据 → 用内置的默认单日配色
            colors = DefaultData.calendarDayColors
            return
        }
        colors = decoded
    }

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
        SaveHub.shared.markDirty("校历配色")
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(colors)
            try data.write(to: Self.fileURL, options: .atomic)
        } catch {
            print("[ScheduleBar] 校历单日颜色保存失败: \(error)")
        }
    }
}
