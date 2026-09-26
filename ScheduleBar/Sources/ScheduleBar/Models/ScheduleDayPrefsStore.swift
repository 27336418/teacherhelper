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

    // MARK: 列宽自适应（2026-09-26 用户要求）
    //
    // 用户原话：「显示星期6的时候自动缩小列宽，保证整体没有向右扩展宽度，保证协调性」。
    // 旧做法是「7 列 → 把面板从 880 撑到 973」，实测有两个问题：
    //   ① 撑宽会被屏幕右边缘截断（SchedulePanelView 里「右边缘不越屏」），
    //      结果面板还是 880 而表格按 782 排 → **最后一列（周日）被切掉**（用户截图）；
    //   ② 「回到周一~周五」时窗口又缩回去，一开一关整个面板左右跳。
    // 现在改成：表格**永远**放进 `baseContentWidth` 里，多出列就**等分压缩列宽**。
    // 效果：6 列以内列宽仍是 94（既有观感零回归）；7 列压到 80，整表 684 ≤ 689。

    /// 课表页可用的内容宽度 —— 必须等于 `SchedulePanelView.contentBaseWidth`
    /// （= 880 面板 − 170 侧栏 − 1 分隔线）。`--selftest-week` 里有断言守着。
    static let baseContentWidth: CGFloat = 709

    /// 列宽上限（6 列以内都用它，保持既有观感）
    static let baseColumnWidth: CGFloat = 94
    /// 列宽下限（7 列压缩后约 80；留点余量，免得以后再加列把字挤没）
    static let minColumnWidth: CGFloat = 72

    /// 纵向滚动条占宽余量。
    /// ⚠️ macOS 系统设置里选「始终显示滚动条」时，滚动条会**占宽**而不是覆盖内容，
    ///    不留余量的话最后一列会被切掉一小条。
    static let scrollBarAllowance: CGFloat = 20

    /// 通用解：「固定宽 fixed + n 个（列宽 + gap）」的表格，在 available 里每列能分到多宽。
    /// 优先用 base；放不下就**等分压缩**（下限 minWidth）—— 于是整表缩进原宽度、不往右扩。
    /// 向下取整到整数 pt，避免半像素把格子画糊。
    static func fittedColumnWidth(columns n: Int, available: CGFloat,
                                  padding: CGFloat, fixed: CGFloat,
                                  gap: CGFloat, base: CGFloat,
                                  minWidth: CGFloat) -> CGFloat {
        guard n > 0 else { return base }
        let usable = available - padding - fixed - scrollBarAllowance
        let raw = (usable - CGFloat(n) * gap) / CGFloat(n)
        return max(minWidth, min(base, raw.rounded(.down)))
    }

    /// 本人课表 / 班级课表的列宽（两页版式完全一致，所以只留一份）：
    /// 外层 `.padding(8)` → 16 + 节次标签 52 + n×(列宽 + 间距 8)
    /// · 6 列 → 94（= 680，与旧版完全一致）
    /// · 7 列 → 80（= 684，仍然 ≤ 709 − 20 滚动条余量）
    static func scheduleColumnWidth(columns n: Int,
                                    available: CGFloat = baseContentWidth) -> CGFloat {
        fittedColumnWidth(columns: n, available: available,
                          padding: 16, fixed: 52, gap: 8,
                          base: baseColumnWidth, minWidth: minColumnWidth)
    }

    /// 本人课表 / 班级课表的整表宽度（含卡片内边距），用于自检断言「放得下」。
    static func scheduleTableWidth(columns n: Int,
                                   available: CGFloat = baseContentWidth) -> CGFloat {
        guard n > 0 else { return 0 }
        return 16 + 52
            + CGFloat(n) * (scheduleColumnWidth(columns: n, available: available) + 8)
    }

    /// 他人课表的列宽（版式与上面两张不同）：
    /// 页面 `.padding(16)` → 32 + 卡片 `.padding(10)` → 20，合计左右内边距 **52**；
    /// 节次列 50、间距 6、基准列宽 85。
    /// 7 列全开时 52 + 50 + 7×91 = 739 会远超 689（滚动条一占宽被切掉 ~30pt），
    /// 所以同样走压缩：7 列 → 77（整表 683）。
    static func teacherColumnWidth(columns n: Int,
                                   available: CGFloat = baseContentWidth) -> CGFloat {
        fittedColumnWidth(columns: n, available: available,
                          padding: 52, fixed: 50, gap: 6,
                          base: 85, minWidth: 66)
    }

    static func teacherTableWidth(columns n: Int,
                                  available: CGFloat = baseContentWidth) -> CGFloat {
        guard n > 0 else { return 0 }
        return 52 + 50
            + CGFloat(n) * (teacherColumnWidth(columns: n, available: available) + 6)
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
