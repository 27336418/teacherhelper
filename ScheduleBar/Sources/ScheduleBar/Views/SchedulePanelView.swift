import SwiftUI

// MARK: - 面板根视图（左侧导航 + 右侧内容区）
// 5 项：个人课表 / 班级课表 / 延时&监考 / 重庆校历 / 提醒设置
// 默认展开个人课表；点击班级/校历/提醒等，内容区向右展开对应视图。

enum PanelTab: String, CaseIterable, Identifiable {
    // ⚠️ rawValue 就是「板块名」，它同时是：侧栏标题、卡片标题的 key（nav_<rawValue>）、
    //    nav_prefs.json 里存的顺序项、SaveHub.dirtyAreas 的键。改名必须四处同步，
    //    并在 NavPrefsStore.renameMap / CardTitleStore 里补旧名迁移（2026-09-21 用户改名）。
    case personal  = "本人课表"
    case class7    = "班级课表"
    case teacher   = "他人课表"
    case extend    = "延时监考"
    case office    = "教师工位"
    case classroom = "教室布局"
    case staff     = "年级师资"
    case student   = "学生信息"
    case seating   = "学生座位"
    case calendar  = "校历日历"
    case reminder  = "日程提醒"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .personal:  return "person.crop.rectangle"
        case .class7:    return "building.2"
        case .teacher:   return "tablecells"
        case .extend:    return "clock.fill"
        case .office:    return "person.3.fill"
        case .classroom: return "square.grid.3x3"
        case .staff:     return "person.text.rectangle"
        case .student:   return "person.2.fill"
        case .seating:   return "square.grid.3x3.fill"
        case .calendar:  return "calendar"
        case .reminder:  return "bell.badge.fill"
        }
    }

    var accentColor: Color {
        switch self {
        case .personal:  return Color(hex: 0x16A085)
        case .class7:    return Color(hex: 0x3498DB)
        case .teacher:   return Color(hex: 0x2C3E50)
        case .extend:    return Color(hex: 0x9B59B6)
        case .office:    return Color(hex: 0x27AE60)
        case .classroom: return Color(hex: 0xF39C12)
        case .staff:     return Color(hex: 0x2980B9)
        case .student:   return Color(hex: 0x16A085)
        case .seating:   return Color(hex: 0x8E44AD)
        case .calendar:  return Color(hex: 0xE67E22)
        case .reminder:  return Color(hex: 0xC0392B)
        }
    }
}

struct SchedulePanelView: View {
    @EnvironmentObject var store: ScheduleStore
    @EnvironmentObject var classStore: ClassScheduleStore
    @EnvironmentObject var extStore: ExtendScheduleStore
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var weekStore: WeekStore
    @EnvironmentObject var reminderStore: ReminderStore
    @EnvironmentObject var titleStore: CardTitleStore

    @State private var selectedTab: PanelTab = .personal
    @State private var showWeekSetup = false
    @State private var showDockIcon = DockPrefs.show     // Dock 图标开关
    @State private var draggedTab: PanelTab? = nil      // 正在拖拽的导航项
    @State private var visitedTabs: Set<PanelTab> = [.personal]  // 已访问过的页面（缓存常驻，切回零重建）

    // 导航顺序 / 隐藏（持久化 nav_prefs.json）
    @ObservedObject private var navPrefs = NavPrefsStore.shared

    private let now = Date()

    // MARK: 面板宽度（左侧固定，右侧按内容自动扩宽）
    // 用户 2026-09-23 反馈：「教室布局」加了很多教室后，整页被撑得比面板还宽 →
    // 左侧侧栏被挤掉一半、右侧教室也看不全。现在的规则：
    //   · 左侧导航列**固定宽度**，内容再宽也不动它；
    //   · 右侧内容区随「教室布局」最宽那一行自动扩宽，**最多 +3 个教室格宽**；
    //   · 再宽就把内容区变成可左右滑动的区域（横向 ScrollView）。
    private let basePanelWidth: CGFloat = 880
    /// ⚠️ 侧栏宽度必须 ≥ 170：里面「教师助手」大标题（20pt×4 字 = 80）+ 左右 22pt 内边距
    /// 就要 124pt，导航项「图标 20 + 间距 9 + 4 字板块名 52 + 三层内边距 56」要 137pt。
    /// 2026-09-23 曾压到 118pt，子视图比容器宽 → SwiftUI 居中摆放 → 文字左右各溢出 26pt 越过灰色分隔线
    /// （用户截图反馈「左侧的板块名称超过了灰色线条」）。**别再压窄它**，要挪宽度请改 basePanelWidth。
    private let navColumnWidth: CGFloat = 170
    private let maxExtraWidth: CGFloat = ClassroomStore.cellPitch * 3   // 3 个教室格 ≈ 177

