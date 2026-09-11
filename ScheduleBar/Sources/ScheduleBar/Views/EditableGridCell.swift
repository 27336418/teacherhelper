import SwiftUI

// MARK: - 通用右键调色板菜单（教室/工位/校历单日换色共用）
// current = 当前 hex（nil=默认）；onPick 回传选中的 hex（nil=恢复默认）
struct ColorPaletteMenu: View {
    let current: String?
    let onPick: (String?) -> Void

    var body: some View {
        Text("自定义颜色")
        ForEach(ClassroomStore.palette, id: \.hex) { item in
            Button {
                onPick(item.hex)
            } label: {
                HStack {
                    Circle()
                        .fill(item.hex.map { Color(hexString: $0) } ?? Color.primary.opacity(0.2))
                        .frame(width: 12, height: 12)
                    Text(item.name)
                    Spacer()
                    if current == item.hex || (item.hex == nil && current == nil) {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
    }
}

// MARK: - 通用可编辑单元格（工位/教室/师资共用）
// 双击进入编辑（参考课表效果），回车/失焦保存；空文本保留占位底色。
struct EditableGridCell: View {
    @Binding var text: String
    var width: CGFloat
    var height: CGFloat = 30
    var font: Font = .system(size: 12)
    var bold: Bool = false
    var tint: Color = .accentColor          // 编辑态描边色
    var backgroundColor: Color? = nil       // 自定义底色（教室颜色等）；nil=默认
    var textColor: Color? = nil             // 显示态文字色（校验红/绿等）；nil=默认
    var onSave: () -> Void = {}

    /// 外部接管编辑态（座位表用）：传入后不再自己判定双击，改由 onTap 回调决定。
    /// 好处：单击可立即响应，不必等系统判定「是不是双击」而延迟。
    var externalEditing: Binding<Bool>? = nil
    /// 显示态被单击时回调（仅在接管编辑态时使用）
    var onTap: (() -> Void)? = nil

    @State private var editingInternal = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var editing: Bool { externalEditing?.wrappedValue ?? editingInternal }

    var body: some View {
        Group {
            if editing {
                TextField("", text: $draft)
                    .focused($focused)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(font)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: width, height: height)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(backgroundColor ?? Color.primary.opacity(0.01)))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(tint.opacity(0.9), lineWidth: 1.5))
                    .onAppear {
                        draft = text
                        DispatchQueue.main.async { focused = true }
                    }
                    .onChange(of: focused) { isFocused in
                        if !isFocused { commit() }
                    }
                    .onSubmit { focused = false }
            } else {
                displayCell
            }
        }
    }

    /// 显示态：接管编辑态时只挂「单击」手势（点击即响应，无判定延迟）；
    /// 未接管时保持原「双击进入编辑」。
    @ViewBuilder
    private var displayCell: some View {
        let base = Text(text.isEmpty ? " " : text)
            .font(bold ? font.weight(.semibold) : font)
            .foregroundStyle(text.isEmpty ? Color.clear : (textColor ?? Color.primary))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: width, height: height)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(backgroundColor ?? Color.primary.opacity(0.01)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
            .contentShape(Rectangle())

        if externalEditing != nil {
            // 单击立即响应（无双击判定延迟）；双击进入编辑。
            // 单/双击都挂在同一视图上，避免父子手势竞争导致的单击滞后。
            base.onTapGesture { onTap?() }
                .onTapGesture(count: 2) { externalEditing?.wrappedValue = true }
        } else {
            base.onTapGesture(count: 2) { editingInternal = true }
        }
    }

    private func commit() {
        text = draft
        if let ext = externalEditing { ext.wrappedValue = false } else { editingInternal = false }
        onSave()
    }
}

// MARK: - 可排序表头单元格（学生信息 / 师资安排共用）
// 单击 = 排序（在升序↔降序↔原顺序间由外部 onToggleSort 决定）；
// 双击 = 重命名；右键菜单可重命名 / 删除（关键列只提示不可改）。
// 为避免单击与双击冲突，采用 0.25s 窗口判定：第一次点击先挂起，若 0.25s 内出现第二次点击则视为双击改名，否则执行排序。
struct SortableHeaderCell: View {
    let title: String
    let width: CGFloat
    var height: CGFloat = 26
    var hPadding: CGFloat = 5            // 标题左右内边距（列窄时可减小，避免文字被压缩）
    var iconSize: CGFloat = 8            // 排序箭头字号
    let isSorted: Bool
    let ascending: Bool
    var isSortable: Bool = true                // false = 该列不参与排序（不显示箭头、单击不排序）
    var onToggleSort: () -> Void
    var onRename: ((String) -> Void)? = nil    // nil = 不支持改名（如锁定的「班级」）
    var onDelete: (() -> Void)? = nil          // nil = 不显示删除（关键列等）
    var lockedNote: String? = nil              // 关键列：右键显示该提示并禁用改名/删除

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool
    @State private var pendingSort: DispatchWorkItem?
    @State private var lastTap = Date.distantPast

