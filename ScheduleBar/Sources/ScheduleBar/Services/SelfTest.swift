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

        // ---- version.json 通道（没发布 Release 也能用） ----
        print("--- version.json 通道自测 ---")
        let owner = GitHubRepoConfig.owner
        let repoName = GitHubRepoConfig.repo
        let branch = GitHubRepoConfig.branch

        // 1) 三条读取通道的真实连通性（仓库还没上传时预期 404）
        let probes: [(String, String, String)] = [
            ("GitHub 内容接口", "https://api.github.com/repos/\(owner)/\(repoName)/contents/version.json?ref=\(branch)", "application/vnd.github.raw"),
            ("jsDelivr CDN", GitHubUpdateService.cdnURL(owner: owner, repo: repoName, branch: branch, path: "version.json"), "application/json"),
            ("raw.githubusercontent", GitHubUpdateService.rawURL(owner: owner, repo: repoName, branch: branch, path: "version.json"), "application/json"),
        ]
        for (label, url, accept) in probes {
            let (code, data) = syncGet(url, accept: accept)
            var extra = ""
            if code == 200, let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let info = GitHubUpdateService.infoFromFeed(json, owner: owner, repo: repoName,
                                                               branch: branch, page: url) {
                    extra = "  → 清单版本 \(info.version)，安装包 \(info.assetName)"
                } else {
                    extra = "  → 200 但不是合法清单（缺 version）"
                }
            } else if code == 404 {
                extra = "  → 清单还没上传（预期）"
            } else if code < 0 {
                extra = "  → 该通道在当前网络不可用"
            }
            print("\(label): HTTP \(code)\(extra)")
        }

        // 2) 用真实公开 JSON 验证「解析 + 比较」链路（jsDelivr 上的 jquery/package.json 带 version 字段）
        print("-- 解析链路（真实 JSON：jquery/package.json）--")
        let (jcode, jdata) = syncGet("https://cdn.jsdelivr.net/gh/jquery/jquery@3.7.1/package.json",
                                     accept: "application/json")
        if jcode == 200, let jdata,
           let json = try? JSONSerialization.jsonObject(with: jdata) as? [String: Any],
           let info = GitHubUpdateService.infoFromFeed(json, owner: owner, repo: repoName,
                                                      branch: branch, page: "selftest") {
            let newer = GitHubUpdateService.compare(info.version, svc.currentVersion) == .orderedDescending
            print("解析成功：version=\(info.version) 比本地(\(svc.currentVersion))新=\(newer)")
        } else {
            print("解析链路测试跳过（HTTP \(jcode)，可能网络受限）")
        }

        // 3) 下载地址候选（含国内加速镜像）
        let sample = GitHubUpdateService.infoFromFeed(
            ["version": "9.9.9", "download": "教师助手_v9.9.9.dmg"],
            owner: owner, repo: repoName, branch: branch, page: "selftest")
        if let sample {
            print("-- 下载地址候选（示例 v9.9.9）--")
            let attempts = GitHubUpdateService.downloadAttempts(primary: sample.assetURL,
                                                               fallbacks: sample.fallbackURLs)
            for (i, u) in attempts.enumerated() { print("  \(i + 1). \(u)") }
        }

        // 4) 纯解析用例（不依赖网络）
        let samples: [([String: Any], String)] = [
            (["version": "1.9.0", "download": "教师助手_v1.9.0.dmg", "notes": "新增视角"], "相对文件名（中文）"),
            (["version": "v2.0.0", "download_url": "https://example.com/a.dmg"], "完整 URL + v 前缀"),
            (["tag_name": "1.9.1"], "只有 tag_name / 没有安装包"),
            (["notes": "缺少 version"], "缺 version（应判为无效）"),
        ]
        print("-- 纯解析用例 --")
        for (json, label) in samples {
            if let info = GitHubUpdateService.infoFromFeed(json, owner: owner, repo: repoName,
                                                           branch: branch, page: "page") {
                let newer = GitHubUpdateService.compare(info.version, svc.currentVersion) == .orderedDescending
                print("\(label): version=\(info.version) 比本地新=\(newer) 安装包=\(info.assetName)")
                print("    → \(info.assetURL)")
            } else {
                print("\(label): 无效（按预期跳过）")
            }
        }
    }

    /// 同步 GET（自检用；返回 HTTP 状态码与响应体）
    /// 必须绕开本地缓存：否则会命中上一次的清单（CDN 缓存可达 12 小时），
    /// 自检会误报「新版本没生效」。
    private static func syncGet(_ urlString: String, accept: String) -> (Int, Data?) {
        guard let url = URL(string: urlString) else { return (-1, nil) }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue("TeacherHelper/selftest", forHTTPHeaderField: "User-Agent")
        var out: (Int, Data?) = (-1, nil)
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            out = ((resp as? HTTPURLResponse)?.statusCode ?? -1, data)
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 25)
        return out
    }

    /// 座位安排自检：模拟应用启动（创建 store → 触发加载与 normalize），打印前后状态
    static func runSeatingCheck() {
        let store = SeatingStore.shared
        print("表格=\(store.rows)x\(store.cols)  讲台=\(store.podium?.compactLabel ?? "无")")
        let seated = Set(store.grid.flatMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        let pool = Set(store.pool)
        print("在座=\(store.seatedCount)  待用=\(store.pool.count)  共=\(store.totalCount)")
        print("待用栏=\(store.pool)")
        print("两处同时出现=\(pool.intersection(seated).sorted())")
        print("数据文件=\(SeatingStore.fileURL().path)")
    }

    /// 座位拖拽 / 取消分组自检（纯逻辑，不启 UI）
    /// 用法：ScheduleBar --selftest-seating-drag
    ///
    /// 覆盖 2026-09-12 的故障：座位格 / 待用小组 / ⌘拖组 的 `.onDrag` 忘了登记 DragContext，
    /// 落点因此一律 `落点拒绝：当前拖动=无` —— 座位无法对换、拖不进待用栏。
    /// 这里用「临时数据目录 + 独立 store」跑完整逻辑，绝不碰真实的 seating.json。
    static func runSeatingDragCheck() {
        let tmp = "/tmp/selftest-seating-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        setenv("SCHEDULEBAR_DATA_DIR", tmp, 1)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        print("临时数据目录 = \(tmp)（真实数据不受影响）")

        // 临时目录每次都是空的 → 走「首次运行」分支（默认 11×11 + 讲台入表），行为确定
        let store = SeatingStore()
        func reset() {
            store.grid = [["甲", "乙", "丙"], ["丁", "戊", ""]]
            store.pool = ["己"]
            store.selection = []
            store.podium = nil
        }
        /// 4×4 空表：给「框选整体移动 / 讲台」用例用
        func resetBig() {
            store.grid = [["甲", "乙", "丙", ""],
                          ["丁", "戊", "", ""],
                          ["", "", "", ""],
                          ["", "", "", ""]]
            store.pool = []
            store.selection = []
            store.podium = nil
        }
        /// 模拟视图层的一次「拿起」（等价于 SeatingView.beginDrag）
        func pick(_ payload: String) { DragContext.begin(module: DragPayload.seating, payload: payload) }

        var cases: [(String, Bool)] = []

        // 0) 全新表：默认 11×11，且讲台已经在表格里面（最后一行居中 3 格，左右两侧仍可排座位）
        cases.append(("新表默认 11×11", store.rows == 11 && store.cols == 11))
        cases.append(("新表默认带讲台（表格内·第11行第5~7列）",
                      store.podium?.row == 10 && store.podium?.col == 4 && store.podium?.span == 3))
        cases.append(("讲台左右两侧的格子仍是座位（第11行第1~4列可排）",
                      !store.isPodium("10-3") && !store.isPodium("10-7")
                      && store.isPodium("10-4") && store.isPodium("10-6")))

        // 1) 拖动来源必须能被落点识别（视图层 beginDrag 登记的正是这两步）
        reset(); pick(SeatingStore.payload(cell: "0-0"))
        cases.append(("拿起后落点能识别来源", DragContext.belongs(to: DragPayload.seating)
                      && DragContext.payload == "cell|0-0"))

        // 2) 座位 ↔ 座位：对换
        store.handleDrop(DragContext.payload ?? "", toKey: "1-0"); DragContext.finish(reason: "座位")
        cases.append(("座位↔座位对换（甲↔丁）",
                      store.name(at: "0-0") == "丁" && store.name(at: "1-0") == "甲"))

        // 3) 座位 → 待用栏
        reset(); pick(SeatingStore.payload(cell: "0-0"))
        store.handleDrop(DragContext.payload ?? "", toKey: nil); DragContext.finish(reason: "座位")
        cases.append(("座位拖到待用栏（甲入待用、格子清空）",
                      (store.name(at: "0-0") ?? "") == "" && store.pool.contains("甲")))

        // 4) 待用栏 → 座位
        reset(); pick(SeatingStore.payload(pool: 0))
        store.handleDrop(DragContext.payload ?? "", toKey: "1-2"); DragContext.finish(reason: "座位")
        cases.append(("待用栏拖回座位（己落到 1-2）",
                      store.name(at: "1-2") == "己" && !store.pool.contains("己")))

        // 5) 「分组」相关用例已随功能移除（2026-09-12）：⌘拖整组 / 组成小组 / 取消分组
        //    这些类型与方法已从 store 删掉，这里是编译期保证，不再有运行时用例。

        // 9) 回归护栏：没有登记来源时（曾经的 bug）落点必须拒绝，而不是「悄悄什么都不做」
        DragContext.cancel()
        cases.append(("未登记来源 → 落点拒绝（回归护栏）",
                      !DragContext.belongs(to: DragPayload.seating)))

        // ── 以下为 2.1.8 新增：Excel 式框选整体移动 + 讲台放进表格 ──

        // 10) 框选：从空格拖到另一格 = 选中矩形一片（只含坐着学生的格）
        resetBig()
        pick(SeatingStore.payload(marquee: "0-0"))
        store.handleDrop("marquee|0-0", toKey: "1-1"); DragContext.finish(reason: "座位")
        cases.append(("空格起手拖动 = 框选 2×2（4 格都有学生）",
                      store.selection == Set(["0-0", "0-1", "1-0", "1-1"])))

        // 11) ⚠️ 框选**只把坐着学生的格**放进选区（2026-09-12 用户反馈：
        //     从空格起手框选「老是会连空格一起选中」，蓝框框住一片空白像误选）
        resetBig(); store.selectRect(from: "0-0", to: "2-3")
        cases.append(("框选只选有学生的格（0-0→2-3 只中甲/乙/丙/丁/戊 5 格，11 个空位不进选区）",
                      store.selection == Set(["0-0", "0-1", "0-2", "1-0", "1-1"])))

        // 12) 框选整体移动：2×2 往右下挪一格，学生跟着走
        resetBig()
        store.selection = ["0-0", "0-1", "1-0", "1-1"]
        let movedOK = store.moveSelection(grab: "0-0", to: "1-1")
        cases.append(("框选整体移动（+1行+1列，甲乙丁戊跟着走、原位清空）",
                      movedOK && store.name(at: "1-1") == "甲" && store.name(at: "1-2") == "乙"
                      && store.name(at: "2-1") == "丁" && store.name(at: "2-2") == "戊"
                      && store.name(at: "0-0") == "" && store.name(at: "0-1") == ""
                      && store.selection.count == 4))

        // 13) 目标位置已有人 → 拒绝，谁都不动
        resetBig()
        store.selection = ["0-0", "0-1"]
        let blockedMove = store.moveSelection(grab: "0-0", to: "1-0")   // 会压到 丁/戊
        cases.append(("框选整体移动·目标有学生 → 拒绝且原样不动",
                      !blockedMove && store.name(at: "0-0") == "甲"
                      && store.name(at: "1-0") == "丁" && store.name(at: "1-1") == "戊"))

        // 14) 撞讲台 → 拒绝
        resetBig(); store.podium = PodiumPlacement(row: 3, col: 0, span: 2)
        store.selection = ["0-0", "0-1"]
        let hitPodium = store.moveSelection(grab: "0-0", to: "3-0")
        cases.append(("框选整体移动·撞上讲台 → 拒绝",
                      !hitPodium && store.name(at: "0-0") == "甲" && store.name(at: "3-0") == ""))

        // 15) 框选整体移动越界（会超出表格右边界）→ 拒绝且原样不动
        resetBig()
        store.selection = ["0-0", "0-1"]
        let oobMove = store.moveSelection(grab: "0-0", to: "0-3")   // 右移 3 格 → 0-1 会落到 0-4（越界）
        cases.append(("框选整体移动·越界 → 拒绝且原样不动",
                      !oobMove && store.name(at: "0-0") == "甲" && store.name(at: "0-1") == "乙"
                      && store.selection == ["0-0", "0-1"]))

        // 15b) 框选状态下拖到**有学生**的格 → 两格直接互换（2026-09-12 修复的核心）
        resetBig()
        store.selection = ["0-0", "0-1"]                 // 框选住 甲 / 乙
        pick(SeatingStore.payload(selection: "0-0"))
        store.handleDrop("selblock|0-0", toKey: "1-1")   // 1-1 = 戊（选区外、有学生）
        DragContext.finish(reason: "座位")
        cases.append(("框选状态下拖到有学生的格 → 两格直接互换（甲↔戊，乙不动，选区清空）",
                      store.name(at: "0-0") == "戊" && store.name(at: "1-1") == "甲"
                      && store.name(at: "0-1") == "乙" && store.selection.isEmpty))

        // 15c) 框选状态下拖到**空位** → 仍然是整块移动（回归护栏）
        resetBig()
        store.selection = ["0-0", "0-1"]
        pick(SeatingStore.payload(selection: "0-0"))
        store.handleDrop("selblock|0-0", toKey: "2-0")   // 2-0 是空位
        DragContext.finish(reason: "座位")
        cases.append(("框选状态下拖到空位 → 整块移动（甲/乙 下移 2 行，原位清空）",
                      store.name(at: "2-0") == "甲" && store.name(at: "2-1") == "乙"
                      && store.name(at: "0-0") == "" && store.name(at: "0-1") == ""))

        // 15d) 单格拖动对换（没有框选时也一样是互换）
        resetBig()
        pick(SeatingStore.payload(cell: "0-0"))
        store.handleDrop("cell|0-0", toKey: "1-1")
        DragContext.finish(reason: "座位")
        cases.append(("单格拖动到有学生的格 → 直接互换（甲↔戊）",
                      store.name(at: "0-0") == "戊" && store.name(at: "1-1") == "甲"))

        // 16) 框选整体拖到待用栏 = 选区学生全部撤下
        resetBig()
        store.selection = ["0-0", "1-0"]
        pick(SeatingStore.payload(selection: "0-0"))
        store.handleDrop("selblock|0-0", toKey: nil); DragContext.finish(reason: "座位")
        cases.append(("框选整体拖到待用栏（甲/丁入待用、格子清空）",
                      store.pool.contains("甲") && store.pool.contains("丁")
                      && store.name(at: "0-0") == "" && store.name(at: "1-0") == ""))

        // 17) 讲台格子拒绝放学生
        resetBig(); store.podium = PodiumPlacement(row: 3, col: 0, span: 2)
        store.handleDrop("cell|0-2", toKey: "3-0"); DragContext.finish(reason: "座位")
        cases.append(("讲台格子拒绝放学生（丙仍在 0-2）",
                      store.name(at: "0-2") == "丙" && store.name(at: "3-0") == ""))

        // 18) 拖动讲台：换行换列（落点当中心）
        resetBig(); store.podium = PodiumPlacement(row: 3, col: 0, span: 2)
        _ = store.movePodium(to: "2-2")
        cases.append(("拖动讲台换行换列（中心对齐落点 → 第3行第2列起）",
                      store.podium?.row == 2 && store.podium?.col == 1))

        // 19) 讲台不能压在学生上
        resetBig(); store.podium = PodiumPlacement(row: 3, col: 0, span: 2)
        let blockedPodium = store.movePodium(to: "0-2")      // 会压到 乙/丙
        cases.append(("讲台压到学生 → 拒绝并留在原处", !blockedPodium && store.podium?.row == 3))

        // 20) 讲台居中 + 宽度可调
        resetBig(); store.podium = PodiumPlacement(row: 2, col: 0, span: 2)
        store.centerPodium()                              // (2,0,2) → (2,1,2)
        let centered = (store.podium?.col == 1 && store.podium?.span == 2)
        store.setPodiumSpan(3)                            // (2,1,3)
        cases.append(("讲台居中 + 宽度可调（居中到第2列、再放宽到 3 格）",
                      centered && store.podium?.span == 3 && store.podium?.col == 1))

        // 21) 删除讲台所在的行 → 讲台自动另找空行（不会越界）
        resetBig(); store.podium = PodiumPlacement(row: 3, col: 0, span: 2)
        store.removeRow(3)
        cases.append(("删除讲台所在行 → 讲台自动重找位置且不越界",
                      store.podium.map { $0.row < store.rows && $0.col + $0.span <= store.cols } ?? false))

        // 22) 删列：讲台左侧被删 → 左移；删到讲台覆盖的列 → 变窄
        resetBig(); store.podium = PodiumPlacement(row: 2, col: 1, span: 3)
        store.removeColumn(0)
        let shiftOK = (store.cols == 3 && store.podium?.col == 0
                       && (store.podium.map { $0.col + $0.span <= store.cols } ?? false))
        resetBig(); store.podium = PodiumPlacement(row: 2, col: 1, span: 3)
        store.removeColumn(3)
        let narrowOK = (store.cols == 3 && store.podium?.span == 2)
        cases.append(("删列后讲台自动收敛（左侧被删→左移；删到覆盖列→变窄）",
                      shiftOK && narrowOK))

        // 23) 插行插列时讲台跟着平移
        resetBig(); store.podium = PodiumPlacement(row: 2, col: 1, span: 2)
        store.insertRow(at: 0); store.insertColumn(at: 0)
        cases.append(("插行插列后讲台跟着平移（第3行第3列起）",
                      store.podium?.row == 3 && store.podium?.col == 2))

        // 24) 框选同时跳过讲台格与空位
        resetBig(); store.podium = PodiumPlacement(row: 1, col: 1, span: 2)
        store.selectRect(from: "0-0", to: "3-3")
        cases.append(("框选自动跳过讲台格 / 空位（0-0→3-3 只中甲/乙/丙/丁 4 格）",
                      store.selection == Set(["0-0", "0-1", "0-2", "1-0"])
                      && !store.selection.contains("1-1") && !store.selection.contains("1-2")))

        // 25) 列号：与行号同一套阿拉伯数字（0→1、9→10、25→26）
        cases.append(("列号 1 / 10 / 26（原 Excel 式 A/B/C 已改成数字）",
                      SeatingStore.columnLabel(0) == "1" && SeatingStore.columnLabel(9) == "10"
                      && SeatingStore.columnLabel(25) == "26"))

        // ── 以下为 2.1.9：取消「分组」功能后的旧数据迁移 ──

        // 26) 旧 v3 文件：色块被忽略、待用小组名单并回待用栏（学生一个不丢）
        let legacyJSON = """
        {"version":3,"grid":[["甲","乙"],["丙",""]],"pool":["己"],"genders":{"甲":"男"},"podium":null,\
        "regions":[{"id":"11111111-1111-1111-1111-111111111111","title":"第1小组","cells":["0-0","0-1"],"colorIndex":0}],\
        "poolGroups":[{"id":"22222222-2222-2222-2222-222222222222","title":"第2小组","names":["庚","辛"],"cols":2,"colorIndex":1}]}
        """
        try? legacyJSON.write(to: URL(fileURLWithPath: tmp + "/seating.json"),
                              atomically: true, encoding: .utf8)
        let migrated = SeatingStore()
        cases.append(("旧 v3 迁移·色块忽略 + 待用小组名单并回待用栏（己/庚/辛 都在）",
                      Set(migrated.pool) == Set(["己", "庚", "辛"])
                      && migrated.name(at: "0-0") == "甲" && migrated.name(at: "0-1") == "乙"
                      && migrated.name(at: "1-0") == "丙"))
        cases.append(("旧 v3 迁移·表格撑到 11×11 且讲台放进表格",
                      migrated.rows == 11 && migrated.cols == 11 && migrated.podium != nil))
        cases.append(("旧 v3 迁移·落盘为 v4 且不再写分组字段",
                      SeatingStore.loadV2()?.version == SeatingStore.dataVersion
                      && SeatingStore.loadV2()?.regions == nil
                      && SeatingStore.loadV2()?.poolGroups == nil))

        // 27) 导出格式（列号表头 + 行号 + 讲台行）能被导入解析正确还原。
        //     列号 2026-09-13 起改成数字（1/2/3…），但旧文件里的 Excel 式字母（A/B/C）必须照样认。
        let exportedRows: [[String]] = [
            ["", "1", "2"],
            ["1", "甲", "乙"],
            ["2", "丙", ""],
            ["3", "讲台", ""],
            ["待用栏", "己"],
        ]
        let reparsed = AppCoordinator.parseSeating(exportedRows)
        let reparsedNames = reparsed.groups.flatMap { $0.seats.flatMap { $0 } }.filter { !$0.isEmpty }
        cases.append(("导出格式可再导入·新列号 1/2（列头/行号/讲台行都不当姓名，甲/乙/丙/待用己 都对）",
                      Set(reparsedNames) == Set(["甲", "乙", "丙"]) && reparsed.pool.contains("己")))

        // 27b) 旧版导出（列号 A/B/C）仍能导入 —— 换了列号不能让老文件打不开
        let legacyHeaderRows: [[String]] = [
            ["", "A", "B"],
            ["1", "甲", "乙"],
            ["2", "丙", ""],
            ["待用栏", "己"],
        ]
        let legacyHeaderParsed = AppCoordinator.parseSeating(legacyHeaderRows)
        let legacyHeaderNames = legacyHeaderParsed.groups.flatMap { $0.seats.flatMap { $0 } }.filter { !$0.isEmpty }
        cases.append(("旧版字母列头（A/B/C）仍可导入（甲/乙/丙 都在、没被当姓名吃掉）",
                      Set(legacyHeaderNames) == Set(["甲", "乙", "丙"]) && legacyHeaderParsed.pool.contains("己")))

        // 28) 模板 → 导入 闭环：空模板不该解析出任何「假姓名」（表头 / 行号 / 讲台 都不算姓名）
        let (tplRows, _) = AppCoordinator.templateRows(.seating)
        let tplParsed = AppCoordinator.parseSeating(tplRows)
        let tplNames = tplParsed.groups.flatMap { $0.seats.flatMap { $0 } }.filter { !$0.isEmpty }
        cases.append(("座位模板→导入：空模板不产生假姓名（表头/行号/讲台都不算）",
                      tplNames.isEmpty && tplParsed.pool.isEmpty))
        var filled = tplRows
        if filled.count > 2 { filled[2][1] = "张三" }        // 第 1 行数据的 B 列填一个姓名
        let filledParsed = AppCoordinator.parseSeating(filled)
        let filledNames = filledParsed.groups.flatMap { $0.seats.flatMap { $0 } }.filter { !$0.isEmpty }
        cases.append(("座位模板填写后可导入（张三被正确解析）", filledNames == ["张三"]))

        print("--- 座位拖拽 / 框选整体移动 / 讲台 / 取消分组后的数据迁移 自检 ---")
        for (name, ok) in cases { print("\(ok ? "✓" : "✗") \(name)") }
        print(cases.allSatisfy { $0.1 } ? "全部通过 ✓" : "存在失败项 ✗")
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
        // 首行是「整行只有 1 个非空格」的标题 → 导入侧 dropTitleRows 会剥掉（座位模板 2.1.9 起也改成这种格式）
        let withTitle: Set<String> = ["个人课表", "班级课表", "学生信息", "年级师资", "教室分布", "班级座位"]
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
        // 办公室工位：模板（含「楼层」行）→ 写盘 → 读回 → parseOffices，楼层要能读回来
        // （导出 / 模板 / 导入三处必须同格式：加字段就要三处一起加，这里就是那道防回归的闸门）
        print("--- 办公室工位：模板 → xlsx → parseOffices（楼层行）---")
        do {
            let (rows, name) = AppCoordinator.templateRows(.office)
            let url = tmpDir.appendingPathComponent("\(name)-楼层.xlsx")
            try XLSX.write(rows, to: url)
            let back = try XLSX.read(url)
            let parsed = AppCoordinator.parseOffices(back)
            let floors = parsed.map(\.floor)
            let officeOk = parsed.count == 2 && floors == ["三楼", "四楼"]
            if !officeOk { bad.append("办公室工位/楼层行") }
            print("  办公室数=\(parsed.count)  标题=\(parsed.map(\.title))  楼层=\(floors)  判定=\(officeOk ? "✓" : "✗")")
        } catch {
            print("  ERROR \(error.localizedDescription)")
            bad.append("办公室工位/楼层行")
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

    // MARK: 定时提醒 → 系统日历 自检（只读：不碰 EventKit / 通知中心，仅打印将要写入的内容）
    // 注意：命令行下创建 EKEventStore 或 UNUserNotificationCenter 会直接 abort 掉进程，
    // 所以这里不初始化任何 Store，直接读 JSON 文件做纯逻辑校验。
    static func runCalendarSyncCheck() {
        print("--- 定时提醒 → 系统「日历」自检（只读，不写入日历）---")
        let enabled = (UserDefaults.standard.object(forKey: "calendarSyncReminders") as? Bool) ?? true
        print("同步开关 = \(enabled ? "开启（默认）" : "关闭")")
        print("写入日历 = 「\(CalendarSyncService.calendarName)」（不存在时自动创建，创建失败则退回系统默认日历）")

        let remindersURL = Self.supportDir.appendingPathComponent("reminders.json")
        let reminders = (try? Data(contentsOf: remindersURL))
            .flatMap { try? JSONDecoder().decode([Reminder].self, from: $0) } ?? []
        print("本地提醒条数 = \(reminders.count)")

        let cal = Calendar.current
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "zh_CN")
        let weekNames = ["", "周日", "周一", "周二", "周三", "周四", "周五", "周六"]

        // ① 星期标签必须与取值指向同一天（2026-09-12 曾整体错位一天，导致「勾了周六却周六不弹」）
        print("--- 星期标签用例（标签必须等于 Calendar.weekday 的同一天）---")
        var labelBad: [String] = []
        for w in 1...7 {
            let got = ReminderStore.weekdayLabel(w)
            let want = weekNames[w]
            if got != want { labelBad.append("\(w)→\(got)（应为 \(want)）") }
            print("  取值 \(w)：标签「\(got)」\(got == want ? "✓" : "✗ 应为「\(want)」")")
        }
        let orderOK = Set(ReminderStore.weekdayDisplayOrder) == Set(1...7)
        if !orderOK { labelBad.append("显示顺序不是 1…7 的排列") }
        print("  显示顺序 = \(ReminderStore.weekdayDisplayOrder.map { ReminderStore.weekdayLabel($0) }.joined(separator: " ")) \(orderOK ? "✓" : "✗")")

        // ② 用真实日历验证「周六」确实命中周六（2026-09-12 是周六）
        let satFormatter = DateFormatter()
        satFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        satFormatter.locale = Locale(identifier: "zh_CN")
        if let sat = satFormatter.date(from: "2026-09-12 11:41") {
            let wd = cal.component(.weekday, from: sat)
            let probe = Reminder(title: "周六用例", hour: 11, minute: 41,
                                 weekdays: ReminderStore.weekdayMonToSat, url: "")
            let hit = probe.fires(on: wd)
            if !hit { labelBad.append("2026-09-12(周六) 未命中「周一至周六」") }
            print("  2026-09-12（Calendar.weekday=\(wd) 即 \(weekNames[wd])）命中「周一至周六」= \(hit ? "✓" : "✗")")
        }
        print(labelBad.isEmpty ? "  星期标签判定=✓" : "  星期标签判定=✗ \(labelBad.joined(separator: "; "))")

        for r in reminders {
            let days = CalendarSyncService.orderedWeekdays(r.weekdays)
            let labels = days.map { weekNames[$0] }.joined(separator: " ")
            let start = CalendarSyncService.firstStart(from: r, calendar: cal)
            print("「\(r.title)」 \(String(format: "%02d:%02d", r.hour, r.minute)) [\(labels)] 每周重复 首次=\(f.string(from: start)) 时长=30 分钟")
        }

        print("--- 星期映射用例（1=周日 … 7=周六，与 Calendar.weekday 一致）---")
        let cases: [Set<Int>] = [[1, 2, 3, 4, 5, 6], [2, 4, 6, 7], [7], [1, 7], []]
        for set in cases {
            let ordered = CalendarSyncService.orderedWeekdays(set)
            let labels = ordered.map { weekNames[$0] }.joined(separator: " ")
            print("\(set.sorted()) -> \(ordered) -> \(labels.isEmpty ? "（无，跳过不写日历）" : labels)")
        }

        print("--- 「首次发生日期」用例（纯函数，用固定提醒）---")
        let probes: [Reminder] = [
            Reminder(title: "A", hour: 7, minute: 52, weekdays: [2, 3, 4, 5, 6], url: ""),
            Reminder(title: "B", hour: 20, minute: 5, weekdays: [1], url: ""),
            Reminder(title: "C", hour: 0, minute: 0, weekdays: [1, 2, 3, 4, 5, 6, 7], url: ""),
        ]
        for p in probes {
            let s = CalendarSyncService.firstStart(from: p, calendar: cal)
            let wd = cal.component(.weekday, from: s)
            let hit = p.weekdays.contains(wd)
            print("\(weekNames[wd]) \(f.string(from: s)) 命中勾选星期=\(hit ? "✓" : "✗") 时:分=\(cal.component(.hour, from: s)):\(cal.component(.minute, from: s))")
        }

        // ② 未勾任何星期 = 一次性提醒（2026-09-17：以前是「永远不会提醒」，用户要求改成「当天提醒一次」）
        print("--- 未勾星期 = 一次性提醒（当天该时刻提醒一次）用例 ---")
        var oneShotBad: [String] = []
        let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
        let todayKey = Reminder.dayString(noon)
        let yKey = Reminder.dayString(cal.date(byAdding: .day, value: -1, to: noon) ?? noon)
        let tKey = Reminder.dayString(cal.date(byAdding: .day, value: 1, to: noon) ?? noon)
        let todayWeekday = cal.component(.weekday, from: noon)

        let dueCases: [(name: String, r: Reminder, shouldFire: Bool)] = [
            ("一次性·当天·刚过点 1 分钟 → 弹",
                    Reminder(title: "A", hour: 11, minute: 59, weekdays: [], url: "", oneShotDay: todayKey),
                    true),
            ("一次性·当天·已过 4 小时 → 也补弹（需求核心）",
                    Reminder(title: "B", hour: 8, minute: 0, weekdays: [], url: "", oneShotDay: todayKey),
                    true),
            ("一次性·当天·还没到点 → 不弹",
                    Reminder(title: "C", hour: 12, minute: 10, weekdays: [], url: "", oneShotDay: todayKey),
                    false),
            ("一次性·昨天 → 不弹（已过期）",
                    Reminder(title: "D", hour: 8, minute: 0, weekdays: [], url: "", oneShotDay: yKey),
                    false),
            ("一次性·明天 → 不弹",
                    Reminder(title: "E", hour: 8, minute: 0, weekdays: [], url: "", oneShotDay: tKey),
                    false),
            ("一次性·没有日期（老数据） → 不弹",
                    Reminder(title: "F", hour: 8, minute: 0, weekdays: [], url: "", oneShotDay: nil),
                    false),
            ("每周·今天命中·刚过点 1 分钟 → 弹",
                    Reminder(title: "G", hour: 11, minute: 59, weekdays: [todayWeekday], url: ""),
                    true),
            ("每周·今天命中·已过 5 分钟 → 不弹（3 分钟窗口）",
                    Reminder(title: "H", hour: 11, minute: 55, weekdays: [todayWeekday], url: ""),
                    false),
            ("每周·今天没勾 → 不弹",
                    Reminder(title: "I", hour: 11, minute: 59,
                             weekdays: [todayWeekday == 1 ? 2 : 1], url: ""),
                    false),
            ("一次性·当天·已经弹过（firedOn=今天） → 不弹（重启不重复）",
                    Reminder(title: "J", hour: 11, minute: 59, weekdays: [], url: "",
                             oneShotDay: todayKey, firedOn: todayKey),
                    false),
        ]
        for c in dueCases {
            let v = ReminderFirer.dueCheck(c.r, now: noon, calendar: cal)
            let ok = v.due == c.shouldFire
            if !ok { oneShotBad.append(c.name) }
            print("  \(c.name)：判定=\(v.due ? "弹" : "不弹")（\(v.reason)）\(ok ? "✓" : "✗ 期望\(c.shouldFire ? "弹" : "不弹")")")
        }

        // syncOneShot 语义：没勾→记今天；勾了→清空；日期已过→重设为今天
        var s1 = Reminder(title: "s1", hour: 9, minute: 0, weekdays: [], url: "")
        s1.syncOneShot(now: noon)
        let s1ok = s1.oneShotDay == todayKey
        if !s1ok { oneShotBad.append("syncOneShot 未填当天") }
        s1.syncOneShot(now: cal.date(byAdding: .day, value: 1, to: noon) ?? noon)
        let s1b = s1.oneShotDay == tKey
        if !s1b { oneShotBad.append("syncOneShot 过期后未重设") }
        var s2 = Reminder(title: "s2", hour: 9, minute: 0, weekdays: [2, 3], url: "", oneShotDay: todayKey)
        s2.syncOneShot(now: noon)
        let s2ok = s2.oneShotDay == nil
        if !s2ok { oneShotBad.append("勾了星期未清 oneShotDay") }
        print("  syncOneShot：空→记今天 \(s1ok ? "✓" : "✗")；过期→重设明天 \(s1b ? "✓" : "✗")；勾了星期→清空 \(s2ok ? "✓" : "✗")")

        // rearmOneShot：改时间 → 过期日期搬回今天，并清掉「今天已提醒」标记（好按新时间再提醒）
        var s3 = Reminder(title: "s3", hour: 9, minute: 0, weekdays: [], url: "",
                          oneShotDay: yKey, firedOn: yKey)
        s3.rearmOneShot(now: noon)
        let s3ok = (s3.oneShotDay == todayKey && s3.firedOn == nil)
        if !s3ok { oneShotBad.append("rearmOneShot 未重置") }
        print("  rearmOneShot：过期日期→今天 且 清掉已提醒标记 \(s3ok ? "✓" : "✗")（oneShotDay=\(s3.oneShotDay ?? "nil") firedOn=\(s3.firedOn ?? "nil")）")

        // 旧版 reminders.json（无 oneShotDay 字段）必须还能解码
        let legacyJSON = #"[{"id":"00000000-0000-0000-0000-0000000000AA","title":"旧数据","hour":17,"minute":43,"weekdays":[],"url":""}]"#
        if let list = try? JSONDecoder().decode([Reminder].self, from: Data(legacyJSON.utf8)) {
            print("  旧格式（无 oneShotDay 字段）解码 = \(list.count) 条 ✓ oneShotDay=\(list[0].oneShotDay ?? "nil")（启动时会补成当天）")
        } else {
            oneShotBad.append("旧格式提醒解码失败")
            print("  旧格式（无 oneShotDay 字段）解码 = ✗")
        }
        print(oneShotBad.isEmpty ? "  一次性提醒判定=✓" : "  一次性提醒判定=✗ \(oneShotBad.joined(separator: "; "))")

        if let d = try? Data(contentsOf: Self.supportDir.appendingPathComponent("calendar_events.json")),
           let m = try? JSONDecoder().decode([String: String].self, from: d) {
            print("已同步事件映射 = \(m.count) 条（calendar_events.json）")
        } else {
            print("已同步事件映射 = 无（尚未同步过）")
        }
    }

    // MARK: 工位拖动对换自检（纯逻辑，不启 UI）：校验「单次 drop 只换一次 + 可撤销 + 可重拖 + 自身防护」
    // 用法：ScheduleBar --selftest-offices
    static func runOfficeSeatCheck() {
        // 用临时数据目录（与师资自检同一做法）。原来是「读真实 offices.json → 写入测试数据
        // → 事后还原」，一旦中途崩了/被强杀，用户的工位表就会变成「办公室A / 甲 / 乙」。
        // 统一走 AppPaths 之后改成全程隔离，真实文件一个字节都不碰。
        let tmp = "/tmp/selftest-offices-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        setenv("SCHEDULEBAR_DATA_DIR", tmp, 1)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        print("临时数据目录 = \(tmp)（真实 offices.json 不受影响）")

        let store = OfficeLayoutStore()
        let o1 = UUID(), o2 = UUID()
        store.offices = [
            OfficeBlock(id: o1, title: "办公室A", seats: [["甲", "乙"], ["丙", "丁"]]),
            OfficeBlock(id: o2, title: "办公室B", seats: [["1", "2"]]),
        ]
        UndoService.shared.undo()   // 清空可能残留的撤销栈

        // 1) 同办公室对换：甲(0,0) ↔ 丁(1,1)
        store.beginSeatDrag(officeID: o1, row: 0, col: 0)
        store.swapSeatTo(officeID: o1, row: 1, col: 1)
        store.finishSeatDrag()
        let a = store.offices[0].seats
        let swap1 = a[0][0] == "丁" && a[1][1] == "甲"

        // 2) 撤销应恢复原状
        _ = UndoService.shared.undo()
        let a2 = store.offices[0].seats
        let restore = a2[0][0] == "甲" && a2[1][1] == "丁"

        // 3) 跨办公室对换：乙(0,1) ↔ 1(0,0 of B)
        store.beginSeatDrag(officeID: o1, row: 0, col: 1)
        store.swapSeatTo(officeID: o2, row: 0, col: 0)
        store.finishSeatDrag()
        let cross = store.offices[0].seats[0][1] == "1"
                  && store.offices[1].seats[0][0] == "乙"

        // 4) 自身拖放（来源==落点）不改变数据
        let before = store.offices[0].seats
        store.beginSeatDrag(officeID: o1, row: 0, col: 0)
        store.swapSeatTo(officeID: o1, row: 0, col: 0)
        store.finishSeatDrag()
        let selfNoOp = store.offices[0].seats == before

        // 5) 落点越界（列不存在）应安全忽略
        let beforeOut = store.offices[0].seats
        store.beginSeatDrag(officeID: o1, row: 0, col: 0)
        store.swapSeatTo(officeID: o1, row: 9, col: 9)
        store.finishSeatDrag()
        let outNoOp = store.offices[0].seats == beforeOut

        print("同办公室对换:   \(swap1 ? "✓" : "✗")")
        print("撤销恢复:       \(restore ? "✓" : "✗")")
        print("跨办公室对换:   \(cross ? "✓" : "✗")")
        print("自身拖放不变:   \(selfNoOp ? "✓" : "✗")")
        print("越界安全忽略:   \(outNoOp ? "✓" : "✗")")

        // ===== 楼层 + 「整张卡片」拖动 =====
        // 换成一组可控的卡片：A/B 在「三楼」、C 在「四楼」、D 未分组
        let oa = UUID(), ob = UUID(), oc = UUID(), od = UUID()
        func resetCards() {
            store.offices = [
                OfficeBlock(id: oa, title: "A", seats: [["甲"]], floor: "三楼"),
                OfficeBlock(id: ob, title: "B", seats: [["乙"]], floor: "三楼"),
                OfficeBlock(id: oc, title: "C", seats: [["丙"]], floor: "四楼"),
                OfficeBlock(id: od, title: "D", seats: [["丁"]]),
            ]
            UndoService.shared.clear()   // 清撤销栈（必须是 clear，不能 undo —— undo 会把快照打回来）
        }
        func order() -> [UUID] { store.offices.map(\.id) }
        func floorOf(_ id: UUID) -> String { store.offices.first(where: { $0.id == id })?.floor ?? "?" }

        resetCards()

        // 6) 楼层顺序 = 卡片顺序里首次出现
        let floorOrder = store.floorNames == ["三楼", "四楼", ""] && store.hasFloors

        // 7) 同楼层重排 / 跨楼层跟随：把 C（四楼）拖到 A（三楼）上 → C 插到 A 之前并归到三楼
        store.beginCardDrag(oc)
        store.moveCard(oc, to: oa)
        store.finishCardDrag()
        let cardMove = order() == [oc, oa, ob, od] && floorOf(oc) == "三楼"
        resetCards()

        // 8) 拖到「楼层标题」上 → 挪到该楼层末尾
        store.beginCardDrag(oa)
        store.moveCard(oa, toFloor: "四楼")
        store.finishCardDrag()
        let toFloor = order() == [ob, oc, oa, od] && floorOf(oa) == "四楼"
        resetCards()

        // 9) 拖到未分组的卡片上 → 自己也变成未分组
        store.beginCardDrag(ob)
        store.moveCard(ob, to: od)
        store.finishCardDrag()
        let toUngrouped = order() == [oa, oc, ob, od] && floorOf(ob).isEmpty
        resetCards()

        // 10) 卡片拖动可整体撤销
        store.beginCardDrag(oc)
        store.moveCard(oc, to: oa)
        store.finishCardDrag()
        _ = UndoService.shared.undo()
        let cardUndo = order() == [oa, ob, oc, od] && floorOf(oc) == "四楼"

        // 11) 楼层整体上移
        store.moveFloor("四楼", by: -1)
        let floorMove = order() == [oc, oa, ob, od] && store.floorNames == ["四楼", "三楼", ""]
        _ = UndoService.shared.undo()

        // 12) 新建楼层（把已有卡片挪进去，不额外造办公室）
        store.addFloor(named: "五楼", assigning: ob)
        let newFloor = order() == [oa, oc, od, ob]
            && floorOf(ob) == "五楼"
            && store.floorNames == ["三楼", "四楼", "", "五楼"]
        _ = UndoService.shared.undo()

        // 13) 楼层改名（整层一起改）
        store.renameFloor("四楼", to: "四楼东")
        let renameFloor = store.floorNames.contains("四楼东") && floorOf(oc) == "四楼东"
        _ = UndoService.shared.undo()

        // 14) 删除楼层 = 删掉该层所有办公室，一次撤销可恢复
        store.deleteFloor("四楼")
        let delFloor = store.offices.count == 3 && !store.floorNames.contains("四楼")
        _ = UndoService.shared.undo()
        let delFloorUndo = store.offices.count == 4 && store.floorNames.contains("四楼")

        // 15) 移出楼层：只清楼层标签，一间办公室都不删
        store.clearFloor("三楼")
        let clearFloor = store.offices.count == 4 && !store.floorNames.contains("三楼")
        _ = UndoService.shared.undo()

        // 16) 自身落点 / 未登记的卡片拖动 → 不改数据
        let beforeCard = store.offices
        store.beginCardDrag(oa)
        store.moveCard(oa, to: oa)
        store.finishCardDrag()
        let selfCardNoOp = store.offices == beforeCard

        // 17) 老 offices.json（没有 floor / seatColors 字段）→ 读成「未分组」，不报错
        let legacy = "[{\"id\":\"\(UUID().uuidString)\",\"title\":\"老办公室\",\"seats\":[[\"甲\",\"乙\"],[\"丙\",\"\"]]}]"
        try? legacy.data(using: .utf8)?.write(to: OfficeLayoutStore.fileURL())
        let reloaded = OfficeLayoutStore()
        let legacyOK = reloaded.offices.count == 1
            && reloaded.offices[0].floor == ""
            && reloaded.offices[0].seatColors.isEmpty
            && reloaded.floorNames == [""]
            && !reloaded.hasFloors

        print("楼层顺序推导:   \(floorOrder ? "✓" : "✗")")
        print("卡片拖动换位:   \(cardMove ? "✓" : "✗")")
        print("拖到楼层标题:   \(toFloor ? "✓" : "✗")")
        print("拖成未分组:     \(toUngrouped ? "✓" : "✗")")
        print("卡片拖动撤销:   \(cardUndo ? "✓" : "✗")")
        print("楼层整体上移:   \(floorMove ? "✓" : "✗")")
        print("新建楼层:       \(newFloor ? "✓" : "✗")")
        print("楼层改名:       \(renameFloor ? "✓" : "✗")")
        print("删除楼层+撤销:  \(delFloor && delFloorUndo ? "✓" : "✗")")
        print("移出楼层:       \(clearFloor ? "✓" : "✗")")
        print("自身落点不变:   \(selfCardNoOp ? "✓" : "✗")")
        print("老 JSON 兼容:   \(legacyOK ? "✓" : "✗")")

        // 18) 拖拽载荷：卡片 / 工位两个模块必须互不误判（否则座位对换会去搬整张卡片）
        let seatPayload = DragPayload.office(oa, row: 1, col: 2)
        let cardPayload = DragPayload.officeCardPayload(oa)
        let payloadOK = DragPayload.officeCardID(from: cardPayload) == oa
            && DragPayload.officeCardID(from: seatPayload) == nil
            && !DragPayload.belongs(seatPayload, to: DragPayload.officeCard)
            && !DragPayload.belongs(cardPayload, to: DragPayload.officeSeat)
        print("拖拽载荷区分:   \(payloadOK ? "✓" : "✗")")

        // 18) 新建办公室可撤销（与「删除办公室」对等）
        resetCards()
        store.addOffice(floor: "三楼")
        let addCount = store.offices.count == 5 && store.offices.last?.floor == "三楼"
        _ = UndoService.shared.undo()
        let addOfficeUndo = store.offices.count == 4 && order() == [oa, ob, oc, od]
        print("新建办公室可撤销: \(addOfficeUndo ? "✓" : "✗")")

        // 19) 新建楼层仍只压一条撤销（撤销一次就完全回到原样，不会「退一半」）
        resetCards()
        store.addFloor(named: "五楼")
        _ = UndoService.shared.undo()
        let newFloorOneStep = store.offices.count == 4 && store.floorNames == ["三楼", "四楼", ""]
        print("新建楼层一步撤销: \(newFloorOneStep ? "✓" : "✗")")

        // 20) 整层拖动：两个楼层整层对调（楼内顺序原样保留、一间办公室都不丢）
        //     A/B 在三楼、C 在四楼 → 拖「三楼」落到「四楼」→ 四楼整块提到前面
        resetCards()
        store.beginFloorDrag(0)
        store.swapFloors(0, 1)
        store.finishFloorDrag()
        let swapFloorsOK = store.floorNames == ["四楼", "三楼", ""]
            && order() == [oc, oa, ob, od]
            && floorOf(oc) == "四楼" && floorOf(oa) == "三楼" && floorOf(ob) == "三楼"
        _ = UndoService.shared.undo()
        let swapFloorsUndo = store.floorNames == ["三楼", "四楼", ""] && order() == [oa, ob, oc, od]
        print("整层交换+撤销:  \(swapFloorsOK && swapFloorsUndo ? "✓" : "✗")")

        // 21) 整层落到自己身上 / 中途取消 → 数据一点不动（不能压出空撤销）
        resetCards()
        let beforeFloor = store.offices
        store.beginFloorDrag(0)
        store.swapFloors(0, 0)
        store.finishFloorDrag()
        let selfFloorNoOp = store.offices == beforeFloor
        store.beginFloorDrag(1)
        let floorCancelled = store.cancelFloorDrag()
        let cancelFloorNoOp = floorCancelled && store.offices == beforeFloor
        print("整层自身落点不变: \(selfFloorNoOp && cancelFloorNoOp ? "✓" : "✗")")

        // 22) 楼层载荷 vs 卡片载荷 vs 工位载荷：三者必须互不误判
        let floorPayload = DragPayload.officeFloorPayload(1)
        let floorPayloadOK = DragPayload.officeFloorIndex(from: floorPayload) == 1
            && DragPayload.officeFloorIndex(from: cardPayload) == nil
            && DragPayload.officeFloorIndex(from: seatPayload) == nil
            && DragPayload.officeCardID(from: floorPayload) == nil
            && !DragPayload.belongs(floorPayload, to: DragPayload.officeCard)
            && !DragPayload.belongs(floorPayload, to: DragPayload.officeSeat)
            && !DragPayload.belongs(cardPayload, to: DragPayload.officeFloor)
        print("楼层载荷区分:   \(floorPayloadOK ? "✓" : "✗")")

        // 23) 整层拖动落到「目标楼层的卡片/座位」上（不必对准标题条）：
        //     三种落点都先归一成「目标楼层下标」，再走同一份提交逻辑。
        resetCards()
        let floorIdxOK = store.floorIndexOfOffice(oa) == 0      // A/B 在三楼 → 下标 0
            && store.floorIndexOfOffice(oc) == 1                // C 在四楼 → 下标 1
            && store.floorIndexOfOffice(UUID()) == nil          // 不存在的卡片 → nil（不会误伤）
        store.beginFloorDrag(0)
        if let fi = store.floorIndexOfOffice(oc) { store.swapFloors(0, fi) }
        store.finishFloorDrag()
        let dropOnCardOK = store.floorNames == ["四楼", "三楼", ""] && order() == [oc, oa, ob, od]
        _ = UndoService.shared.undo()
        print("整层落到卡片上: \(floorIdxOK && dropOnCardOK ? "✓" : "✗")")

        let ok = swap1 && restore && cross && selfNoOp && outNoOp
            && floorOrder && cardMove && toFloor && toUngrouped && cardUndo
            && floorMove && newFloor && renameFloor && delFloor && delFloorUndo
            && clearFloor && selfCardNoOp && legacyOK && payloadOK
            && addCount && addOfficeUndo && newFloorOneStep
            && swapFloorsOK && swapFloorsUndo && selfFloorNoOp && cancelFloorNoOp && floorPayloadOK
            && floorIdxOK && dropOnCardOK
        print(ok ? "工位对换/楼层自检全部通过 ✓" : "工位对换/楼层自检存在问题 ✗")
    }

    // MARK: 教室自检（纯逻辑，临时数据目录，不碰真实 classrooms.json）
    // 用法：ScheduleBar --selftest-classroom
    // 覆盖：同层对换、**跨楼层对换**、主行↔附加行对换、原地拖放、越界安全忽略、
    //       对换可撤销、单击选中→删除选中格子（含撤销）、选中格子被换走后仍能删掉。
    static func runClassroomCheck() {
        let tmp = "/tmp/selftest-classroom-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        setenv("SCHEDULEBAR_DATA_DIR", tmp, 1)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        print("临时数据目录 = \(tmp)（真实 classrooms.json 不受影响）")

        let store = ClassroomStore()

        func room(_ k: String) -> ClassroomCell { ClassroomCell(kind: .room, klass: k, room: "") }
        let f1 = UUID(), f2 = UUID()
        store.floors = [
            ClassroomFloor(id: f1, title: "4楼",
                           cells: ["A1", "A2", "A3"].map(room),
                           extraRows: [ClassroomRow(cells: ["B1", "B2"].map(room))]),
            ClassroomFloor(id: f2, title: "5楼", cells: ["C1", "C2"].map(room)),
        ]
        let r1 = store.floors[0].extraRows[0].id
        _ = UndoService.shared.undo()   // 清空可能残留的撤销栈

        let names0 = { store.floors[0].cells.map(\.klass) }
        let names1 = { store.floors[1].cells.map(\.klass) }
        let extra0 = { store.floors[0].extraRows[0].cells.map(\.klass) }

        // 1) 跨楼层对换：A1(4楼主行0) ↔ C2(5楼主行1)
        store.beginDrag(floorID: f1, rowID: nil, index: 0)
        store.swapTo(floorID: f2, rowID: nil, index: 1)
        store.finishDrag()
        let crossFloor = names0() == ["C2", "A2", "A3"] && names1() == ["C1", "A1"]

        // 2) 撤销应恢复原状
        _ = UndoService.shared.undo()
        let undoSwap = names0() == ["A1", "A2", "A3"] && names1() == ["C1", "C2"]

        // 3) 同层主行 ↔ 附加行对换：A2 ↔ B2
        store.beginDrag(floorID: f1, rowID: nil, index: 1)
        store.swapTo(floorID: f1, rowID: r1, index: 1)
        store.finishDrag()
        let crossRow = names0() == ["A1", "B2", "A3"] && extra0() == ["B1", "A2"]

        // 4) 原地拖放（楼层/行/下标全同）不改变数据
        let before = store.floors
        store.beginDrag(floorID: f1, rowID: nil, index: 0)
        store.swapTo(floorID: f1, rowID: nil, index: 0)
        store.finishDrag()
        let selfNoOp = store.floors == before

        // 5) 越界落点安全忽略
        store.beginDrag(floorID: f1, rowID: nil, index: 0)
        store.swapTo(floorID: f1, rowID: nil, index: 99)
        store.finishDrag()
        let outNoOp = store.floors == before

        // 6) 单击选中 → 按 Delete 删除选中的格子
        let target = store.floors[0].cells[2]           // A3
        store.select(floorID: f1, rowID: nil, cellID: target.id)
        let delOK = store.deleteSelectedCell()
        let delGone = delOK && store.floors[0].cells.count == 2
            && !store.floors[0].cells.contains { $0.id == target.id }
            && store.selection == nil                   // 删完自动清掉选中态

        // 7) 删除可撤销
        _ = UndoService.shared.undo()
        let delUndo = store.floors[0].cells.contains { $0.id == target.id }
            && store.floors[0].cells.count == 3

        // 8) 选中的格子被跨楼层换走 → 选中态跟着走，仍能删掉它
        let moving = store.floors[0].cells[0]           // A1
        store.select(floorID: f1, rowID: nil, cellID: moving.id)
        store.beginDrag(floorID: f1, rowID: nil, index: 0)
        store.swapTo(floorID: f2, rowID: nil, index: 0)
        store.finishDrag()
        let selFollows = store.selection?.floorID == f2 && store.selection?.cellID == moving.id
        let delAfterMove = store.deleteSelectedCell()
        let followOK = selFollows && delAfterMove
            && !store.floors[1].cells.contains { $0.id == moving.id }

        // 9) 没选中时按 Delete 不应该删任何东西
        let countBefore = store.floors.reduce(0) { $0 + $1.cellCount }
        let noSel = !store.deleteSelectedCell()
            && store.floors.reduce(0) { $0 + $1.cellCount } == countBefore

        // 10) 整层拖动：把两层在列表里的位置互换（2026-09-26 用户要求「上下交换整个楼层」）
        store.beginFloorDrag(0)
        store.swapFloors(0, 1)
        store.finishFloorDrag()
        let floorSwap = store.floors.map(\.title) == ["5楼", "4楼"]

        // 11) 整层对调可撤销
        _ = UndoService.shared.undo()
        let floorSwapUndo = store.floors.map(\.title) == ["4楼", "5楼"]

        // 12) 整层「原地」（来源 == 目标）不改变任何数据、也不登记撤销
        let floorSnap = store.floors
        store.beginFloorDrag(0)
        store.swapFloors(0, 0)
        store.finishFloorDrag()
        let floorSelfNoOp = store.floors == floorSnap

        // 13) 整层拖动被外部打断 → 只复位状态，不动数据
        store.beginFloorDrag(1)
        store.setFloorSwapTarget(0)
        let floorCancelHad = store.cancelFloorDrag()
        let floorCancelNoOp = floorCancelHad && store.floors == floorSnap && store.floorSwapTarget == nil

        // 14) 楼层下标按 id 现算（整层拖动会改顺序，不能缓存下标）
        let floorIdxOK = store.floorIndex(of: f1) == 0 && store.floorIndex(of: f2) == 1

        // 15) 整层载荷与格子载荷互不误判
        let floorPayload = DragPayload.classroomFloorPayload(1)
        let floorPayloadOK = DragPayload.classroomFloorIndex(from: floorPayload) == 1
            && DragPayload.classroomFloorIndex(from: DragPayload.classroom(floor: f1, row: nil, index: 0)) == nil
            && !DragPayload.belongs(floorPayload, to: DragPayload.classroomCell)

        print("跨楼层对换:     \(crossFloor ? "✓" : "✗")")
        print("对换可撤销:     \(undoSwap ? "✓" : "✗")")
        print("主行↔附加行:    \(crossRow ? "✓" : "✗")")
        print("原地拖放不变:   \(selfNoOp ? "✓" : "✗")")
        print("越界安全忽略:   \(outNoOp ? "✓" : "✗")")
        print("选中后删除:     \(delGone ? "✓" : "✗")")
        print("删除可撤销:     \(delUndo ? "✓" : "✗")")
        print("选中跟随换位:   \(followOK ? "✓" : "✗")")
        print("无选中不误删:   \(noSel ? "✓" : "✗")")
        print("整层对调:       \(floorSwap ? "✓" : "✗")")
        print("整层对调可撤销: \(floorSwapUndo ? "✓" : "✗")")
        print("整层原地不变:   \(floorSelfNoOp ? "✓" : "✗")")
        print("整层取消复位:   \(floorCancelNoOp ? "✓" : "✗")")
        print("楼层下标现算:   \(floorIdxOK ? "✓" : "✗")")
        print("整层载荷区分:   \(floorPayloadOK ? "✓" : "✗")")
        print("临时目录已写盘: \((try? Data(contentsOf: ClassroomStore.fileURL())) != nil ? "✓" : "✗")")

        let ok = crossFloor && undoSwap && crossRow && selfNoOp && outNoOp
            && delGone && delUndo && followOK && noSel
            && floorSwap && floorSwapUndo && floorSelfNoOp && floorCancelNoOp
            && floorIdxOK && floorPayloadOK
        print(ok ? "教室自检全部通过 ✓" : "教室自检存在问题 ✗")
    }

    // MARK: 师资单元格颜色自检（纯逻辑，临时数据目录，不碰真实 staff.json）
    // 用法：ScheduleBar --selftest-staff
    // 覆盖：单格设色/清色、按「同一个人 / 同一班型」批量设色、持久化、删列后颜色键左移、
    //       整表清色、旧版 staff.json（没有 colors 字段）兼容。
    static func runStaffColorCheck() {
        let tmp = "/tmp/selftest-staff-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        setenv("SCHEDULEBAR_DATA_DIR", tmp, 1)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        print("临时数据目录 = \(tmp)（真实 staff.json 不受影响）")

        let store = StaffStore()
        _ = UndoService.shared.undo()   // 清空可能残留的撤销栈

        store.headers = ["班级", "班主任", "班型", "语文", "英语"]
        store.rows = [
            StaffRow(cells: ["1", "张三", "联招班", "张三", "李四"]),
            StaffRow(cells: ["2", "李四", "冲刺1", "张三", "王五"]),
            StaffRow(cells: ["3", "张三", "联招班", "赵六", "李四"]),
        ]
        let r0 = store.rows[0].id, r1 = store.rows[1].id, r2 = store.rows[2].id
        var cases: [(String, Bool)] = []

        // 1) 默认无自定义颜色（视图层即「默认灰」）
        cases.append(("默认无自定义颜色", store.color(rowID: r0, col: 3) == nil))

        // 2) 单格设色 / 读回 / 清除
        store.setColor("E74C3C", rowID: r0, col: 3)
        cases.append(("单格设色可读回", store.color(rowID: r0, col: 3) == "E74C3C"))
        store.setColor(nil, rowID: r0, col: 3)
        cases.append(("清除单格颜色", store.color(rowID: r0, col: 3) == nil))

        // 3) 按「同一个人」批量设色：张三 共 4 格（0-班主任 / 0-语文 / 1-语文 / 2-班主任）
        store.setColorForAllCells(text: "张三", hex: "3498DB")
        let zhang = [(r0, 1), (r0, 3), (r1, 3), (r2, 1)]
        cases.append(("按姓名批量设色（4 格）",
                      zhang.allSatisfy { store.color(rowID: $0.0, col: $0.1) == "3498DB" }))
        cases.append(("不误伤其它格", store.color(rowID: r1, col: 1) == nil
                      && store.color(rowID: r2, col: 0) == nil))

        // 4) 按「同一班型」批量设色：联招班 2 格，且容忍首尾空格
        store.rows[2].cells[2] = " 联招班 "
        store.setColorForAllCells(text: "联招班", hex: "2ECC71")
        cases.append(("按班型批量设色（含首尾空格）",
                      store.color(rowID: r0, col: 2) == "2ECC71"
                      && store.color(rowID: r2, col: 2) == "2ECC71"
                      && store.color(rowID: r1, col: 2) == nil))

        // 5) 颜色随 staff.json 持久化
        store.save()
        let reloaded = StaffStore.load()
        cases.append(("颜色随 staff.json 持久化",
                      reloaded?.rows.first { $0.id == r0 }?.colors["1"] == "3498DB"))

        // 6) 删列后颜色键整体左移（删第 3 列「语文」→ 原第 4 列「英语」变 3）
        store.setColor("9B59B6", rowID: r1, col: 4)
        store.removeColumn(3)
        cases.append(("删列后颜色键左移",
                      store.color(rowID: r1, col: 3) == "9B59B6"
                      && store.color(rowID: r0, col: 1) == "3498DB"))

        // 7) 整表清色
        store.clearAllColors()
        cases.append(("整表清色", store.rows.allSatisfy { $0.colors.isEmpty }))

        // 8) 旧版 staff.json（没有 colors 字段）能正常读取
        let legacy = """
        {"headers":["班级","班主任"],"rows":[{"id":"11111111-1111-1111-1111-111111111111","cells":["1","张三"]}]}
        """
        if let d = try? JSONDecoder().decode(StaffData.self, from: Data(legacy.utf8)) {
            cases.append(("旧版数据（无 colors）兼容",
                          d.rows.count == 1 && d.rows[0].colors.isEmpty && d.rows[0].cells[1] == "张三"))
        } else {
            cases.append(("旧版数据（无 colors）兼容", false))
        }

        // 9) 学科配色（2026-09-26「不同学科用不同颜色」）：
        //    同一学科整列同色、不同学科不同色、非学科列不配色、未知科目也稳定给色
        let cChinese = StaffStore.subjectColor(forColumnHeader: "语文")
        let cMath = StaffStore.subjectColor(forColumnHeader: "数学")
        let cEnglish = StaffStore.subjectColor(forColumnHeader: "英语")
        cases.append(("学科色：语文/数学/英语各不相同",
                      cChinese != nil && cMath != nil && cEnglish != nil
                      && Set([cChinese!, cMath!, cEnglish!]).count == 3))
        cases.append(("学科色：同一学科名永远同色",
                      StaffStore.subjectColor(forColumnHeader: "语文") == cChinese
                      && StaffStore.subjectColor(forColumnHeader: " 语文 ") == cChinese))
        cases.append(("学科色：非学科列不配色（班级/班主任/班型）",
                      StaffStore.subjectColor(forColumnHeader: "班级") == nil
                      && StaffStore.subjectColor(forColumnHeader: "班主任") == nil
                      && StaffStore.subjectColor(forColumnHeader: "班型") == nil
                      && !StaffStore.isSubjectColumn("班型")))
        cases.append(("学科色：表头带后缀也能认出（「语文(含作文)」）",
                      StaffStore.subjectColor(forColumnHeader: "语文(含作文)") == cChinese))
        // 未知科目（视图里「添加科目」会生成这类名字）→ 仍给一个稳定颜色，且不会与已知学科混用同一套判断
        let c1 = StaffStore.subjectColor(forColumnHeader: "科目12")
        let c2 = StaffStore.subjectColor(forColumnHeader: "科目12")
        cases.append(("学科色：未知科目稳定给色（同一名字同色）", c1 != nil && c1 == c2))
        // 全部默认表头都拿到确定的取舍：非学科列 nil，其余必修色
        let defaultMap = StaffStore.defaultHeaders.map { ($0, StaffStore.subjectColor(forColumnHeader: $0)) }
        cases.append(("学科色：默认表头 3 列不配色、8 个学科都有色",
                      defaultMap.prefix(3).allSatisfy { $0.1 == nil }
                      && defaultMap.dropFirst(3).allSatisfy { $0.1 != nil }))
        // 8 个默认学科两两不同色（一眼能区分哪几列是同一门课）
        let subjectHexes = defaultMap.dropFirst(3).compactMap { $0.1 }
        cases.append(("学科色：8 个默认学科两两不同色", Set(subjectHexes).count == subjectHexes.count))

        for (name, ok) in cases { print("\(ok ? "✓" : "✗") \(name)") }
        print(cases.allSatisfy { $0.1 } ? "师资颜色自检全部通过 ✓" : "师资颜色自检存在问题 ✗")
    }

    private static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScheduleBar", isDirectory: true)
    }

    // MARK: - 统一保存中心自检（全程在临时目录，绝不触碰真实数据）
    //
    // 用法：教师助手.app/Contents/MacOS/ScheduleBar --selftest-save
    //
    // 覆盖「编辑只标脏 → 点保存/⌘S → 落盘」这条链：
    //   ① 只标脏时**不写盘**（用户要能看见「有未保存的改动」这个状态）
    //   ② saveNow / saveIfNeeded 才真正落盘，且落盘后脏状态清空
    //   ③ 无改动时 saveIfNeeded 不产生无谓 IO
    //   ④ 每个可编辑板块都能把自己标脏（名字与数量必须与 SaveHub.writeAll 的覆盖面一致）
    //   ⑤ 最后把替身换回真实实现，确认 json **真的**写出了文件
    //
    // ⚠️ 自检必须把数据目录重定向走（SCHEDULEBAR_DATA_DIR）：任何 store 的 init 里
    //    都可能有历史迁移，读到真实目录就会写用户的真实数据。
    //    2026-09-18 就是因为「提醒」的迁移用了 UserDefaults 开关、且裸二进制偏好域不同，
    //    被自检进程当成首次运行重跑，把用户的提醒星期整体搬错了一天。
    static func runSaveCheck() {
        let tmp = NSTemporaryDirectory() + "sb-save-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        setenv("SCHEDULEBAR_DATA_DIR", tmp, 1)      // 必须在任何 store 被创建之前
        defer {
            unsetenv("SCHEDULEBAR_DATA_DIR")
            try? FileManager.default.removeItem(atPath: tmp)
        }

        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("  \(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "  [\(detail)]")")
            ok ? (pass += 1) : (fail += 1)
        }

        let hub = SaveHub.shared
        var writes = 0
        hub.useStubWriter { writes += 1 }
        hub.clearDirty()
        defer {
            hub.clearDirty()
            hub.useDefaultWriter()
        }

        print("保存中心自检 —— 兜底延时 \(Int(SaveHub.fallbackDelay)) 秒，数据目录=\(tmp)")

        // ① 初始干净
        check("初始状态无未保存改动", !hub.hasUnsaved, "unsavedCount=\(hub.unsavedCount)")

        // ② 编辑 → 只标脏，不写盘
        ScheduleStore.shared.scheduleSave()
        check("编辑本人课表后：标记为有未保存改动", hub.hasUnsaved)
        check("板块名正确（按钮提示文案用的就是它）", hub.dirtyAreas.contains("本人课表"),
              "dirtyAreas=\(hub.dirtyAreas.sorted().joined(separator: "、"))")
        check("只标脏、未落盘（没点保存前不写文件）", writes == 0, "writes=\(writes)")

        // ③ 同一板块连续编辑只算一处
        let n1 = hub.unsavedCount
        ScheduleStore.shared.scheduleSave()
        check("同一板块连续编辑不新增待保存项", hub.unsavedCount == n1, "unsavedCount=\(hub.unsavedCount)")

        // ④ 多个板块累积
        StaffStore.shared.scheduleSave()
        check("第二个板块也标脏 → 共 2 处", hub.unsavedCount == 2, "unsavedList=\(hub.unsavedList)")
        check("多板块时仍未落盘", writes == 0, "writes=\(writes)")

        // ⑤ saveNow：落盘一次 + 清空脏状态
        let before = hub.saveNow(reason: "自检")
        check("saveNow 报告「落盘前有 2 处未保存」", before == 2, "返回=\(before)")
        check("saveNow 触发了一次落盘动作", writes == 1, "writes=\(writes)")
        check("落盘后脏状态清空（按钮转「已保存」）", !hub.hasUnsaved, "unsavedCount=\(hub.unsavedCount)")
        check("落盘后记录保存时间", hub.lastSavedAt != nil)
        check("落盘后显示「已保存」瞬时标记", hub.justSaved)

        // ⑥ 无改动时 saveIfNeeded 不做无谓 IO
        hub.saveIfNeeded(reason: "自检·无改动")
        check("无改动时 saveIfNeeded 不写盘", writes == 1, "writes=\(writes)")

        // ⑦ 有改动时 saveIfNeeded 会兜底落盘（关面板 / 关窗口 / 退出走的就是这条）
        CalendarRemarkStore.shared.scheduleSave()
        check("标记一处新的未保存改动", hub.hasUnsaved)
        hub.saveIfNeeded(reason: "自检·兜底")
        check("有改动时 saveIfNeeded 兜底落盘", writes == 2, "writes=\(writes)")
        check("兜底落盘后脏状态清空", !hub.hasUnsaved)

        // ⑧ 每个走 SaveHub 的板块都能把自己标脏（名字必须与 writeAll 的覆盖面一致）
        // ⚠️ 「教室布局」不在此列：用户 2026-09-23 要求教室的编辑/新增**即时落盘**，
        //    它的 scheduleSave() 直接 save()，不经过 markDirty（见下面的单独检查）。
        let areas: [(String, () -> Void)] = [
            ("本人课表", { ScheduleStore.shared.scheduleSave() }),
            ("班级课表", { ClassScheduleStore.shared.scheduleSave() }),
            ("他人课表", { TeacherScheduleStore.shared.scheduleSave() }),
            ("学生座位", { SeatingStore.shared.scheduleSave() }),
            ("年级师资", { StaffStore.shared.scheduleSave() }),
            ("学生信息", { StudentStore.shared.scheduleSave() }),
            ("教师工位", { OfficeLayoutStore.shared.scheduleSave() }),
            ("延时监考", { ExtendScheduleStore.shared.scheduleSave() }),
            ("日程提醒", { ReminderStore.shared.scheduleSave() }),
            ("校历备注", { CalendarRemarkStore.shared.scheduleSave() }),
            ("校历配色", { CalendarDayColorStore.shared.scheduleSave() }),
            ("导航排序", { NavPrefsStore.shared.scheduleSave() }),
            ("当前周", { WeekStore.shared.scheduleSave() }),
            ("板块标题", { CardTitleStore.shared.scheduleSave() }),
        ]
        // 必须与 SaveHub.writeAll 覆盖的 store 数量一致（漏一个就会有板块改了不落盘）
        // = 上面 14 个走「标脏」的 + 1 个「即时落盘」的教室布局
        let expectedAreaCount = 15
        var missing: [String] = []
        for (name, mark) in areas {
            hub.clearDirty()
            mark()
            if !hub.dirtyAreas.contains(name) { missing.append(name) }
        }
        check("每个走统一保存的板块都能把自己标脏", missing.isEmpty,
              missing.isEmpty ? "共 \(areas.count) 个" : "缺失=\(missing.joined(separator: "、"))")
        check("标脏板块（14）+ 即时落盘板块（教室布局）与 writeAll 覆盖面一致",
              areas.count + 1 == expectedAreaCount, "\(areas.count) + 1 / 期望 \(expectedAreaCount)")

        // 「教室布局」即时落盘：改一下就写文件，不进「未保存」列表
        hub.clearDirty()
        ClassroomStore.shared.scheduleSave()
        check("教室布局改为即时落盘（不标脏、不进未保存列表）",
              !hub.dirtyAreas.contains("教室布局"))

        // ⑨ 单板块清除不影响其他
        hub.clearDirty()
        ScheduleStore.shared.scheduleSave()
        StaffStore.shared.scheduleSave()
        hub.clearDirty("本人课表")
        check("clearDirty(板块) 只清一个", hub.dirtyAreas.contains("年级师资") && !hub.dirtyAreas.contains("本人课表"),
              "unsavedList=\(hub.unsavedList)")

        // ⑩ 兜底延时必须是「有意义的一段时间」，不能被误改成 0（那样每个按键都写盘）
        check("兜底自动保存延时在 3~30 秒之间", (3...30).contains(SaveHub.fallbackDelay),
              "\(Int(SaveHub.fallbackDelay)) 秒")

        // ⑪ 端到端：换成「真的写文件」的落盘实现，确认 json 确实落到了磁盘
        //    ⚠️ 这里不能用 SaveHub 的默认 writeAll：它会调 ReminderStore.save()，
        //       而那条链要建系统通知（UNUserNotificationCenter）——命令行进程没有 App bundle，
        //       会直接抛 NSException 崩掉（不是数据问题，是 CLI 无 bundle 的固有限制）。
        hub.useStubWriter {
            ScheduleStore.shared.save()
            StaffStore.shared.save()
            SeatingStore.shared.save()
        }
        hub.clearDirty()
        ScheduleStore.shared.scheduleSave()
        StaffStore.shared.scheduleSave()
        SeatingStore.shared.scheduleSave()
        let n = hub.saveNow(reason: "自检·端到端")
        check("端到端 saveNow 报告 3 处", n == 3, "返回=\(n)")
        let fm = FileManager.default
        var produced: [String] = []
        for f in ["personal.json", "staff.json", "seating.json"] {
            let path = tmp + "/" + f
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let size = attrs[.size] as? Int, size > 2 {
                produced.append("\(f)(\(size)B)")
            }
        }
        check("真实落盘：三个 json 都写出了非空文件", produced.count == 3,
              produced.joined(separator: " "))
        check("AppPaths 重定向生效（写的是临时目录，不是真实数据目录）",
              AppPaths.dataDir.path == tmp, AppPaths.dataDir.path)

        hub.clearDirty()
        print("保存中心自检：\(pass) 项通过，\(fail) 项失败 \(fail == 0 ? "✓" : "✗")")
        if fail > 0 { exit(1) }
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

    // MARK: 教师课表自检（--selftest-teacher）
    // 用临时数据目录：真实 teacher_schedules.json 一个字节都不会被碰。
    static func runTeacherCheck() {
        let tmp = "/tmp/selftest-teacher-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        setenv("SCHEDULEBAR_DATA_DIR", tmp, 1)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        print("临时数据目录 = \(tmp)（真实 teacher_schedules.json 不受影响）")

        var failed: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "  [\(detail)]")")
            if !ok { failed.append(name) }
        }

        // 1) 解析学校下发的「长表」：表头 + 每位教师连续若干行
        let grid: [[String]] = [
            ["姓名", "节次", "周一", "周二", "周三", "周四", "周五", "周六", "周天"],
            ["刘娇/尹海燕", "第1节课", "", "", "", "", "", "", ""],
            ["刘娇/尹海燕", "第2节课", "", "", "", "", "", "", ""],
            ["刘娇/尹海燕", "第7节课", "", "", "初二-11 班/心", "", "", "", ""],
            ["丁灵", "第1节课", "初一-18 数学", "", "初一-18 数学", "初一-18 数学", "", "", ""],
            ["丁灵", "第2节课", "初一-18 数学", "", "", "", "", "", ""],
            ["丁灵", "第4节课", "", "初一-17 数学", "初一-17 数学", "", "", "", ""],
        ]
        let parsed = AppCoordinator.parseTeacherSchedules(grid)
        check("解析长表：按教师聚合成 2 位", parsed.count == 2, "\(parsed.count)")
        let ding = parsed.first { $0.teacher == "丁灵" }
        check("节次按出现顺序保留", ding?.periods == ["第1节课", "第2节课", "第4节课"],
              "\(ding?.periods ?? [])")
        check("单元格落位正确（丁灵·周三·第1节）", ding?.cells.first.map { $0[2] } == "初一-18 数学",
              ding?.cells.first.map { $0[2] } ?? "nil")
        check("成对姓名（刘娇/尹海燕）原样保留",
              parsed.contains { $0.teacher == "刘娇/尹海燕" })

        // 2) 无表头 / 「星期x」写法也能认
        let noHeader: [[String]] = [
            ["王老师", "第1节课", "初二-3 语文", "", "", "", "", "", ""],
            ["王老师", "第2节课", "", "初二-3 语文", "", "", "", "", ""],
        ]
        let p2 = AppCoordinator.parseTeacherSchedules(noHeader)
        check("无表头时按默认列序解析", p2.count == 1 && p2[0].cells[0][0] == "初二-3 语文")
        let weekStyle: [[String]] = [
            ["姓名", "节次", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"],
            ["李老师", "第1节课", "", "", "", "", "初三-9 化学", "", ""],
        ]
        let p3 = AppCoordinator.parseTeacherSchedules(weekStyle)
        check("「星期一…星期日」写法可识别", p3.first?.cells.first?[4] == "初三-9 化学",
              p3.first?.cells.first?[4] ?? "nil")

        // 3) 模糊查询：包含即命中
        let store = TeacherScheduleStore()
        UndoService.shared.clear()
        store.replaceAll(parsed)
        check("导入后教师数 = 2", store.teacherCount == 2, "\(store.teacherCount)")
        check("课节统计 = 7", store.lessonCount == 7, "\(store.lessonCount)")
        check("查询「丁」命中丁灵", store.search("丁").map(\.teacher) == ["丁灵"])
        check("查询「灵」命中丁灵（中间字）", store.search("灵").map(\.teacher) == ["丁灵"])
        check("查询「尹海燕」命中成对姓名", store.search("尹海燕").map(\.teacher) == ["刘娇/尹海燕"])
        check("查询「张」无人命中", store.search("张").isEmpty)
        check("空关键字 = 全部", store.search("").count == 2)
        check("关键字两端空格被忽略", store.search("  丁  ").count == 1)
        check("查询结果不影响原数据", store.teacherCount == 2)

        // 3b) 下拉 / 标签区的顺序：姓名升序（中文按拼音）
        let order = store.search("").map { $0.teacher }
        check("列表按姓名升序", zip(order, order.dropFirst())
                .allSatisfy { TeacherScheduleStore.nameAscending($0, $1) },
              order.joined(separator: " < "))
        check("下拉列表本身也是升序", zip(store.sortedByName.map { $0.teacher },
                                   store.sortedByName.map { $0.teacher }.dropFirst())
                .allSatisfy { TeacherScheduleStore.nameAscending($0, $1) })

        // 4) 单元格文本拆分与配色
        let s1 = TeacherBlock.split("初一-18 数学")
        let s2 = TeacherBlock.split("晚自习")
        check("拆「班级 科目」", s1.room == "初一-18" && s1.subject == "数学", "\(s1)")
        check("无空格时整串当科目", s2.room.isEmpty && s2.subject == "晚自习")
        check("科目配色可命中（数学）", TeacherBlock.subjectColor("数学") != nil)

        // 5) 改格子 + 撤销
        guard let dingID = store.search("丁灵").first?.id else {
            check("取到丁灵这条记录", false)
            print("教师课表自检存在问题 ✗")
            return
        }
        store.setCell(blockID: dingID, row: 1, col: 0, text: "初一-19 语文")
        check("改格子生效", store.teacher(dingID)?.cells[1][0] == "初一-19 语文")
        _ = UndoService.shared.undo()
        check("改格子可撤销", store.teacher(dingID)?.cells[1][0] == "初一-18 数学")

        // 6) 新建 / 重名自动序号 / 重命名 / 删除（都可撤销）
        store.addTeacher()
        check("新建教师", store.teacherCount == 3 && store.teachers.last?.teacher == "新教师")
        store.addTeacher()
        check("重名自动加序号", store.teachers.last?.teacher == "新教师2",
              store.teachers.last?.teacher ?? "nil")
        _ = UndoService.shared.undo()
        _ = UndoService.shared.undo()
        check("连续撤销回到 2 位", store.teacherCount == 2, "\(store.teacherCount)")

        store.renameTeacher(dingID, to: "丁灵老师")
        check("重命名生效", store.search("丁灵老师").count == 1)
        _ = UndoService.shared.undo()
        check("重命名可撤销", store.search("丁灵").count == 1)

        store.removeTeacher(dingID)
        check("删除教师", store.teacherCount == 1)
        _ = UndoService.shared.undo()
        check("删除可撤销", store.teacherCount == 2)

        // 7) 模板 → 解析 回环（用户按模板填完再导入）
        let (tplRows, tplName) = AppCoordinator.templateRows(.teacher)
        let back = AppCoordinator.parseTeacherSchedules(tplRows)
        check("模板文件名", tplName == "他人课表模板", tplName)
        check("模板可被自己的解析器读回", back.count == 1 && back[0].teacher == "张老师",
              "\(back.map { $0.teacher })")
        check("模板示例格保留（张老师·周一·第1节）", back.first?.cells.first?[0] == "初一-18 数学",
              back.first?.cells.first?[0] ?? "nil")

        // 8) 落盘 → 重新装载一致
        store.save()
        let reloaded = TeacherScheduleStore()
        check("写入后重新装载一致", reloaded.teacherCount == store.teacherCount
              && reloaded.lessonCount == store.lessonCount,
              "\(reloaded.teacherCount) 位 / \(reloaded.lessonCount) 节")

        // 9) 该板块也要能被 SaveHub 标脏（保存按钮才会亮）
        SaveHub.shared.clearDirty()
        store.scheduleSave()
        check("编辑后 SaveHub 标脏「他人课表」",
              SaveHub.shared.dirtyAreas.contains("他人课表"))
        SaveHub.shared.clearDirty()
        UndoService.shared.clear()

        print(failed.isEmpty ? "教师课表自检全部通过 ✓"
                             : "教师课表自检存在问题 ✗（\(failed.joined(separator: "、"))）")
    }

    // MARK: 教师课表：直接解析一份 xlsx（--import-teacher <xlsx> [--write]）
    // 用于拿学校的真实长表做端到端验收：只解析并打印摘要；
    // 加 --write 才把结果写进**当前数据目录**的 teacher_schedules.json。
    static func importTeacherFile(_ path: String, write: Bool) {
        do {
            let url = URL(fileURLWithPath: path)
            let grid = try XLSX.read(url)
            let blocks = AppCoordinator.parseTeacherSchedules(grid)
            print("文件：\(url.lastPathComponent)")
            print("表格：\(grid.count) 行 × \(grid.map { $0.count }.max() ?? 0) 列")
            print("解析：\(blocks.count) 位教师，\(blocks.reduce(0) { $0 + $1.lessonCount }) 节课")
            let sortedNames = blocks.map { $0.teacher }
                .sorted { TeacherScheduleStore.nameAscending($0, $1) }
            let ascending = zip(sortedNames, sortedNames.dropFirst())
                .allSatisfy { TeacherScheduleStore.nameAscending($0, $1) }
            print("姓名升序（下拉 / 标签区顺序）：\(ascending ? "✓" : "✗")")
            print("  前 10 位：" + sortedNames.prefix(10).joined(separator: "、"))
            print("  末 3 位：" + sortedNames.suffix(3).joined(separator: "、"))
            print("前 3 位课表摘要：")
            for b in blocks.prefix(3) {
                print("--- \(b.teacher)（\(b.lessonCount) 节）---")
                for (i, per) in b.periods.enumerated() where i < b.cells.count {
                    let items = b.cells[i].enumerated()
                        .filter { !$0.element.isEmpty }
                        .map { "\(TeacherBlock.days[$0.offset]) \($0.element)" }
                    if !items.isEmpty { print("  \(per): \(items.joined(separator: " / "))") }
                }
            }
            if write {
                let store = TeacherScheduleStore()
                store.replaceAll(blocks)
                store.save()
                print("已写入：\(TeacherScheduleStore.fileURL().path)")
            }
        } catch {
            print("ERROR: \(error.localizedDescription)")
        }
    }

    // MARK: 星期列自检（7 列 / 隐藏周六 / 6→7 列迁移）
    // 用法：ScheduleBar --selftest-week
    // 覆盖：三张表列定义一致、**6→7 列迁移必须把周日留在周日列**、最旧 7 列格式不再被删列、
    //       星期标签识别、导入列定位（先认表头再兜底）、可见列下标、表格自然宽（面板加宽依据）。
    static func runWeekColumnCheck() {
        let tmp = "/tmp/selftest-week-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        setenv("SCHEDULEBAR_DATA_DIR", tmp, 1)
        defer {
            unsetenv("SCHEDULEBAR_DATA_DIR")
            try? FileManager.default.removeItem(atPath: tmp)
        }
        print("临时数据目录 = \(tmp)（真实 personal.json / classes.json 不受影响）")

        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("  \(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "  [\(detail)]")")
            ok ? (pass += 1) : (fail += 1)
        }

        // 1) 三张课的星期列定义必须完全一致：周六 = index 5、周日 = index 6
        print("--- 1) 三张表的星期列定义 ---")
        check("本人课表 7 列、周六=5 / 周日=6",
              ScheduleStore.days.count == 7 && ScheduleStore.days[5] == "周六" && ScheduleStore.days[6] == "周日",
              ScheduleStore.days.joined(separator: ","))
        check("班级课表 7 列、周六=5 / 周日=6",
              ClassLayout.days.count == 7 && ClassLayout.days[5] == "星期6" && ClassLayout.days[6] == "周日",
              ClassLayout.days.joined(separator: ","))
        check("他人课表 7 列、周六=5 / 周天=6",
              TeacherBlock.days.count == 7 && TeacherBlock.days[5] == "周六" && TeacherBlock.days[6] == "周天",
              TeacherBlock.days.joined(separator: ","))
        check("ScheduleWeek.saturday=5 / sunday=6 且与 days.count 一致",
              ScheduleWeek.saturday == 5 && ScheduleWeek.sunday == 6
              && ScheduleStore.days.count == ScheduleWeek.columnCount)

        // 2) 6→7 列迁移：周日必须仍在 index 6，周六列补空
        print("--- 2) 6→7 列迁移（不能把周日灌进周六列）---")
        let six = ["一", "二", "三", "四", "五", "日"]
        let migrated = ClassLayout.migrateDayColumns(six)
        check("6 列 → 7 列", migrated.count == 7, "\(migrated.count)")
        check("迁移后 index 6 仍是「日」、index 5 为空（补出周六列）",
              migrated[6] == "日" && migrated[5] == "" && migrated[0] == "一",
              migrated.joined(separator: "|"))
        check("已是 7 列时原样保留（幂等）", ClassLayout.migrateDayColumns(migrated) == migrated)
        check("行宽不足 6 列时只按尾补空、不插周六列",
              ClassLayout.migrateDayColumns(["a", "b"]) == ["a", "b", "", "", "", "", ""])

        // 3) 本人课表：把 6 列旧数据写盘 → 走真实 load()
        print("--- 3) personal.json（6 列旧数据）→ load() ---")
        let personal6 = PersonalData(groups: ScheduleStore.defaultGroups,
                                     grid: (0..<13).map { _ in ["一", "二", "三", "四", "五", "周日标记"] })
        if let d = try? JSONEncoder().encode(personal6) { try? d.write(to: ScheduleStore.fileURL()) }
        if let loaded = ScheduleStore.load(), let row = loaded.grid.first {
            check("load() 后每行 7 列",
                  loaded.grid.allSatisfy { $0.count == 7 },
                  "行数=\(loaded.grid.count) 首行宽=\(row.count)")
            check("旧 6 列的周日仍在 index 6、周六列补空",
                  row.count == 7 && row[6] == "周日标记" && row[5] == "",
                  row.joined(separator: "|"))
        } else {
            check("load() 能读出 6 列旧数据", false)
        }

        // 4) 最旧格式（纯 [[String]]，7 列 = 周一~周日）曾经被删列，现在必须原样保留
        print("--- 4) 最旧格式（纯数组 7 列）---")
        let oldest: [[String]] = (0..<13).map { _ in ["一", "二", "三", "四", "五", "六", "日"] }
        if let d = try? JSONEncoder().encode(oldest) { try? d.write(to: ScheduleStore.fileURL()) }
        if let loaded = ScheduleStore.load(), let row = loaded.grid.first {
            check("最旧 7 列格式：周六/周日都还在（不再删 index 5）",
                  row.count == 7 && row[5] == "六" && row[6] == "日",
                  row.joined(separator: "|"))
        } else {
            check("最旧 7 列格式能读出", false)
        }

        // 5) 班级课表：classes.json 6 列 → loadBank()
        print("--- 5) classes.json（6 列旧数据）→ loadBank() ---")
        let cell6: [String: [String]] = ["第1节": ["一", "二", "三", "四", "五", "周日标记"]]
        let bank6 = ClassBankData(classes: ["测试班"], defaultClass: "测试班",
                                  bank: ["测试班": ClassData(groups: ClassLayout.defaultGroups, cells: cell6)])
        if let d = try? JSONEncoder().encode(bank6) { try? d.write(to: ClassScheduleStore.fileURL()) }
        if let loaded = ClassScheduleStore.loadBank(),
           let row = loaded.bank["测试班"]?.cells["第1节"] {
            check("loadBank() 后行宽 7", row.count == 7, "\(row.count)")
            check("旧 6 列的周日仍在 index 6、周六列补空",
                  row.count == 7 && row[6] == "周日标记" && row[5] == "",
                  row.joined(separator: "|"))
        } else {
            check("loadBank() 能读出 6 列旧数据", false)
        }
        let canon = ClassLayout.canonicalize(groups: ClassLayout.defaultGroups, cells: cell6)
        check("canonicalize 复制旧单元格时也补出周六列",
              canon.cells["第1节"]?.count == 7 && canon.cells["第1节"]?[6] == "周日标记",
              "\(canon.cells["第1节"]?.count ?? -1)")

        // 6) 星期标签识别（含 xlsx 竖排「星⏎期⏎五」）
        print("--- 6) 星期标签 → 列下标 ---")
        let dayCases: [(String, Int?)] = [
            ("周一", 0), ("星期一", 0), ("礼拜一", 0), ("周1", 0),
            ("星期三", 2), ("星\n期\n五", 4), ("周六", 5), ("星期六", 5), ("礼拜六", 5),
            ("周日", 6), ("周天", 6), ("星期天", 6), ("星期日", 6),
            ("节次", nil), ("", nil),
        ]
        for (raw, want) in dayCases {
            let got = ScheduleWeek.dayIndex(from: raw)
            check("「\(raw.replacingOccurrences(of: "\n", with: "⏎"))」→ \(want.map(String.init) ?? "nil")",
                  got == want, "实得 \(got.map(String.init) ?? "nil")")
        }
        check("ClassLayout.dayIndex 已改为共用实现（周六不再是 nil）",
              ClassLayout.dayIndex(from: "星期六") == 5 && ClassLayout.dayIndex(from: "星期日") == 6)

        // 7) 导入列定位：先认表头，认不出再按位置兜底
        print("--- 7) 导入列定位（先认表头，再按位置兜底）---")
        let map6 = ScheduleWeek.headerColumnMap(["节次", "周一", "周二", "周三", "周四", "周五", "周日"])
        check("旧 6 天表头：周日落到 index 6 而不是 5", map6[6] == 6 && map6[5] == nil, "\(map6)")
        let map7 = ScheduleWeek.headerColumnMap(["节次"] + ScheduleStore.days)
        check("新 7 天表头：周六取第 6 列、周日取第 7 列", map7[5] == 6 && map7[6] == 7, "\(map7)")
        check("位置兜底：旧 7 宽行（节次+6天）d=6 → 第 6 列",
              ScheduleWeek.fallbackColumn(dayIndex: 6, rowWidth: 7) == 6)
        check("位置兜底：旧 7 宽行 d=5（周六）取不到（那时表里没这列）",
              ScheduleWeek.fallbackColumn(dayIndex: 5, rowWidth: 7) == nil)
        check("位置兜底：新 8 宽行 d=5→6、d=6→7",
              ScheduleWeek.fallbackColumn(dayIndex: 5, rowWidth: 8) == 6
              && ScheduleWeek.fallbackColumn(dayIndex: 6, rowWidth: 8) == 7)

        // 8) 可见列下标（默认隐藏周六、显示周日）
        print("--- 8) 显隐 —— 默认隐藏周六、显示周日 ---")
        check("默认（周六关、周日开）= 周一~周五 + 周日",
              ScheduleWeek.visibleIndices(showSaturday: false, showSunday: true) == [0, 1, 2, 3, 4, 6])
        check("全开 = 7 列", ScheduleWeek.visibleIndices(showSaturday: true, showSunday: true) == Array(0...6))
        check("只开周六 = 周一~周六",
              ScheduleWeek.visibleIndices(showSaturday: true, showSunday: false) == [0, 1, 2, 3, 4, 5])
        check("全关 = 周一~周五",
              ScheduleWeek.visibleIndices(showSaturday: false, showSunday: false) == [0, 1, 2, 3, 4])
        check("偏好默认值 = 隐藏周六 / 显示周日",
              ScheduleDayPrefsStore.shared.showSaturday == false
              && ScheduleDayPrefsStore.shared.showSunday == true)

        // 9) 表格自然宽（决定面板要不要加宽）
        print("--- 9) 表格自然宽 / 面板加宽依据 ---")
        check("6 列自然宽 = 680（默认视图）",
              ScheduleWeek.tableNaturalWidth(columns: 6) == 680,
              "\(ScheduleWeek.tableNaturalWidth(columns: 6))")
        check("7 列自然宽 = 782（已超过 709 的内容区）",
              ScheduleWeek.tableNaturalWidth(columns: 7) == 782,
              "\(ScheduleWeek.tableNaturalWidth(columns: 7))")
        check("6 列（含滚动条余量）= 700 ≤ 709 → 默认视图面板不变宽",
              ScheduleWeek.tableIdealWidth(columns: 6) <= 709,
              "\(ScheduleWeek.tableIdealWidth(columns: 6))")
        check("7 列（含滚动条余量）= 802 > 709 → 面板加宽 93pt",
              ScheduleWeek.tableIdealWidth(columns: 7) == 802,
              "\(ScheduleWeek.tableIdealWidth(columns: 7))")

        // 10) 真落盘：走 SaveHub.writeAll 里那两个 save()，写出来的必须是 7 列
        //     （load() 迁移对了但 save() 又写回 6 列的话，下次读回来还得再迁一次 —— 必须有这层）
        print("--- 10) save() 落盘宽度 ---")
        if let d = try? JSONEncoder().encode(personal6) { try? d.write(to: ScheduleStore.fileURL()) }
        let pStore = ScheduleStore()            // 从 6 列旧文件装载 → 应迁成 7 列
        pStore.save()
        if let raw = try? Data(contentsOf: ScheduleStore.fileURL()),
           let back = try? JSONDecoder().decode(PersonalData.self, from: raw) {
            check("本人课表 save() 后文件里每行 7 列",
                  !back.grid.isEmpty && back.grid.allSatisfy { $0.count == 7 },
                  "宽度=\(Set(back.grid.map(\.count)).sorted())")
            check("本人课表落盘后周日仍在 index 6、周六列空",
                  back.grid.first?.count == 7 && back.grid.first?[6] == "周日标记"
                  && back.grid.first?[5] == "",
                  (back.grid.first ?? []).joined(separator: "|"))
        } else {
            check("本人课表 save() 能写出可读的 personal.json", false)
        }

        if let d = try? JSONEncoder().encode(bank6) { try? d.write(to: ClassScheduleStore.fileURL()) }
        let cStore = ClassScheduleStore()       // 同理：从 6 列旧文件装载
        cStore.save()
        if let raw = try? Data(contentsOf: ClassScheduleStore.fileURL()),
           let back = try? JSONDecoder().decode(ClassBankData.self, from: raw),
           let row = back.bank["测试班"]?.cells["第1节"] {
            check("班级课表 save() 后单元格 7 列", row.count == 7, "宽度=\(row.count)")
            check("班级课表落盘后周日仍在 index 6、周六列空",
                  row.count == 7 && row[6] == "周日标记" && row[5] == "",
                  row.joined(separator: "|"))
        } else {
            check("班级课表 save() 能写出可读的 classes.json", false)
        }

        // ⚠️ 汇总行里别出现「✗」字形：脚本是按行 grep '✗' 统计失败数的，
        //    写成「✗ 0」会被当成 1 个失败（2026-09-26 实际踩到）。
        print(fail == 0
              ? "星期列自检全部通过 ✓（\(pass) 项）"
              : "星期列自检存在问题：失败 \(fail) / \(pass + fail) 项")
    }
}
