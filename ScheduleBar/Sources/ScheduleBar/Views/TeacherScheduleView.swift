import SwiftUI
import AppKit   // NSApp.currentEvent（单击/双击用 clickCount 区分）

// MARK: - 他人课表（查询 / 导入 / 模板）
//
// 学校发来的「课表定稿（长表）」按教师导入后，这里可以按姓名模糊查询，
// 选中一位教师就看到他这一周的课（13 节 × 周一~周天）。
// 单元格也可双击直接改（与其它板块一致，改动可撤销）。

struct TeacherScheduleView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @ObservedObject private var store = TeacherScheduleStore.shared

    @State private var keyword = ""
    @State private var appliedKeyword = ""      // 去抖后的关键字
    @State private var searchWork: DispatchWorkItem?
    @State private var selectedID: UUID?
    /// 单击选中的格子（行=节次下标，列=周一~周天）。选中后全表「同内容」格子一起高亮，
    /// 其余格子转灰 —— 与「班级课表」`ScheduleCell` 完全同一套观感。
    @State private var selectedCell: (row: Int, col: Int)?

    // 网格尺寸：内容区 709（面板 880 − 侧栏 170 − 分隔 1）
    //         − 页面内边距 32（`.padding(16)`）− 卡片内边距 20（`.padding(10)`）− 滚动条余量 20 = 637
    // 6 列以内：50 + 6×91 = 596 放得下 → 保持 85（与旧版一致，零回归）
    // 7 列全开：50 + 7×91 = 687 **放不下**（旧版会顶破、最后一列被切）
    //           → 列宽自动压到 77（2026-09-26 用户要求「不往右扩宽、自动缩小列宽」）
    private let periodWidth: CGFloat = 50
    private var cellWidth: CGFloat {
        ScheduleWeek.teacherColumnWidth(columns: dayPrefs.visibleDayCount)
    }
    private let cellHeight: CGFloat = 38
    private let gap: CGFloat = 6

    /// 星期列显隐（三张课表共用一份设置）
    @ObservedObject private var dayPrefs = ScheduleDayPrefsStore.shared

    /// 当前可见的星期列下标 —— 数据永远是 7 列（周一~周五 / 周六 / 周天），
    /// 这里只是**渲染层过滤**，隐藏不会删掉任何一节课。
    private var visibleDays: [Int] { dayPrefs.visibleDayIndices }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbar

            // ⚠️ 2026-09-26 用户要求「滚动时冻结这些内容」：
            //    顶部两行工具栏（标题 / 撤销·保存·新建 + 导入·下载·查询·下拉·徽标）留在滚动区**外面**，
            //    往下翻课表时一直看得见；只有「命中姓名芯片 + 一周课表」滚动。
            //    ⚠️ 课表的表头（节次 / 周一…周天）靠 `grid` 里 LazyVStack 的 pinnedViews 钉住，
            //       它必须待在这个 ScrollView **里面**才钉得动 —— 别再把 grid 挪到滚动区外。
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // 只在「查询到人」时才列姓名 —— 不做「全部教师」大列表
                    // （286 个名字铺开既占地方又难找，查询/下拉两条路足够）
                    if !trimmedKeyword.isEmpty {
                        if hitList.isEmpty {
                            noResult
                        } else {
                            teacherChips
                        }
                    }
                    if let block = selectedBlock {
                        scheduleCard(block)
                    } else {
                        hint
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        // 打开板块先摆上「升序第一位教师」的课表（不空着），换人时清掉格子高亮
        .onAppear { showFirstTeacherIfNeeded() }
        .onChange(of: appliedKeyword) { _ in selectIfNeeded() }
        .onChange(of: selectedID) { _ in selectedCell = nil }
    }

    // MARK: 顶部工具栏（两行；与「教师工位」保持同一版式）
    private var toolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                EditableCardTitle(icon: "tablecells", key: "teacher")
                Spacer(minLength: 8)
                WeekVisibilityMenu()
                UndoButton()
                SaveButton()
                Button {
                    store.addTeacher()
                    selectedID = store.teachers.last?.id
                } label: {
                    Label("新建教师", systemImage: "plus")
                }
                .fixedSize()
                .help("手工新增一位教师（13 节空表），可逐格填写")
            }

            HStack(spacing: 8) {
                Menu {
                    Button("导入 xlsx") { coordinator.importTeacherSchedules() }
                    Button("下载填写模板") { coordinator.downloadTemplate(.teacher) }
                } label: {
                    Label("导入", systemImage: "square.and.arrow.down")
                }
                .fixedSize()
                .help("导入他人课表长表：姓名 | 节次 | 周一…周天，单元格写「班级 科目」；可先下载模板")
                Button("下载") { coordinator.exportTeacher() }
                    .fixedSize()
                    .help("把当前他人课表导出成 xlsx（长表格式，与模板一致）")

                searchField
                teacherPicker
                badge
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("输入教师姓名查找（支持模糊，包含即可）", text: $keyword)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onChange(of: keyword) { v in
                    searchWork?.cancel()
                    let w = DispatchWorkItem { appliedKeyword = v }
                    searchWork = w
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
                }
            if !keyword.isEmpty {
                Button {
                    keyword = ""
                    appliedKeyword = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清空查询")
            }
            if !trimmedKeyword.isEmpty {
                Text("找到 \(hitList.count) 位")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        .frame(minWidth: 150, maxWidth: .infinity)
    }

    // MARK: 下拉单选（全部教师，按姓名升序）
    // 与搜索框两条路都通向「选中某位教师」：搜索适合只记得一个字，
    // 下拉适合想直接顺着名单挑人。
    private var teacherPicker: some View {
        Menu {
            if sortedTeachers.isEmpty {
                Text("还没有教师数据")
            } else {
                ForEach(sortedTeachers) { b in
                    Button {
                        choose(b.id)
                    } label: {
                        if b.id == selectedID {
                            Label(b.teacher, systemImage: "checkmark")
                        } else {
                            Text(b.teacher)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 11))
                Text(selectedBlock?.teacher ?? "选择教师")
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(width: 138, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("下拉单选：列出全部教师（按姓名升序），选一位直接看他的课表")
    }

    private var badge: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.text.rectangle")
                .foregroundStyle(.secondary)
            Text("共 \(store.teacherCount) 位教师 · \(store.lessonCount) 节课")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        .fixedSize()
    }

    // MARK: 命中的教师（横向铺开，点一下看他的课表）
    private var teacherChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("查询结果 \(hitList.count) 位")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(hitList.count > 1 ? "（点姓名切换）" : "")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    if #available(macOS 13.0, *) {
                        // 内容宽度排布：成对姓名（如「张晓晓/楚皓」）不会被省略号截断
                        ChipFlow(spacing: 6, lineSpacing: 6) { chips }
                            .padding(.vertical, 1)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 6)],
                                  alignment: .leading, spacing: 6) { chips }
                            .padding(.vertical, 1)
                    }
                }
                .frame(maxHeight: 132)
                // ⚠️ 不显式回顶时，这个内嵌 ScrollView 的初始位置会随机落在名单中间
                //    （LazyVGrid 高度是懒算的），看着像「打开就跳到了 L 开头」。
                .onAppear { scrollToTop(proxy) }
                .onChange(of: appliedKeyword) { _ in scrollToTop(proxy) }
                .onChange(of: hitList.count) { _ in scrollToTop(proxy) }
            }
        }
    }

    @ViewBuilder
    private var chips: some View {
        ForEach(hitList) { block in
            teacherChip(block).id(block.id)
        }
    }

    private func teacherChip(_ block: TeacherBlock) -> some View {
        let on = block.id == selectedID
        return Button {
            selectedID = block.id
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.fill")
                    .font(.system(size: 9))
                Text(block.teacher)
                    .font(.system(size: 11, weight: on ? .semibold : .regular))
                    .fixedSize()
                Spacer(minLength: 0)
                if on {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(on ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(on ? Color.accentColor.opacity(0.8) : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("查看「\(block.teacher)」的课表（\(block.lessonCount) 节课）")
    }

    // MARK: 单个教师的课表
    private func scheduleCard(_ block: TeacherBlock) -> some View {
        let index = store.index(of: block.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.rectangle")
                    .foregroundStyle(.secondary)
                TeacherNameField(
                    name: block.teacher,
                    onCommit: { store.renameTeacher(block.id, to: $0) }
                )
                Text("\(block.lessonCount) 节课")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                Spacer(minLength: 0)
                Menu {
                    Button("重命名…") { /* 双击姓名即可改名，这里只作提示 */ }
                        .disabled(true)
                    Button(role: .destructive) {
                        store.removeTeacher(block.id)
                        if selectedID == block.id { selectedID = nil }
                    } label: {
                        Label("删除这位教师", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("教师操作")
            }

            grid(block, index: index)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
    }

    /// 表头：节次 / 周一…周天（钉在课表顶部，见 `grid` 里的 pinnedViews）
    private var gridHeader: some View {
        HStack(spacing: gap) {
            Text("节次")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: periodWidth, height: 24)
            ForEach(visibleDays, id: \.self) { d in
                Text(TeacherBlock.days[d])
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: cellWidth, height: 24)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
            }
        }
    }

    private func grid(_ block: TeacherBlock, index: Int?) -> some View {
        // ⚠️ 表头钉在顶部（2026-09-26 用户要求「上下滑动时保持最上面的…固定置顶冻结」）：
        //    往下看后面的节次时，「节次 / 周一…周天」一直可见，不用来回滚。
        //    钉住的表头必须自带不透明背景，否则课表行会从它后面透出来。
        LazyVStack(alignment: .leading, spacing: gap, pinnedViews: [.sectionHeaders]) {
            Section {
                ForEach(Array(block.periods.enumerated()), id: \.offset) { row, period in
                    HStack(spacing: gap) {
                        Text(period)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(width: periodWidth, height: cellHeight)
                        ForEach(visibleDays, id: \.self) { col in
                            let cellText = block.cells[row][col]
                            let key = cellText.trimmingCharacters(in: .whitespacesAndNewlines)
                            TeacherCell(
                                text: cellText,
                                width: cellWidth,
                                height: cellHeight,
                                isSelected: selectedCell?.row == row && selectedCell?.col == col,
                                isSameContent: highlightKey != nil && !key.isEmpty && key == highlightKey,
                                isDimmed: highlightKey != nil,
                                onSelect: { toggleSelect(row: row, col: col) },
                                onCommit: { store.setCell(blockID: block.id, row: row, col: col, text: $0) }
                            )
                        }
                    }
                }
            } header: {
                gridHeader
                    .padding(.vertical, 2)
                    .background { FrostedView() }
            }
        }
    }

    private var noResult: some View {
        VStack(spacing: 6) {
            Image(systemName: "person.fill.questionmark")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("没找到含「\(trimmedKeyword)」的教师")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("换个字试试，比如只输姓氏；也可以点「导入」把课表长表导进来")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
    }

    private var hint: some View {
        VStack(spacing: 6) {
            Image(systemName: "hand.point.up.left")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(store.teacherCount == 0 ? "还没有他人课表数据" : "选一位教师，查看他这一周的课")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(store.teacherCount == 0
                 ? "点「导入 → 下载填写模板」填好后再导入，或直接导入学校给的课表长表"
                 : "用上面的下拉列表选人，或在搜索框里输入姓名（支持模糊匹配）")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
    }

    // MARK: 辅助
    private var trimmedKeyword: String {
        appliedKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 标签区与下拉统一用 store 的升序结果（中文按拼音），找人不费眼
    private var hitList: [TeacherBlock] {
        store.search(appliedKeyword)
    }

    /// 下拉列表用的顺序：按姓名升序（中文按拼音，用 localizedStandardCompare）
    private var sortedTeachers: [TeacherBlock] {
        store.sortedByName
    }

    /// 把教师列表滚回最上面（首项对齐顶部）
    private func scrollToTop(_ proxy: ScrollViewProxy) {
        guard let first = hitList.first else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(first.id, anchor: .top)
        }
    }

    /// 下拉里选了一位：选中他，并清掉搜索词 —— 否则标签区被搜索过滤后看不到这个人
    private func choose(_ id: UUID) {
        searchWork?.cancel()
        keyword = ""
        appliedKeyword = ""
        selectedID = id
    }

    private var selectedBlock: TeacherBlock? {
        selectedID.flatMap { store.teacher($0) }
    }

    /// 查询结果变了之后，把选中项落到结果里的第一个（避免「选中的人被过滤掉了」）
    private func selectIfNeeded() {
        let list = hitList
        if let id = selectedID, list.contains(where: { $0.id == id }) { return }
        selectedID = list.first?.id
    }

    // MARK: 单击选中（同内容一起高亮，其余转灰）

    /// 高亮键 = 被点中那格的文本。同一位教师里，同一个「班级 科目」串就是「同内容」→ 全表一起亮。
    /// 空格子不参与高亮（返回 nil：整表既不转灰也不高亮）。
    private var highlightKey: String? {
        guard let sc = selectedCell, let b = selectedBlock,
              b.cells.indices.contains(sc.row),
              b.cells[sc.row].indices.contains(sc.col) else { return nil }
        let t = b.cells[sc.row][sc.col].trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// 再点同一格 = 取消高亮（与「班级课表」一致）
    private func toggleSelect(row: Int, col: Int) {
        if selectedCell?.row == row, selectedCell?.col == col {
            selectedCell = nil
        } else {
            selectedCell = (row, col)
        }
    }

    /// 打开这个板块时默认摆上「升序第一位教师」的课表 —— 不空着
    /// （用户 2026-09-21 指定：默认显示排序的第一个老师的课表）。
    /// 已经在看某位教师时不打扰，只有「没选中 / 选中的人已被删掉」才兜底。
    private func showFirstTeacherIfNeeded() {
        if let id = selectedID, store.teacher(id) != nil { return }
        selectedID = store.sortedByName.first?.id
    }
}

// MARK: - 教师姓名（双击改名）
private struct TeacherNameField: View {
    let name: String
    let onCommit: (String) -> Void

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("", text: $draft)
                    .focused($focused)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .frame(width: 160)
                    .onAppear {
                        draft = name
                        DispatchQueue.main.async { focused = true }
                    }
                    .onChange(of: focused) { f in if !f { commit() } }
                    .onSubmit { focused = false }
            } else {
                Text(name)
                    .font(.headline)
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { editing = true }
                    .help("双击重命名这位教师（成对写法如「刘娇/尹海燕」原样保留）")
            }
        }
    }

    private func commit() {
        editing = false
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty, t != name { onCommit(t) }
    }
}

// MARK: - 课表格子（显示「班级 + 科目」两行；双击可改）
private struct TeacherCell: View {
    let text: String
    let width: CGFloat
    let height: CGFloat
    /// 单击选中态：这一格就是被点中的那格（描边更粗更实）
    var isSelected: Bool = false
    /// 与被点中的那格「同内容」（这里就是同一个「班级 科目」串）→ 跟着一起高亮
    var isSameContent: Bool = false
    /// 整表高亮态：点了某一格时为 true —— 命中的格子淡红高亮，**其余格子统一退回默认灰**。
    /// 与「班级课表」`ScheduleCell`、「年级师资」`EditableGridCell` 同一套观感（用户 2026-09-21 指定）。
    var isDimmed: Bool = false
    var highlightColor: Color = .red
    let onSelect: () -> Void
    let onCommit: (String) -> Void

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var parts: (room: String, subject: String) { TeacherBlock.split(text) }

    var body: some View {
        Group {
            if editing {
                TextField("", text: $draft)
                    .focused($focused)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .frame(width: width, height: height)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.accentColor.opacity(0.9), lineWidth: 1.5))
                    .onAppear {
                        draft = text
                        DispatchQueue.main.async { focused = true }
                    }
                    .onChange(of: focused) { f in if !f { commit() } }
                    .onSubmit { focused = false }
            } else {
                display
                    .contentShape(Rectangle())
                    // ⚠️ 单击/双击必须合到一个手势里，靠系统 clickCount 区分（与班级课表 `ScheduleCell` 同款）。
                    //    两个 onTapGesture 叠在同一视图上时，单击总是先赢，双击永远进不去编辑态。
                    .onTapGesture {
                        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { editing = true }
                        else { onSelect() }
                    }
                    .help(text.isEmpty
                          ? "单击：选中（同内容的格子一起高亮，其余转灰）；双击：填写这节课，写「班级 科目」，如 初一-18 数学"
                          : "\(parts.room) \(parts.subject)｜单击高亮同内容，双击修改")
            }
        }
    }

    private var display: some View {
        let p = parts
        return VStack(spacing: 0) {
            if !p.room.isEmpty {
                Text(p.room)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            if !p.subject.isEmpty {
                Text(p.subject)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(subjectColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(width: width, height: height)
        .background(RoundedRectangle(cornerRadius: 5).fill(fillColor))
        // 「同内容」标记：叠一层淡红底（0.30，与「年级师资」「班级课表」同款），描边走 borderColor。
        // 底色此时已经是灰的，不会再和科目色打架，所以不需要那圈「内侧白隔离环」。
        .overlay {
            if isSelected || isSameContent {
                RoundedRectangle(cornerRadius: 5).fill(highlightColor.opacity(0.30))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 5)
            .stroke(borderColor, lineWidth: borderWidth))
    }

    /// 科目配色（display 与底色共用）
    private var tint: Color? { TeacherBlock.subjectColor(parts.subject) }

    /// 科目文字色：命中格保持科目色（红/蓝…），高亮态下的**非命中格连文字一起转灰** ——
    /// 否则满屏红色「政治」压着灰底，看着像没高亮（2026-09-21 实机调过）。
    private var subjectColor: Color {
        if isDimmed && !isSelected && !isSameContent { return Color.secondary }
        return tint ?? Color.primary
    }

    private var isEmptyText: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }

    /// 与「年级师资」`EditableGridCell` / 「班级课表」`ScheduleCell` 严格一致的转灰底。
    /// ⚠️ 不能再压暗 —— 整表转灰时压暗会让课表看上去像没上色。
    private static let dimFill = Color.gray.opacity(0.20)

    /// 底色：点了某一格 → 非命中格统一转灰；平时按科目着色（空格子只留极浅灰）
    private var fillColor: Color {
        if isDimmed { return Self.dimFill }
        return isEmptyText ? Color.primary.opacity(0.03)
                           : (tint?.opacity(0.13) ?? Color.primary.opacity(0.07))
    }

    /// 描边：命中的格子红描边（被点中的那格更粗更实）
    private var borderColor: Color {
        if isSelected { return highlightColor.opacity(0.95) }
        if isSameContent { return highlightColor.opacity(0.75) }
        return Color.primary.opacity(isEmptyText ? 0.06 : 0.12)
    }

    private var borderWidth: CGFloat {
        if isSelected { return 2 }
        if isSameContent { return 1.5 }
        return 0.5
    }

    private func commit() {
        editing = false
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if t != text { onCommit(t) }
    }
}

// MARK: - 流式布局（姓名标签按内容宽度排，放不下就换行）
// ⚠️ LazyVGrid 的 .adaptive 是「等宽列」：成对姓名（「张晓晓/楚皓」6 字）会超出列宽被
//    截成「张晓…楚皓」。这里按每个子视图的「理想宽度」排布，长名也能完整显示。
@available(macOS 13.0, *)
private struct ChipFlow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxW {
                widest = max(widest, x - spacing)
                x = 0
                y += lineH + lineSpacing
                lineH = 0
            }
            x += size.width + spacing
            lineH = max(lineH, size.height)
        }
        widest = max(widest, x - spacing)
        return CGSize(width: min(widest, maxW), height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineH + lineSpacing
                lineH = 0
            }
            s.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineH = max(lineH, size.height)
        }
    }
}
