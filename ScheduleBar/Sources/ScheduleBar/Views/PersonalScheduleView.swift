import SwiftUI
import Foundation

// MARK: - 班级配色图例项
private struct ClassLegendItem: Identifiable {
    let id = UUID()
    let name: String
    let color: Color
}

// MARK: - 个人课表卡片（与班级课表一致的分组结构：上午 / 下午 / 晚自习，节次可增删）
struct PersonalScheduleView: View {
    @EnvironmentObject var store: ScheduleStore
    @EnvironmentObject var coordinator: AppCoordinator

    /// 明暗主题 —— 只用于给「早自习淡绿底色」挑透明度（见下）
    @Environment(\.colorScheme) private var colorScheme

    @State private var selected: ScheduleCellID? = nil
    @State private var editing: ScheduleCellID? = nil

    // 节次重命名（2.5.24）：双击节次名进入编辑，回车提交、Esc 取消。
    // 只改名字，不动课程内容 —— 存储侧见 `ScheduleStore.renamePeriod(in:at:to:)`。
    @State private var renamingRow: PeriodRowID? = nil
    @State private var renameDraft: String = ""
    @State private var renameGroup: Int = 0
    @State private var renameRowIndex: Int = 0
    @State private var renameKeyMonitor: Any? = nil
    @FocusState private var renameFocused: Bool

    // 与班级课表严格一致：节次标签 52 + n×(列宽 + 间距 8)（n = 可见列数，周六/周日按开关增减）
    //
    // ⚠️ 列宽**不是常量**：2026-09-26 用户要求「显示周六时自动缩小列宽，保证整体没有向右扩展宽度」。
    //    面板内容区恒为 709（课表页不再撑宽面板），所以 7 列时列宽由 94 压到 80，
    //    整表 684 ≤ 689（709 − 20 滚动条余量），一列都不会被切。
    //    6 列以内仍是 94 → 默认视图与旧版像素级一致。
    private var colWidth: CGFloat {
        ScheduleWeek.scheduleColumnWidth(columns: dayPrefs.visibleDayCount)
    }

    /// 跨天自动刷新（避免过了午夜仍高亮昨天那一列）
    @ObservedObject private var clock = TodayClock.shared

    /// 星期列显隐（三张课表共用一份设置）
    @ObservedObject private var dayPrefs = ScheduleDayPrefsStore.shared

    /// 当前可见的星期列下标 —— 数据永远是 7 列，这里只是**渲染层过滤**，隐藏不删数据
    private var visibleDays: [Int] { dayPrefs.visibleDayIndices }

    /// 今天对应的表头列下标（周一~周六→0~5，周日→6）
    private var todayColumn: Int? { clock.weekdayColumn }
    private let labelWidth: CGFloat = 52
    private let spacing: CGFloat = 8

    // MARK: - 非上课时段（早自习）的视觉区分（2026-10-13 用户要求）
    //
    // 用户原话：「早自习和第1节行间距调大一些，早自习加一个淡淡的底色，和上课区分一下」。
    // 早自习不是「课」，混在编号节次里容易看串，所以给它两件事：
    //   ① 一条**淡底色带** —— 2026-10-13 用户先要「淡淡的底色」，随后指定**淡绿色**。
    //      ⚠️ 绿**不在**课程配色里（课程色只有橙 / 蓝 / 紫 / 青），所以不会被误读成某节课；
    //         改色时务必仍避开橙蓝紫青。
    //   ② 它下面**多留一段空白**，把「早自习」和「第1节」在视觉上分开。
    // ⚠️ 只按名字认（默认只有「早自习」）。以后要把「午自习 / 晚自习」也这样处理，往这个集合里加名字即可。
    private static let nonClassPeriods: Set<String> = ["早自习"]
    /// 淡底色带的内边距（上下各留一点，让底色成「一条带」而不是紧贴格子）
    private static let nonClassBandPad: CGFloat = 5
    /// 底色带**之外**再留的底部空白 → 与下一节的总间距 = 本值 + LazyVStack 的 spacing(8)
    private static let nonClassGapBelow: CGFloat = 12
    /// 淡绿底色本身。
    /// 深色主题下同一个透明度会糊成一团、看不出是绿的，所以按主题给两档透明度。
    private var nonClassTint: Color {
        Color.green.opacity(colorScheme == .dark ? 0.22 : 0.16)
    }

    private func isNonClassPeriod(_ label: String) -> Bool {
        Self.nonClassPeriods.contains(label)
    }

    /// 选中格的班级键（"7"/"7班" 都归为 "7班"），用于高亮全表同班级的格子
    private var selectedKey: String? {
        guard let s = selected else { return nil }
        let key = classKey(store.cell(s.period, s.day))
        return key.isEmpty ? nil : key
    }

