import Foundation
import SwiftUI

// MARK: - 个人课表数据模型（上午/下午/晚自习 分组，节次可增删；持久化 personal.json）

/// 一个时段分组（上午 / 下午 / 晚自习）
struct PersonalGroup: Codable, Equatable {
    var title: String
    var periods: [String]
}

/// 存储格式：{"groups": [...], "grid": [[...]]}
/// grid 行序与 groups.flatMap{ $0.periods } 一一对应
struct PersonalData: Codable {
    var groups: [PersonalGroup]
    var grid: [[String]]
}

/// 个人课表存储（7 天；周一~周五 + 周六 + 周日 —— 周六/周日可在界面里显示或隐藏）
/// 单元格内容为班级/巡班文本，如 "7"、"8"、"巡1-15班"、"8班+巡16-30"
final class ScheduleStore: ObservableObject {
    static let shared = ScheduleStore()

    // 列：星期（7 天；顺序：周一→周五、周六、周日）
    // ⚠️ 周六在 index 5、周日在 index 6 —— 与 ClassLayout.days / TeacherBlock.days 保持一致。
    //    6→7 列迁移必须在 index 5 **插入空白周六**（见 addSaturdayColumn），
    //    整行右移或在末尾补空都会让用户的周日数据落到周六列上。
    static let days = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    /// 默认布局：上午 早自习 + 5 节 → 下午 4 节 → 晚自习 4 节
    ///
    /// ⚠️「早自习」必须留在默认布局里（2.5.24 起）：它只是**一行名字特殊的普通节次**，
    ///    淡绿底色靠名字识别（见 `PersonalScheduleView.nonClassPeriods`）。
    ///    默认布局里没有它，别人装完就永远看不到这一行 —— 2026-11-10 用户报的正是这个。
    static let defaultGroups: [PersonalGroup] = [
        PersonalGroup(title: "上午", periods: ["早自习", "第1节", "第2节", "第3节", "第4节", "第5节"]),
        PersonalGroup(title: "下午", periods: ["第6节", "第7节", "第8节", "第9节"]),
        PersonalGroup(title: "晚自习", periods: ["晚1", "晚2", "晚3", "晚4"]),
    ]

    /// 旧版（无分组）默认节次，仅用于迁移历史数据
    private static let legacyPeriods = [
        "早自习", "第1节", "第2节", "第3节", "第4节", "第5节",
        "第6节", "第7节", "第8节", "第9节", "晚自习"
    ]

    @Published var groups: [PersonalGroup] {
        didSet { scheduleSave() }
    }
    @Published var grid: [[String]] {
        didSet { scheduleSave() }
    }


    init() {
        let data = ScheduleStore.load()
        // 兜底：没有本地数据、或本地数据节次为空（旧版清空过）→ 用默认布局，
        // 保证个人课表任何情况下都「有节次的空表」，可以直接双击填写。
        var gs: [PersonalGroup]
        if let g = data?.groups, !g.isEmpty, !g.allSatisfy({ $0.periods.isEmpty }) {
            gs = g
        } else {
            gs = ScheduleStore.defaultGroups
        }
        var gd = ScheduleStore.normalizeGrid(data?.grid ?? [], periods: gs.flatMap { $0.periods })
        // 一次性迁移（2.5.24）：老数据里没有「早自习」→ 在最前面补一行**空白**。
        let migrated = ScheduleStore.addEarlyStudyRowIfNeeded(&gs, grid: &gd)

        self.groups = gs
        self.grid = gd
        // 修正历史错位：保证「第N节」/「晚N」按显示顺序连续编号
        renumberPeriods()
        isInitializing = false   // 装载结束，之后的改动才算用户编辑
        // ⚠️ 迁移补的那一行必须立刻落盘：装载期的赋值被 `isInitializing` 闸门挡掉了，
        //    不在这里补一次 save，下次启动标记已存在 → 行不会再加 → 用户眼里「补了又没了」。
        if migrated { save() }
    }

    static func emptyGrid(periods: [String]) -> [[String]] {
        Array(repeating: Array(repeating: "", count: days.count), count: periods.count)
    }

