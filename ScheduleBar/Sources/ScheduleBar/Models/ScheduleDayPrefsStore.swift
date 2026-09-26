import Foundation
import SwiftUI

// MARK: - 课表「星期列」的定义与显隐偏好
//
// 三张课表（本人 / 班级 / 他人）的数据列**统一为 7 列**：
//     0~4 = 周一~周五，5 = 周六，6 = 周日（他人课表的第 7 天写作「周天」，下标同为 6）
//
// 「显示 / 隐藏周六、周日」只是**渲染层过滤**，数据永远是 7 列 ——
// 隐藏周六不会丢数据，重新打开开关立刻又能看到原内容。
//
// 偏好存 `UserDefaults`（与 OfficeLayoutStore 的「内部/外部视角」「显示左右门」同一套路）：
// 这是纯显示偏好，**不进 SaveHub、不进 writeAll、不占 --selftest-save 的 expectedAreaCount**。
// ⚠️ 别把它做成 json store —— 那会连带改 4 处覆盖面统计，收益为零。
// ⚠️ 也**不要**用 UserDefaults 当「一次性迁移」开关（见 AppPaths 顶部说明）。

enum ScheduleWeek {
    /// 一周列数（三张课表的数据列数都是它）
    static let columnCount = 7
    /// 周六列下标
    static let saturday = 5
    /// 周日列下标（他人课表里标签写作「周天」）
    static let sunday = 6

    /// 可显示的列下标（始终按 周一→周日 顺序；周六/周日按开关收放）
    static func visibleIndices(showSaturday: Bool, showSunday: Bool) -> [Int] {
        var idx = Array(0..<saturday)          // 周一~周五
        if showSaturday { idx.append(saturday) }
        if showSunday { idx.append(sunday) }
        return idx
    }

    /// 中文星期标签 → 列下标。
    /// 认「周一 / 星期一 / 礼拜一 / 周天 / 周日 / 数字」；认不出返回 nil。
    /// ⚠️ xlsx 里「星期」常写成竖排（星␊␊期␊␊一），先 compact 去掉换行/空格。
    static func dayIndex(from raw: String) -> Int? {
        var s = ClassLayout.compact(raw)
        for prefix in ["星期", "礼拜", "周"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
            break
        }
        switch s {
        case "一", "1":     return 0
        case "二", "2":     return 1
        case "三", "3":     return 2
        case "四", "4":     return 3
        case "五", "5":     return 4
        case "六", "6":     return 5
        case "日", "天", "7": return 6
        default:            return nil
        }
    }

    /// 表头行 →「列下标 → 文件列下标」映射（用于导入时认星期，而不是傻按位置取）。
    /// - Parameter header: 表头行（第 0 列通常是「节次」）
    static func headerColumnMap(_ header: [String]) -> [Int: Int] {
        var map: [Int: Int] = [:]
        for (col, raw) in header.enumerated() where col > 0 {
            guard let d = dayIndex(from: raw) else { continue }
            if map[d] == nil { map[d] = col }
        }
        return map
    }

    /// 本人课表 / 班级课表的表格自然宽度（两页版式完全一致，所以只留一份）：
    /// 外层 `.padding(8)` → 16 + 标签 52 + n×94(列宽) + n×8(间距)
    /// （n = 可见列数；6 列 = 680 不撑宽面板，7 列 = 782 → 面板要跟着加宽）
    static func tableNaturalWidth(columns n: Int) -> CGFloat {
        guard n > 0 else { return 0 }
        return 16 + 52 + CGFloat(n) * 94 + CGFloat(n) * 8
    }

    /// 纵向滚动条占宽余量。
    /// ⚠️ macOS 系统设置里选「始终显示滚动条」时，滚动条会**占宽**而不是覆盖内容，
    ///    不留余量的话最后一列会被切掉一小条（7 列时正好顶到边界，一点余量都没有）。
    static let scrollBarAllowance: CGFloat = 20

    /// 课表页真正向面板索要的宽度 = 表格自然宽 + 滚动条余量。
    /// （6 列 = 700 ≤ 709 → 面板不变宽；7 列 = 802 > 709 → 面板加宽 93pt）
    static func tableIdealWidth(columns n: Int) -> CGFloat {
        guard n > 0 else { return 0 }
        return tableNaturalWidth(columns: n) + scrollBarAllowance
    }

    /// 表头认不出星期时的**位置兜底**：
    /// · 行宽 ≥ 8（「节次」+ 7 天，新格式）→ 第 d 天就在第 d+1 列
    /// · 行宽 == 7（「节次」+ 6 天，旧格式：周一~周五 + 周日）→ 第 6 列是**周日**，
    ///   不能按位置取，否则周日的内容会被灌进周六列
    static func fallbackColumn(dayIndex d: Int, rowWidth: Int) -> Int? {
        if rowWidth >= ScheduleWeek.columnCount + 1 { return d + 1 }
        if rowWidth == ScheduleWeek.columnCount {    // 7 列 = 节次 + 6 天（旧）
            return d < saturday ? d + 1 : (d == sunday ? 6 : nil)
        }
        return d + 1
    }
}

// MARK: - 显隐偏好（三张课表共用一份设置）

final class ScheduleDayPrefsStore: ObservableObject {
    static let shared = ScheduleDayPrefsStore()

    /// 显示周六 —— 默认**关**（用户要求：默认隐藏周六）
    @Published var showSaturday: Bool {
        didSet { UserDefaults.standard.set(showSaturday, forKey: Self.saturdayKey) }
    }

    /// 显示周日 —— 默认**开**（用户要求：默认显示周日）
    @Published var showSunday: Bool {
        didSet { UserDefaults.standard.set(showSunday, forKey: Self.sundayKey) }
    }

    private static let saturdayKey = "scheduleShowSaturday"
    private static let sundayKey   = "scheduleShowSunday"

    private init() {
        let d = UserDefaults.standard
        // ⚠️ 用 object(forKey:) as? Bool 而不是 bool(forKey:)：后者在键不存在时返回 false，
        //    无法区分「用户明确关掉」和「从未设置过」——周日默认是**开**，必须区分。
        showSaturday = (d.object(forKey: Self.saturdayKey) as? Bool) ?? false
        showSunday   = (d.object(forKey: Self.sundayKey) as? Bool) ?? true
    }

    /// 当前可见的列下标
    var visibleDayIndices: [Int] {
        ScheduleWeek.visibleIndices(showSaturday: showSaturday, showSunday: showSunday)
    }

    /// 当前可见列数（面板宽度按它算）
    var visibleDayCount: Int { visibleDayIndices.count }
}
