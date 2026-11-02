import SwiftUI
import Combine

/// 行锚点 id：延时列与监考块共用，供 `ScrollViewReader.scrollTo` 定位「当前周」那一行。
/// 用「块 id + 行下标」而不是「周次」—— 同一块里可能有多行是同一周（数据允许重复），
/// 且周次是用户可编辑文本，随时会变。
private func extRowAnchor(_ blockID: UUID, _ row: Int) -> String {
    "ext-row-\(blockID.uuidString)-\(row)"
}

// MARK: - 延时 & 监考 卡片（延时三天并列，监考块式可编辑）
// 标题支持改名：单击=展开/收起，双击=修改名称，右键=重命名菜单。
// 分组按稳定 kind 标记（delay/exam），改名不影响分组；列主题色按列位置固定，改名不变色。

struct ExtendScheduleView: View {
    @EnvironmentObject var extStore: ExtendScheduleStore
    @EnvironmentObject var weekStore: WeekStore
    @EnvironmentObject var coordinator: AppCoordinator
    @State private var collapsed: Set<UUID> = []

    // MARK: 当前周（2026-11-02 用户报「延时没有自动跳转到当前周并高亮」）
    //
    // 两个独立的毛病，一起修：
    //   ① **不自动跳转** —— 这里原本根本没有 ScrollViewReader，从来没滚过。
    //   ② **高亮滞后** —— 高亮条件是 `周次 == weekStore.currentWeek`，而 `currentWeek`
    //      是从 `Date()` 现算的计算属性，**不发布任何变化**。以前只有别的状态变了
    //      （比如点一下页面）才会重绘一遍、顺带重算出正确值。所以跨天后、或者面板
    //      复用旧页面时，高亮会停在旧的周次上。
    // 现在：观察 `TodayClock`（跨天/唤醒/激活都会发 @Published），并把周次落进 @State，
    //      每次页面变可见都重新取一次 + 滚过去。
    @ObservedObject private var clock = TodayClock.shared
    @State private var currentWeek: Int = WeekStore.shared.currentWeek

    // 面板 880 - 导航 170 - 分隔线 - 外层 padding 16×2 - 卡片 padding 8×2 ≈ 661
    private let cardWidth: CGFloat = 661
    private let trashWidth: CGFloat = 24

    private func toggleBlock(_ id: UUID) {
        if collapsed.contains(id) {
            collapsed.remove(id)
        } else {
            collapsed.insert(id)
        }
    }

