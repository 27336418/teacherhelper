import SwiftUI

// MARK: - 教室分布视图（逐层卡片；班级/房号/层名双击编辑；行、列均可增删）
struct ClassroomMapView: View {
    @EnvironmentObject var store: ClassroomStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    EditableCardTitle(icon: "square.grid.3x3", key: "classroom")
                    Spacer()
                    UndoButton()
                    Button {
                        store.addFloor()
                    } label: {
                        Label("添加楼层", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                }

                ForEach($store.floors) { $floor in
                    FloorCard(floor: $floor)
                }
            }
            .padding(16)
        }
    }
}

struct FloorCard: View {
    @Binding var floor: ClassroomFloor
    @EnvironmentObject var store: ClassroomStore
    @State private var titleEditing = false
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool

    private let blockWidth: CGFloat = 52
    private let gap: CGFloat = 3
    private let btnWidth: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 层名 + 操作
            HStack(spacing: 6) {
                if titleEditing {
                    TextField("", text: $titleDraft)
                        .focused($titleFocused)
                        .textFieldStyle(.plain)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .onAppear {
                            titleDraft = floor.title
                            DispatchQueue.main.async { titleFocused = true }
                        }
                        .onChange(of: titleFocused) { f in
                            if !f {
                                titleEditing = false
                                floor.title = titleDraft
                            }
                        }
                        .onSubmit { titleFocused = false }
                } else {
                    Text(floor.title)
                        .font(.headline)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { titleEditing = true }
                        .help("双击重命名")
                }
                Spacer()
                Button {
                    floor.extraRows.append(ClassroomRow(blocks: (0..<floor.rowWidth)
                        .map { _ in ClassroomSide(klass: "", room: "") }))
                } label: {
                    Label("添加行", systemImage: "plus.rectangle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("在本楼层下方增加一排教室")
                Button {
                    store.removeFloor(floor.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("删除此楼层")
            }

            // 主行：左翼 + 办公室 + 右翼（每侧末尾可加列）
            HStack(alignment: .top, spacing: gap) {
                ForEach(floor.left.indices, id: \.self) { i in
                    roomBlock(side: $floor.left[i]) {
                        let snap = store.floors
                        floor.left.remove(at: i)
                        UndoService.shared.register("删除教室") {
                            store.floors = snap
                            store.save()
                        }
                    }
                }
                addBlockButton { floor.left.append(ClassroomSide(klass: "", room: "")) }

                // 中间办公室
                VStack(spacing: 2) {
                    EditableGridCell(text: $floor.officeName, width: blockWidth, height: 22,
                                     font: .system(size: 10), bold: true,
                                     tint: Color(hex: 0xF39C12))
                    EditableGridCell(text: $floor.officeRoom, width: blockWidth, height: 22,
                                     font: .system(size: 11), bold: true,
                                     tint: Color(hex: 0xF39C12))
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 5).fill(officeFill))
                .contextMenu { colorMenu(current: floor.officeColor) { floor.officeColor = $0 } }

                ForEach(floor.right.indices, id: \.self) { i in
                    roomBlock(side: $floor.right[i]) {
                        let snap = store.floors
                        floor.right.remove(at: i)
                        UndoService.shared.register("删除教室") {
                            store.floors = snap
                            store.save()
                        }
                    }
                }
                addBlockButton { floor.right.append(ClassroomSide(klass: "", room: "")) }
            }

            // 附加行（可继续加列、整行删除）
            ForEach($floor.extraRows) { $row in
                HStack(alignment: .top, spacing: gap) {
                    ForEach(row.blocks.indices, id: \.self) { i in
                        roomBlock(side: $row.blocks[i]) {
                            let snap = store.floors
                            row.blocks.remove(at: i)
                            UndoService.shared.register("删除教室") {
                                store.floors = snap
                                store.save()
                            }
                        }
                    }
                    addBlockButton { row.blocks.append(ClassroomSide(klass: "", room: "")) }
                    Button {
                        let snap = store.floors
                        floor.extraRows.removeAll { $0.id == row.id }
                        UndoService.shared.register("删除教室行") {
                            store.floors = snap
                            store.save()
                        }
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("删除这一行")
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.3)))
    }

    // 行尾「加一列教室」按钮
    private func addBlockButton(_ insert: @escaping () -> Void) -> some View {
        Button(action: insert) {
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .bold))
                .frame(width: btnWidth, height: 46)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.01)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("在末尾添加一间教室")
    }

    // 办公室底色：自定义色 > 默认浅灰（与个人课表面板底色同款系统色）
    private var officeFill: AnyShapeStyle {
        if let hex = floor.officeColor, !hex.isEmpty {
            return AnyShapeStyle(Color(hexString: hex).opacity(0.4))
        }
        return AnyShapeStyle(.quaternary.opacity(0.3))
    }

    // 颜色右键菜单（教室/办公室共用）
    @ViewBuilder
    private func colorMenu(current: String?, set: @escaping (String?) -> Void) -> some View {
        ColorPaletteMenu(current: current, onPick: set)
    }

    // 单间教室块：上班级（粗体）+ 下房号；右键换色 / 删除这一列
    // 显示样式：整格底色填充 —— 默认浅灰（同个人课表底色），自定义色优先淡显
    private func roomBlock(side: Binding<ClassroomSide>, onDelete: @escaping () -> Void) -> some View {
        let sideValue = side.wrappedValue
        let fill = roomBlockFill(for: sideValue)
        return VStack(spacing: 2) {
            EditableGridCell(text: side.klass, width: blockWidth, height: 24,
                             font: .system(size: 11), bold: true)
            EditableGridCell(text: side.room, width: blockWidth, height: 20,
                             font: .system(size: 10))
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 5).fill(fill))
        .contextMenu {
            colorMenu(current: sideValue.color) { side.wrappedValue.color = $0 }
            Divider()
            Button(role: .destructive) { onDelete() } label: {
                Label("删除这间教室", systemImage: "trash")
            }
        }
        .help("双击编辑文字，右键更换颜色 / 删除")
    }

    /// 教室块整格底色：自定义色 > 默认浅灰（与个人课表面板底色同款系统色）
    private func roomBlockFill(for side: ClassroomSide) -> AnyShapeStyle {
        if let hex = side.color, !hex.isEmpty {
            return AnyShapeStyle(Color(hexString: hex).opacity(0.4))
        }
        return AnyShapeStyle(.quaternary.opacity(0.3))
    }
}
