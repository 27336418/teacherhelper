import SwiftUI

// MARK: - 延时 & 监考 卡片（延时三天并列，监考块式可编辑）
// 标题支持改名：单击=展开/收起，双击=修改名称，右键=重命名菜单。
// 分组按稳定 kind 标记（delay/exam），改名不影响分组；列主题色按列位置固定，改名不变色。

struct ExtendScheduleView: View {
    @EnvironmentObject var extStore: ExtendScheduleStore
    @EnvironmentObject var weekStore: WeekStore
    @EnvironmentObject var coordinator: AppCoordinator
    @State private var collapsed: Set<UUID> = []

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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbarRow

            // ⚠️ 2026-09-26 用户要求「滚动时冻结这些内容」：
            //    标题行（延时/周日/监考 + 撤销·保存·导入·下载 + 操作提示）留在滚动区**外面**，
            //    只有下面的「延时」多天列与「监考」块滚动。
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
                                                currentWeek: weekStore.currentWeek,
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
                            currentWeek: weekStore.currentWeek,
                            isCollapsed: collapsed.contains(extStore.blocks[i].id),
                            save: { extStore.scheduleSave() },
                            onToggle: { toggleBlock(extStore.blocks[i].id) }
                        )
                    }
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
            SaveButton()
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