    /// 重新取一次「当前是第几周」，并把那一行滚到视野中间。
    private func refreshWeekAndScroll(_ proxy: ScrollViewProxy) {
        let w = weekStore.currentWeek
        if w != currentWeek { currentWeek = w }     // 触发子视图重算 isCurrent（高亮）
        guard let anchor = rowAnchor(forWeek: w) else {
            SaveHub.log("[延时] 进入板块：当前周 \(w)，没有该周的行可跳转")
            return
        }
        SaveHub.log("[延时] 进入板块：当前周 \(w)，滚到行锚点 \(anchor)")
        // 第一枪：页面已经布局过（跨天刷新、从别的板块切回来）→ 立刻生效
        proxy.scrollTo(anchor, anchor: .center)
        // 第二枪：刚从 `isHidden = true` 变可见时页面还没布局、行锚点可能尚未注册 → 等一帧再来一次。
        // ⚠️ 实测：离屏容器（无窗口）里两枪都不产生滚动，真实窗口里两枪都生效 ——
        //    所以 `--selftest-render` 拍不出这个效果，别拿它当「没修好」的证据。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            proxy.scrollTo(anchor, anchor: .center)
        }
    }

    /// 找「第一处周次 == w」的行锚点（延时列与监考块按数据顺序找）。
    private func rowAnchor(forWeek w: Int) -> String? {
        for b in extStore.blocks {
            for r in b.rows.indices {
                let raw = b.rows[r].first?.trimmingCharacters(in: .whitespaces) ?? ""
                if Int(raw) == w { return extRowAnchor(b.id, r) }
            }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbarRow

            // ⚠️ 2026-09-26 用户要求「滚动时冻结这些内容」：
            //    标题行（延时/周日/监考 + 撤销·保存·导入·下载 + 操作提示）留在滚动区**外面**，
            //    只有下面的「延时」多天列与「监考」块滚动。
            // ScrollViewReader：用于「进入本板块就滚到当前周那一行」（2026-11-02 用户要求）。
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // ---- 延时：多天并列，列头置顶冻结，标题可折叠/改名 ----
                        let delayIdx = extStore.blocks.indices.filter { extStore.blocks[$0].kind == "delay" }
                        if !delayIdx.isEmpty {
                            let colWidth = (cardWidth - CGFloat(delayIdx.count - 1) * 6) / CGFloat(delayIdx.count)
                            HStack(alignment: .top, spacing: 6) {
                                ForEach(delayIdx.indices, id: \.self) { j in
                                    let i = delayIdx[j]
                                    DelayColumnView(block: $extStore.blocks[i],
                                                    colWidth: colWidth,
                                                    trashWidth: trashWidth - 6,
                                                    accent: extendDelayPalette[j % extendDelayPalette.count],
                                                    currentWeek: currentWeek,
                                                    isCollapsed: collapsed.contains(extStore.blocks[i].id),
                                                    save: { extStore.scheduleSave() },
                                                    onToggle: { toggleBlock(extStore.blocks[i].id) })
                                        .frame(width: colWidth, alignment: .top)   // 固定等宽列+顶对齐，保证各标题齐平
                                }
                            }
                        }

                        // ---- 监考：块式（可折叠、可改名、可增删行）----
                        let examIdx = extStore.blocks.indices.filter { extStore.blocks[$0].kind == "exam" }
                        ForEach(examIdx, id: \.self) { i in
                            ExtendBlockView(
                                block: $extStore.blocks[i],
                                cardWidth: cardWidth,
                                trashWidth: trashWidth,
                                accent: extendExamAccent,
                                currentWeek: currentWeek,
                                isCollapsed: collapsed.contains(extStore.blocks[i].id),
                                save: { extStore.scheduleSave() },
                                onToggle: { toggleBlock(extStore.blocks[i].id) }
                            )
                        }
                    }
                }
                // 首次创建时也要定位一次
                .onAppear { refreshWeekAndScroll(proxy) }
                // 跨天 / 睡眠唤醒 / App 激活：重新取周次（TodayClock 只在日期真变了时才发布）
                .onChange(of: clock.today) { _ in refreshWeekAndScroll(proxy) }
                // 切回本板块：页面是复用的，onAppear 不会再触发，只能靠这个通知
                .onReceive(NotificationCenter.default.publisher(for: .panelDidBecomeVisible)) { note in
                    guard (note.userInfo?["tab"] as? String) == PanelTab.extend.rawValue else { return }
                    refreshWeekAndScroll(proxy)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.3)))
        // 仅当任一子表折叠状态变化时播放过渡，收起/展开平滑滑动（不顿跳）
        .animation(.easeInOut(duration: 0.18), value: collapsed)
    }

    // MARK: - 顶部工具栏（冻结在滚动区外）
    private var toolbarRow: some View {
        HStack {
            EditableCardTitle(icon: "clock.fill", key: "extend")
            Spacer()
            UndoButton()
            Menu {
                Button("延时&监考") { coordinator.importExtendFile() }
                Divider()
                Button("下载填写模板") { coordinator.downloadTemplate(.extend) }
            } label: {
                Label("导入", systemImage: "square.and.arrow.down")
            }
            .help("导入 xlsx：每段一行「子表, 名称」+ 表头行 + 数据行；名称含「监考」归为监考块，可先下载模板填写")
            Button("下载") { coordinator.exportExtend() }
                .help("下载当前延时&监考数据（xlsx，含所有子表）")
            Text("点击标题可展开/收起，双击标题可改名")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 可改名标题栏（单击=折叠/展开，双击=改名，右键=重命名）
struct BlockTitleBar<Trailing: View>: View {
    let title: String
    let accent: Color
    let isCollapsed: Bool
    let onToggle: () -> Void
    let onRename: (String) -> Void
    @ViewBuilder var trailing: () -> Trailing

    @State private var editing = false
    @State private var draft = ""
    @State private var pendingToggle: DispatchWorkItem?
    @State private var lastTap = Date.distantPast
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.subheadline.bold())
                    .foregroundStyle(accent)
                    .focused($focused)
                    .lineLimit(1)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(accent.opacity(0.18)))
                    .onAppear { draft = title }
                    .onSubmit { commit() }
                    .onChange(of: focused) { isFocused in
                        if !isFocused { commit() }
                    }
            } else {
                HStack {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption.bold())
                        .foregroundStyle(accent)
                    Text(title)
                        .font(.subheadline.bold())
                        .foregroundStyle(accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    trailing()
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(accent.opacity(0.18)))
                .contentShape(Rectangle())
                .onTapGesture { handleTap() }
                .contextMenu {
                    Button {
                        beginEditing()
                    } label: {
                        Label("重命名", systemImage: "pencil")
                    }
                }
                .help("单击展开/收起；双击修改名称")
            }
        }
        .onDisappear { pendingToggle?.cancel(); pendingToggle = nil }
    }

    // 0.25s 挂起窗口区分单击（折叠）与双击（改名）
    private func handleTap() {
        let now = Date()
        if pendingToggle != nil && now.timeIntervalSince(lastTap) < 0.25 {
            pendingToggle?.cancel()
            pendingToggle = nil
            lastTap = .distantPast
            beginEditing()
            return
        }
        lastTap = now
        pendingToggle?.cancel()
        let item = DispatchWorkItem {
            self.pendingToggle = nil
            self.onToggle()
        }
        pendingToggle = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    private func beginEditing() {
        draft = title
        editing = true
        DispatchQueue.main.async { focused = true }
    }

    private func commit() {
        editing = false
        let newTitle = draft.trimmingCharacters(in: .whitespaces)
        if !newTitle.isEmpty && newTitle != title {
            onRename(newTitle)
        }
    }
}

