import Foundation
import AppKit
import SwiftUI

// MARK: - 个人课表「新增节次 / 编辑 / 对换」自检（2026-10-01）
//
// 对应两件用户反馈：
//   ① 新增节次应当是「Excel 插入行」：只多出一节**空白**节次，后面节次的编号顺延（第n节→第n+1节），
//      已有课程跟着自己那一行整体下移，不重排、不丢失、不覆盖；
//   ② 双击编辑 / 拖动对换靠后的节次（第9节）必须能存上、能换位，不该「必须退出再打开」。
//
// 全部在**临时数据目录**里跑（内部 setenv SCHEDULEBAR_DATA_DIR），绝不碰真实数据。
// 用法：ScheduleBar --selftest-personal-edit
enum PersonalEditCheck {

    // MARK: - 与用户真实数据同形的预置（上午 早自习+第1~5节 / 下午 第6~9节 / 晚自习 晚自习）
    private static let seedGroups: [PersonalGroup] = [
        PersonalGroup(title: "上午", periods: ["早自习", "第1节", "第2节", "第3节", "第4节", "第5节"]),
        PersonalGroup(title: "下午", periods: ["第6节", "第7节", "第8节", "第9节"]),
        PersonalGroup(title: "晚自习", periods: ["晚自习"]),
    ]

    /// 场景1用：每组若干节课，便于观察「内容跟着行下移」
    private static func seedFilled(_ store: ScheduleStore) {
        for (i, p) in store.orderedPeriods.enumerated() {
            store.setCell(p, i % ScheduleStore.days.count, "C\(i)")
        }
    }

    /// 写预置文件 + 新建 store（每次调用都给一个干净起点）
    @discardableResult
    private static func freshStore(fill: Bool) -> ScheduleStore {
        let data = PersonalData(
            groups: seedGroups,
            grid: Array(repeating: Array(repeating: "", count: ScheduleStore.days.count),
                        count: seedGroups.flatMap { $0.periods }.count)
        )
        if let raw = try? JSONEncoder().encode(data) {
            try? raw.write(to: AppPaths.file("personal.json"))
        }
        let s = ScheduleStore()
        if fill { seedFilled(s) }
        return s
    }

