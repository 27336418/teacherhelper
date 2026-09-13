import SwiftUI
import AppKit

// MARK: - 课表单元格「同内容高亮」离屏渲染取证
//
// 用法：ScheduleBar --render-cells /tmp/cells.png
//
// 为什么需要它：2026-09-13 这次 bug 是**纯视觉**的 —— 命中「同内容」的格子只是加了一圈
// 「本身课程色」的描边（`color(text).opacity(0.8)`），而底色就是同一个颜色，肉眼完全看不出来。
// 逻辑自检全绿照样白搭，只有看到像素才算验证过。
//
// 而 `screencapture` 要求屏幕处于解锁可见状态；机器锁屏时截出来是全黑。`ImageRenderer`
// 走的是离屏渲染，不依赖屏幕是否可见，所以锁屏、无人值守时也能出图。
// 渲染的是**真实的 `ScheduleCell`**，不是复制出来的仿制品，不存在「预览和实际不一致」。
//
// ⚠️ `ImageRenderer` 需要 macOS 13+，而本包部署目标是 macOS 12 —— 所以整个工具用
//    `@available` 圈起来，只在显式传 `--render-cells` 且系统够新时才跑，不影响 App 本体。
@available(macOS 13.0, *)
enum CellPreview {

    @MainActor
    static func renderScheduleCells(to path: String) {
        // 用课表里真实出现过的 9 门课（颜色固定映射），特别带上正红「语文」和暗红「政治」——
        // 它们就是红环最容易糊掉的那两种底色，必须进样本。
        let courses = ["语文·于理想", "数学·林科", "英语·邓雨蒙", "物理·陈乐怡", "化学·蒙真真",
                       "历史·赖炳森", "政治·余燕", "体育·王加鹏", "足球·王加鹏"]

        var rows: [AnyView] = []
        for (i, c) in courses.enumerated() {
            rows.append(AnyView(
                HStack(spacing: 8) {
                    Text(c)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.black)
                        .frame(width: 94, alignment: .leading)

                    // ① 未命中：应该保持原样
                    ScheduleCell(text: c, width: 94,
                                 id: ScheduleCellID(period: "p", day: i * 3),
                                 color: courseColor,
                                 isSelected: false, isSameContent: false, isEditing: false,
                                 onSelect: {}, onStartEditing: {},
                                 onUpdate: { _ in }, onEndEditing: {})

                    // ② 命中（同内容，但不是被点中的那格）
                    ScheduleCell(text: c, width: 94,
                                 id: ScheduleCellID(period: "p", day: i * 3 + 1),
                                 color: courseColor,
                                 isSelected: false, isSameContent: true, isEditing: false,
                                 onSelect: {}, onStartEditing: {},
                                 onUpdate: { _ in }, onEndEditing: {})

                    // ③ 被点中的那一格（红环更粗）
                    ScheduleCell(text: c, width: 94,
                                 id: ScheduleCellID(period: "p", day: i * 3 + 2),
                                 color: courseColor,
                                 isSelected: true, isSameContent: true, isEditing: false,
                                 onSelect: {}, onStartEditing: {},
                                 onUpdate: { _ in }, onEndEditing: {})
                }
            ))
        }

        let content = VStack(alignment: .leading, spacing: 6) {
            Text("① 未命中　　② 命中（同内容）　　③ 被点中那一格")
                .font(.system(size: 10))
                .foregroundStyle(Color.black)
            ForEach(0..<rows.count, id: \.self) { i in rows[i] }
        }
        .padding(12)
        .background(Color.white)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("✗ 离屏渲染失败（ImageRenderer 返回空）")
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("✓ 已输出课表单元格高亮预览：\(path)")
        } catch {
            print("✗ 写入失败：\(error)")
        }
    }
}
