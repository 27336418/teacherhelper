import SwiftUI

// MARK: - 即时悬停提示（鼠标放上去立即显示，不等系统 tooltip 的 1~2 秒延迟）
// 用法：.instantTooltip("小组：第3小组")，可放在任意 View 后面。
// 每个使用点各自持有 @State，ForEach 中的多格互不影响。
struct InstantTooltip: ViewModifier {
    let text: String
    /// true = 气泡显示在下方（首行防顶部裁剪时用）
    var below: Bool = false
    @State private var showing = false

    func body(content: Content) -> some View {
        content
            .onHover { h in showing = h && !text.isEmpty }
            .overlay(alignment: below ? .bottom : .top) {
                if showing {
                    Text(text)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.black.opacity(0.78))
                        )
                        .fixedSize()
                        .offset(y: below ? 24 : -24)
                        .zIndex(9999)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .animation(.easeIn(duration: 0.08), value: showing)
                }
            }
    }
}

extension View {
    func instantTooltip(_ text: String, below: Bool = false) -> some View {
        modifier(InstantTooltip(text: text, below: below))
    }
}
