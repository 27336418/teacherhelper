import SwiftUI

// MARK: - 工位拖动对换代理
// 设计要点：拖动过程中只做「高亮」反馈（不改数据），真正交换只在 performDrop 时发生一次。
// 这样保证：① 交换确定（不会因 hover 多次触发而乱跳）；② 撤销一定生效（提交点唯一）；
// ③ 拖完后可立即再次拖动任意工位对换。内部/外部视角下都用模型坐标，天然都支持。
struct OfficeSeatSwapDelegate: DropDelegate {
    let officeID: UUID
    let row: Int
    let col: Int
    let store: OfficeLayoutStore

    /// 本落点是否该管家下的这次拖拽（不是工位模块 → 一概不理，
    /// 尤其不能顺手清掉 DragContext，否则「拖了没换」之后下一拖也没有来源）
    private var isSeatDrag: Bool { DragContext.belongs(to: DragPayload.officeSeat) }
    /// ⚠️ 「整张卡片」拖动经过座位区时也要接住：卡片中间的座位格占了大半面积，
    ///    如果只有标题条能落，用户会以为「卡片拖不动」。
    private var isCardDrag: Bool { DragContext.belongs(to: DragPayload.officeCard) }
    /// 同理，「整个楼层」拖动经过座位区时也要接住（落到哪个座位 = 跟那一层对调）
    private var isFloorDrag: Bool { DragContext.belongs(to: DragPayload.officeFloor) }

    private var isOurs: Bool { isSeatDrag || isCardDrag || isFloorDrag }

    func validateDrop(info: DropInfo) -> Bool { isOurs }

    private func highlight() {
        if isFloorDrag {
            if let fi = store.floorIndexOfOffice(officeID) { store.setFloorSwapTarget(fi) }
        } else if isCardDrag {
            store.setCardDropTarget(officeID)
        } else {
            store.setDropHighlight(officeID: officeID, row: row, col: col)
        }
    }

    func dropEntered(info: DropInfo) {
        guard isOurs else { return }
        highlight()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard isOurs else { return nil }
        highlight()
        return DropProposal(operation: .move)
    }

    // 唯一提交点：**同步**执行一次交换并登记撤销，随后清除高亮。
    // （不能放进 loadObject 的异步回调：macOS 26 上拖拽会话会因此不复位，之后再也拖不动）
    func performDrop(info: DropInfo) -> Bool {
        if isFloorDrag {
            guard let fi = store.floorIndexOfOffice(officeID) else {
                DragContext.reject(DragPayload.officeFloor)
                return false
            }
            return OfficeFloorDrop.perform(store: store, targetIndex: fi)
        }
        if isCardDrag { return OfficeCardDrop.perform(store: store, targetID: officeID) }
        guard isSeatDrag else { DragContext.reject(DragPayload.officeSeat); return false }
        store.swapSeatTo(officeID: officeID, row: row, col: col)
        store.clearDropHighlight()
        store.finishSeatDrag()
        DragContext.finish(reason: "工位")
        return true
    }
}

// MARK: - 「整张卡片」拖动的落点（卡片 / 楼层标题共用提交逻辑）
enum OfficeCardDrop {
    /// 落点 = 某张卡片：插到它的位置并跟随它的楼层
    static func perform(store: OfficeLayoutStore, targetID: UUID) -> Bool {
        guard let src = DragPayload.officeCardID(from: DragContext.payload) else {
            DragContext.reject(DragPayload.officeCard)
            return false
        }
        store.moveCard(src, to: targetID)
        return commit(store: store)
    }

    /// 落点 = 楼层标题：挪到该楼层末尾
    static func perform(store: OfficeLayoutStore, floor: String) -> Bool {
        guard let src = DragPayload.officeCardID(from: DragContext.payload) else {
            DragContext.reject(DragPayload.officeCard)
            return false
        }
        store.moveCard(src, toFloor: floor)
        return commit(store: store)
    }

    private static func commit(store: OfficeLayoutStore) -> Bool {
        store.clearCardDropTargets()
        store.finishCardDrag()
        DragContext.finish(reason: "办公室卡片")
        return true
    }
}

// MARK: - 「整个楼层」拖动的提交（楼层条 / 卡片 / 座位 三种落点共用）
// 三种落点都归一成「目标楼层下标」，所以提交逻辑只有这一份。
enum OfficeFloorDrop {
    static func perform(store: OfficeLayoutStore, targetIndex: Int) -> Bool {
        guard let src = DragPayload.officeFloorIndex(from: DragContext.payload) else {
            DragContext.reject(DragPayload.officeFloor)
            return false
        }
        store.swapFloors(src, targetIndex)
        store.clearCardDropTargets()
        store.finishFloorDrag()
        DragContext.finish(reason: "办公室楼层")
        return true
    }
}

/// 落点 = 某张办公室卡片（整卡高亮）
/// 另外也接「整个楼层」的拖动：落到目标楼层的任意一张卡片上 = 与那一层对调
/// （不让用户非得精确对准 30pt 高的楼层条；见 `floorIndexOfOffice` 的说明）
struct OfficeCardDropDelegate: DropDelegate {
    let targetID: UUID
    let store: OfficeLayoutStore

    private var isCardDrag: Bool { DragContext.belongs(to: DragPayload.officeCard) }
    private var isFloorDrag: Bool { DragContext.belongs(to: DragPayload.officeFloor) }
    private var isOurs: Bool { isCardDrag || isFloorDrag }

