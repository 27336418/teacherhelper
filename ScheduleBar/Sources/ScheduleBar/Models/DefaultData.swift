import Foundation
import SwiftUI

// MARK: - 内置默认数据（已清空，发给别人安装时让对方自己填写）
// 各 Store 在没有本地 JSON 时加载这里的默认值；已有 JSON 仍以本地数据为准。
enum DefaultData {

    // MARK: 个人课表（上午 / 下午 / 晚自习）
    // 新机器默认就带节次（上午第1-5节 / 下午第6-9节 / 晚自习晚1-晚4），格子内容为空，
    // 装好即可双击空格直接填写。
    static let personalGroups: [PersonalGroup] = ScheduleStore.defaultGroups
    static let personalGrid: [[String]] =
        ScheduleStore.emptyGrid(periods: ScheduleStore.defaultGroups.flatMap { $0.periods })

    // MARK: 班级课表（key 为组名，例 "1"/"一"/"七"；空表示不显示任何预填内容）
    static let classCells: [String: [String]] = [:]

    // MARK: 教室分布
    static let classrooms: [ClassroomFloor] = []

    // MARK: 办公室工位布局
    static let offices: [OfficeBlock] = []

    // MARK: 定时提醒
    static let reminders: [Reminder] = []

    // MARK: 卡片 / 导航标题（空：UI 自行用 key 兜底）
    static let titles: [String: String] = [:]

    // MARK: 第 1 周开始日期（yyyy-MM-dd；空字符串表示未设置，今天所在周为第 1 周）
    /// 发布版默认第 1 周周一：2026-08-31
    static let firstWeekStart = "2026-08-31"

    // MARK: 校历备注（week-N → 备注）
    static let calendarRemarks: [String: String] = [:]

    // MARK: 校历单日自定义颜色（yyyy-MM-dd → hex）
    static let calendarDayColors: [String: String] = [:]

    // MARK: 左侧导航默认顺序
    static let navOrder: [String] = [
        "个人课表", "班级课表", "延时监考", "学生信息", "学生座位",
        "日程提醒", "校历日历", "年级师资", "教师工位", "教室布局"
    ]
    static let navHidden: [String] = []
}