    private static var pass = 0, fail = 0
    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("  \(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "  [\(detail)]")")
        ok ? (pass += 1) : (fail += 1)
    }

    static func run() {
        let tmp = "/tmp/selftest-personal-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        setenv("SCHEDULEBAR_DATA_DIR", tmp, 1)
        defer {
            unsetenv("SCHEDULEBAR_DATA_DIR")
            try? FileManager.default.removeItem(atPath: tmp)
        }
        print("=== 个人课表 新增节次 / 编辑 / 对换 自检 ===")
        print("临时数据目录 = \(tmp)（真实 personal.json 不受影响）")
        print("预置 = " + seedGroups.map { "\($0.title)[\($0.periods.joined(separator: ","))]" }.joined(separator: " "))

        // ---------------------------------------------------------------- 1) 在「下午」新增（末尾）
        print("\n--- 1) 在「下午」组新增一节（该组末尾，后面只有晚自习）---")
        var store = freshStore(fill: true)
        let beforeRows = snapshotRows(store)
        store.addPeriod(in: 1)
        printRows(store, "新增后")
        check("节次数 11 → 12", store.orderedPeriods.count == 12, "\(store.orderedPeriods.count)")
        check("网格行数 = 节次数", store.grid.count == store.orderedPeriods.count,
              "\(store.grid.count)/\(store.orderedPeriods.count)")
        check("新节次「第10节」在该组末尾、内容为空",
              store.orderedPeriods[10] == "第10节"
              && store.grid[10].allSatisfy { $0.isEmpty })
        // 插入点是第 10 行（该组末尾）：它之前一行都没动；晚自习那一行整体下移到第 11 行
        check("插入点之前的内容一行都没动",
              Array(beforeRows[0..<10]) == Array(store.grid[0..<10]))
        check("晚自习那一行整体下移一行（内容原样）", store.grid[11] == beforeRows[10])
        check("旧内容一条不丢", cellSet(store.grid) == cellSet(beforeRows))

        // ---------------------------------------------------------------- 2) 在「上午」新增（中间）
        print("\n--- 2) 在「上午」组新增一节（表中部：Excel 插入行）---")
        store = freshStore(fill: true)
        let before2 = snapshotRows(store)
        store.addPeriod(in: 0)
        printRows(store, "新增后")
        check("节次数 11 → 12", store.orderedPeriods.count == 12, "\(store.orderedPeriods.count)")
        check("网格行数 = 节次数", store.grid.count == store.orderedPeriods.count,
              "\(store.grid.count)/\(store.orderedPeriods.count)")
        check("新节次是「第6节」，且这一行为空",
              store.orderedPeriods[6] == "第6节" && store.grid[6].allSatisfy { $0.isEmpty })
        check("插入点之后的编号顺延：第6~9节 → 第7~10节",
              Array(store.orderedPeriods[7...10]) == ["第7节", "第8节", "第9节", "第10节"],
              store.orderedPeriods[7...10].joined(separator: ","))
        check("自定义名原样保留（早自习 / 晚自习）",
              store.orderedPeriods.first == "早自习" && store.orderedPeriods.last == "晚自习")
        // 内容必须跟着自己那一行下移：原来的第 6 行内容，现在必须出现在第 7 行
        check("已有课程跟着自己的行下移、没有被覆盖或重排",
              Array(before2[6...]) == Array(store.grid[7...]) )
        check("插入点之前的内容原地不动", Array(before2[0..<6]) == Array(store.grid[0..<6]))
        check("旧内容一条不丢", cellSet(store.grid) == cellSet(before2))

        // ---------------------------------------------------------------- 3) 新增之后编辑靠后的节次
        print("\n--- 3) 新增之后：编辑「第9节」要能存上 ---")
        editAndReload(store, period: "第9节")

        // ---------------------------------------------------------------- 4) 新增之后对调靠后的节次
        print("\n--- 4) 新增之后：对调「第9节」要能换位 ---")
        swapAndReload(store, from: "第9节", fromDay: 0, to: "第8节", toDay: 1)

        // ---------------------------------------------------------------- 5) 网格行数异常时自愈
        print("\n--- 5) 网格行数少于节次数（历史异常）→ 写入必须自愈而不是静默失败 ---")
        store = freshStore(fill: true)
        store.grid.removeLast()      // 人为制造「行数 < 节次数」
        print("  制造异常：节次 \(store.orderedPeriods.count) 个 / 网格 \(store.grid.count) 行")
        let r = store.flatIndex(of: "第9节")!
        store.setCell("第9节", 0, "自愈写入")
        check("行数已被补齐", store.grid.count == store.orderedPeriods.count,
              "\(store.grid.count)/\(store.orderedPeriods.count)")
        check("「第9节」的编辑确实写进去了", store.grid[r][0] == "自愈写入", store.grid[r][0])
        check("落盘后重新装载仍是新值", ScheduleStore().cell("第9节", 0) == "自愈写入")

        // ---------------------------------------------------------------- 6) 删除节次
        print("\n--- 6) 删除「第8节」后，编号集中、行数同步、末尾节次仍可编辑 ---")
        store = freshStore(fill: true)
        store.removePeriod("第8节")
        printRows(store, "删除后")
        check("节次数 11 → 10", store.orderedPeriods.count == 10, "\(store.orderedPeriods.count)")
        check("网格行数 = 节次数", store.grid.count == store.orderedPeriods.count,
              "\(store.grid.count)/\(store.orderedPeriods.count)")
        // 删掉第8节之后，原来的第9节顺延成第8节（编号连续、无空洞）——就像 Excel 删除一行
        check("编号顺延无空洞",
              Array(store.orderedPeriods[6...8]) == ["第6节", "第7节", "第8节"],
              store.orderedPeriods[6...8].joined(separator: ","))
        check("删除处的内容被一起删掉（原来是第8行）", store.grid[8][2] == "C9")
        editAndReload(store, period: "第8节")   // 末尾那个编号节次必须仍可写

        // ---------------------------------------------------------------- 7) 同名节次出现在两个分组
        print("\n--- 7) 同名节次出现在两个分组时，删除只删一个（行数不能多删）---")
        let dup = PersonalData(
            groups: [PersonalGroup(title: "上午", periods: ["第1节", "第2节"]),
                     PersonalGroup(title: "下午", periods: ["第2节", "第3节"])],
            grid: Array(repeating: Array(repeating: "", count: ScheduleStore.days.count), count: 4)
        )
        if let raw = try? JSONEncoder().encode(dup) { try? raw.write(to: AppPaths.file("personal.json")) }
        store = ScheduleStore()
        print("  重编号后 = \(store.orderedPeriods.joined(separator: ","))（应无重号）")
        store.removePeriod("第2节")
        check("删除后行数 = 节次数", store.grid.count == store.orderedPeriods.count,
              "\(store.grid.count)/\(store.orderedPeriods.count)")

        print("\n---")
        print(fail == 0 ? "全部通过 ✓（\(pass) 项）" : "存在失败项 ✗（通过 \(pass) / 失败 \(fail)）")
        if fail > 0 { exit(1) }
    }

    // MARK: - 用例辅助
    private static func snapshotRows(_ s: ScheduleStore) -> [[String]] { s.grid }
    private static func cellSet(_ rows: [[String]]) -> [String] {
        rows.flatMap { $0 }.filter { !$0.isEmpty }.sorted()
    }
    private static func printRows(_ s: ScheduleStore, _ title: String) {
        print("  【\(title)】节次(\(s.orderedPeriods.count))=\(s.orderedPeriods.joined(separator: ","))  网格 \(s.grid.count) 行")
        for (i, p) in s.orderedPeriods.enumerated() where i < s.grid.count {
            print("     \(String(format: "%2d", i)) \(p)→ " + s.grid[i].map { $0.isEmpty ? "·" : $0 }.joined(separator: " "))
        }
    }

    private static func editAndReload(_ s: ScheduleStore, period: String) {
        guard let r = s.flatIndex(of: period) else {
            check("flatIndex(\(period)) 存在", false); return
        }
        s.setCell(period, 0, "改过了")
        check("内存中已写入", s.grid[r][0] == "改过了", s.grid[r][0])
        check("落盘后重新装载仍是新值", ScheduleStore().cell(period, 0) == "改过了",
              ScheduleStore().cell(period, 0))
    }

    private static func swapAndReload(_ s: ScheduleStore, from: String, fromDay: Int,
                                      to: String, toDay: Int) {
        guard let fr = s.flatIndex(of: from), let tr = s.flatIndex(of: to) else {
            check("两个节次都能定位", false); return
        }
        let a = s.grid[fr][fromDay], b = s.grid[tr][toDay]
        s.beginCellDrag(from, fromDay)
        check("拿起时 store 登记了拖动来源", s.cellDragSource != nil)
        s.swapCellTo(to, toDay)
        check("对换已生效（\(from)@\(fromDay)『\(a)』 ↔ \(to)@\(toDay)『\(b)』）",
              s.grid[fr][fromDay] == b && s.grid[tr][toDay] == a)
        let re = ScheduleStore()
        check("落盘后重新装载仍是对换后的值",
              re.cell(from, fromDay) == b && re.cell(to, toDay) == a)
        s.finishCellDrag()
    }

    // MARK: - 把真实页面渲染成 PNG 看效果（--render-personal <目录>）
    //
    // 用真实数据（先整份拷到临时目录，绝不写真实数据），渲染「我的课表」页面：
    //   00-初始 / 01-下午新增 / 02-上午新增
    // 目的：人眼确认「新增节次」后的表格长什么样（而不是靠推理）。
    static func render(outDir: String) {
        let realDir = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/ScheduleBar")
        let tmp = "/tmp/render-personal-\(UUID().uuidString.prefix(8))"
        if FileManager.default.fileExists(atPath: realDir) {
            try? FileManager.default.copyItem(atPath: realDir, toPath: tmp)
        } else {
            try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        }
        setenv("SCHEDULEBAR_DATA_DIR", tmp, 1)
        print("真实数据 = \(realDir)")
        print("渲染副本 = \(tmp)")
        print("PNG 目录 = \(outDir)")
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        _ = NSApplication.shared
        let container = PanelHostContainer()
        container.frame = NSRect(x: 0, y: 0, width: 880, height: 700)
        let makeContent: (PanelTab) -> AnyView = { tab in
            AnyView(
                SchedulePanelPages.content(tab)
                    .environmentObject(ScheduleStore.shared)
                    .environmentObject(ClassScheduleStore.shared)
                    .environmentObject(ExtendScheduleStore.shared)
                    .environmentObject(CardTitleStore.shared)
                    .environmentObject(WeekStore.shared)
                    .environmentObject(ReminderStore.shared)
                    .environmentObject(OfficeLayoutStore.shared)
                    .environmentObject(ClassroomStore.shared)
                    .environmentObject(StaffStore.shared)
                    .environmentObject(StudentStore.shared)
                    .environmentObject(SeatingStore.shared)
                    .environmentObject(AppCoordinator.shared)
            )
        }
        container.sync(tabs: [.personal], selected: .personal, makeContent: makeContent)
        container.layoutSubtreeIfNeeded()

        func shot(_ name: String) {
            let stats = container.renderStats(for: .personal, pngDirectory: outDir)
            print("  \(name): \(stats.described)")
            let src = (outDir as NSString).appendingPathComponent("板块-\(PanelTab.personal.rawValue).png")
            let dst = (outDir as NSString).appendingPathComponent("\(name).png")
            try? FileManager.default.removeItem(atPath: dst)
            try? FileManager.default.moveItem(atPath: src, toPath: dst)
        }

        let store = ScheduleStore.shared
        printRows(store, "初始")
        shot("00-初始")

        store.addPeriod(in: 1)      // 下午
        printRows(store, "在下午新增后")
        shot("01-下午新增")

        store.removePeriod("第10节")
        let d = store.orderedPeriods
        store.addPeriod(in: 0)      // 上午
        printRows(store, "在上午新增后")
        shot("02-上午新增")
        print("（节次序列回到 \(d.joined(separator: ",")) 后再在上午新增；渲染只在副本上进行）")
        print("（真实 personal.json 未被修改）")
    }
}