    /// 这张卡片所属楼层在 floorNames 里的下标（整层拖动的落点）
    private var targetFloorIndex: Int? { store.floorIndexOfOffice(targetID) }

    func validateDrop(info: DropInfo) -> Bool { isOurs }

    private func highlight() {
        if isFloorDrag {
            if let fi = targetFloorIndex { store.setFloorSwapTarget(fi) }
        } else {
            store.setCardDropTarget(targetID)
        }
    }

    func dropEntered(info: DropInfo) {
        guard isOurs else { return }
        highlight()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard isOurs else { return nil }
        highlight()
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        if isFloorDrag {
            guard let fi = targetFloorIndex else { DragContext.reject(DragPayload.officeFloor); return false }
            return OfficeFloorDrop.perform(store: store, targetIndex: fi)
        }
        guard isCardDrag else { DragContext.reject(DragPayload.officeCard); return false }
        return OfficeCardDrop.perform(store: store, targetID: targetID)
    }
}

/// 落点 = 楼层标题条。两种拖拽都落在这里：
///   ① 拖「办公室卡片」上来 → 把卡片挪进这一层（原有行为）；
///   ② 拖「整个楼层」上来 → 两个楼层整层对调（2026-09-26 新增）。
struct OfficeFloorDropDelegate: DropDelegate {
    let floorIndex: Int
    let floor: String
    let store: OfficeLayoutStore

    private var isCardDrag: Bool { DragContext.belongs(to: DragPayload.officeCard) }
    private var isFloorDrag: Bool { DragContext.belongs(to: DragPayload.officeFloor) }
    private var isOurs: Bool { isCardDrag || isFloorDrag }

    func validateDrop(info: DropInfo) -> Bool { isOurs }

    private func highlight() {
        if isFloorDrag { store.setFloorSwapTarget(floorIndex) }
        else { store.setFloorDropTarget(floor) }
    }

    func dropEntered(info: DropInfo) {
        guard isOurs else { return }
        highlight()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard isOurs else { return nil }
        highlight()
        return DropProposal(operation: .move)
    }

    // ⚠️ 唯一提交点必须**同步**改数据（见 DragSwapSupport 顶部说明）。
    //    不是本模块的拖拽要「原样拒绝、什么都不清」。
    func performDrop(info: DropInfo) -> Bool {
        if isFloorDrag { return OfficeFloorDrop.perform(store: store, targetIndex: floorIndex) }
        guard isCardDrag else { DragContext.reject(DragPayload.officeCard); return false }
        return OfficeCardDrop.perform(store: store, floor: floor)
    }
}

// MARK: - 顶部工具栏（三行：标题 ／ 撤销·保存 + 视角 ／ 导入·下载·新建 + 查找 + 人数）
//
// 抽成独立 View 的原因：它只依赖 `store` + `CardTitleStore` + 几个动作闭包，
// 不碰 `AppCoordinator`，所以能用 `ImageRenderer` 离屏渲染取证（机器锁屏时
// `screencapture` 只会得到全黑图，离屏渲染不受影响）。
struct OfficeToolbar: View {
    @ObservedObject var store: OfficeLayoutStore
    @Binding var keyword: String
    @Binding var appliedKeyword: String
    var onImport: () -> Void
    var onTemplate: () -> Void
    var onDownload: () -> Void
    var onNewFloor: () -> Void

    @State private var searchWork: DispatchWorkItem?

    var body: some View {
        VStack(spacing: 8) {
            // 第一行：板块标题 … 撤销 / 保存 ＋ 内部·外部视角 ＋ 显示左右门（全部右对齐同一行）
            HStack(spacing: 8) {
                EditableCardTitle(icon: "person.3.fill", key: "office")
                Spacer(minLength: 8)
                UndoButton()
                SaveButton()
                Picker("", selection: $store.studentView) {
                    Text("内部视角").tag(false)
                    Text("外部视角").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("内部视角：从办公室内部看，左右门在工位上方；外部视角：从办公室外部看，整张工位表 180° 镜像，左右门移到工位下方")
                Toggle("显示左右门", isOn: $store.showDoors)
                    .toggleStyle(.checkbox)
                    .fixedSize()
                    .help("隐藏或显示办公室的左右门标识（内部视角在工位上方，外部视角在工位下方）")
            }

            // 第二行：导入 / 下载 / 新建 + 查找工位 + 办公室总人数
            HStack(spacing: 8) {
                Menu {
                    Button("导入 xlsx") { onImport() }
                    Button("下载填写模板") { onTemplate() }
                } label: {
                    Label("导入", systemImage: "square.and.arrow.down")
                }
                .fixedSize()
                .help("导入工位布局；可先下载模板（每段先写「楼层」，再写「办公室」+ 每排座位）填写")
                Button("下载") { onDownload() }
                    .fixedSize()
                    .help("把当前工位布局导出成 xlsx（含「楼层」行）")
                // 「新建」= 原来的「新建楼层」+「添加办公室」合并成一个入口
                Menu {
                    if store.hasFloors {
                        ForEach(store.floorNames, id: \.self) { f in
                            Button("新建办公室（\(f.isEmpty ? "未分组" : f)）") { store.addOffice(floor: f) }
                        }
                    } else {
                        Button("新建办公室") { store.addOffice() }
                    }
                    Divider()
                    Button("新建楼层…") { onNewFloor() }
                } label: {
                    Label("新建", systemImage: "plus")
                }
                .fixedSize()
                .help("新建办公室（可选楼层）或新建楼层")

                searchField
                headcountBadge
            }
        }
    }

    // MARK: 姓名查询框（第二行）
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("输入姓名查找工位", text: $keyword)
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
            }
            if !appliedKeyword.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("找到 \(hitCount) 个工位")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        .frame(minWidth: 120, maxWidth: .infinity)
    }

    // MARK: 所有办公室人数之和（第二行右侧）
    private var headcountBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.3.fill")
                .foregroundStyle(.secondary)
            Text("办公室共 \(store.totalHeadcount) 人")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        .fixedSize()
    }

    /// 命中的工位数（所有办公室合计）
    private var hitCount: Int {
        let k = appliedKeyword.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return 0 }
        var n = 0
        for o in store.offices {
            for row in o.seats {
                for s in row where s.localizedCaseInsensitiveContains(k) { n += 1 }
            }
        }
        return n
    }
}