    @ObservedObject private var classroomStore = ClassroomStore.shared

    /// 星期列显隐（三张课表共用）。
    /// ⚠️ 面板宽度**不再**随它变（2026-09-26 起课表页固定基础宽度、靠压缩列宽容纳 7 列），
    ///    这里观察它只是为了宽度取证日志能把「可见星期列」一起打出来。
    @ObservedObject private var dayPrefs = ScheduleDayPrefsStore.shared

    /// 面板基础宽度下、内容区能拿到的宽度（减去侧栏与分隔线）。
    /// ⚠️ 课表页的版式常量 `ScheduleWeek.baseContentWidth` 必须与它相等（自检里有断言）。
    private var contentBaseWidth: CGFloat {
        let w = basePanelWidth - navColumnWidth - 1
        assert(abs(w - ScheduleWeek.baseContentWidth) < 0.5,
               "面板基础内容宽 \(w) 与 ScheduleWeek.baseContentWidth \(ScheduleWeek.baseContentWidth) 不一致")
        return w
    }

    /// 当前这一页「自然需要」的宽度 —— 只有会横向变长的板块登记在这里，其余按基础宽度。
    /// ⚠️ 课表页**故意不登记**：2026-09-26 用户要求「显示周六时不往右扩宽、自动缩小列宽」，
    ///    所以 `.personal` / `.class7` 一律返回基础宽度，列宽由 `ScheduleWeek.scheduleColumnWidth`
    ///    按可见列数压缩（见 ScheduleDayPrefsStore 顶部说明）。
    private var currentPageIdealWidth: CGFloat {
        switch selectedTab {
        case .classroom: return classroomStore.idealContentWidth
        case .calendar:  return ChongqingCalendarView.idealWidth   // 备注栏加宽后需要的宽度
        default:         return contentBaseWidth
        }
    }

    /// 面板实际宽度 = 基础 + 当前页需要的额外宽度（截断到 maxExtraWidth）
    private var panelWidth: CGFloat {
        basePanelWidth + min(max(0, currentPageIdealWidth - contentBaseWidth), maxExtraWidth)
    }

    /// 内容区可用宽度（面板实际宽度 − 侧栏 − 分隔线）。
    /// 现在只用于核对/日志：内容本身是弹性的，宽度由窗口决定。
    private var contentAvailableWidth: CGFloat { panelWidth - navColumnWidth - 1 }

    /// 宽度取证（§35）：`SCHEDULEBAR_TRACE_WIDTH=1` → 日志打
    /// 「当前页 / 可见星期列数 / 需要宽 / 面板宽 / 内容区宽」。
    /// ⚠️ 内容被裁、左侧栏被挤时先开这个看数字，别再靠肉眼量截图。
    /// ⚠️ 必须**在 onAppear 也调一次**：用 `--tab` 直接落在目标页时 panelWidth 从来没「变化」过，
    ///    只挂在 `onChange(of: panelWidth)` 上会一条日志都打不出来（2026-09-26 踩到）。
    private func traceWidth(_ tag: String) {
        guard ProcessInfo.processInfo.environment["SCHEDULEBAR_TRACE_WIDTH"] != nil else { return }
        SaveHub.log("面板宽度[\(tag)] 页=\(selectedTab.rawValue) 可见星期列=\(dayPrefs.visibleDayCount)"
            + " 需要=\(Int(currentPageIdealWidth)) 面板=\(Int(panelWidth))"
            + " 内容区=\(Int(contentAvailableWidth))")
    }