    /// 底部图例：自动扫描课表中出现过的班级 → 对应颜色
    private var legend: [ClassLegendItem] {
        var map: [String: Color] = [:]
        for row in store.grid {
            for cell in row {
                for t in classTokens(cell) where !t.isEmpty {
                    map[t] = classTokenColor(t)
                }
            }
        }
        return map.sorted { a, b in
            let na = Int(a.0.replacingOccurrences(of: "班", with: "")) ?? Int.max
            let nb = Int(b.0.replacingOccurrences(of: "班", with: "")) ?? Int.max
            return na == nb ? a.0 < b.0 : na < nb
        }
        .map { ClassLegendItem(name: $0.0, color: $0.1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolbarRow

            // ⚠️ 2026-09-26 用户要求「滚动时冻结这些内容」：
            //    ① 工具栏（标题 / 撤销·保存·导入·下载）留在滚动区**外面**，往下翻节次时一直可见；
            //    ② 「节次 / 星期1…周日」表头行用 `pinnedViews: [.sectionHeaders]` 钉在表体顶部。
            //       ⚠️ 表头必须和表体在**同一个**滚动容器里：分开放会因滚动条占用宽度而错位（§39a）。
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(Array(store.groups.enumerated()), id: \.offset) { gIdx, group in
                            HStack(spacing: spacing) {
                                Text(group.title).font(.caption.bold())
                                    .frame(width: labelWidth, alignment: .leading)
                                Button {
                                    store.addPeriod(in: gIdx)
                                } label: {
                                    Image(systemName: "plus.circle")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("在「\(group.title)」添加节次")
                                Spacer()
                            }
                            .padding(.vertical, 2)

                            ForEach((0..<group.periods.count).map { PeriodRowID(group: gIdx, row: $0) },
                                    id: \.self) { key in
                                let label = group.periods[key.row]
                                periodRow(label, group: gIdx, row: key.row)
                                    // 非上课时段（早自习）：淡底色带 + 与下一节拉开距离（见上方常量说明）。
                                    // ⚠️ 底色只加**上下**内边距，不加左右 —— 加左右会把这一行的格子整体推右，
                                    //    和表头 / 其它行的列就对不齐了。
                                    .padding(.vertical, isNonClassPeriod(label) ? Self.nonClassBandPad : 0)
                                    .background {
                                        if isNonClassPeriod(label) {
                                            // ⚠️ 装饰层一律关掉命中测试（本项目铁律）：否则这条带子会盖住
                                            //    格子的拖拽落点 →「有高亮、松手没反应」（2.5.5 踩过一次）。
                                            RoundedRectangle(cornerRadius: 8).fill(nonClassTint)
                                                .allowsHitTesting(false)
                                        }
                                    }
                                    .padding(.bottom, isNonClassPeriod(label) ? Self.nonClassGapBelow : 0)
                            }
                        }

                        // 班级配色图例（不同班级 → 不同颜色）
                        if !legend.isEmpty {
                            HStack(spacing: 10) {
                                Text("班级色").font(.system(size: 10)).foregroundStyle(.secondary)
                                ForEach(legend) { item in
                                    HStack(spacing: 3) {
                                        Circle().fill(item.color).frame(width: 8, height: 8)
                                        Text(item.name).font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                        }
                    } header: {
                        columnHeaderRow
                            .padding(.bottom, 2)
                            .background { FrostedView() }
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.3)))
        // 切走板块时把按键监听摘掉，避免它留在别的页面上抢回车
        .onDisappear { removeRenameKeyMonitor() }
    }

    // MARK: - 顶部工具栏（冻结在滚动区外）
    private var toolbarRow: some View {
        HStack {
            EditableCardTitle(icon: "person.crop.rectangle", key: "personal")
            Spacer()
            WeekVisibilityMenu()
            UndoButton()
            // 与班级课表风格一致：右上角「导入」下拉 + 「下载」
            Menu {
                Button("本人课表") { coordinator.importPersonalFile() }
                Divider()
                Button("下载填写模板") { coordinator.downloadTemplate(.personal) }
            } label: {
                Label("导入", systemImage: "square.and.arrow.down")
            }
            .help("下载模板：先导出空白模板，填写后从这里导入")
            Button("下载") { coordinator.exportPersonal() }
        }
    }

    // MARK: - 表头行（节次 / 星期1…周日，钉在表体顶部）
    private var columnHeaderRow: some View {
        HStack(spacing: spacing) {
            Text("节次").font(.caption.bold()).frame(width: labelWidth, alignment: .leading)
            ForEach(visibleDays, id: \.self) { d in
                let isToday = d == todayColumn
                Text(ScheduleStore.days[d]).font(.caption.bold())
                    .frame(width: colWidth)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isToday ? Color.accentColor.opacity(0.16) : Color.clear)
                    )
                    .foregroundStyle(isToday ? Color.accentColor : Color.secondary)
            }
        }
    }

    // MARK: 一行节次
    private func periodRow(_ p: String, group: Int, row: Int) -> some View {
        HStack(spacing: spacing) {
            periodLabel(p, group: group, row: row)

            ForEach(visibleDays, id: \.self) { d in
                cellView(period: p, day: d)
            }
        }
    }

    /// 节次名（双击改名 / 右键改名、删除）
    @ViewBuilder
    private func periodLabel(_ p: String, group: Int, row: Int) -> some View {
        let key = PeriodRowID(group: group, row: row)
        if renamingRow == key {
            TextField("节次名", text: $renameDraft)
                .textFieldStyle(.plain)
                .font(.caption)
                .multilineTextAlignment(.trailing)
                .frame(width: labelWidth)
                .focused($renameFocused)
                .onSubmit { commitRename(group: group, row: row) }
                .onExitCommand { cancelRename() }
                // 点到别处就当提交，避免留下一个「看着在编辑、其实早没焦点」的错觉
                .onChange(of: renameFocused) { focused in
                    if !focused { commitRename(group: group, row: row) }
                }
        } else {
            Text(p).font(.caption)
                .frame(width: labelWidth, alignment: .trailing)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { beginRename(p, group: group, row: row) }
                .contextMenu {
                    Button {
                        beginRename(p, group: group, row: row)
                    } label: {
                        Label("重命名此节次", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        store.removePeriod(p)
                        selected = nil
                        editing = nil
                    } label: {
                        Label("删除此节次", systemImage: "minus.circle")
                    }
                }
                .help("双击可重命名；右键可重命名或删除")
        }
    }

    private func beginRename(_ p: String, group: Int, row: Int) {
        renameDraft = p
        renameGroup = group
        renameRowIndex = row
        renamingRow = PeriodRowID(group: group, row: row)
        // 先让 TextField 出现在视图里，下一帧再要焦点（同帧设置焦点拿不到）
        DispatchQueue.main.async { renameFocused = true }
        installRenameKeyMonitor()
    }

    /// 回车 / Esc 用**应用级按键监听**兜底。
    /// ⚠️ 面板是非激活浮窗，`@FocusState` 不一定跟着 AppKit 的第一响应者走：
    ///    实测「双击能进编辑、也能粘贴文字，但 Return 不触发 onSubmit」。
    ///    监听 keyDown 直接把这两个键截下来，不依赖 SwiftUI 的焦点状态。
    private func installRenameKeyMonitor() {
        removeRenameKeyMonitor()
        renameKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 36, 76:                       // Return / 小键盘 Enter
                commitRename(group: renameGroup, row: renameRowIndex)
                return nil
            case 53:                           // Esc
                cancelRename()
                return nil
            default:
                return event
            }
        }
    }

