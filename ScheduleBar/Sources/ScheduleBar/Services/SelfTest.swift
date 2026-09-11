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

    /// 下载模板自检（只读）：生成全部 7 个模板并检查结构锚点，同时验证导入侧会跳过标题行
    /// 用法：ScheduleBar --selftest-templates
    static func runTemplateCheck() {
        let tmpDir = URL(fileURLWithPath: "/tmp/selftest-templates", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        // 新机器默认值：个人课表必须自带节次、内容全空
        let dGroups = DefaultData.personalGroups
        let dPeriods = dGroups.flatMap { $0.periods }
        let dGridEmpty = DefaultData.personalGrid.allSatisfy { $0.allSatisfy { $0.isEmpty } }
        let dOk = !dGroups.isEmpty && dPeriods.count == 13 && DefaultData.personalGrid.count == 13 && dGridEmpty
        print("--- 新机器默认个人课表 ---")
        print("  分组: " + dGroups.map { "\($0.title)[\($0.periods.joined(separator: ","))]" }.joined(separator: " "))
        print("  节次=\(dPeriods.count)  网格=\(DefaultData.personalGrid.count)行×\(DefaultData.personalGrid.first?.count ?? 0)列  内容全空=\(dGridEmpty)  判定=\(dOk ? "✓" : "✗")")
        var bad: [String] = dOk ? [] : ["新机器默认个人课表"]

        let kinds: [(String, AppCoordinator.ImportTemplate)] = [
            ("个人课表", .personal), ("班级课表", .classSheet), ("学生信息", .student),
            ("年级师资", .staff), ("办公室工位", .office), ("班级座位", .seating),
            ("延时监考", .extend), ("教室分布", .classroom),
        ]
        for (label, kind) in kinds {
            let (rows, name) = AppCoordinator.templateRows(kind)
            let flat = rows.flatMap { $0 }.map { $0.trimmingCharacters(in: .whitespaces) }
            let firstCell = rows.first?.first?.trimmingCharacters(in: .whitespaces) ?? ""
            // 锚点：标题 / 节次 / 第几周 / 办公室 / 小组 / 子表 / 楼层
            let anchors = ["节次", "第几周", "办公室", "小组", "子表", "楼层"]
            let hasAnchor = anchors.contains { flat.contains($0) }
            let hasTitle = !firstCell.isEmpty
            let nonEmptyRows = rows.filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }.count
            // 要求：有标题（首格非空）或结构锚点，且不止一行（说明有可填写的骨架）
            let ok = (hasAnchor || hasTitle) && nonEmptyRows >= 2
            if !ok { bad.append(label) }
            print("【\(label)】\(name).xlsx  行=\(rows.count) 有内容行=\(nonEmptyRows) 列≈\(rows.map { $0.count }.max() ?? 0)")
            print("   标题/首格=\(firstCell)   锚点=\(hasAnchor ? "有" : "无")   判定=\(ok ? "✓" : "✗")")
            print("   前 3 行: " + rows.prefix(3).map { $0.joined(separator: "|") }.joined(separator: "  //  "))
        }
        print("--- dropTitleRows 用例（导入侧跳过标题行）---")
        let cases: [(String, [[String]], Int)] = [
            ("有标题行", [["学生信息"], ["序号", "姓名"], ["1", "张三"]], 2),
            ("无标题行", [["序号", "姓名"], ["1", "张三"]], 2),
            ("节次表带标题", [["个人课表"], ["节次", "周一"], ["第1节", "7"]], 2),
        ]
        for (label, input, expect) in cases {
            let out = AppCoordinator.dropTitleRows(input)
            print("  \(label): \(input.count) 行 → \(out.count) 行（期望 \(expect)）")
            if out.count != expect { bad.append("dropTitleRows/\(label)") }
        }

        // 落盘 → 读回：验证标题行在真实 xlsx 里也能被导入侧识别并跳过
        print("--- xlsx 落盘并读回（\(tmpDir.path)）---")
        let withTitle: Set<String> = ["个人课表", "班级课表", "学生信息", "年级师资", "教室分布"]
        for (label, kind) in kinds {
            let (rows, name) = AppCoordinator.templateRows(kind)
            let url = tmpDir.appendingPathComponent("\(name).xlsx")
            do {
                try XLSX.write(rows, to: url)
                let back = try XLSX.read(url)
                let dropped = AppCoordinator.dropTitleRows(back)
                let removedTitle = dropped.count == back.count - 1
                let wantTitle = withTitle.contains(label)
                let ok = removedTitle == wantTitle
                if !ok { bad.append("读回/\(label)") }
                print("  \(label): 写 \(rows.count) 行 → 读回 \(back.count) 行，去标题后 \(dropped.count) 行"
                      + "  首格=\(back.first?.first ?? "")  应跳过标题=\(wantTitle)  判定=\(ok ? "✓" : "✗")")
            } catch {
                print("  \(label): ERROR \(error.localizedDescription)")
                bad.append("读回/\(label)")
            }
        }
        // 教室分布：模板 → 解析回环
        print("--- 教室分布 解析回环 ---")
        let (cRows, _) = AppCoordinator.templateRows(.classroom)
        let parsedFloors = AppCoordinator.parseClassrooms(AppCoordinator.dropTitleRows(cRows))
        for f in parsedFloors {
            print("  \(f.title): 主行=\(f.cells.count) 附加行=\(f.extraRows.count)")
            print("    " + f.cells.map { "\($0.kind == .office ? "办" : "教"):\($0.klass)/\($0.room)" }.joined(separator: " "))
        }
        let cOk = parsedFloors.count == 2
            && parsedFloors.first?.cells.contains { $0.kind == .office } == true
            && parsedFloors.first?.extraRows.count == 1
            && parsedFloors.last?.cells.contains { $0.kind == .office } == true
        if !cOk { bad.append("教室分布解析") }
        print("  判定=\(cOk ? "✓" : "✗")")

        // 旧 classrooms.json 迁移：left + office + right → 平铺 cells
        print("--- 旧 classrooms.json 迁移 ---")
        let legacyJSON = """
        [{"title":"X栋4楼",
          "left":[{"klass":"19班","room":"X401"},{"klass":"23班","room":"X402"}],
          "officeName":"办公室","officeRoom":"X406","officeColor":"2ECC71",
          "right":[{"klass":"26班","room":"X407"}],
          "extraRows":[{"blocks":[{"klass":"1班","room":"X501"}]}]}]
        """
        var migrationOK = false
        if let data = legacyJSON.data(using: .utf8),
           let fs = try? JSONDecoder().decode([ClassroomFloor].self, from: data),
           let f = fs.first {
            print("  楼层=\(fs.count) 主行=\(f.cells.count) 附加行=\(f.extraRows.count) 附加行格子=\(f.extraRows.first?.cells.count ?? 0)")
            print("  顺序: " + f.cells.map { "\($0.kind == .office ? "办" : "教"):\($0.klass)/\($0.room)" }.joined(separator: " "))
            migrationOK = f.cells.count == 4
                && f.cells[2].kind == .office && f.cells[2].room == "X406" && f.cells[2].color == "2ECC71"
                && f.extraRows.first?.cells.first?.kind == .room
        } else {
            print("  解码失败")
        }
        if !migrationOK { bad.append("旧 JSON 迁移") }
        print("  判定=\(migrationOK ? "✓" : "✗")")

        print(bad.isEmpty ? "全部通过 ✓" : "异常：\(bad.joined(separator: ", "))")
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