    var body: some View {
        HStack(spacing: 0) {
            // 左侧导航列：固定宽度，右侧再宽也不挤它
            navColumn
                .frame(width: navColumnWidth)

            Divider()

            // 右侧内容区
            contentArea
        }
        // ⚠️ 这里**不要**再写 `.frame(width: panelWidth)`：
        //    固定宽度会让内容在窗口还没跟上时「比窗口宽」，SwiftUI 默认居中摆放 →
        //    左侧栏目先向左飘一半再弹回来（用户反馈的「切换板块时左侧栏目左右抖动」），
        //    右侧则会被窗口裁掉（用户反馈的「右上角显示不全」）。
        //    现在只声明「填满宿主 + 左上对齐」：左侧栏永远从 x=0 开始，内容永远不超出窗口，
        //    需要更宽的页（教室布局）在页面内部自己横向滚动。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { FrostedView() }
        // 面板宽度变了（例如切到「教室布局」/「校历日历」）→ 把新宽度同步给 popover 窗口，
        // 否则 SwiftUI 这边变宽了、窗口还是 880，右边照样被裁。
        .onChange(of: panelWidth) { w in
            AppDelegate.applyPanelWidth(w)
            // 宽度取证（§35）：SCHEDULEBAR_TRACE_WIDTH=1 → 打「当前页 / 可见星期列数 / 需要宽 / 面板宽」
            // ⚠️ 面板宽度异常（内容被裁 / 左侧栏被挤）时先开这个，别再肉眼量截图。
            if ProcessInfo.processInfo.environment["SCHEDULEBAR_TRACE_WIDTH"] != nil {
                SaveHub.log("面板宽度 页=\(selectedTab.rawValue) 可见星期列=\(dayPrefs.visibleDayCount)"
                    + " 需要=\(Int(currentPageIdealWidth)) 面板=\(Int(w))"
                    + " 内容区=\(Int(w - navColumnWidth - 1))")
            }
        }
        // 每次切页登记缓存，之后切回不再重建（消除卡顿）
        .onChange(of: selectedTab) { t in
            visitedTabs.insert(t)
            // 离开「教室布局」就取消选中：否则回到本页会看到上次的蓝框，
            // 而且 Delete 键监听器虽然一直在，也该在没有选中时保持沉默。
            if t != .classroom { ClassroomStore.shared.clearSelection() }
        }
        .onChange(of: showDockIcon) { on in
            DockPrefs.set(on)
        }
        .onAppear {
            // --tab <板块名>：截图取证时直接停在目标板块（不必点侧栏，坐标不稳）
            if let name = AppDelegate.initialTabName, let t = PanelTab(rawValue: name) {
                selectedTab = t
                visitedTabs.insert(t)
            }
            // 首帧补一次窗口宽度同步。--tab 指定的板块是在这里就位的，
            // 那一帧 panelWidth 已经是最终值、**没有「变化」过**，光靠 onChange 会漏掉，
            // 结果是停在 880 而内容按 948 排（右边被裁）。
            let w = panelWidth
            DispatchQueue.main.async {
                AppDelegate.applyPanelWidth(w)
                traceWidth("首帧")
            }
        }
    }