// MARK: - 办公室工位布局视图（双列卡片；座位/标题双击编辑，座位右键换色，可增删行/办公室）
struct OfficeLayoutView: View {
    @EnvironmentObject var store: OfficeLayoutStore
    @EnvironmentObject var coordinator: AppCoordinator

    @State private var keyword = ""
    @State private var appliedKeyword = ""     // 去抖后的关键字（避免每次键入都重算）

    /// 折叠起来的楼层（2026-09-26 用户要求「楼层可以折叠或者展开」）。
    /// 键用楼层名 —— 与 `store.floorNames` 同一套标识，空串代表「未分组」。
    /// 刻意不做持久化：这是「先看一眼总览」的临时界面态，重开面板回到全部展开更符合预期；
    /// 也避免为它多开一个 store 字段 + json。**只影响显示，绝不改数据**。
    @State private var collapsedFloors: Set<String> = []

    private func toggleFloorCollapsed(_ floor: String) {
        if collapsedFloors.contains(floor) { collapsedFloors.remove(floor) }
        else { collapsedFloors.insert(floor) }
    }

    /// ⚠️ 仅取证用：离屏渲染（`--render-office-page`）时给出「内容区可用宽度」。
    /// 为什么需要这个开关：`ImageRenderer` **画不了 `ScrollView` / `GeometryReader`**（出白图），
    /// 所以离屏那条路必须绕开这两层容器、直接把宽度喂进来。运行时保持 nil，走真实页面路径。
    /// 两条路共用同一个 `pageContent(availableWidth:)`，所以「预览 = 实际」不会走样。
    var offscreenWidth: CGFloat? = nil

    /// 楼层编辑状态（行内输入，**不弹窗**：NSAlert 会先把 popover 关掉，用户就得重新打开面板）
    enum FloorEditKind: Equatable { case new, rename(String) }
    @State private var floorEditKind: FloorEditKind? = nil
    @State private var floorDraft = ""
    @State private var floorAssign: UUID? = nil      // 新建楼层时要把哪张卡片挪进去
    @FocusState private var floorFieldFocused: Bool

    var body: some View {
        if let w = offscreenWidth {
            pageContent(availableWidth: w)          // 取证路径：不套 ScrollView / GeometryReader
        } else {
            // ⚠️ 卡片要按「本页实际可用宽度」自适应列宽（2026-09-23 用户要求：右侧空余太多），
            //    所以这里必须量出内容区宽度再往下传。
            //    用 GeometryReader 直接读、把数字当参数传下去（而不是 @State + onChange）：
            //    窗口宽度变化时 GeometryReader 的闭包会重算，卡片自然跟着重排，少一处状态同步。
            //    availableWidth = 内容区宽度 − 左右各 16pt 内边距。
            GeometryReader { geo in
                let available = max(0, geo.size.width - 32)
                let _ = traceLayout("内容区实测 \(Int(geo.size.width.rounded()))pt → 可用 \(Int(available.rounded()))pt")
                pageContent(availableWidth: available, scrollBody: true)
            }
        }
    }

