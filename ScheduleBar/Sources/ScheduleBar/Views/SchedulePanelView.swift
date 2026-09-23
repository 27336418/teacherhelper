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

    var body: some View {
        HStack(spacing: 0) {
            // 左侧导航列
            navColumn

            Divider()

            // 右侧内容区
            contentArea
        }
        .frame(width: 880, height: 720)
        .background(FrostedView())
        // 每次切页登记缓存，之后切回不再重建（消除卡顿）
        .onChange(of: selectedTab) { t in
            visitedTabs.insert(t)
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
        }
    }

    // MARK: 左侧导航
    private var navColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题 + 周次胶囊
            HStack {
                Text("教师助手")
                    .font(.title3.bold())
                Spacer()
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
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    BackupService.exportBackup()
                } label: {
                    Label("备份全部数据", systemImage: "archivebox")
                        .frame(maxWidth: .infinity)
                }
                .help("一键导出全部数据与设置（课表/学生/座位/提醒/备注/布局/设置）到备份文件")
                Button {
                    BackupService.importBackup()
                } label: {
                    Label("从备份恢复", systemImage: "arrow.counterclockwise.circle")
                        .frame(maxWidth: .infinity)
                }
                .help("从备份文件一键导入并恢复全部数据与设置（恢复后自动重启生效）")
                Button {
                    AppCoordinator.shared.clearAllData()
                } label: {
                    Label("清空所有数据", systemImage: "trash.slash")
                        .frame(maxWidth: .infinity)
                }
                .foregroundStyle(.red)
                .help("清空全部业务数据（课表/师资/学生/工位/教室/座位/延时监考/提醒），保留表结构，重启生效")
                Button {
                    AppCoordinator.shared.checkForUpdate(manually: true)
                } label: {
                    Label("检查更新", systemImage: "arrow.triangle.2.circlepath.circle")
                        .frame(maxWidth: .infinity)
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
                        .frame(maxWidth: .infinity)
                }
                .foregroundStyle(.red)
                .keyboardShortcut("q", modifiers: [.command])
                .help("退出教师助手 (⌘Q)")
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: 170)
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
            ZStack {
                ForEach(cachedTabs, id: \.self) { tab in
                    tabView(tab)
                        .opacity(tab == selectedTab ? 1 : 0)
                        .allowsHitTesting(tab == selectedTab)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    // 单页视图（首次访问后常驻缓存）
    @ViewBuilder
    private func tabView(_ tab: PanelTab) -> some View {
        switch tab {
        case .personal:
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PersonalScheduleView()
                }
                .padding(16)
            }
        case .class7:
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ClassScheduleView()
                }
                .padding(16)
            }
        case .teacher:
            TeacherScheduleView()
        case .extend:
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ExtendScheduleView()
                }
                .padding(16)
            }
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
