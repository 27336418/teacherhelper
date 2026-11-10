import Foundation

// MARK: - 「早自习」默认行 + 老数据迁移 + 节次重命名 自检（2026-11-10）
//
// 起因：用户问「别人使用的时候为什么没有早自习？」
//   早自习不是内置行，只是名字叫「早自习」的普通节次；淡绿底色按名字识别。
//   2.x 的分组默认布局从「第1节」开始 → 新装的人根本没有这一行。
//
// 本自检覆盖：
//   ① 全新安装默认就带「早自习」，且在上午第一行；
//   ② 老数据（已存过 personal.json、没有早自习）首次运行被补一行**空白**，原有课程内容不挪位；
//   ③ 补过一次就不再补；用户删掉后也不复活（标记文件生效）；
//   ④ 节次重命名：改名字、课程内容不串行；空名 / 重名被拒。
//
// 用法：ScheduleBar --selftest-early
// ⚠️ 全部在临时数据目录里跑，绝不碰真实数据。
enum EarlyStudyCheck {

    private static var pass = 0, fail = 0
    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("  \(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "  [\(detail)]")")
        ok ? (pass += 1) : (fail += 1)
    }

    /// 没有早自习的老数据（就是 2.5.23 及更早用户磁盘上的样子），每行填一个可辨认的内容
    private static func writeLegacy(_ dir: String) {
        let groups = [
            PersonalGroup(title: "上午", periods: ["第1节", "第2节", "第3节", "第4节", "第5节"]),
            PersonalGroup(title: "下午", periods: ["第6节", "第7节", "第8节", "第9节"]),
            PersonalGroup(title: "晚自习", periods: ["晚1", "晚2"]),
        ]
        let rows = groups.flatMap { $0.periods }.enumerated().map { i, _ in
            ["C\(i)", "", "", "", "", "", ""] as [String]
        }
        let data = PersonalData(groups: groups, grid: rows)
        if let raw = try? JSONEncoder().encode(data) {
            try? raw.write(to: URL(fileURLWithPath: dir + "/personal.json"))
        }
        // 老用户还没有迁移标记
        try? FileManager.default.removeItem(atPath: dir + "/migrations.json")
    }

    static func run() {
        let tmp = "/tmp/selftest-early-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        setenv("SCHEDULEBAR_DATA_DIR", tmp, 1)
        defer {
            unsetenv("SCHEDULEBAR_DATA_DIR")
            try? FileManager.default.removeItem(atPath: tmp)
        }

        print("=== 早自习默认行 / 老数据迁移 / 节次重命名 自检 ===")

        // ---- ① 全新安装 ----
        print("--- ① 全新安装（无 personal.json）---")
        try? FileManager.default.removeItem(atPath: tmp + "/personal.json")
        try? FileManager.default.removeItem(atPath: tmp + "/migrations.json")
        var s = ScheduleStore()
        check("默认第一个节次就是「早自习」", s.orderedPeriods.first == "早自习",
              "实际=\(s.orderedPeriods.prefix(3).joined(separator: ","))")
        check("行数 = 节次数", s.grid.count == s.orderedPeriods.count,
              "\(s.grid.count) / \(s.orderedPeriods.count)")
        check("早自习那一行是全空的", s.grid.first?.allSatisfy { $0.isEmpty } ?? false)

        // ---- ② 老数据迁移 ----
        print("--- ② 老数据（没有早自习）首次运行 ---")
        writeLegacy(tmp)
        s = ScheduleStore()
        check("老数据被补上「早自习」", s.orderedPeriods.first == "早自习",
              "实际=\(s.orderedPeriods.prefix(3).joined(separator: ","))")
        check("补的是空白行（没有借别人的课）", s.grid.first?.allSatisfy { $0.isEmpty } ?? false)
        check("原来第1节的课仍在第1节", s.cell("第1节", 0) == "C0",
              "实际=\(s.cell("第1节", 0))")
        check("原来最后一节的课仍在最后一节", s.cell("晚2", 0) == "C10",
              "实际=\(s.cell("晚2", 0))")
        check("行数仍 = 节次数", s.grid.count == s.orderedPeriods.count,
              "\(s.grid.count) / \(s.orderedPeriods.count)")
        check("补的那一行已经落盘（不是只改了内存）",
              (try? Data(contentsOf: URL(fileURLWithPath: tmp + "/personal.json")))
                .flatMap { try? JSONDecoder().decode(PersonalData.self, from: $0) }?
                .groups.first?.periods.first == "早自习")

        // ---- ③ 不重复补、删了不复活 ----
        print("--- ③ 第二次启动 / 用户删掉之后 ---")
        s = ScheduleStore()
        check("重启不重复补「早自习」",
              s.orderedPeriods.filter { $0 == "早自习" }.count == 1,
              "出现了 \(s.orderedPeriods.filter { $0 == "早自习" }.count) 次")
        s.removePeriod("早自习")
        check("能删掉「早自习」", !s.orderedPeriods.contains("早自习"))
        s = ScheduleStore()
        check("删掉后重启不再复活", !s.orderedPeriods.contains("早自习"),
              "实际=\(s.orderedPeriods.prefix(2).joined(separator: ","))")

        // ---- ④ 节次重命名 ----
        print("--- ④ 节次重命名 ---")
        let oldCell = s.cell("第1节", 0)
        check("改名成功：第1节 → 早读", s.renamePeriod(in: 0, at: 0, to: "早读"))
        check("名字真的换了", s.orderedPeriods.first == "早读", "实际=\(s.orderedPeriods.first ?? "-")")
        check("课程内容跟着行、没有串", s.cell("早读", 0) == oldCell,
              "改前=\(oldCell) 改后=\(s.cell("早读", 0))")
        check("重名被拒（不能出现两个同名节次）",
              !s.renamePeriod(in: 0, at: 1, to: "早读"),
              "第二行仍叫 \(s.orderedPeriods[1])")
        check("空名被拒", !s.renamePeriod(in: 0, at: 1, to: "   "))
        check("改成「早自习」会立刻变成非上课时段",
              s.renamePeriod(in: 0, at: 1, to: "早自习") && s.orderedPeriods.contains("早自习"))
        s = ScheduleStore()
        check("改名结果已落盘（重启后还在）",
              s.orderedPeriods.contains("早读") && s.orderedPeriods.contains("早自习"))
        check("重启后没有因为重命名打乱行数", s.grid.count == s.orderedPeriods.count,
              "\(s.grid.count) / \(s.orderedPeriods.count)")

        print("———————————————————————————")
        print("早自习 / 重命名自检：\(pass) 通过 / \(fail) 失败")
        if fail > 0 { exit(1) }
    }
}