    /// 整页内容（工具栏 + 楼层分组）。真实路径与离屏取证共用这一份，保证预览不走样。
    ///
    /// - Parameter scrollBody: **只有楼层卡片区**进纵向 `ScrollView`。
    ///   ⚠️ 2026-09-26 用户要求「滚动时冻结这些内容」：工具栏那两行（导入/下载/新建/查找工位/
    ///      办公室共 N 人）必须留在滚动区**外面**，否则往下翻楼层时整条工具栏被带走，
    ///      想换个楼层视角或重新搜索都要先滚回顶部。
    ///      离屏取证路径传 `false`（`ImageRenderer` 画不了 `ScrollView`，会出白图），
    ///      这样「两层结构」在预览里也一次成型、与实际页面对得上。
    private func pageContent(availableWidth: CGFloat, scrollBody: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            // 「新建楼层」的行内输入框：紧跟在工具栏下方（原来挂在列表末尾，
            // 整合进「新建」菜单后改到顶部，点完立刻就能看见并输入）
            if floorEditKind == .new { floorEditorRow(isNew: true) }
            if scrollBody {
                ScrollView { floorsSection(availableWidth: availableWidth) }
            } else {
                floorsSection(availableWidth: availableWidth)
            }
        }
        .padding(16)
    }

    // MARK: 顶部工具栏（真正的实现在 OfficeToolbar —— 抽出去是为了能离屏渲染取证）
    private var toolbar: some View {
        OfficeToolbar(
            store: store,
            keyword: $keyword,
            appliedKeyword: $appliedKeyword,
            onImport: { coordinator.importOffice() },
            onTemplate: { coordinator.downloadTemplate(.office) },
            onDownload: { coordinator.exportOffice() },
            onNewFloor: { beginNewFloor() }
        )
    }


    // MARK: 楼层分组（没设过楼层时退化成原来的「一张张平铺」）
    @ViewBuilder
    private func floorsSection(availableWidth: CGFloat) -> some View {
        if store.hasFloors {
            // ⚠️ 用 `LazyVStack` + `pinnedViews: [.sectionHeaders]` 把「办公室情况」楼层条
            //    （`4楼 3间·27人`）钉在顶部：上下滑动时它一直可见，用户随时知道在看哪一层。
            //    钉住的表头必须自带**不透明背景**，否则卡片会从它后面透出来（下面那层 FrostedView）。
            //    （2026-09-26 用户要求：「上下滑动时保持最上面的比如办公室情况等固定置顶冻结」）
            //    折叠只是把 Section 的**内容**置空，表头条照旧钉着 —— 折起来的那层仍然看得见、点得到。
            LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                ForEach(store.floorNames, id: \.self) { floor in
                    Section {
                        if !collapsedFloors.contains(floor) {
                            cardRows(store.offices(inFloor: floor), availableWidth: availableWidth)
                                .padding(.top, 10)
                        }
                    } header: {
                        floorHeader(floor)
                            .padding(.vertical, 4)
                            .background { FrostedView() }
                    }
                }
            }
        } else {
            cardRows(store.offices, availableWidth: availableWidth)
        }
    }

    /// 楼层标题条：也是「整张卡片」的落点（把卡片拖到这一条上 = 挪到该楼层）
    @ViewBuilder
    private func floorHeader(_ floor: String) -> some View {
        if floorEditKind == .rename(floor) {
            floorEditorRow(isNew: false)
        } else {
            floorHeaderBar(floor)
        }
    }

    private func floorHeaderBar(_ floor: String) -> some View {
        let count = store.offices(inFloor: floor).count
        let people = store.headcount(inFloor: floor)
        let index = store.floorNames.firstIndex(of: floor) ?? 0
        // 两种落点高亮：① 卡片落点 = 把卡片挪进这一层；② 整层落点 = 两个楼层对调
        let isCardTarget = store.floorDropTarget == floor
        let isSwapTarget = store.floorSwapTarget == index
        let isTarget = isCardTarget || isSwapTarget
        let isSource = store.floorDragSourceIndex == index
        let canUp = index > 0
        let canDown = index < store.floorNames.count - 1
        let label = floor.isEmpty ? "未分组" : floor
        let collapsed = collapsedFloors.contains(floor)
        return HStack(spacing: 8) {
            // 折叠箭头（2026-09-26 用户要求「楼层可以折叠或者展开」）：
            // ⚠️ 只让这一个箭头可点 —— 楼层条本身同时是「整卡拖动」的落点和右键菜单的宿主，
            //    若整条都可点折叠，用户拖卡片过来一松手就会顺手把这一层折起来。
            Button { toggleFloorCollapsed(floor) } label: {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .help(collapsed ? "展开「\(label)」的办公室" : "折叠「\(label)」的办公室")
            Image(systemName: "building.2.fill")
                .font(.system(size: 12))
                .foregroundStyle(isTarget ? Color.accentColor : Color.secondary)
            Text(label)
                .font(.system(size: 13, weight: .bold))
            Text("\(count) 间 · \(people) 人")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if collapsed {
                Text("已折叠")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Button { store.moveFloor(floor, by: -1) } label: {
                Image(systemName: "chevron.up").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .disabled(!canUp)
            .help("把「\(label)」整层上移")
            Button { store.moveFloor(floor, by: 1) } label: {
                Image(systemName: "chevron.down").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .disabled(!canDown)
            .help("把「\(label)」整层下移")
            Button { store.addOffice(floor: floor) } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("在「\(label)」加一间办公室")
            Menu {
                Button("重命名…") { beginRenameFloor(floor) }
                if !floor.isEmpty {
                    Button("移出楼层（保留办公室）") { store.clearFloor(floor) }
                    Divider()
                    Button("删除本楼层（含 \(count) 间办公室）", role: .destructive) {
                        store.deleteFloor(floor)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("楼层操作")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(isTarget ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(isTarget ? Color.accentColor : Color.primary.opacity(0.10), lineWidth: isTarget ? 2 : 1)
            // ⚠️ 装饰层不拦鼠标 —— 否则会挡住这一条上的「整层拖动」落点
            .allowsHitTesting(false))
        // 整层拖动：来源楼层画淡一点，一眼看出「正在搬哪一层」
        .opacity(isSource ? 0.5 : 1)
        .contentShape(Rectangle())
        .onDrag {
            // 拿起整层：同步登记来源模块（落点据此判断归属，见 DragSwapSupport 顶部说明）
            store.beginFloorDrag(index)
            let payload = DragPayload.officeFloorPayload(index)
            DragContext.begin(module: DragPayload.officeFloor, payload: payload)
            return NSItemProvider(object: payload as NSString)
        }
        .onDrop(of: [.text], delegate: OfficeFloorDropDelegate(floorIndex: index, floor: floor, store: store))
        .help("拖动这一条可以把「\(label)」整层上下搬动（松手与目标楼层对调）；把办公室卡片拖上来则挪进这一层")
    }

    /// 楼层名称输入行：新建（列表末尾）/ 改名（楼层标题处）共用
    private func floorEditorRow(isNew: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "building.2")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(isNew ? "新建楼层：" : "改名：")
                .font(.system(size: 12))
            TextField("楼层名称（例如：三楼、X栋4楼）", text: $floorDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(width: 190)
                .focused($floorFieldFocused)
                .onSubmit { commitFloorEdit() }
            Button(isNew ? "创建" : "保存") { commitFloorEdit() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button("取消") { cancelFloorEdit() }
                .controlSize(.small)
            if isNew, let a = floorAssign, let o = store.offices.first(where: { $0.id == a }) {
                Text("（「\(o.title)」将移入该楼层）")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
    }

    private func beginNewFloor(assign id: UUID? = nil) {
        floorAssign = id
        floorDraft = ""
        floorEditKind = .new
        DispatchQueue.main.async { floorFieldFocused = true }
    }

    private func beginRenameFloor(_ floor: String) {
        floorAssign = nil
        floorDraft = floor
        floorEditKind = .rename(floor)
        DispatchQueue.main.async { floorFieldFocused = true }
    }

    private func cancelFloorEdit() {
        floorEditKind = nil
        floorDraft = ""
        floorAssign = nil
    }

    private func commitFloorEdit() {
        guard let kind = floorEditKind else { return }
        let name = floorDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        floorEditKind = nil
        defer { floorDraft = ""; floorAssign = nil }
        guard !name.isEmpty else { return }
        switch kind {
        case .new:            store.addFloor(named: name, assigning: floorAssign)
        case .rename(let o):  store.renameFloor(o, to: name)
        }
    }

    /// 一组卡片（同一楼层内）按两列排布；超过 4 列的卡片单独占一行
    @ViewBuilder
    private func cardRows(_ list: [OfficeBlock], availableWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            ForEach(Array(rowIDs(list).enumerated()), id: \.offset) { _, row in
                let widths = rowCardWidths(row, availableWidth: availableWidth)
                HStack(alignment: .top, spacing: Self.rowSpacing) {
                    ForEach(Array(row.enumerated()), id: \.element) { i, id in
                        // 卡片宽度：父视图按「本行可用宽度」摊给每张卡片（自适应列宽）；
                        // 摊不满（列少 / 宽度还没量出来）时传 nil，卡片保持固定列宽。
                        OfficeCard(office: binding(for: id),
                                   keyword: appliedKeyword,
                                   onNewFloor: { beginNewFloor(assign: $0) },
                                   targetWidth: widths[i])
                    }
                    // 单张卡片独占一行、且没摊满宽度时，补一个弹性占位保证左对齐。
                    if row.count == 1 {
                        Color.clear.frame(maxWidth: .infinity, minHeight: 1)
                    }
                }
            }
        }
    }

    /// 行内卡片之间的间距（表头 / 楼层标题条不参与，只用于卡片排布）
    private static let rowSpacing: CGFloat = 12

    // MARK: 列宽取证（`SCHEDULEBAR_TRACE_OFFICE=1`）
    // 为什么需要它：卡片自适应列宽依赖「本页真实可用宽度」，而离屏渲染（--render-office-page）
    // 是绕开 GeometryReader 喂进去的，证明不了运行时量到的宽度对不对。屏幕锁定/别处全屏时
    // 又抓不到图 —— 于是把实测数字直接打进日志，核对「右侧还空多少」不必靠截图。
    private static var seenLayoutTraces: Set<String> = []
    private func traceLayout(_ key: String) {
        guard ProcessInfo.processInfo.environment["SCHEDULEBAR_TRACE_OFFICE"] == "1" else { return }
        guard Self.seenLayoutTraces.insert(key).inserted else { return }  // 一次布局会算很多遍，只记一次
        SaveHub.log("工位列宽：\(key)")
    }

    /// 把一行里可用的宽度摊给各张卡片：每张卡片先按「列数 × 基准列宽」算出自然宽度，
    /// 多出来的宽度**按列数平分**（等于每一列加同样多），所以列多的卡片自然更宽。
    /// - 一行两张卡：摊的是整行宽度；
    /// - **一行只有一张卡：只摊「半行」**（见下面的 `rowShare`），避免这张卡被拉成巨无霸。
    /// 每列最多加到 `OfficeCard.maxSeatWidth`（兜底上限）。
    /// 返回 nil 表示「保持固定列宽」。
    private func rowCardWidths(_ row: [UUID], availableWidth: CGFloat) -> [CGFloat?] {
        let fallback: [CGFloat?] = Array(repeating: nil, count: row.count)
        guard availableWidth > 0, !row.isEmpty else { return fallback }
        var naturals: [CGFloat] = []
        var cols: [Int] = []
        for id in row {
            let block = store.offices.first { $0.id == id }
            let n = max(1, block?.seats.map(\.count).max() ?? OfficeLayoutStore.seatColumns)
            cols.append(n)
            naturals.append(OfficeCard.naturalWidth(columns: n))
        }
        // ⚠️ 一张卡片独占一行时按「半行」分配（2026-09-26 用户要求「新建办公室默认列宽为我截图所示列宽」）：
        //    否则这张卡独占整行、每格被拉到 maxSeatWidth 上限（120pt），比同页两卡并排的行（每格 ~74pt）
        //    粗一大截 —— 新建出来的那张卡尤其刺眼（名单还是空的，格子却最大）。
        //    「半行」正好等于「两卡同行时单卡能拿到的宽度」，于是整页每行的卡片一样宽、格子一样大。
        let rowShare = row.count == 1
            ? max(0, (availableWidth - Self.rowSpacing) / 2)
            : availableWidth
        let gaps = CGFloat(row.count - 1) * Self.rowSpacing
        let room = rowShare - gaps
        let totalNatural = naturals.reduce(0, +)
        let halfRowNote = row.count == 1 ? "（单卡按半行 \(Int(rowShare.rounded()))pt）" : ""
        // 自然宽度已经超过可用宽度（列太多）→ 交给 OfficeCard 自己按上限收窄，这里不参与。
        guard totalNatural > 0, totalNatural < room - 1 else {
            traceLayout("可用 \(Int(availableWidth.rounded()))pt\(halfRowNote)｜\(cols) 列：自然宽 \(Int(totalNatural.rounded()))pt 已占满，不摊")
            return fallback
        }
        let totalCols = CGFloat(cols.reduce(0, +))
        let extraPerCol = min((room - totalNatural) / max(1, totalCols),
                              OfficeCard.maxSeatWidth - OfficeCard.baseSeatWidth)
        guard extraPerCol > 0.5 else { return fallback }   // 几乎没富余，别为 0.4pt 折腾
        let widths = naturals.enumerated().map { i, nat in nat + extraPerCol * CGFloat(cols[i]) }
        // 顺带记下每列最终宽度：= 卡宽减掉列间距/尾部按钮/内边距后再除以列数
        let detail = zip(cols, widths).map { c, w -> String in
            let extras = CGFloat(c) * OfficeCard.seatSpacing + OfficeCard.trailingWidth + OfficeCard.cardHPadding
            let cell = (w - extras) / CGFloat(c)
            return "\(c)列 → 卡 \(Int(w.rounded()))pt / 格 \(String(format: "%.1f", cell))pt"
        }.joined(separator: "， ")
        let used = widths.reduce(0, +) + gaps
        traceLayout("可用 \(Int(availableWidth.rounded()))pt\(halfRowNote)｜\(detail)｜合计 \(Int(used.rounded()))pt（余 \(String(format: "%.1f", rowShare - used))pt）")
        return widths
    }

    /// 把办公室按两列分组；超过 4 列的办公室单独占一行，
    /// 但不会改变其它办公室的排列方式。
    private func rowIDs(_ list: [OfficeBlock]) -> [[UUID]] {
        var rows: [[UUID]] = []
        var index = 0
        while index < list.count {
            let office = list[index]
            if isWide(office) {
                rows.append([office.id])
                index += 1
            } else if index + 1 < list.count && !isWide(list[index + 1]) {
                rows.append([office.id, list[index + 1].id])
                index += 2
            } else {
                rows.append([office.id])
                index += 1
            }
        }
        return rows
    }

    private func isWide(_ office: OfficeBlock) -> Bool {
        (office.seats.map(\.count).max() ?? OfficeLayoutStore.seatColumns) > 4
    }

    private func binding(for id: UUID) -> Binding<OfficeBlock> {
        guard let index = store.offices.firstIndex(where: { $0.id == id }) else {
            return .constant(OfficeBlock(title: "", seats: [[]]))
        }
        return $store.offices[index]
    }
}

// 单间办公室卡片
struct OfficeCard: View {
    @Binding var office: OfficeBlock
    @EnvironmentObject var store: OfficeLayoutStore
    var keyword: String = ""                 // 查询姓名（已去抖）；命中的工位高亮闪烁
    /// 「新建楼层…」（从卡片上的楼层菜单触发，把这张卡片一起挪进新楼层）
    var onNewFloor: (UUID) -> Void = { _ in }
    /// 父视图按「本行可用宽度」分配到本卡片的目标宽度；nil = 保持固定列宽。
    /// 见 `OfficeLayoutView.rowCardWidths`。
    var targetWidth: CGFloat? = nil
    @State private var titleEditing = false
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool

    // MARK: 尺寸常量（自适应列宽要按「整行」汇总宽度，所以提成 static 供父视图复用）
    /// 工位列的基准列宽 —— 自适应时**只加宽不缩窄**，永远不比它窄
    static let baseSeatWidth: CGFloat = 60
    /// 自适应拉伸的上限列宽（避免一张卡片独占一行时被拉成巨无霸格子）
    static let maxSeatWidth: CGFloat = 120
    /// 列间距（表头 / 座位行 / 门牌行共用，保证栅格对齐）
    static let seatSpacing: CGFloat = 4
    /// 行尾「删除本行/本列」按钮统一占位，保证表头行与座位行栅格对齐
    static let trailingWidth: CGFloat = 18
    /// 卡片左右内边距合计（`.padding(8)` ×2）
    static let cardHPadding: CGFloat = 16

    /// 卡片自然宽度 = 列数 × 基准列宽 + 列间距 + 行尾按钮 + 左右内边距
    static func naturalWidth(columns n: Int) -> CGFloat {
        let n = max(1, n)
        return CGFloat(n) * baseSeatWidth + CGFloat(n) * seatSpacing
            + trailingWidth + cardHPadding
    }

    private var seatWidth: CGFloat { Self.baseSeatWidth }
    private var columnSpacing: CGFloat { Self.seatSpacing }
    private var trailingButtonWidth: CGFloat { Self.trailingWidth }
    /// 卡片可用宽度上限（面板 880 − 侧栏 170 − 内边距留白）：
    /// 只有在列数多到会溢出时才整体收窄。
    private let maxCardWidth: CGFloat = 660

    /// 实际列宽：
    /// ① 父视图分配了目标宽度（自适应列宽）→ 把宽度摊进每一列，且不小于基准列宽；
    /// ② 没分配 → 基准列宽 60；
    /// ③ 列数多到会溢出 → 按比例收窄（下限 22）。
    private var cellW: CGFloat {
        let n = max(1, columnCount)
        let extras = CGFloat(n) * columnSpacing + trailingButtonWidth + Self.cardHPadding
        if let target = targetWidth {
            let available = target - extras
            if available > CGFloat(n) * seatWidth {
                return available / CGFloat(n)
            }
        }
        let needed = CGFloat(n) * seatWidth + extras
        guard needed > maxCardWidth else { return seatWidth }
        let avail = maxCardWidth - trailingButtonWidth - Self.cardHPadding
            - CGFloat(n) * columnSpacing
        return max(22, avail / CGFloat(n))
    }

    /// 卡片宽度 = 列数 × 列宽 + 列间距 + 行尾按钮 + 左右内边距
    private var cardWidth: CGFloat {
        let n = max(1, columnCount)
        return CGFloat(n) * cellW + CGFloat(n) * columnSpacing + trailingButtonWidth
            + Self.cardHPadding
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 标题行：左边「手柄 + 标题」= 整张卡片的抓取区（拖动换位置 / 换楼层），双击标题改名
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    titleView
                }
                .contentShape(Rectangle())
                .onDrag {
                    // 拿起时同步登记来源模块（见 DragSwapSupport.swift 的说明）
                    store.beginCardDrag(office.id)
                    let payload = DragPayload.officeCardPayload(office.id)
                    DragContext.begin(module: DragPayload.officeCard, payload: payload)
                    return NSItemProvider(object: payload as NSString)
                }
                .help("按住这里拖动：整张卡片换位置、换楼层；双击标题可改名")

                Text("\(office.headcount)人")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    .help("当前办公室实际人数")
                floorMenu
                Button {
                    store.removeOffice(office.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("删除此办公室")
            }

            if store.showDoors && !store.studentView {
                // 内部视角：从办公室内部看，门在工位上方
                doorRow(left: "左门", right: "右门")
            }

            // 列管理：每列可删除，末尾可增加一列（外部视角下显示列号镜像）
            // 列宽固定：加列只是向右多一列，不会把已有列挤窄
            HStack(spacing: columnSpacing) {
                ForEach(0..<columnCount, id: \.self) { displayCol in
                    let c = modelCol(displayCol)
                    HStack(spacing: 2) {
                        Text("列\(c + 1)")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity)
                        Button {
                            store.removeColumn(office.id, c)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("删除第\(c + 1)列")
                    }
                    .frame(width: cellW)
                }
                Button {
                    store.addColumn(office.id)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("增加一列")
                .frame(width: trailingButtonWidth)
            }

            // 座位（动态列数 × N 行；右键可换座位颜色）
            ForEach(0..<rowCount, id: \.self) { displayRow in
                let r = modelRow(displayRow)
                HStack(spacing: columnSpacing) {
                    ForEach(0..<columnCount, id: \.self) { displayCol in
                        let c = modelCol(displayCol)
                        if office.seats.indices.contains(r), office.seats[r].indices.contains(c) {
                            seatCell(row: r, col: c)
                        } else {
                            Color.clear.frame(width: cellW, height: 26)
                        }
                    }
                    Button {
                        store.removeRow(office.id, r)
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("删除此行")
                    .frame(width: trailingButtonWidth)
                }
            }

            Button {
                store.addRow(office.id)
            } label: {
                Label("添加一行", systemImage: "plus")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            if store.showDoors && store.studentView {
                // 外部视角：门移到工位下方，左门仍在左、右门仍在右（与内部视角的命名一致）
                doorRow(left: "左门", right: "右门")
            }
        }
        .padding(8)
        .frame(width: cardWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.3)))
        // 整张卡片 = 「整张卡片拖动」的落点：座位格会先接住，这里兜住标题/按钮/留白区，
        // 于是「卡片任意位置都能互相拖」。
        .onDrop(of: [.text], delegate: OfficeCardDropDelegate(targetID: office.id, store: store))
        .overlay(
            Group {
                if store.cardDropTarget == office.id {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.accentColor, lineWidth: 2.5)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(Color.accentColor.opacity(0.06)))
                }
            }
            // ⚠️ 高亮层不拦鼠标：整张卡本身就是「整卡拖动 / 整层拖动」的落点，
            //    被自己盖住就会出现「有高亮、松手却没反应」
            .allowsHitTesting(false)
        )
        // 正在被拖动的卡片画淡一点，便于看清「哪张在动、要落到哪」
        .opacity(store.cardDragSourceID == office.id ? 0.45 : 1)
    }

    /// 标题（双击进入行内改名）
    @ViewBuilder
    private var titleView: some View {
        if titleEditing {
            TextField("", text: $titleDraft)
                .focused($titleFocused)
                .textFieldStyle(.plain)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .onAppear {
                    titleDraft = office.title
                    DispatchQueue.main.async { titleFocused = true }
                }
                .onChange(of: titleFocused) { f in
                    if !f {
                        titleEditing = false
                        office.title = titleDraft
                    }
                }
                .onSubmit { titleFocused = false }
        } else {
            Text(office.title)
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { titleEditing = true }
                .help("双击重命名")
        }
    }

    /// 卡片上的楼层菜单：点一下就能换楼层 / 建新楼层（也可以直接把卡片拖到别的楼层去）
    private var floorMenu: some View {
        Menu {
            ForEach(store.floorNames, id: \.self) { f in
                Button {
                    store.setFloor(office.id, to: f)
                } label: {
                    if f == office.floor {
                        Label(f.isEmpty ? "未分组" : f, systemImage: "checkmark")
                    } else {
                        Text(f.isEmpty ? "未分组" : f)
                    }
                }
            }
            Divider()
            if !office.floor.isEmpty {
                Button("移出楼层（未分组）") { store.setFloor(office.id, to: "") }
            }
            Button("新建楼层…") { onNewFloor(office.id) }
        } label: {
            Image(systemName: office.floor.isEmpty ? "building.2" : "building.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(office.floor.isEmpty ? Color.secondary : Color.accentColor)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(office.floor.isEmpty
              ? "所属楼层：未分组（点此选择或新建楼层）"
              : "所属楼层：\(office.floor)（点此更换）")
    }

    /// 门牌行：与座位栅格对齐——左门落在第一列、右门落在最后一列，中间留空列。
    private func doorRow(left: String, right: String) -> some View {
        HStack(spacing: columnSpacing) {
            if columnCount >= 2 {
                doorLabel(left).frame(width: cellW)
                ForEach(1..<max(1, columnCount - 1), id: \.self) { _ in
                    Color.clear.frame(width: cellW, height: 20)
                }
                doorLabel(right).frame(width: cellW)
            } else {
                // 只有一列时左右门各占半格，避免门牌撑破栅格
                doorLabel(left).frame(width: cellW / 2)
                doorLabel(right).frame(width: cellW / 2)
            }
            Color.clear.frame(width: trailingButtonWidth, height: 20)
        }
    }

    private func doorLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.yellow.opacity(0.35)))
    }

    private var columnCount: Int {
        max(1, office.seats.map(\.count).max() ?? OfficeLayoutStore.seatColumns)
    }

    private var rowCount: Int {
        max(1, office.seats.count)
    }

    private func modelRow(_ displayRow: Int) -> Int {
        store.studentView ? rowCount - 1 - displayRow : displayRow
    }

    private func modelCol(_ displayCol: Int) -> Int {
        store.studentView ? columnCount - 1 - displayCol : displayCol
    }

    /// 该座位是否命中查询（忽略大小写、忽略首尾空格）
    private func isHit(row r: Int, col c: Int) -> Bool {
        let k = keyword.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty, r < office.seats.count, c < office.seats[r].count else { return false }
        return office.seats[r][c].localizedCaseInsensitiveContains(k)
    }

    // 单个座位格：自定义底色 + 右键调色板；命中查询时包进 BreathingWrap 播放独立的呼吸动画
    private func seatCell(row r: Int, col c: Int) -> some View {
        let hex = office.seatColor(row: r, col: c)
        let hit = isHit(row: r, col: c)
        let cell = EditableGridCell(text: $office.seats[r][c],
                                    width: cellW,
                                    height: 26,
                                    flexible: false,
                                    backgroundColor: hex.map { Color(hexString: $0).opacity(0.30) },
                                    onSave: {})
        .contextMenu {
            ColorPaletteMenu(current: hex) { office.setSeatColor($0, row: r, col: c) }
        }
        .help("双击编辑文字，右键更换颜色")

        return Group {
            if hit {
                // 每个命中格独享动画：子视图销毁时动画随之消失，互不干扰
                BreathingWrap { cell }
            } else {
                cell
            }
        }
        .overlay(
            Group {
                if let hl = store.dropHighlight, hl.officeID == office.id, hl.row == r, hl.col == c {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.accentColor, lineWidth: 2.5)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.18)))
                }
            }
            // ⚠️ 同上：格子高亮不能拦住自己身上的落点检测
            .allowsHitTesting(false)
        )
        .contentShape(Rectangle())
        .onDrag {
            store.beginSeatDrag(officeID: office.id, row: r, col: c)
            // 拿起时同步登记来源模块，落点据此同步换位（见 DragSwapSupport.swift 的说明）
            let payload = DragPayload.office(office.id, row: r, col: c)
            DragContext.begin(module: DragPayload.officeSeat, payload: payload)
            return NSItemProvider(object: payload as NSString)
        }
        .onDrop(of: [.text], delegate: OfficeSeatSwapDelegate(officeID: office.id,
                                                               row: r, col: c, store: store))
        .help("双击编辑文字，拖动可与其它工位对换，右键更换颜色")
        .zIndex(hit ? 1 : 0)
    }
}

// MARK: - 命中工位的呼吸动画包装（放大缩小 + 橙色高亮，动画生命周期与本视图绑定）
private struct BreathingWrap<Content: View>: View {
    let content: () -> Content
    @State private var on = false

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.orange.opacity(on ? 0.75 : 0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.orange, lineWidth: on ? 3 : 2)
                    .opacity(on ? 1 : 0.5)
                    .allowsHitTesting(false)   // 呼吸高亮只是装饰，别拦住工位本身的拖拽
            )
            .shadow(color: Color.orange.opacity(on ? 0.5 : 0.15), radius: on ? 7 : 3)
            .scaleEffect(on ? 1.15 : 0.85)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) {
                    on = true
                }
            }
    }
}