// MARK: - 单天延时列（并列展示，标题可折叠/改名，表头置顶冻结）
struct DelayColumnView: View {
    @Binding var block: ExtendBlock
    @EnvironmentObject var extStore: ExtendScheduleStore
    let colWidth: CGFloat
    let trashWidth: CGFloat
    let accent: Color
    var currentWeek: Int = 1
    var isCollapsed: Bool
    var save: () -> Void
    var onToggle: () -> Void

    private var cellWidth: CGFloat {
        let n = max(block.header.count, 1)
        return (colWidth - 12 - trashWidth) / CGFloat(n)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // 标题（可折叠/改名）
            BlockTitleBar(
                title: block.title,
                accent: accent,
                isCollapsed: isCollapsed,
                onToggle: onToggle,
                onRename: { newTitle in
                    block.title = newTitle
                    save()
                }
            ) {
                EmptyView()
            }

            if !isCollapsed {
                // 表头（置顶冻结，与数据列宽一致）
                HStack(spacing: 2) {
                    ForEach(block.header, id: \.self) { h in
                        Text(h)
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: cellWidth)
                            .foregroundStyle(accent)
                    }
                    Color.clear.frame(width: trashWidth)
                }
                .padding(.horizontal, 1)

                // 数据行（当前周次行整体高亮）
                ForEach(block.rows.indices, id: \.self) { r in
                    let weekNum = Int(block.rows[r].first?.trimmingCharacters(in: .whitespaces) ?? "") ?? -1
                    let isCurrent = weekNum == currentWeek
                    HStack(spacing: 2) {
                        ForEach(block.rows[r].indices, id: \.self) { c in
                            ExtCell(text: $block.rows[r][c], width: cellWidth, height: 26,
                                    emphasized: isCurrent && c == 0,
                                    emphasizedColor: weekAmber,
                                    onCommit: save)
                        }
                        Button {
                            let snap = extStore.blocks
                            block.rows.remove(at: r)
                            save()
                            UndoService.shared.register("删除「\(block.title)」行") {
                                extStore.blocks = snap
                                extStore.scheduleSave()
                            }
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .frame(width: trashWidth)
                        .help("删除此行")
                    }
                    .padding(.horizontal, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isCurrent ? weekRowYellow.opacity(0.85)
                                            : Color.clear)
                    )
                    .id(extRowAnchor(block.id, r))      // 行锚点：供「滚到当前周」定位
                }

                // 添加行
                Button {
                    block.rows.append(Array(repeating: "", count: block.header.count))
                } label: {
                    Label("添加一行", systemImage: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
                .padding(.leading, 1)
            }
        }
        .fixedSize(horizontal: false, vertical: true)   // 内容永远取理想高度，防止被拉伸后间隙摊开
        .frame(maxHeight: .infinity, alignment: .top)   // 若列被拉成等高，内容钉在顶部，空隙留到底部
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(accent.opacity(0.06)))                // 整列淡色底，区分各天
    }
}

