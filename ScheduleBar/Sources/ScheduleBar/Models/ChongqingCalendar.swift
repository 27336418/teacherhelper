import Foundation
import SwiftUI

// MARK: - 普通日历数据模型（2025-2026 学年）
// 固定 22 周，每周一为起点；
// 所有日期由「设置-第1周开始日期」动态推算；备注默认值按周号放置。

enum ChongqingCalendar {
    static let totalWeeks = 22

    /// 第 n 周的周一日期（n 从 1 起）
    static func monday(week n: Int, firstWeekMonday: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: (n - 1) * 7, to: firstWeekMonday) ?? firstWeekMonday
    }

    /// 各周备注默认值（用户可编辑覆盖）
    static let defaultRemarks: [Int: String] = [
        1:  "开学行课",
        2:  "教师节",
        5:  "中秋节、国庆节按国家规定放假",
        13: "中小学放假",
        18: "元旦节按国家规定放假",
        21: "中小学复习考试",
        23: "义务教育阶段放寒假",
        24: "高中阶段（含中职）放寒假",
        25: "第二学期开学行课",
        29: "清明节按国家规定放假",
        33: "中小学春假",
        34: "劳动节按国家规定放假",
        38: "“六一”国际儿童节",
        41: "端午节按国家规定放假",
        43: "中小学复习考试",
        45: "中小学放暑假",
    ]

    // 农历历法与节假日缓存（只算一次，避免滚动时反复换算卡顿）
    private static let chineseCal: Calendar = {
        var c = Calendar(identifier: .chinese)
        c.locale = Locale(identifier: "zh_CN")
        return c
    }()
    private static var holidayCache: [Date: String?] = [:]

    /// 国家规定节假日判定（返回节日名，非节假日返回 nil）
    /// 公历固定：元旦 1/1；清明 4/4-4/6；劳动节 5/1-5/3；国庆 10/1-10/7
    /// 农历推算：端午 五月初五；中秋 八月十五
    static func holidayName(for date: Date) -> String? {
        if let cached = holidayCache[date] { return cached }
        let cal = Calendar.current
        let m = cal.component(.month, from: date)
        let d = cal.component(.day, from: date)
        var name: String? = nil
        switch (m, d) {
        case (1, 1):      name = "元旦"
        case (4, 4...6):  name = "清明节"
        case (5, 1...3):  name = "劳动节"
        case (10, 1...7): name = "国庆节"
        default:
            let c = chineseCal.dateComponents([.month, .day], from: date)
            if c.isLeapMonth != true {
                if c.month == 8 && c.day == 15 { name = "中秋节" }
                if c.month == 5 && c.day == 5  { name = "端午节" }
            }
        }
        holidayCache[date] = name
        return name
    }
}