    private func removeRenameKeyMonitor() {
        if let m = renameKeyMonitor {
            NSEvent.removeMonitor(m)
            renameKeyMonitor = nil
        }
    }

    /// 正在改名时点了别的格子 → 先把名字提交掉，再继续原来的点击
    private func commitRenamingIfNeeded() {
        guard renamingRow != nil else { return }
        commitRename(group: renameGroup, row: renameRowIndex)
    }

    private func cancelRename() {
        removeRenameKeyMonitor()
        renamingRow = nil
        renameFocused = false
    }

    private func commitRename(group: Int, row: Int) {
        removeRenameKeyMonitor()
        // 无论成没成，都收起输入框 —— 否则失焦时留下了「看着在编辑、其实没焦点」的死状态。
        _ = store.renamePeriod(in: group, at: row, to: renameDraft)
        renamingRow = nil
        renameFocused = false
    }

    // MARK: 单个单元格：不同班级 → 不同颜色
    private func cellView(period: String, day: Int) -> some View {
        let id = ScheduleCellID(period: period, day: day)
        let cellText = store.cell(period, day)
        let sameContent = selectedKey != nil && classKey(cellText) == selectedKey
        return ScheduleCell(
            text: cellText,
            width: colWidth,
            id: id,
            color: classColor,
            isSelected: selected == id,
            isSameContent: sameContent,
            isEditing: editing == id,
            isDimmed: selectedKey != nil,
            onSelect: {
                commitRenamingIfNeeded()
                editing = nil
                if selected == id { selected = nil } else { selected = id }
            },
            onStartEditing: {
                editing = id
                selected = nil
            },
            onUpdate: { store.setCell(period, day, $0) },
            onEndEditing: { editing = nil }
        )
        .onDrag {
            store.beginCellDrag(period, day)
            // 拿起时同步登记来源模块，落点据此同步换位（见 DragSwapSupport.swift 的说明）
            let payload = DragPayload.cell(DragPayload.personalCell, period, day)
            DragContext.begin(module: DragPayload.personalCell, payload: payload)
            return NSItemProvider(object: payload as NSString)
        }
        .onDrop(of: [.text], delegate: ScheduleCellSwapDelegate(
            table: DragPayload.personalCell,
            onPerform: { store.swapCellTo(period, day) },
            onFinish: { store.finishCellDrag() },
            // 兜底：DragContext 被兜底轮询误清时，靠 store 里记着的来源再认一次（见 DragSwapSupport）
            ownsFallback: { store.cellDragSource != nil && DragContext.recentlyActiveDrag }
        ))
        .help("单击：高亮全表同班级，其余格子变灰；再点一次取消。双击编辑；拖动可与其它格子对换")
    }
}