    // MARK: 左侧导航
    private var navColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题 + 周次胶囊
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("教师助手")
                    .font(.title3.bold())
                // 版本号（2026-09-26 用户要求「左上角教师助手后面跟上版本号；版本号字体调小一些」）。
                // ⚠️ 侧栏宽度硬底线 170pt：标题 20pt×4 字 ≈ 80pt + 左右各 22pt 内边距，
                //    只剩 ~46pt 给版本号。这里用 10pt 小字（`v2.5.4` ≈ 30pt）正好放得下；
                //    万一以后变长，靠 minimumScaleFactor 缩，**绝不折行、也不撑宽侧栏**。
                Text(AppVersion.display)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .help(AppVersion.tooltip)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 6)

            HStack(spacing: 6) {
                Text("第 \(weekStore.currentWeek) 周")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor))
                    .contentShape(Capsule())
                    .onTapGesture { showWeekSetup = true }
                    .help("点击设置第1周开始日期")
                    .popover(isPresented: $showWeekSetup, arrowEdge: .bottom) { WeekSetupView() }
                // 日期必须一行显示完整：lineLimit(1) + 轻微缩放，空间再紧也不折行
                Text("\(weekdayString()) \(dateString())")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 12)

            // 导航条目（可拖拽排序；右键隐藏）
            // 顺序变化时用弹簧动画平滑归位
            ForEach(navPrefs.visibleTabs, id: \.self) { tab in
                navItem(tab)
                    .onDrag {
                        draggedTab = tab
                        return NSItemProvider(object: tab.rawValue as NSString)
                    }
                    .onDrop(of: [.text], delegate: NavReorderDelegate(
                        item: tab,
                        visible: navPrefs.visibleTabs,
                        dragged: $draggedTab,
                        move: { from, to in navPrefs.moveVisible(from: from, to: to) }
                    ))
            }

            // 空白处：右键可把隐藏的板块调出来
            Spacer(minLength: 0)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .contextMenu { hiddenMenu }

            // 底部操作：备份恢复 / 升级 / Dock / 退出
            // ⚠️ 文案 2026-09-26 按用户要求精简（截图里圈的就是这四个按钮）：
            //    「备份全部数据 → 备份数据」「从备份恢复 → 恢复数据」「清空所有数据 → 清空数据」。
            //    侧栏只有 170pt 宽，四个字一行刚好；「全部/所有」这类冗余词去掉更清爽。
            //    作用范围写在 `.help()` 里，"检查更新" 本来就是四个字、不用改。
            // ⚠️ 2026-09-26 第二处修改：用户反馈「这图的两侧空白较多，尽量与上面的板块宽度相同」。
            //    实测（截图 2x 量像素）：导航项目内的胶囊 = 16…154 = **138pt**，
            //    而这里的按钮 = 22…148 = **126pt**，左右各多空 6pt。
            //    所以内边距 22 → **16**（= 导航项的 `.padding(.horizontal, 16)`），
            //    并把 Label 改成 `.leading` 对齐 —— 否则 bordered 按钮的标签是**居中**的，
            //    与上面「图标在左、文字紧随」的导航项对不齐（宽度一样了但看着还是不齐）。
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    BackupService.exportBackup()
                } label: {
                    Label("备份数据", systemImage: "archivebox")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .help("一键导出全部数据与设置（课表/学生/座位/提醒/备注/布局/设置）到备份文件")
                Button {
                    BackupService.importBackup()
                } label: {
                    Label("恢复数据", systemImage: "arrow.counterclockwise.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .help("从备份文件一键导入并恢复全部数据与设置（恢复后自动重启生效）")
                Button {
                    AppCoordinator.shared.clearAllData()
                } label: {
                    Label("清空数据", systemImage: "trash.slash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(.red)
                .help("清空全部业务数据（课表/师资/学生/工位/教室/座位/延时监考/提醒），保留表结构，重启生效")
                Button {
                    AppCoordinator.shared.checkForUpdate(manually: true)
                } label: {
                    Label("检查更新", systemImage: "arrow.triangle.2.circlepath.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .help("连接 GitHub 检查新版本；发现新版本会打开下载地址")
                Toggle("Dock 图标", isOn: $showDockIcon)
                    .font(.system(size: 12))
                    .toggleStyle(.switch)
                    .help("在 Dock 中显示教师助手图标；点 Dock 图标可打开独立窗口（可最小化到 Dock）")
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("退出", systemImage: "power")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(.red)
                .keyboardShortcut("q", modifiers: [.command])
                .help("退出教师助手 (⌘Q)")
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        // 宽度由外层 .frame(width: navColumnWidth) 统一决定，这里只负责填满并左对齐。
        // ⚠️ 不要再在这里写死宽度：内外两个宽度不一致时，SwiftUI 会把过宽的子视图**居中**摆放，
        //    于是左右各溢出一半，左侧内容会越过灰色分隔线（用户反馈过的现象）。
        .frame(maxWidth: .infinity, alignment: .leading)
        // 顺序/显隐变化时整体平滑过渡（拖拽排序、隐藏、恢复）
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: navPrefs.order)
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: navPrefs.hidden)
    }

    private func navItem(_ tab: PanelTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 9) {
                Image(systemName: tab.icon)
                    .font(.system(size: 14))
                    .frame(width: 20)
                NavEditableTitle(tab: tab, isSelected: isSelected)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                Spacer()
            }
            .foregroundStyle(isSelected ? tab.accentColor : Color.primary)
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? tab.accentColor.opacity(0.14) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 1)
        // 拖拽中的条目：轻微放大 + 半透明 + 投影，松手后弹回
        .scaleEffect(draggedTab == tab ? 1.04 : 1.0)
        .opacity(draggedTab == tab ? 0.55 : 1.0)
        .shadow(color: draggedTab == tab ? Color.black.opacity(0.18) : Color.clear,
                radius: draggedTab == tab ? 6 : 0, x: 0, y: 2)
        .animation(.spring(response: 0.26, dampingFraction: 0.78), value: draggedTab)
        // 鼠标移上去即切换（拖拽过程中不切换，避免乱跳）
        // ⚠️ 只要左键还按着就不能换页：拖动单元格时鼠标划过左侧栏会切页，
        //    松手就落到另一个板块的落点上（表现为「拖了没换 / 换到别处」）。
        .onHover { inside in
            guard inside, draggedTab == nil else { return }
            guard NSEvent.pressedMouseButtons == 0 else { return }
            if selectedTab != tab { selectedTab = tab }
        }
        .contextMenu {
            Button {
                navPrefs.hide(tab)
                if selectedTab == tab { selectedTab = navPrefs.visibleTabs.first ?? tab }
            } label: {
                Label("隐藏此板块", systemImage: "eye.slash")
            }
            Text("双击名称可重命名")
        }
    }

    // 空白处右键：显示被隐藏的板块
    @ViewBuilder
    private var hiddenMenu: some View {
        let hidden = navPrefs.hiddenTabs
        if hidden.isEmpty {
            Text("没有隐藏的板块")
        } else {
            Text("显示隐藏的板块")
            Divider()
            ForEach(hidden, id: \.self) { tab in
                Button {
                    navPrefs.show(tab)
                    selectedTab = tab
                } label: {
                    Label(tab.rawValue, systemImage: tab.icon)
                }
            }
            Divider()
            Button("全部显示") { navPrefs.showAll() }
        }
    }

    // MARK: 右侧内容区
    // 已访问的页面缓存常驻（ZStack 叠放），切换只改透明度，避免反复重建大表格导致卡顿。
    //
    // ⚠️ 2026-09-12 关键修复：**当前选中页必须是 ZStack 里最后一个（最上层）**。
    //   `.allowsHitTesting(false)` 只挡得住 SwiftUI 自己的手势（所以隐藏页上的 .onDrag 确实起不来），
    //   但挡不住 AppKit 的拖拽落点注册：隐藏页上 `.onDrop` 仍是有效的落点，谁在最上层谁接走松手。
    //   原来的顺序是 PanelTab.allCases（个人→班级→…→提醒），于是：
    //     · 在「个人课表」拖格子，松手被上层的「班级课表」接走 → 提交给了 csc，实际什么都没换；
    //     · 一旦访问过「提醒设置」（排在最后 = 永远在最上层），它的空白区就把后面的松手全吃掉
    //       → 「工位拖不动」。
    //   把选中页挪到末尾即可：可见页永远优先命中，隐藏页只在可见页没有落点的空白处兜底，
    //   而兜底那一次也会被各落点代理按「非本模块」拒掉（见 DragSwapSupport.swift）。
    private var cachedTabs: [PanelTab] {
        var list = PanelTab.allCases.filter { visitedTabs.contains($0) }
        if let i = list.firstIndex(of: selectedTab) {
            list.append(list.remove(at: i))
        }
        return list
    }

    @ViewBuilder
    private var contentArea: some View {
        if navPrefs.visibleTabs.isEmpty || navPrefs.isHidden(selectedTab) {
            // 全部隐藏 / 当前项被隐藏时的兜底提示
            VStack(spacing: 8) {
                Image(systemName: "sidebar.left")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("没有显示的板块")
                    .foregroundStyle(.secondary)
                Text("在左侧空白处右键可重新显示")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // 内容宽度**跟着窗口走**（弹性），不再向窗口索要一个固定宽度。
            // 这样即使窗口宽度晚了一拍，右侧也只是内容暂时窄一点（需要横滑的页自己去滚动），
            // 绝不会出现「内容比窗口宽、右边被裁掉」——用户 2026-09-23 反馈的
            // 「右上角显示不全」就是右上角工具栏被排到超出窗口的位置后被裁。
            // 面板宽度本身仍由 `panelWidth` → `AppDelegate.applyPanelWidth` 驱动窗口。
            ZStack {
                ForEach(cachedTabs, id: \.self) { tab in
                    tabView(tab)
                        .opacity(tab == selectedTab ? 1 : 0)
                        .allowsHitTesting(tab == selectedTab)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // 单页视图（首次访问后常驻缓存）
    @ViewBuilder
    private func tabView(_ tab: PanelTab) -> some View {
        switch tab {
        // ⚠️ 2026-09-26：这三个页面**不再套外层 ScrollView**。
        //    它们内部自己已经是「工具栏冻结 + ScrollView 滚内容」（§39g），
        //    外面再套一层的话，内层 ScrollView 拿到的是「高度未定」的提议 → 直接撑成内容高度、
        //    自己永远不滚，真正滚动的是外层 → 刚冻结的工具栏又跟着滚走了。
        //    外层顺带提供的 16pt 内边距改由这里的 `.padding(16)` 顶替（观感不变）。
        case .personal:
            PersonalScheduleView()
                .padding(16)
        case .class7:
            ClassScheduleView()
                .padding(16)
        case .teacher:
            TeacherScheduleView()
        case .extend:
            ExtendScheduleView()
                .padding(16)
        case .calendar:
            ChongqingCalendarView()
        case .reminder:
            ReminderSettingsView()
        case .office:
            OfficeLayoutView()
        case .classroom:
            ClassroomMapView()
        case .staff:
            StaffView()
        case .student:
            StudentInfoView()
        case .seating:
            SeatingView()
        }
    }

    // 格式器只创建一次（原先每次渲染都新建，白耗 CPU）
    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "EEE"
        return f
    }()
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f
    }()

    private func weekdayString() -> String {
        Self.weekdayFormatter.string(from: now)
    }

    private func dateString() -> String {
        Self.dateFormatter.string(from: now)
    }
}

// MARK: - 导航条目可编辑标题（双击改名，存 titles.json；清空还原默认名）
struct NavEditableTitle: View {
    let tab: PanelTab
    let isSelected: Bool

    @EnvironmentObject var titles: CardTitleStore
    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var key: String { "nav_\(tab.rawValue)" }

    var body: some View {
        Group {
            if isEditing {
                TextField("", text: $draft)
                    .focused($focused)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .frame(minWidth: 80)
                    .onAppear {
                        draft = titles.title(for: key)
                        DispatchQueue.main.async { focused = true }
                    }
                    .onChange(of: focused) { isFocused in
                        if !isFocused { commit() }
                    }
                    .onSubmit { focused = false }
            } else {
                Text(titles.title(for: key))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { isEditing = true }
                    .help("双击重命名")
            }
        }
    }

    private func commit() {
        isEditing = false
        titles.set(key, draft)
    }
}

// MARK: - 导航拖拽排序代理（可见项之间换位）
struct NavReorderDelegate: DropDelegate {
    let item: PanelTab
    let visible: [PanelTab]
    @Binding var dragged: PanelTab?
    let move: (Int, Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let d = dragged, d != item else { return }
        guard let from = visible.firstIndex(of: d),
              let to = visible.firstIndex(of: item) else { return }
        move(from, to)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragged = nil
        return true
    }
}
