import SwiftUI
import AppKit

// MARK: - 课表单元格唯一标识（行标签/节次 + 列下标）—— 个人课表与 7 班课表共用
struct ScheduleCellID: Hashable {
    let period: String
    let day: Int
}

// MARK: - 课表单元格（个人 & 班级共用）
// 单击 → 选中（同一科目/同一内容的其他格子保持课程色高亮，其余变灰）
// 双击 → 进入编辑模式（可修改文字，边输边存）
struct ScheduleCell: View {
    let text: String
    let width: CGFloat
    let height: CGFloat = 32
    let id: ScheduleCellID
    let color: (String) -> Color
    var extraColors: ((String) -> [Color])? = nil   // 一个格含多个班级时渲染渐变
    let isSelected: Bool
    let isSameContent: Bool  // 与选中格是同一科目/同一内容 → 保持高亮
    let isDimmed: Bool       // 选中了其他内容时，本格变灰
    let isEditing: Bool
    let onSelect: () -> Void
    let onStartEditing: () -> Void
    let onUpdate: (String) -> Void
    let onEndEditing: () -> Void

    @State private var editingText: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if isEditing {
                TextField("", text: $editingText)
                    .focused($focused)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .frame(width: width, height: height)
                    .background(cellBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.accentColor.opacity(0.9), lineWidth: 1.5)
                    )
                    .onChange(of: editingText) { newValue in onUpdate(newValue) }
                    .onAppear {
                        editingText = text
                        DispatchQueue.main.async { focused = true }
                    }
                    .onChange(of: focused) { isFocused in
                        if !isFocused { onEndEditing() }
                    }
                    .onSubmit { focused = false }
            } else {
                Text(text)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .frame(width: width, height: height)
                    .background(cellBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(borderColor,
                                    lineWidth: isSelected ? 1.5 : (isSameContent ? 1.0 : 0.5))
                    )
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { onStartEditing() }
                    .onTapGesture { onSelect() }
            }
        }
    }

    private var fillColor: Color {
        if isDimmed { return Color(hex: 0xAEB6BD).opacity(0.35) }   // 其他内容变灰
        return color(text).opacity(isEmpty(text) ? 0.12 : 0.85)      // 选中格/相同内容保持本色
    }

    /// 单元格底色：单班级用纯色，多班级（如「7/巡16-30」）用左右渐变
    @ViewBuilder
    private var cellBackground: some View {
        let cs = extraColors?(text) ?? []
        if isDimmed || isEmpty(text) || cs.count < 2 {
            RoundedRectangle(cornerRadius: 6).fill(fillColor)
        } else {
            RoundedRectangle(cornerRadius: 6).fill(
                LinearGradient(colors: cs.map { $0.opacity(0.85) },
                               startPoint: .leading, endPoint: .trailing)
            )
        }
    }

    private var borderColor: Color {
        if isSelected { return Color.accentColor.opacity(0.9) }
        if isSameContent { return color(text).opacity(0.8) }          // 相同内容用本色描边
        return Color.primary.opacity(0.08)
    }

    private func isEmpty(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

// MARK: - 全校班级课表卡片（可切换班级 / 设默认班级，按班级着色，支持下载）
struct ClassScheduleView: View {
    @EnvironmentObject var classStore: ClassScheduleStore
    @EnvironmentObject var coordinator: AppCoordinator

    @State private var selected: ScheduleCellID? = nil
    @State private var editing: ScheduleCellID? = nil

    /// 跨天自动刷新（避免过了午夜仍高亮昨天那一列）
    @ObservedObject private var clock = TodayClock.shared
    private var store: ClassScheduleStore { classStore }

    // 与个人课表严格一致：标签 52 + 6×94 + 间距 8×5 = 656，撑满内容区
    private let colWidth: CGFloat = 94

    /// 今天对应的表头列下标（周一~周五→0~4，周日→5；周六无列返回 nil）
    private var todayColumn: Int? { clock.weekdayColumn }
    private let labelWidth: CGFloat = 52
    private let spacing: CGFloat = 8

    /// 选中格的科目名（如 "语文"），用于高亮所有相同科目
    private var selectedCourseKey: String? {
        guard let s = selected else { return nil }
        let text = classStore.cell(s.period, s.day)
        let key = courseKey(text)
        return key.isEmpty ? nil : key
    }

    /// 班级切换下拉
    private var classPicker: some View {
        Menu {
            ForEach(store.classes, id: \.self) { name in
                Button {
                    store.select(name)
                    selected = nil
                    editing = nil
                } label: {
                    if name == store.current {
                        Label(name + (name == store.defaultClass ? "（默认）" : ""), systemImage: "checkmark")
                    } else {
                        Text(name + (name == store.defaultClass ? "（默认）" : ""))
                    }
                }
            }
            if store.classes.isEmpty {
                Text("尚未导入班级")
            }
            Divider()
            Button("新建空班级…") { promptNewClass() }
            if !store.current.isEmpty {
                if store.current != store.defaultClass {
                    Button("把「\(store.current)」设为默认") { store.setDefault() }
                }
                Divider()
                Button(role: .destructive) { confirmDeleteCurrent() } label: {
                    Label("删除「\(store.current)」", systemImage: "trash")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 10))
                Text(store.current.isEmpty ? "选择班级" : store.current)
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 9))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
            .foregroundStyle(Color.accentColor)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("切换班级；可把当前班设为默认，下次打开直接显示")
    }

    /// 删除当前班级（先确认，防误删；⌘Z 可撤销）
    private func confirmDeleteCurrent() {
        let name = store.current
        guard !name.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "删除班级「\(name)」？"
        alert.informativeText = "该班级的课表数据将被清除（可用 ⌘Z 撤销）。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        PanelHelper.prepare()
        PanelHelper.bringFront(alert)
        if alert.runModal() == .alertFirstButtonReturn {
            store.removeCurrent()
            selected = nil
            editing = nil
        }
    }

    /// 新建班级（弹窗输入名称）
    private func promptNewClass() {
        let alert = NSAlert()
        alert.messageText = "新建班级"
        alert.informativeText = "输入班级名称，例如「初3-7」。新建后可直接在表格里填写课表。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "班级名称"
        alert.accessoryView = field
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")
        PanelHelper.prepare()
        PanelHelper.bringFront(alert)
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            store.newClass(named: name.isEmpty ? "新班级" : name)
            selected = nil
            editing = nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                EditableCardTitle(icon: "building.2", key: "class")
                classPicker
                if !store.current.isEmpty && store.current == store.defaultClass {
                    Text("默认")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                        .foregroundStyle(Color.accentColor)
                } else if !store.current.isEmpty {
                    Button("设为默认") { store.setDefault() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .help("设为默认班级：下次打开应用直接显示这个班")
                }
                Spacer()
                UndoButton()
                // 与个人课表风格一致：右上角「导入」下拉 + 「下载」
                Menu {
                    Button("导入课表文件（自动识别：单班 / 全校定稿）") { coordinator.importClassFile() }
                    Divider()
                    Button("下载填写模板（单班）") { coordinator.downloadTemplate(.classSheet) }
                    Button("新建空班级…") { promptNewClass() }
                    if !store.current.isEmpty {
                        Button("把「\(store.current)」设为默认班级") { store.setDefault() }
                        Button("删除「\(store.current)」") { confirmDeleteCurrent() }
                    }
                } label: {
                    Label("导入", systemImage: "square.and.arrow.down")
                }
                Menu {
                    Button("下载「\(store.current.isEmpty ? "当前班级" : store.current)」") { coordinator.exportClass() }
                    Button("下载全校（定稿格式，\(store.classes.count) 个班）") { coordinator.exportWholeSchool() }
                        .disabled(store.classes.isEmpty)
                } label: {
                    Text("下载")
                }
                .fixedSize()
            }

            if store.classes.isEmpty {
                Text("还没有班级数据：点右上角「导入」选择课表文件，会自动识别单班/全校定稿并导入全部班级；也可以「新建空班级」手动填写。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 表头（当前星期列高亮，课表内容不变）
            HStack(spacing: spacing) {
                Text("节次").font(.caption.bold()).frame(width: labelWidth, alignment: .leading)
                ForEach(0..<ClassLayout.days.count, id: \.self) { d in
                    let isToday = d == todayColumn
                    Text(ClassLayout.days[d]).font(.caption.bold())
                        .frame(width: colWidth)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isToday ? Color.accentColor.opacity(0.16) : Color.clear)
                        )
                        .foregroundStyle(isToday ? Color.accentColor : Color.secondary)
                }
            }

            // 按分组动态渲染（组头可添加节次，节次右键删除）
            ForEach(Array(classStore.groups.enumerated()), id: \.element.title) { gIdx, group in
                HStack(spacing: spacing) {
                    Text(group.title).font(.caption.bold())
                        .frame(width: labelWidth, alignment: .leading)
                    Button {
                        classStore.addPeriod(in: gIdx)
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("在此段添加节次")
                    Spacer()
                }
                .padding(.vertical, 2)

                ForEach(Array(group.periods.enumerated()), id: \.element) { _, p in
                    HStack(spacing: spacing) {
                        Text(p).font(.caption)
                            .frame(width: labelWidth, alignment: .trailing)
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button(role: .destructive) {
                                    classStore.removePeriod(p)
                                    selected = nil
                                    editing = nil
                                } label: {
                                    Label("删除此节次", systemImage: "minus.circle")
                                }
                            }
                            .help("右键可删除此节次")
                        ForEach(0..<ClassLayout.days.count, id: \.self) { d in
                            let id = ScheduleCellID(period: p, day: d)
                            let cellText = classStore.cell(p, d)
                            let cellKey = courseKey(cellText)
                            let sameContent = selectedCourseKey != nil && cellKey == selectedCourseKey
                            ScheduleCell(
                                text: cellText,
                                width: colWidth,
                                id: id,
                                color: courseColor,
                                isSelected: selected == id,
                                isSameContent: sameContent,
                                isDimmed: selected != nil && !sameContent,
                                isEditing: editing == id,
                                onSelect: {
                                    editing = nil
                                    if selected == id { selected = nil }
                                    else { selected = id }
                                },
                                onStartEditing: {
                                    editing = id
                                    selected = nil
                                },
                                onUpdate: { classStore.setCell(p, d, $0) },
                                onEndEditing: { editing = nil }
                            )
                            .onDrag {
                                classStore.beginCellDrag(p, d)
                                return NSItemProvider(object: DragPayload.cell(DragPayload.classCell, p, d) as NSString)
                            }
                            .onDrop(of: [.text], delegate: ScheduleCellSwapDelegate(
                                table: DragPayload.classCell,
                                onPerform: { classStore.swapCellTo(p, d) },
                                onFinish: { classStore.finishCellDrag() }
                            ))
                            .help("双击编辑；拖动可与其它格子对换")
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.3)))
    }
}