    var body: some View {
        Group {
            if editing {
                renameField
            } else {
                interactiveArea
            }
        }
        .onDisappear { pendingSort?.cancel(); pendingSort = nil }
    }

    /// 可排序列：单击排序 / 双击改名（含当前正被排序的列，便于循环取消）；
    /// 不可排序列：单击无效，双击改名（若有改名权限），右键菜单仍可用。
    @ViewBuilder
    private var interactiveArea: some View {
        if isSortable || isSorted {
            displayArea
                .contentShape(Rectangle())
                .onTapGesture { handleTap() }
                .contextMenu { contextItems }
                .help(isSorted ? "再点一次切换升/降序；双击改名" : "点击按此列排序；双击改名")
        } else {
            displayArea
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    if onRename != nil { beginRename() }
                }
                .contextMenu { contextItems }
                .help("不可排序；双击改名")
        }
    }

    // MARK: 显示态：标题 + 排序箭头（高亮当前排序列；不可排序列不显示箭头）
    // 标题优先占满可用宽度：箭头固定小尺寸，文字不足时才按 minimumScaleFactor 轻微缩放
    private var displayArea: some View {
        HStack(spacing: 2) {
            Text(title.isEmpty ? " " : title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 1)
            if isSortable || isSorted {
                Image(systemName: sortIcon)
                    .font(.system(size: iconSize, weight: .bold))
                    .foregroundStyle(isSorted ? Color.accentColor : Color.secondary.opacity(0.45))
                    .layoutPriority(1)
            }
        }
        .padding(.horizontal, hPadding)
        .frame(width: width, height: height)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(isSorted ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .stroke(Color.accentColor.opacity(isSorted ? 0.45 : 0.08), lineWidth: isSorted ? 1 : 0.5))
    }

    private var sortIcon: String {
        if isSorted { return ascending ? "arrow.up" : "arrow.down" }
        return "arrow.up.arrow.down"
    }

    // MARK: 单击 / 双击判定
    private func handleTap() {
        let now = Date()
        if pendingSort != nil && now.timeIntervalSince(lastTap) < 0.25 {
            // 双击 → 取消挂起的排序，进入改名
            pendingSort?.cancel()
            pendingSort = nil
            lastTap = .distantPast
            beginRename()
            return
        }
        lastTap = now
        pendingSort?.cancel()
        let item = DispatchWorkItem {
            self.pendingSort = nil
            self.onToggleSort()
        }
        pendingSort = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    // MARK: 改名
    private func beginRename() {
        guard onRename != nil else { return }
        editing = true
        draft = title
    }

    private var renameField: some View {
        TextField("", text: $draft)
            .focused($focused)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
            .frame(width: width, height: height)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(0.02)))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(Color.accentColor.opacity(0.9), lineWidth: 1.2))
            .onAppear {
                draft = title
                DispatchQueue.main.async { focused = true }
            }
            .onChange(of: focused) { isFocused in
                if !isFocused { commitRename() }
            }
            .onSubmit { focused = false }
    }

    private func commitRename() {
        editing = false
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty, t != title {
            onRename?(t)
        }
    }

    // MARK: 右键菜单
    @ViewBuilder
    private var contextItems: some View {
        if let note = lockedNote {
            Text(note)
        } else {
            if onRename != nil {
                Button("重命名列…") { beginRename() }
            }
            if onDelete != nil {
                if onRename != nil { Divider() }
                Button(role: .destructive) {
                    onDelete?()
                } label: {
                    Label("删除此列", systemImage: "minus.circle")
                }
            }
        }
    }
}
