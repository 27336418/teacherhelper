import SwiftUI

// MARK: - 「星期」显隐菜单（本人课表 / 班级课表 / 他人课表 共用同一个组件）
//
// 三张课表共用一份设置（ScheduleDayPrefsStore）——在任意一张表上改动，
// 另外两张立即跟着变，不会出现「这张有周六、那张没有」的错乱感。

struct WeekVisibilityMenu: View {
    @ObservedObject private var prefs = ScheduleDayPrefsStore.shared

    var body: some View {
        Menu {
            Toggle("显示周六", isOn: $prefs.showSaturday)
            Toggle("显示周日", isOn: $prefs.showSunday)
            Divider()
            Text("三张课表统一生效")
        } label: {
            Label("星期", systemImage: "calendar")
        }
        .fixedSize()
        .help("显示或隐藏「周六 / 周日」列；本人课表、班级课表、他人课表统一生效（隐藏不会删除数据）")
    }
}
