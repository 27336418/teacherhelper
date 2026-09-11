import SwiftUI

// MARK: - 可编辑卡片标题（双击进入编辑，回车/失焦保存；清空则还原默认名）
struct EditableCardTitle: View {
    let icon: String
    let key: String

    @EnvironmentObject var titles: CardTitleStore
    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if isEditing {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .foregroundStyle(.secondary)
                    TextField("", text: $draft)
                        .focused($focused)
                        .textFieldStyle(.plain)
                        .font(.headline)
                        .frame(minWidth: 120)
                        .onAppear {
                            draft = titles.title(for: key)
                            DispatchQueue.main.async { focused = true }
                        }
                        .onChange(of: focused) { isFocused in
                            if !isFocused { commit() }
                        }
                        .onSubmit { focused = false }
                }
            } else {
                Label(titles.title(for: key), systemImage: icon)
                    .font(.headline)
                    .fixedSize(horizontal: true, vertical: false)
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