// MARK: - 单个子表（可编辑、可增删行、可折叠/改名）—— 用于监考
struct ExtendBlockView: View {
    @Binding var block: ExtendBlock
    @EnvironmentObject var extStore: ExtendScheduleStore
    let cardWidth: CGFloat
    let trashWidth: CGFloat
    let accent: Color
    var currentWeek: Int = 1
    var isCollapsed: Bool
    var save: () -> Void
    var onToggle: () -> Void

    private var colWidth: CGFloat {
        let n = max(block.header.count, 1)
        return (cardWidth - 12 - trashWidth) / CGFloat(n)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 标题栏（可折叠/改名）
            BlockTitleBar(
                title: block.title,
                accent: accent,
                isCollapsed: isCollapsed,
                onToggle: onToggle,
                onRename: { newTitle in
                    block.title = newTitle
                    save()
                }
            ) {
                Text("\(block.rows.count) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !isCollapsed {
                // 表头
                HStack(spacing: 2) {
                    ForEach(block.header, id: \.self) { h in
                        Text(h)
                            .font(.caption.bold())
                            .frame(width: colWidth)
                            .padding(.vertical, 4)
                            .foregroundStyle(.secondary)
                    }
                    Color.clear.frame(width: trashWidth)
                }
                .padding(.horizontal, 2)

                // 数据行（当前周次行整体高亮）
                ForEach(block.rows.indices, id: \.self) { r in
                    let weekNum = Int(block.rows[r].first?.trimmingCharacters(in: .whitespaces) ?? "") ?? -1
                    let isCurrent = weekNum == currentWeek
                    HStack(spacing: 2) {
                        ForEach(block.rows[r].indices, id: \.self) { c in
                            ExtCell(text: $block.rows[r][c], width: colWidth,
                                    emphasized: isCurrent && c == 0,
                                    emphasizedColor: weekAmber,
                                    onCommit: save)
                        }
                        Button {
                            let snap = extStore.blocks
                            block.rows.remove(at: r)
                            save()
                            UndoService.shared.register("删除「\(block.title)」行") {
                                extStore.blocks = snap
                                extStore.scheduleSave()
                            }
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .frame(width: trashWidth)
                        .help("删除此行")
                    }
                    .padding(.horizontal, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isCurrent ? weekRowYellow.opacity(0.85)
                                            : Color.clear)
                    )
                    .id(extRowAnchor(block.id, r))      // 行锚点：供「滚到当前周」定位
                }

                // 添加行
                Button {
                    block.rows.append(Array(repeating: "", count: block.header.count))
                } label: {
                    Label("添加一行", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
                .padding(.leading, 2)
            }
        }
        .fixedSize(horizontal: false, vertical: true)   // 防止监考块被拉伸导致间隙摊开
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - 子表单元格（轻量可编辑文本）
struct ExtCell: View {
    @Binding var text: String
    var width: CGFloat = 96
    var height: CGFloat = 26
    var emphasized: Bool = false      // 当前周数字列：加粗 + 高亮色
    var emphasizedColor: Color = .accentColor
    var onCommit: () -> Void = {}

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(.system(size: 12, weight: emphasized ? .bold : .regular))
            .foregroundStyle(emphasized ? emphasizedColor : Color.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)    // 长文本自动缩小保证完整显示
            .frame(width: width, height: height)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(emphasized ? weekRowYellow.opacity(0.9)
                                     : Color.primary.opacity(0.01))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(emphasized ? weekAmber.opacity(0.8)
                                       : Color.primary.opacity(0.08),
                            lineWidth: emphasized ? 1.2 : 0.5)
            )
            .onChange(of: text) { _ in onCommit() }
    }
}
