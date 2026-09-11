import Foundation

// MARK: - 隐藏自检：不启动 UI，直接把导入解析结果打印出来
// 用法：教师助手.app/Contents/MacOS/ScheduleBar --selftest-import /path/to/全校课表.xlsx
//     教师助手.app/Contents/MacOS/ScheduleBar --selftest-seating
//     教师助手.app/Contents/MacOS/ScheduleBar --selftest-update [owner/repo]
//        实测 GitHub release 查询链路（不传则用内置仓库；传则用指定的公开仓库）
enum SelfTest {
    /// 升级链路自检：同步等待网络请求，打印查询结果
    static func runUpdateCheck(override repo: String?) {
        let svc = GitHubUpdateService.shared
        let target = repo ?? "\(GitHubRepoConfig.owner)/\(GitHubRepoConfig.repo)"
        print("本地版本 = v\(svc.currentVersion) (build \(svc.currentBuild))")
        print("内置仓库 = \(GitHubRepoConfig.owner)/\(GitHubRepoConfig.repo)  已配置=\(svc.isConfigured)")
        let api = "https://api.github.com/repos/\(target)/releases/latest"
        print("查询 API = \(api)")

        let sem = DispatchSemaphore(value: 0)
        var done = false
        var req = URLRequest(url: URL(string: api)!)
        req.timeoutInterval = 15
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err {
                print("ERROR: \(err.localizedDescription)")
            } else if let http = resp as? HTTPURLResponse {
                print("HTTP \(http.statusCode)")
                if let data, let s = String(data: data, encoding: .utf8) {
                    print("响应前 400 字：\n\(String(s.prefix(400)))")
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        let tag = (json["tag_name"] as? String) ?? "(无 tag_name)"
                        let assets = (json["assets"] as? [[String: Any]]) ?? []
                        print("tag_name = \(tag)")
                        print("assets 数 = \(assets.count)")
                        for a in assets.prefix(3) {
                            print("  asset: \(a["name"] ?? "?") -> \(a["browser_download_url"] ?? "?")")
                        }
                        let remote = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                        print("比较：远端 \(remote) vs 本地 \(svc.currentVersion) = \(GitHubUpdateService.compare(remote, svc.currentVersion).rawValue)  (1=远端更新)")
                    }
                }
            }
            done = true
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 20)
        if !done { print("超时：20s 内未返回") }

        print("--- semver 比较自测（期望：1 / 0 / 1 / 1 / 1）---")
        for (a, b) in [("v1.7.0", "1.6.0"), ("1.6.0", "1.6.0"), ("1.6.1", "1.6.0"), ("2.0", "1.9.9"), ("1.10.0", "1.9.9")] {
            let av = a.hasPrefix("v") ? String(a.dropFirst()) : a
            let bv = b.hasPrefix("v") ? String(b.dropFirst()) : b
            print("\(a) vs \(b) -> \(GitHubUpdateService.compare(av, bv).rawValue)")
        }
    }

    /// 座位安排自检：模拟应用启动（创建 store → 触发加载与 normalize），打印前后状态
    static func runSeatingCheck() {
        let store = SeatingStore.shared
        print("表格=\(store.rows)x\(store.cols)  分组=\(store.regions.count)")
        let seated = Set(store.grid.flatMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        let pool = Set(store.pool)
        print("在座=\(store.seatedCount)  待用=\(store.pool.count)  共=\(store.totalCount)")
        print("待用栏=\(store.pool)")
        print("两处同时出现=\(pool.intersection(seated).sorted())")
        print("数据文件=\(SeatingStore.fileURL().path)")
    }

    /// 节次规整自检：只读预演，不改动任何数据文件
    /// 用法：ScheduleBar --selftest-periods
    static func runPeriodCheck() {
        print("--- 用例1：历史命名（上午4/下午5/晚自习4）→ 应变为 上午5/下午4/晚自习4、第1-13节 ---")
        var legacy = ClassData(groups: [
            ClassGroup(title: "上午", periods: ["一", "二", "三", "四"]),
            ClassGroup(title: "下午", periods: ["五", "六", "七", "八", "九"]),
            ClassGroup(title: "晚自习", periods: ["晚1", "晚2", "晚3", "晚4"]),
        ], cells: [:])
        for p in legacy.groups.flatMap({ $0.periods }) {
            legacy.cells[p] = ["\(p)的内容"] + Array(repeating: "", count: ClassLayout.days.count - 1)
        }
        dump(ClassLayout.canonicalize(groups: legacy.groups, cells: legacy.cells), label: "用例1")

        print("--- 用例2：带多余节次（上午含节次13、下午含节次14、晚自习含节次15）---")
        var messy = ClassData(groups: [
            ClassGroup(title: "上午", periods: ["一", "二", "三", "四", "节次13"]),
            ClassGroup(title: "下午", periods: ["五", "六", "七", "八", "九", "节次14"]),
            ClassGroup(title: "晚自习", periods: ["晚1", "晚2", "晚3", "晚4", "节次15"]),
        ], cells: [:])
        for p in messy.groups.flatMap({ $0.periods }) {
            messy.cells[p] = [p] + Array(repeating: "", count: ClassLayout.days.count - 1)
        }
        dump(ClassLayout.canonicalize(groups: messy.groups, cells: messy.cells), label: "用例2")

        print("--- 用例3：已是「第N节」体系 → 保持分组，只按序重编号 ---")
        let numbered = ClassData(groups: [
            ClassGroup(title: "上午", periods: ["第1节", "第2节"]),
            ClassGroup(title: "下午", periods: ["第3节"]),
            ClassGroup(title: "晚自习", periods: ["第4节"]),
        ], cells: [:])
        dump(ClassLayout.canonicalize(groups: numbered.groups, cells: numbered.cells), label: "用例3")

        print("--- 用例4：新增节次（占位符）应被编成最后一个序号 ---")
        let withNew = ClassLayout.canonicalize(
            groups: [ClassGroup(title: "上午", periods: ["第1节", "第2节", "＿新节＿"]),
                     ClassGroup(title: "下午", periods: ["第3节"])],
            cells: ["第1节": Array(repeating: "", count: ClassLayout.days.count)],
            placeholders: ["＿新节＿"])
        dump(withNew, label: "用例4")

        print("--- 用例5：真实数据只读预演（\(ClassScheduleStore.fileURL().path)）---")
        guard let raw = try? Data(contentsOf: ClassScheduleStore.fileURL()),
              let bank = try? JSONDecoder().decode(ClassBankData.self, from: raw) else {
            print("（读不到 classes.json，跳过）")
            return
        }
        print("班级数 = \(bank.classes.count)，默认班 = \(bank.defaultClass)")
        var changed = 0
        for (name, d) in bank.bank.sorted(by: { $0.key < $1.key }) {
            let r = ClassLayout.canonicalize(groups: d.groups, cells: d.cells)
            let before = d.groups.flatMap { $0.periods }
            let after = r.groups.flatMap { $0.periods }
            if before != after { changed += 1 }
            if ["初1-1", "初3-7", bank.defaultClass].contains(name) {
                print("【\(name)】")
                print("  改前: " + d.groups.map { "\($0.title)[\($0.periods.joined(separator: ","))]" }.joined(separator: " "))
                print("  改后: " + r.groups.map { "\($0.title)[\($0.periods.joined(separator: ","))]" }.joined(separator: " "))
            }
        }
        print("需要改动的班级数 = \(changed) / \(bank.bank.count)")
        print("（本自检只读，不会写盘）")
    }

    private static func dump(_ r: (groups: [ClassGroup], cells: [String: [String]]), label: String) {
        for g in r.groups {
            print("  \(g.title): \(g.periods.joined(separator: ","))")
        }
        let moved = r.cells.filter { !$0.value.allSatisfy { $0.isEmpty } }
        print("  内容迁移：\(moved.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value[0])" }.joined(separator: " "))")
    }

    static func runImport(path: String) {
        do {
            let grid = try XLSX.read(URL(fileURLWithPath: path))
            print("读取成功：行数=\(grid.count)  最大列数=\(grid.map { $0.count }.max() ?? 0)")
            let entries = AppCoordinator.parseWholeSchool(grid)
            print("识别班级数=\(entries.count)")
            print("前 3 个班=\(entries.prefix(3).map { $0.name }.joined(separator: ", "))")
            print("后 3 个班=\(entries.suffix(3).map { $0.name }.joined(separator: ", "))")
            let sample = entries.first { $0.name == "初3-1" } ?? entries.last
            if let c = sample {
                print("--- 样本班级：\(c.name) ---")
                for g in c.data.groups {
                    print("分组「\(g.title)」节次: \(g.periods.joined(separator: ","))")
                }
                for p in c.data.groups.flatMap({ $0.periods }) {
                    print("  \(p): \(c.data.cells[p] ?? [])")
                }
            }
        } catch {
            print("ERROR: \(error.localizedDescription)")
        }
    }
}
