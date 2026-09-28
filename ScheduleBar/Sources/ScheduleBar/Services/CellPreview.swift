import SwiftUI
import AppKit

// MARK: - 课表单元格「同内容高亮」离屏渲染取证
//
// 用法：ScheduleBar --render-cells /tmp/cells.png
//
// 为什么需要它：课表高亮这一路改过三版，每版都是**纯视觉**问题 ——
//   2.2.7 之前：命中格只加一圈「本身就是课程色」的描边，底色同色 → 肉眼完全看不出变化；
//   2.2.7      ：改成外红环 + 内白隔离环；
//   2.2.8      ：用户拍板「参考年级师资安排的效果」→ 命中格淡红底、其余格退回默认灰。
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

    /// 与真实 7 班课表一致的样本（含正红「语文·于理想」、暗红「政治·余燕」两个最难的底色）
    private static let sample: [[String]] = [
        ["语文·于理想", "数学·林科",   "英语·邓雨蒙", "物理·陈乐怡"],
        ["数学·林科",   "语文·于理想", "化学·蒙真真", "历史·赖炳森"],
        ["英语·邓雨蒙", "政治·余燕",   "语文·于理想", "体育·王加鹏"],
        ["政治·余燕",   "数学·林科",   "足球·王加鹏", "语文·于理想"],
    ]

    @MainActor
    static func renderScheduleCells(to path: String) {
        // 点中的格子（语文 第 1 行第 1 列）与它的分组键
        let hitRow = 0, hitCol = 0
        let hitKey = courseKey(sample[hitRow][hitCol])

        func grid(selected: Bool) -> some View {
            VStack(spacing: 4) {
                ForEach(Array(sample.enumerated()), id: \.offset) { r, row in
                    HStack(spacing: 6) {
                        ForEach(Array(row.enumerated()), id: \.offset) { c, text in
                            let marked = selected && courseKey(text) == hitKey
                            ScheduleCell(
                                text: text,
                                width: 108,
                                id: ScheduleCellID(period: "p\(r)", day: c),
                                color: courseColor,
                                isSelected: selected && r == hitRow && c == hitCol,
                                isSameContent: marked,
                                isEditing: false,
                                isDimmed: selected,
                                onSelect: {}, onStartEditing: {},
                                onUpdate: { _ in }, onEndEditing: {}
                            )
                        }
                    }
                }
            }
        }

        func caption(_ s: String) -> some View {
            Text(s).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.black)
        }

        let content = VStack(alignment: .leading, spacing: 10) {
            caption("① 未点击：每格按自己所属科目着色")
            grid(selected: false)

            Divider().frame(width: 460)

            caption("② 点一下「语文」（第 1 行第 1 格）：全表同科目的格子淡红高亮（被点中那格描边更粗），其余格子变默认灰")
            grid(selected: true)
        }
        .padding(14)
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

    // MARK: 教师工位工具栏（三行布局）离屏渲染取证
    //
    // 用法：ScheduleBar --render-office-toolbar /tmp/office-toolbar.png
    // ⚠️ `UndoButton` 读的是**全局单例**的当前状态，
    //    同一棵视图树里渲染两次会得到同样的结果 → 必须分两次渲染再合成。
    @MainActor
    static func renderOfficeToolbar(to path: String) {
        let store = OfficeLayoutStore.shared
        let titles = CardTitleStore.shared
        let undo = UndoService.shared

        /// 面板内宽 = 窗口 906 − 左右各 16 内边距
        let panelWidth: CGFloat = 874

        func shot(caption: String, withUndo: Bool) -> NSImage? {
            undo.clear()
            if withUndo {
                undo.register("拖动了办公室卡片") {}
            }
            let content = VStack(alignment: .leading, spacing: 10) {
                Text(caption)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.black)
                OfficeToolbar(
                    store: store,
                    keyword: .constant(""),
                    appliedKeyword: .constant(""),
                    onImport: {}, onTemplate: {}, onDownload: {}, onNewFloor: {}
                )
                .environmentObject(titles)
                .frame(width: panelWidth)
            }
            .padding(16)
            .background(Color.white)
            let r = ImageRenderer(content: content)
            r.scale = 2
            return r.nsImage
        }

        let head = shot(caption: "① 第一行＝标题 ＋ 撤销 / 内部·外部视角 / 显示左右门（同一行右对齐）；第二行＝导入 / 下载 / 新建 ＋ 查找工位 ＋ 办公室共多少人",
                        withUndo: true)
        let body = shot(caption: "② 没有可撤销操作时「撤销」按钮不出现（位置留给紧凑布局）",
                        withUndo: false)
        undo.clear()

        guard let head, let body else { print("✗ 离屏渲染失败"); return }
        let gap: CGFloat = 18
        let size = NSSize(width: max(head.size.width, body.size.width),
                          height: head.size.height + gap + body.size.height)
        let out = NSImage(size: size)
        out.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        head.draw(in: NSRect(x: 0, y: body.size.height + gap,
                             width: head.size.width, height: head.size.height))
        body.draw(in: NSRect(origin: .zero, size: body.size))
        out.unlockFocus()

        guard let tiff = out.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("✗ 合成失败")
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("✓ 已输出教师工位工具栏预览：\(path)")
        } catch {
            print("✗ 写入失败：\(error)")
        }
    }

    // MARK: 教师工位「整页」离屏渲染（核对卡片自适应列宽用）
    // 用法：ScheduleBar --render-office-page /tmp/office-page.png [内容宽度pt]
    //
    // 为什么需要它：2026-09-23 用户要求「右侧空余太多，请调节自适应列宽」——又是纯视觉问题，
    // 逻辑自检看不出来。而实测时经常碰上「面板落在别的 Space / 别的 App 正全屏」：
    // 全屏截图抓到的是别人的窗口；`screencapture -l <windowid>` 又要求窗口 alpha=1
    // （面板淡入中或已收起都会 could not create image）。离屏渲染不受这些影响。
    //
    // ⚠️ `ImageRenderer` 画不了 `Menu` / `TextField`（黄色禁行占位）→ 顶部工具栏那一两行会是占位，
    //    但**卡片区是纯 Text/Button，能如实渲染**，恰好是本入口要核对的部分。
    // ⚠️ 默认内容宽度 709 = 面板 880 − 侧栏 170 − 分隔线 1，与真机一致（页面内还有左右各 16 内边距）。
    @MainActor
    static func renderOfficePage(to path: String, contentWidth: CGFloat = 712) {
        let store = OfficeLayoutStore.shared
        let titles = CardTitleStore.shared

        // ⚠️ `ImageRenderer` 画不了 `ScrollView` / `GeometryReader`（出白图），
        //    所以这里给 OfficeLayoutView 传 offscreenWidth，走「不套滚动容器」的那条路。
        let content = OfficeLayoutView(offscreenWidth: max(0, contentWidth - 32))
            .environmentObject(store)
            .environmentObject(titles)
            .environmentObject(AppCoordinator.shared)
            .frame(width: contentWidth, height: 1000, alignment: .topLeading)
            .background(Color.white)

        let r = ImageRenderer(content: content)
        r.scale = 2
        guard let img = r.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("✗ 离屏渲染失败（ImageRenderer 返回空）")
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("✓ 已输出教师工位整页预览：\(path)（内容宽 \(Int(contentWidth))pt）")
        } catch {
            print("✗ 写入失败：\(error)")
        }
    }
}