    /// 把任意行列数的网格归一到给定节次数量（列不足补空、超出截断；行同理）
    static func normalizeGrid(_ grid: [[String]], periods: [String]) -> [[String]] {
        var out: [[String]] = grid.map { row in
            var r = Array(row.prefix(days.count))
            if r.count < days.count {
                r.append(contentsOf: Array(repeating: "", count: days.count - r.count))
            }
            return r
        }
        if out.count < periods.count {
            out.append(contentsOf: Array(repeating: Array(repeating: "", count: days.count),
                                         count: periods.count - out.count))
        }
        if out.count > periods.count { out = Array(out.prefix(periods.count)) }
        return out
    }

    // MARK: 派生数据
    /// 全部节次（按分组顺序展开）
    var orderedPeriods: [String] { groups.flatMap { $0.periods } }
    /// 兼容旧引用（导入 / 导出等）
    var periods: [String] { orderedPeriods }

    /// 节次 → grid 行下标
    func flatIndex(of period: String) -> Int? {
        var i = 0
        for g in groups {
            if let k = g.periods.firstIndex(of: period) { return i + k }
            i += g.periods.count
        }
        return nil
    }

    /// 诊断输出（两种运行模式都留痕，都能核对）：
    /// · 总是打 stdout —— 终端里跑自检时当场可见；
    /// · **自检 / 取证运行**（`SCHEDULEBAR_DATA_DIR` 已重定向）→ 写进那个临时目录的
    ///   `个人课表诊断.log`。这样自检也有留痕可查，又**绝不污染用户的运行日志**
    ///   （否则以后翻日志取证时，会看到一堆「用户没做过的操作」）；
    /// · **真实运行**（没重定向）→ 追加进 `~/Library/Logs/教师助手.log`。
    ///
    /// ⚠️ GUI 进程的 stdout 是无处可去的：不写文件 = 用户报问题时我们手上什么都没有。
    private func diagLog(_ line: String) {
        print("[ScheduleBar] \(line)")
        let stamp = { () -> String in
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f.string(from: Date())
        }()
        guard let c = getenv("SCHEDULEBAR_DATA_DIR"), let dir = String(validatingUTF8: c), !dir.isEmpty else {
            DragSessionGuard.log(line)      // 真实运行 → 用户日志
            return
        }
        let path = (dir as NSString).appendingPathComponent("个人课表诊断.log")
        guard let data = "[\(stamp)] \(line)\n".data(using: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// 网格行数必须与节次总数一一对应。**写操作前先自愈**。
    ///
    /// 为什么必须有这一步：`grid` 是「按行下标」存内容的，一旦行数比节次数少，
    /// 靠后的节次（例如「第9节」）算出来的行号就越界 —— `setCell` / `swapCellTo` 的
    /// guard 会**静默返回**，用户看到的就是「双击编辑第9节、把它拖到别处都不生效」；
    /// 而重新打开 App 时 `init` 里的 `normalizeGrid` 会把网格补齐，于是又「好了」。
    /// 这正是「必须退出再打开才行」这一类现象的来源，所以在写路径上直接把它抹掉。
    /// - Returns: 是否真的修正过（修正过会打一行日志，便于取证）
    @discardableResult
    func ensureGridShape() -> Bool {
        let want = orderedPeriods.count
        guard grid.count != want else { return false }
        let had = grid.count
        grid = ScheduleStore.normalizeGrid(grid, periods: orderedPeriods)
        diagLog("个人课表网格行数自愈：\(had) → \(grid.count)（节次数 \(want)）")
        return true
    }

    func cell(_ period: String, _ day: Int) -> String {
        guard let r = flatIndex(of: period), r < grid.count, day < grid[r].count else { return "" }
        return grid[r][day]
    }

    func setCell(_ period: String, _ day: Int, _ value: String) {
        guard let r = flatIndex(of: period) else { return }
        ensureGridShape()   // 行数不一致 → 先补齐，别让这次编辑静默丢失
        guard r < grid.count, day < grid[r].count else { return }
        guard grid[r][day] != value else { return }   // 值没变就不写盘（编辑态 onAppear 会回灌一次原值）
        grid[r][day] = value
        scheduleSave()
    }

    // MARK: 单元格拖动对换（同一张个人课表内）

    /// 拖动中的单元格来源（普通 var，不进 @Published：拖动过程中不刷新视图）
    var cellDragSource: ScheduleCellID?
    private var cellDragSnapshot: [[String]]?

    func beginCellDrag(_ period: String, _ day: Int) {
        guard let r = flatIndex(of: period), r < grid.count, day < grid[r].count else { return }
        cellDragSnapshot = grid
        cellDragSource = ScheduleCellID(period: period, day: day)
    }

    /// 把拖动来源格与目标格的课表内容对换
    func swapCellTo(_ period: String, _ day: Int) {
        guard let src = cellDragSource,
              let sr = flatIndex(of: src.period), let dr = flatIndex(of: period) else { return }
        ensureGridShape()   // 同上：行数不一致会让对换静默失败
        guard sr < grid.count, dr < grid.count,
              grid[sr].indices.contains(src.day), grid[dr].indices.contains(day),
              !(sr == dr && src.day == day) else { return }
        let tmp = grid[sr][src.day]
        grid[sr][src.day] = grid[dr][day]
        grid[dr][day] = tmp
        scheduleSave()
        // 来源位置跟着被拖动的内容走，避免 dropEntered 连续触发时来回抖动
        cellDragSource = ScheduleCellID(period: period, day: day)
    }

    func finishCellDrag() {
        defer { cellDragSource = nil; cellDragSnapshot = nil }
        guard let snap = cellDragSnapshot, snap != grid else { return }
        UndoService.shared.register("调整课表位置") { [weak self] in
            guard let self else { return }
            self.grid = snap
            self.scheduleSave()
        }
    }

    /// 拖动被外部打断（切走 App / 窗口失去 key / 面板收起）时清掉拖动状态。
    /// 只复位来源与快照，不改任何单元格内容、不登记撤销 —— 避免上一轮的
    /// 拖动来源残留，导致下一次对换换错对象或「拖了没反应」。
    /// - Returns: 之前是否真的有一次未完成的拖动（用于判断要不要重建面板窗口）
    @discardableResult
    func cancelCellDrag() -> Bool {
        let had = cellDragSource != nil
        cellDragSource = nil
        cellDragSnapshot = nil
        return had
    }

    // MARK: 节次增删（在某个时段内）

    /// 新增一节**空白**节次（严格按 Excel「插入行」的语义，2026-10-01 用户指定）：
    ///
    /// 1. 新节次追加到**该组末尾**，它的那一行内容全空（不会借用、不会覆盖任何已有课程）；
    /// 2. 该行插在表格的正确位置（= 该组最后一行之后），**后面的节次整体下移一行**，
    ///    它们的内容跟着自己那一行一起下移（不重排、不丢失 —— 就像 Excel 里插入一行）；
    /// 3. 只把「第N节 / 晚N」的**编号**按显示顺序重排（第n节 → 第n+1节），
    ///    自定义名称（早自习 / 晚自习…）原样保留。
    ///
    /// ⚠️ 一次算完再整体赋值：中间态（新节次与后面组同号）绝不落盘、也绝不进渲染。
    ///
    /// - Returns: 新节次的标签（分组下标非法时 nil）。供自检断言、以及「高亮刚加的这一行」用。
    @discardableResult
    func addPeriod(in groupIndex: Int) -> String? {
        guard groups.indices.contains(groupIndex) else { return nil }
        ensureGridShape()
        // 校验用快照：必须取在**自愈之后、任何改动之前**，否则比的是两个不同的基准。
        let gridBefore = grid

        // 新节次的标签：按**该组自己的**最大编号 +1（「上午/下午」用「第N节」，「晚自习」用「晚N」）
        let isEvening = groups[groupIndex].title.contains("晚")
        let label: String
        if isEvening {
            let nums = groups[groupIndex].periods.compactMap { Self.eveningNumber($0) }
            label = "晚\((nums.max() ?? 0) + 1)"
        } else {
            let nums = groups[groupIndex].periods.compactMap { Self.numberedPart($0) }
            label = "第\((nums.max() ?? 0) + 1)节"
        }

        var gs = groups
        var gd = grid
        // 插入位置 = 该组最后一个节次之后（= 新标签在展开后的下标）
        let insertAt = groups[0..<groupIndex].reduce(0) { $0 + $1.periods.count }
            + gs[groupIndex].periods.count
        gs[groupIndex].periods.append(label)
        let blankRow = Array(repeating: "", count: Self.days.count)
        if insertAt <= gd.count { gd.insert(blankRow, at: insertAt) } else { gd.append(blankRow) }

        groups = gs          // 先落「改后」的整体状态
        grid = gd
        renumberPeriods()    // 再统一重排编号（第n节 → 第n+1节）

        // 自证 + 兜底：新节次必须是空的一行，行数与节次数仍一一对应。
        // （不用 assert：release 下断言会被编译掉，这里要的是真保证。）
        if let r = flatIndex(of: label), r < grid.count, !grid[r].allSatisfy({ $0.isEmpty }) {
            diagLog("⚠️ 新增节次「\(label)」意外的非空行，已清空")
            grid[r] = Array(repeating: "", count: Self.days.count)
        }
        _ = ensureGridShape()
        if grid.count != orderedPeriods.count {
            diagLog("⚠️ 新增节次后行数 \(grid.count) ≠ 节次数 \(orderedPeriods.count)")
        }

        // MARK: 运行时硬校验（用户 2026-10-01 明确定的规则，每次新增都真跑一遍并留日志）
        //
        // 规则原话：「上午插入节，不能影响到下午的课的安排……参考 excel 的插入行功能，
        //           不能改变其他的内容和位置」「下午编号改变，但是只变化编号，不改变课程内容；
        //           比如第6节8班变成第7节8班」。
        // 翻成人话就是两条不变式：
        //   ① 插入点**以上**的行，逐格一模一样；
        //   ② 插入点**以下**的行整体下移一行之后（原来的第 i 行 → 现在的第 i+1 行），逐格一模一样。
        // 只要这两条成立，就说明「动的只有插入的那一行 + 节次的名字」，其它课一格没碰。
        // ⚠️ 用 print 而不是 assert：release 构建会把 assert 整个编译掉，而这个保证在任何
        //    构建下都必须真的被执行、并能在日志里被核对（用户长期约定：取证看运行日志）。
        let gridAfter = grid
        var intact = true
        for i in 0..<insertAt where i < gridBefore.count && i < gridAfter.count {
            if gridBefore[i] != gridAfter[i] { intact = false; break }
        }
        if intact {
            for i in insertAt..<gridBefore.count where i + 1 < gridAfter.count {
                if gridBefore[i] != gridAfter[i + 1] { intact = false; break }
            }
        }
        let movedRows = max(0, gridBefore.count - insertAt)
        if intact {
            diagLog("新增节次：组「\(groups[groupIndex].title)」→「\(label)」，插在第 \(insertAt + 1) 行；"
                + "其余 \(movedRows) 行整体下移一行、内容逐格未变 ✓")
        } else {
            diagLog("⚠️ 新增节次「\(label)」后，其他节次的课程内容发生了变化（本应只变编号）——"
                + "请把这份日志发出来定位")
        }
        return label
    }

    /// 删除节次（连同它那一行的内容），随后统一重编号
    /// ⚠️ 只删**第一个**同名节次：同名节次出现在多个分组时，逐个分组都删会把节次数
    ///    比网格行数多删掉，导致后面的节次整体错位、靠后的格子再也写不进去。
    func removePeriod(_ label: String) {
        guard orderedPeriods.count > 1, let flat = flatIndex(of: label) else { return }
        let snapGroups = groups, snapGrid = grid
        var gs = groups
        var removed = false
        for i in gs.indices where !removed {
            if let k = gs[i].periods.firstIndex(of: label) {
                gs[i].periods.remove(at: k)
                removed = true
            }
        }
        guard removed else { return }
        var gd = grid
        if flat < gd.count { gd.remove(at: flat) }
        groups = gs
        grid = gd
        // 删除后重新编号，让后续节次顺序保持连续
        renumberPeriods()
        UndoService.shared.register("删除节次「\(label)」") { [weak self] in
            guard let self else { return }
            self.groups = snapGroups
            self.grid = snapGrid
            self.scheduleSave()
        }
    }

    /// 重命名某一节（2.5.24 用户要求 A+B 的 B）—— 只换**名字**，那一行的课程一格都不动。
    ///
    /// 有了它，「早自习」「午自习」「早读」这类非上课时段谁都能自己造：
    /// 双击节次名改名即可，改完立刻按新名字判定要不要那条淡绿底色。
    ///
    /// ⚠️ 重名一律拒绝：单元格是按「节次名」定位的（`flatIndex(of:)` 取第一个同名），
    ///    一旦出现两个同名节次，后面那个就读不到自己的数据、写进去也会串行。
    /// - Returns: 是否真的改成了（空名 / 重名 / 与原值相同都返回 false）。
    @discardableResult
    func renamePeriod(in groupIndex: Int, at row: Int, to newName: String) -> Bool {
        guard groups.indices.contains(groupIndex),
              groups[groupIndex].periods.indices.contains(row) else { return false }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        let old = groups[groupIndex].periods[row]
        guard name != old else { return false }
        guard !orderedPeriods.contains(name) else {
            diagLog("重命名被拒：「\(name)」已经是另一节的名称（同名节次会让数据串行）")
            return false
        }
        ensureGridShape()
        var gs = groups
        gs[groupIndex].periods[row] = name
        groups = gs                      // didSet → 立即落盘
        UndoService.shared.register("重命名节次「\(old)」→「\(name)」") { [weak self] in
            guard let self else { return }
            var back = self.groups
            guard back.indices.contains(groupIndex),
                  back[groupIndex].periods.indices.contains(row) else { return }
            back[groupIndex].periods[row] = old
            self.groups = back
            self.scheduleSave()
        }
        diagLog("重命名节次：组「\(groups[groupIndex].title)」第 \(row + 1) 行「\(old)」→「\(name)」，课程内容未动")
        return true
    }

    /// 重新编号所有「第N节」/「晚N」节次：按显示顺序重新填充连续编号；
    /// 自定义名称（如「早自习」「晚自习」「课间」等）保持原样不动。
    ///
    /// ⚠️ 先在局部副本上算完再**一次性赋值**：`groups` 是 `@Published` + `didSet` 落盘，
    ///    逐格赋值会让一次「新增节次」触发 N 次写盘（既慢，也让「文件 mtime 批次」取证失真）。
    func renumberPeriods() {
        var gs = groups
        var dayCounter = 0
        var eveCounter = 0
        for i in gs.indices {
            for j in gs[i].periods.indices {
                let p = gs[i].periods[j]
                if Self.numberedPart(p) != nil {
                    dayCounter += 1
                    gs[i].periods[j] = "第\(dayCounter)节"
                } else if Self.eveningNumber(p) != nil {
                    eveCounter += 1
                    gs[i].periods[j] = "晚\(eveCounter)"
                }
            }
        }
        if gs != groups { groups = gs }   // 没变就不写盘
    }

    /// "第3节"/"第10节" → 3/10；不匹配返回 nil
    private static func numberedPart(_ s: String) -> Int? {
        guard s.hasPrefix("第"), s.hasSuffix("节"), s.count > 2 else { return nil }
        return sectionNumber(s)
    }

    /// "晚1"/"晚12" → 1/12；"晚自习" 等含汉字的返回 nil
    private static func eveningNumber(_ s: String) -> Int? {
        guard s.hasPrefix("晚"), s.count > 1 else { return nil }
        let tail = String(s.dropFirst())
        return tail.allSatisfy { $0.isNumber } ? sectionNumber(tail) : nil
    }

    func clear() {
        let snapGroups = groups, snapGrid = grid
        groups = ScheduleStore.defaultGroups
        grid = ScheduleStore.emptyGrid(periods: orderedPeriods)
        scheduleSave()
        UndoService.shared.register("重置个人课表") { [weak self] in
            guard let self else { return }
            self.groups = snapGroups
            self.grid = snapGrid
            self.scheduleSave()
        }
    }

    // MARK: 持久化（JSON，存于 Application Support/ScheduleBar；输入去抖）
    /// 装载/规范化期间为 true —— 此时对属性的赋值不是「用户编辑」，不该让保存按钮亮起来。
    /// ⚠️ `@Published` 属性的 `didSet` 在 `init` 里**也会触发**（赋值走的是属性包装器的
    ///    setter，不是纯初始化路径），所以必须有这道闸门：否则 App 一启动就有
    ///    「个人课表 / 学生座位 / 当前周」三个板块显示「有未保存的改动」
    ///    （2026-09-18 实测）。init 末尾把它置回 false。
    private var isInitializing = true

    /// 用户编辑 → **立即落盘**（2026-09-28 用户要求「自动保存所有板块」）：改一下就写盘，不走 SaveHub 标脏。
    func scheduleSave() {
        guard !isInitializing else { return }   // 装载期不算用户编辑
        save()
    }

    func save() {
        do {
            let url = Self.fileURL()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(PersonalData(groups: groups, grid: grid))
            try data.write(to: url, options: .atomic)
        } catch {
            print("[ScheduleBar] 保存失败: \(error)")
        }
    }

    // MARK: 一次性迁移（2.5.24：给老数据补「早自习」行）
    //
    // 用户 2026-11-10 问：「别人使用的时候为什么没有早自习？」
    // 原因：早自习不是内置行，只是名字叫「早自习」的普通节次；淡绿底色按名字识别。
    //      老版本默认布局里有它，2.x 改成分组布局后默认值从「第1节」开始 → 新装的人看不到。
    //
    // 这里做两件事：
    //   ① 默认布局自带早自习（见 defaultGroups）；
    //   ② 老数据（已经存过 personal.json 的人）首次运行新版本时，在最前面补一行**空白**。
    //
    // ⚠️ 只补一次，且**删了不复活**：动手前先看标记文件，无论这次有没有真的补，都写标记。
    //    否则用户右键删掉这一行，下次启动又冒出来。
    // ⚠️ 标记用文件、不用 UserDefaults：裸二进制与 App 的偏好域不同，UserDefaults 开关会重跑。
    private static let migrationsFile = "migrations.json"
    private static let earlyStudyKey = "earlyStudyRow"

    static func hasMigrated(_ key: String) -> Bool {
        guard let raw = try? Data(contentsOf: AppPaths.file(migrationsFile)),
              let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { return false }
        return obj[key] != nil
    }

    static func markMigrated(_ key: String, value: String) {
        var obj: [String: Any] = [:]
        if let raw = try? Data(contentsOf: AppPaths.file(migrationsFile)),
           let old = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] {
            obj = old
        }
        obj[key] = value
        guard let out = try? JSONSerialization.data(withJSONObject: obj,
                                                    options: [.sortedKeys, .prettyPrinted]) else { return }
        try? FileManager.default.createDirectory(at: AppPaths.dataDir, withIntermediateDirectories: true)
        try? out.write(to: AppPaths.file(migrationsFile), options: .atomic)
    }

    /// 老数据补「早自习」行。直接改 `groups` / `grid`，返回**这次有没有真的补**。
    private static func addEarlyStudyRowIfNeeded(_ groups: inout [PersonalGroup],
                                                grid: inout [[String]]) -> Bool {
        // 已经做过就彻底不管 —— 包括「用户后来自己删掉了」这种情况。
        guard !hasMigrated(earlyStudyKey) else { return false }
        defer { markMigrated(earlyStudyKey, value: AppVersion.short) }

        let alreadyHas = groups.contains { $0.periods.contains("早自习") }
        guard !alreadyHas, !groups.isEmpty else { return false }

        groups[0].periods.insert("早自习", at: 0)
        // ⚠️ 补的是**空白行**插在最前，不是把已有内容整体下移：
        //    行序 ↔ 节次名是一一对应的，插空行后原来的「第1节」仍带着自己的课。
        grid.insert(Array(repeating: "", count: days.count), at: 0)
        DragSessionGuard.log("迁移：老数据缺「早自习」，已在最前面补一行空白（只做这一次；删掉后不再补）")
        return true
    }

    // MARK: 加载与迁移

    /// 6 列（周一~周五 + 周日）→ 7 列：在 **index 5 插入空白周六**。
    ///
    /// 历史沿革：最老的版本本来就是 7 列（周一~周日，周六在 index 5），
    /// 后来「去掉周六」把那第 5 列删掉 → 周日从 index 6 落到 index 5。
    /// 现在恢复 7 列，所以：
    ///   · 7 列的老文件 ≈ 新布局，**原样保留**（⚠️ 千万不要再删 index 5）；
    ///   · 6 列的文件必须把空白周六插回 index 5，周日才会回到 index 6。
    private static func addSaturdayColumn(_ rows: [[String]]) -> [[String]] {
        rows.map { row in
            guard row.count == days.count - 1 else { return row }
            var r = row
            r.insert("", at: days.count - 2)   // 插在「周日」前面
            return r
        }
    }

    static func load() -> PersonalData? {
        let url = fileURL()
        guard let raw = try? Data(contentsOf: url) else { return nil }

        // 新格式：{"groups","grid"}
        if let d = try? JSONDecoder().decode(PersonalData.self, from: raw), !d.groups.isEmpty {
            return normalize(PersonalData(groups: d.groups, grid: addSaturdayColumn(d.grid)))
        }
        // 中间格式：{"periods","grid"} → 按名称归入 上午/下午/晚自习
        if let d = try? JSONDecoder().decode([String: [[String]]].self, from: raw),
           let oldPeriods = d["periods"]?.compactMap({ $0.first }),
           let oldGrid = d["grid"], !oldPeriods.isEmpty {
            return normalize(regroup(periods: oldPeriods, grid: addSaturdayColumn(oldGrid)))
        }
        // 最旧格式：纯 [[String]]（7 列 = 周一~周日，已经是新布局，原样使用）
        if let rows = try? JSONDecoder().decode([[String]].self, from: raw) {
            let oldPeriods = rows.count == legacyPeriods.count
                ? legacyPeriods
                : (0..<rows.count).map { "第\($0 + 1)节" }
            return normalize(regroup(periods: oldPeriods, grid: addSaturdayColumn(rows)))
        }
        return nil
    }

    /// 把扁平节次按名称分入 上午/下午/晚自习，并同步重排 grid 行
    private static func regroup(periods: [String], grid: [[String]]) -> PersonalData {
        let pairs: [(String, [String])] = periods.enumerated().map { i, p in
            (p, i < grid.count ? grid[i] : Array(repeating: "", count: days.count))
        }
        var early: [(String, [String])] = []
        var am: [(String, [String])] = []
        var pm: [(String, [String])] = []
        var ev: [(String, [String])] = []
        for pair in pairs {
            let p = pair.0
            if p.contains("晚") {
                ev.append(pair)
            } else if let n = sectionNumber(p) {
                if n <= 5 { am.append(pair) } else { pm.append(pair) }
            } else if p.contains("早") {
                early.append(pair)
            } else {
                am.append(pair)
            }
        }
        let ordered = early + am + pm + ev
        var out: [PersonalGroup] = [
            PersonalGroup(title: "上午", periods: (early + am).map { $0.0 }),
            PersonalGroup(title: "下午", periods: pm.map { $0.0 }),
            PersonalGroup(title: "晚自习", periods: ev.map { $0.0 }),
        ]
        out = out.filter { !$0.periods.isEmpty }
        if out.isEmpty { out = defaultGroups }
        return PersonalData(groups: out, grid: ordered.map { $0.1 })
    }

    /// "第3节" → 3
    private static func sectionNumber(_ s: String) -> Int? {
        let digits = s.compactMap { $0.isNumber ? Int(String($0)) : nil }
        guard !digits.isEmpty else { return nil }
        return digits.reduce(0) { $0 * 10 + $1 }
    }

    /// 行列数归一（防止手工改动导致越界）
    private static func normalize(_ d: PersonalData) -> PersonalData {
        var out = d
        if out.groups.isEmpty { out.groups = defaultGroups }
        let flat = out.groups.flatMap { $0.periods }
        out.grid = out.grid.map { row in
            var r = row
            if r.count < days.count { r.append(contentsOf: Array(repeating: "", count: days.count - r.count)) }
            if r.count > days.count { r = Array(r.prefix(days.count)) }
            return r
        }
        if out.grid.count < flat.count {
            out.grid.append(contentsOf: Array(repeating: Array(repeating: "", count: days.count),
                                              count: flat.count - out.grid.count))
        }
        if out.grid.count > flat.count { out.grid = Array(out.grid.prefix(flat.count)) }
        return out
    }

    static func fileURL() -> URL {
        // 统一走 AppPaths：自检可用 SCHEDULEBAR_DATA_DIR 把数据目录重定向到
        // 临时目录 —— 所有 store 都必须支持，否则它在 init 里的迁移会写真实数据。
        AppPaths.file("personal.json")
    }
}
