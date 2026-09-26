import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 导入/导出协调器（菜单栏 app 的面板交互）
final class AppCoordinator: ObservableObject {
    static let shared = AppCoordinator()

    private let xlsxType = UTType(filenameExtension: "xlsx") ?? .data

    // MARK: 导入（由用户在选择时指定类型）
    func importPersonalFile() {
        importFile("导入本人课表", grid: importPersonal)
    }

    // MARK: - 在线检查更新（GitHub release）
    func checkForUpdate(manually: Bool = false) {
        GitHubUpdateService.shared.checkForUpdates(auto: !manually) { [weak self] r in
            self?.presentUpdateResult(r, manual: manually)
        }
    }

    private func presentUpdateResult(_ r: GitHubUpdateService.Result, manual: Bool) {
        switch r {
        case .notConfigured:
            // 仓库地址内置在代码里；未配置时静默（不打扰用户）
            if manual {
                PanelHelper.prepare()
                let a = NSAlert()
                a.messageText = "检查更新不可用"
                a.informativeText = "尚未内置有效的 GitHub 仓库地址，请把 GitHubUpdateService 顶部的 owner / repo 改成您的公开仓库后重新打包。当前地址：\(GitHubUpdateService.shared.repoIdentifier)"
                PanelHelper.bringFront(a)
                a.runModal()
            }
        case .latest(let cur):
            if manual {
                PanelHelper.prepare()
                let a = NSAlert()
                a.messageText = "已是最新版本"
                a.informativeText = "当前 v\(cur)，暂无可用更新。"
                PanelHelper.bringFront(a)
                a.runModal()
            }
        case .update(let info):
            // 自动检查时：同一版本每天只自动提示/下载一次，避免重复下载。
            if !manual, !shouldAutoPrompt(version: info.version) { return }
            if !manual { markAutoPrompted(version: info.version) }
            guard !info.assetURL.isEmpty else {
                if let u = URL(string: info.page) { NSWorkspace.shared.open(u) }
                return
            }
            let ver = info.version
            GitHubUpdateService.shared.downloadUpdate(from: info.assetURL,
                                                      fallbacks: info.fallbackURLs,
                                                      suggestedName: info.assetName) { result in
                switch result {
                case .success(let url):
                    // 下载完成 → 直接打开 dmg，用户把 App 拖进「应用程序」即完成更新
                    NSWorkspace.shared.open(url)
                case .failure(let error):
                    if manual {
                        PanelHelper.prepare()
                        let a = NSAlert()
                        a.messageText = "更新下载失败"
                        a.informativeText = "v\(ver) 的安装包没能下载下来：\(error.localizedDescription)\n\n可点「打开下载页面」手动下载。"
                        a.addButton(withTitle: "好")
                        a.addButton(withTitle: "打开下载页面")
                        PanelHelper.bringFront(a)
                        if a.runModal() == .alertSecondButtonReturn {
                            let target = info.assetURL.isEmpty ? info.page : info.assetURL
                            if let u = URL(string: target) { NSWorkspace.shared.open(u) }
                        }
                    }
                }
            }
        case .noSource(let hint):
            // 仓库可达，但既没有 Release 也没有 version.json：
            // 这不是网络故障，给一份「怎么发布更新」的可执行说明，而不是吓人的报错。
            if manual {
                PanelHelper.prepare()
                let a = NSAlert()
                a.messageText = "暂时没有可用的更新信息"
                a.informativeText = """
                \(hint)

                发布一次更新只需要两步（浏览器里即可完成，不用 git，也不用创建 Release）：
                1. 打开仓库 www.github.com/\(GitHubUpdateService.shared.repoIdentifier)
                2. 用「Add file → Upload files」上传两个文件：
                   · version.json（版本号与安装包文件名）
                   · 教师助手_v\(GitHubUpdateService.shared.currentVersion).dmg

                文件模板就在教师助手所在的项目文件夹里，直接拖进去即可。
                """
                a.addButton(withTitle: "打开仓库页面")
                a.addButton(withTitle: "好")
                PanelHelper.bringFront(a)
                if a.runModal() == .alertFirstButtonReturn,
                   let u = URL(string: GitHubUpdateService.shared.repoPageURL) {
                    NSWorkspace.shared.open(u)
                }
            }
        case .error(let msg):
            if manual {
                PanelHelper.prepare()
                let a = NSAlert()
                a.messageText = "检查更新失败"
                a.informativeText = "\(msg)\n\n仓库：www.github.com/\(GitHubUpdateService.shared.repoIdentifier)\n（若网络无法访问 GitHub，可稍后重试）"
                a.addButton(withTitle: "好")
                a.addButton(withTitle: "打开仓库页面")
                PanelHelper.bringFront(a)
                if a.runModal() == .alertSecondButtonReturn,
                   let u = URL(string: GitHubUpdateService.shared.repoPageURL) {
                    NSWorkspace.shared.open(u)
                }
            }
        }
    }

    // MARK: 清空所有数据（保留表结构，便于他人直接双击填写）
    /// 清空全部业务数据：个人/班级课表、年级师资、学生信息、工位、教室分布、座位安排、延时&监考、提醒。
    /// 保留各表的行列结构（标题/节次/列名/办公室数/楼层等），仅删除已填内容；随后重启应用生效。
    func clearAllData() {
        let a = NSAlert()
        a.messageText = "清空所有数据"
        a.informativeText = "将清空：本人课表、班级课表、他人课表、年级师资、学生信息、工位、教室分布、座位安排、延时&监考、提醒设置。\n操作会保留各表的行列结构（便于直接双击填写），但所有已填内容会被删除，且不可撤销。\n确认后应用会自动重启生效。"
        a.alertStyle = .critical
        a.addButton(withTitle: "清空并重启")
        a.addButton(withTitle: "取消")
        PanelHelper.prepare()
        PanelHelper.bringFront(a)
        guard a.runModal() == .alertFirstButtonReturn else { return }

        SeatingStore.shared.clearAll()
        ClassScheduleStore.shared.clearAllData()
        ScheduleStore.shared.clear()
        OfficeLayoutStore.shared.clearSeats()
        ClassroomStore.shared.clearRooms()
        StudentStore.shared.clear()
        StaffStore.shared.clear()
        ExtendScheduleStore.shared.clearAll()
        ReminderStore.shared.clearAll()

        SeatingStore.seatLog("清空所有数据：已完成，即将重启生效")
        BackupService.restartApp()
    }

    // MARK: 自动检查的节流（同一版本每天最多自动提示一次）
    private let autoPromptVersionKey = "update.autoPrompt.version"
    private let autoPromptDayKey     = "update.autoPrompt.day"

    private func todayStamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func shouldAutoPrompt(version: String) -> Bool {
        let d = UserDefaults.standard
        let savedVer = d.string(forKey: autoPromptVersionKey) ?? ""
        let savedDay = d.string(forKey: autoPromptDayKey) ?? ""
        return !(savedVer == version && savedDay == todayStamp())
    }

    private func markAutoPrompted(version: String) {
        let d = UserDefaults.standard
        d.set(version, forKey: autoPromptVersionKey)
        d.set(todayStamp(), forKey: autoPromptDayKey)
    }

    /// 导入课表文件：自动识别「全校定稿」还是「单个班级课表」
    func importClassFile() {
        let panel = makeOpenPanel("导入课表文件（自动识别：单班 / 全校定稿）")
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let grid = try XLSX.read(url)
                // 格式判别：A 列「星期」+ B 列「节次」→ 全校定稿；否则按单班表处理
                let isWholeSchool = grid.prefix(8).contains { row in
                    let cells = row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    let firstNonEmpty = cells.first { !$0.isEmpty }
                    return firstNonEmpty == "星期" &&
                           cells.dropFirst().prefix(3).contains { $0 == "节次" }
                }
                if isWholeSchool {
                    let entries = AppCoordinator.parseWholeSchool(grid)
                    guard !entries.isEmpty else {
                        showAlert("没认出这个格式",
                                  "需要一张「行=节次、列=班级、按星期分块」的全校课表（A 列「星期」、B 列「节次」，表头为班级名）。")
                        return
                    }
                    ClassScheduleStore.shared.replaceAll(entries)
                    showAlert("导入完成",
                              "自动识别为「全校课表定稿」，共导入 \(entries.count) 个班级：\n\(entries.prefix(6).map { $0.name }.joined(separator: "、"))\(entries.count > 6 ? " …" : "")\n\n在标题旁的班级下拉里切换班级，点「设为默认」后下次打开直接显示。")
                } else {
                    ClassScheduleStore.shared.ensureClass()
                    importClass(grid)
                    showAlert("导入完成",
                              "自动识别为「单个班级课表」，已导入当前班级「\(ClassScheduleStore.shared.current)」。")
                }
            } catch {
                showAlert("导入失败", error.localizedDescription)
            }
        }
    }

    // MARK: 全校课表定稿（一张表横排全部班级：行=节次，列=班级，按星期分块）
    func importWholeSchoolFile() {
        let panel = makeOpenPanel("导入全校课表定稿（一次导入全部班级）")
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let grid = try XLSX.read(url)
                let entries = AppCoordinator.parseWholeSchool(grid)
                guard !entries.isEmpty else {
                    showAlert("没认出这个格式",
                              "需要一张「行=节次、列=班级、按星期分块」的全校课表（表头含「星期」「节次」和班级名）。\n也可以先用「单个班级课表」导入单个班的表。")
                    return
                }
                ClassScheduleStore.shared.replaceAll(entries)
                showAlert("导入完成", "共导入 \(entries.count) 个班级：\(entries.prefix(3).map { $0.name }.joined(separator: "、"))…\n可在标题旁的班级下拉里切换，或把常用班级设为默认。")
            } catch {
                showAlert("导入失败", error.localizedDescription)
            }
        }
    }

    /// 解析「全校课表定稿」：表头行找班级列，A 列星期（向下沿用），B 列节次
    static func parseWholeSchool(_ grid: [[String]]) -> [(name: String, data: ClassData)] {
        // 1) 表头行：同时含「星期」与「节次」
        guard let hRow = grid.firstIndex(where: { row in
            row.contains { $0.contains("星期") } &&
            row.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "节次" }
        }) else { return [] }

        let header = grid[hRow]
        var classCols: [(col: Int, name: String)] = []
        for c in 0..<header.count {
            let raw = header[c].trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty { continue }
            if raw.contains("星期") || raw == "节次" || raw == "序号" { continue }
            if Int(raw) != nil { continue }                    // 末尾的纯数字序号列
            classCols.append((c, normalizeClassName(raw)))
        }
        guard !classCols.isEmpty else { return [] }

        // 2) 逐行扫描：星期分块 → 节次 → 各班内容
        var perClass: [String: [String: [String]]] = [:]
        var periodOrder: [String] = []
        var currentDay: Int? = nil

        for r in (hRow + 1)..<grid.count {
            let row = grid[r]
            func val(_ i: Int) -> String {
                i < row.count ? row[i].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            }
            // 重复表头行跳过
            if val(0).contains("星期") && val(1) == "节次" { continue }

            let dayRaw = val(0)
            if !dayRaw.isEmpty {
                let compactDay = ClassLayout.compact(dayRaw)
                let looksLikeDay = compactDay.contains("星期") || compactDay.contains("周") || compactDay.contains("礼拜")
                if looksLikeDay {
                    // 认得出的星期 → 切块（周六 = 5、周日/周天 = 6 都能认；认不出的标签 → nil，跳过该块）
                    currentDay = ClassLayout.dayIndex(from: dayRaw)
                }
                // 不是星期标签（例如合并单元格残留的字）→ 沿用上一个星期块
            }
            let periodRaw = val(1)
            guard let day = currentDay, !periodRaw.isEmpty else { continue }
            if dayRaw.isEmpty && periodRaw.isEmpty { continue }

            let label = ClassLayout.periodLabel(from: periodRaw)
            if !periodOrder.contains(label) { periodOrder.append(label) }

            for (col, name) in classCols {
                let text = cleanCellText(val(col))
                var cls = perClass[name] ?? [:]
                var dayVals = cls[label] ?? Array(repeating: "", count: ClassLayout.days.count)
                dayVals[day] = text
                cls[label] = dayVals
                perClass[name] = cls
            }
        }
        guard !periodOrder.isEmpty, !perClass.isEmpty else { return [] }

        // 3) 分组：上午（前 4 节）/ 下午（其余白天）/ 晚自习（晚X）
        let groups = makeGroups(from: periodOrder)

        // 4) 组装每班数据（补齐所有节次 × 7 天：周一~周五 + 周六 + 周日）
        var out: [(name: String, data: ClassData)] = []
        for (_, name) in classCols {
            var cells: [String: [String]] = [:]
            for p in groups.flatMap({ $0.periods }) {
                var arr = perClass[name]?[p] ?? Array(repeating: "", count: ClassLayout.days.count)
                if arr.count < ClassLayout.days.count {
                    arr.append(contentsOf: Array(repeating: "", count: ClassLayout.days.count - arr.count))
                }
                if arr.count > ClassLayout.days.count { arr = Array(arr.prefix(ClassLayout.days.count)) }
                cells[p] = arr
            }
            let hasContent = cells.values.contains { $0.contains { !$0.isEmpty } }
            if hasContent { out.append((name, ClassData(groups: groups, cells: cells))) }
        }
        return out
    }

    /// 依据文件里出现的节次顺序生成分组（上午前 5 节 / 下午第 6-9 节 / 其余白天与「晚X」归晚自习）
    static func makeGroups(from periodOrder: [String]) -> [ClassGroup] {
        let dayLabels = periodOrder.filter { !$0.hasPrefix("晚") }
        let eveLabels = periodOrder.filter { $0.hasPrefix("晚") }
        var groups: [ClassGroup] = []

        if !dayLabels.isEmpty {
            let am = min(ClassLayout.morningCount, dayLabels.count)
            groups.append(ClassGroup(title: "上午", periods: Array(dayLabels[0..<am])))
            let pmEnd = min(ClassLayout.dayPeriodCount, dayLabels.count)
            if dayLabels.count > am {
                groups.append(ClassGroup(title: "下午", periods: Array(dayLabels[am..<pmEnd])))
            }
            if dayLabels.count > pmEnd {
                groups.append(ClassGroup(title: "晚自习", periods: Array(dayLabels[pmEnd...])))
            }
        }
        if !eveLabels.isEmpty {
            if let i = groups.firstIndex(where: { $0.title == "晚自习" }) {
                groups[i].periods.append(contentsOf: eveLabels)
            } else {
                groups.append(ClassGroup(title: "晚自习", periods: eveLabels))
            }
        }
        return groups.isEmpty ? ClassLayout.defaultGroups : groups
    }

    /// 班级名规范化：「初-20」→「初1-20」
    static func normalizeClassName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("初-") { s = "初1" + s.dropFirst(1) }
        return s
    }

    /// 单元格文本清理：换行 → 「·」，去掉制表符等
    static func cleanCellText(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&#10;", with: "·")
           .replacingOccurrences(of: "&#13;", with: "·")
           .replacingOccurrences(of: "&#9;", with: "")
           .replacingOccurrences(of: "&nbsp;", with: " ")
           .replacingOccurrences(of: "\r\n", with: "·")
           .replacingOccurrences(of: "\n", with: "·")
           .replacingOccurrences(of: "\r", with: "·")
           .replacingOccurrences(of: "\t", with: "")
           .trimmingCharacters(in: .whitespaces)
    }

    // MARK: 他人课表：导入 / 下载
    func importTeacherSchedules() {
        let panel = makeOpenPanel("导入他人课表")
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let grid = try XLSX.read(url)
                let blocks = AppCoordinator.parseTeacherSchedules(grid)
                guard !blocks.isEmpty else {
                    showAlert("没认出他人课表",
                              "文件格式（长表）：第一行表头写「姓名 | 节次 | 周一 … 周天」，"
                              + "下面每位教师连续若干行、一行一节课，单元格写「班级 科目」（如 初一-18 数学）。\n"
                              + "可先点「导入 → 下载填写模板」照着填。")
                    return
                }
                let store = TeacherScheduleStore.shared
                let snap = store.teachers
                store.replaceAll(blocks)
                UndoService.shared.register("导入他人课表") { store.replaceAll(snap) }
                let lessons = blocks.reduce(0) { $0 + $1.lessonCount }
                showAlert("导入完成", "共 \(blocks.count) 位教师、\(lessons) 节课。")
            } catch {
                showAlert("导入失败", error.localizedDescription)
            }
        }
    }

    /// 解析教师课表长表：
    ///   表头行（含「姓名」）给出「节次列」与「周一…周天」各列的位置；
    ///   同一姓名的多行合并成一位教师（节次按出现顺序）。
    /// 容错：没有表头时按默认列序（姓名 / 节次 / 周一…周天）解析；天列名支持「周一/星期一/一」。
    static func parseTeacherSchedules(_ grid: [[String]]) -> [TeacherBlock] {
        guard !grid.isEmpty else { return [] }

        func clean(_ row: [String]) -> [String] {
            row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        /// 「周一 / 星期一 / 周1 / 一」→ 0…6；周日 / 周天 / 星期日 → 6
        /// ⚠️ 用有序数组按顺序匹配，不用字典 —— 字典遍历顺序不确定，
        ///    一旦某串同时含两个字键（如「周六日」）结果就会飘。
        func dayIndex(_ s: String) -> Int? {
            let t = s.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            let named: [(String, Int)] = [("一", 0), ("二", 1), ("三", 2), ("四", 3),
                                          ("五", 4), ("六", 5), ("日", 6), ("天", 6)]
            if let hit = named.first(where: { t.contains($0.0) }) { return hit.1 }
            if t == "7" { return 6 }          // 「周7」这种写法
            return nil
        }

        // ① 找表头行：第一格是「姓名 / 老师 / 教师」，或整行含 2 个以上「周x」
        var headerRow = -1
        var dayCols: [Int: Int] = [:]      // 列下标 → 天下标
        var nameCol = 0
        var periodCol = 1

        for (r, raw) in grid.prefix(8).enumerated() {
            let row = clean(raw)
            let dayHits = row.enumerated().compactMap { (c, v) -> (Int, Int)? in
                if let d = dayIndex(v), v.contains("周") || v.contains("星期") || v.contains("礼拜") {
                    return (c, d)
                }
                return nil
            }
            let hasName = row.first.map { $0.contains("姓名") || $0.contains("老师") || $0.contains("教师") } ?? false
            let hasPeriodCol = row.contains { $0.contains("节次") || $0.contains("第几节") }
            // ⚠️ 只凭「含『老师』」不够：数据行里的「王老师」也含「老师」，
            //    那样会把第一行数据当表头吃掉。必须同时具备「节次列」或 ≥2 个天列才算表头。
            if (hasName && (hasPeriodCol || dayHits.count >= 2)) || dayHits.count >= 2 {
                headerRow = r
                for (c, d) in dayHits where dayCols[d] == nil { dayCols[d] = c }
                if let nc = row.firstIndex(where: { $0.contains("姓名") || $0.contains("老师") || $0.contains("教师") }) {
                    nameCol = nc
                }
                if let pc = row.firstIndex(where: { $0.contains("节次") || $0.contains("第几节") }) {
                    periodCol = pc
                }
                break
            }
        }

        let start = headerRow >= 0 ? headerRow + 1 : 0
        if dayCols.isEmpty {
            // 没有可识别的表头 → 按默认列序：姓名 / 节次 / 周一…周天
            nameCol = 0
            periodCol = 1
            for d in 0..<TeacherBlock.days.count { dayCols[d] = 2 + d }
        }
        let orderedDayCols = (0..<TeacherBlock.days.count).map { dayCols[$0] ?? (2 + $0) }

        // ② 逐行聚合（同姓名可分散出现，按首次出现顺序）
        var order: [String] = []
        var periodsOf: [String: [String]] = [:]
        var rowsOf: [String: [[String]]] = [:]

        for raw in grid.dropFirst(start) {
            let row = clean(raw)
            func cell(_ i: Int) -> String { i < row.count ? row[i] : "" }

            let name = cell(nameCol)
            guard !name.isEmpty, name != "姓名" else { continue }
            let period = cell(periodCol)
            guard !period.isEmpty else { continue }

            let dayCells = orderedDayCols.map { cell($0) }
            if order.last != name, !order.contains(name) { order.append(name) }
            if rowsOf[name] == nil { rowsOf[name] = []; periodsOf[name] = [] }
            // 同一节次重复出现 → 覆盖（后写的为准），避免多出一行
            if let at = periodsOf[name]?.firstIndex(of: period) {
                rowsOf[name]?[at] = dayCells
            } else {
                periodsOf[name]?.append(period)
                rowsOf[name]?.append(dayCells)
            }
        }

        // ③ 没有节次列、只有一行一天的（一行一位教师）也支持：把天当行
        if order.isEmpty {
            for raw in grid {
                let row = clean(raw)
                guard let name = row.first, !name.isEmpty, name != "姓名" else { continue }
                let dayCells = orderedDayCols.map { $0 < row.count ? row[$0] : "" }
                guard dayCells.contains(where: { !$0.isEmpty }) else { continue }
                order.append(name)
                periodsOf[name] = [name]
                rowsOf[name] = [dayCells]
            }
        }

        return order.compactMap { name in
            guard let periods = periodsOf[name], let cells = rowsOf[name] else { return nil }
            return TeacherBlock(teacher: name, periods: periods, cells: cells)
        }
    }

    func exportTeacher() {
        let panel = makeSavePanel("下载他人课表", defaultName: "他人课表.xlsx")
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try XLSX.write(exportTeacherRows(), to: url)
            } catch {
                showAlert("下载失败", error.localizedDescription)
            }
        }
    }

    private func exportTeacherRows() -> [[String]] {
        var rows: [[String]] = [["姓名", "节次"] + TeacherBlock.days]
        for b in TeacherScheduleStore.shared.teachers {
            for (i, p) in b.periods.enumerated() {
                rows.append([b.teacher, p] + (i < b.cells.count ? b.cells[i] : Array(repeating: "", count: TeacherBlock.days.count)))
            }
        }
        return rows
    }

    // MARK: 教师工位：导入 / 下载
    func importOffice() {
        let panel = makeOpenPanel("导入办公室工位布局")
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let grid = try XLSX.read(url)
                let offices = AppCoordinator.parseOffices(grid)
                guard !offices.isEmpty else {
                    showAlert("没认出工位数据",
                              "文件格式：每间办公室一段 —— 第一列写「办公室」、第二列写名称，下面每行是一排座位（每行最多 \(OfficeLayoutStore.seatColumns) 个姓名）。")
                    return
                }
                let store = OfficeLayoutStore.shared
                let snap = store.offices
                store.offices = offices
                UndoService.shared.register("导入工位布局") { store.offices = snap }
                showAlert("导入完成", "共导入 \(offices.count) 间办公室。")
            } catch {
                showAlert("导入失败", error.localizedDescription)
            }
        }
    }

    // MARK: 教室分布：导入 / 下载（教室与办公室同为平铺格子，可拖对换）
    func importClassroom() {
        let panel = makeOpenPanel("导入教室分布")
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let grid = try XLSX.read(url)
                let floors = AppCoordinator.parseClassrooms(AppCoordinator.dropTitleRows(grid))
                guard !floors.isEmpty else {
                    showAlert("没认出教室数据",
                              "文件格式：每层一段 —— 第一列写「楼层」、第二列写层名；下面每行一个格子：\n"
                              + "· 教室：`教室, 19班, X401`\n"
                              + "· 办公室：`办公室, 办公室, X406`\n"
                              + "· 第 4 列可选颜色（如 2ECC71）\n"
                              + "· 写一行「附加行」可开始本层的下一排")
                    return
                }
                ClassroomStore.shared.replaceAll(floors)
                let total = floors.reduce(0) { $0 + $1.cellCount }
                showAlert("导入完成", "共导入 \(floors.count) 个楼层、\(total) 个格子（教室/办公室）。")
            } catch {
                showAlert("导入失败", error.localizedDescription)
            }
        }
    }

    /// 解析教室分布：
    ///   `楼层, X栋4楼` 开一段；`附加行` 开本层下一排；
    ///   `教室, 19班, X401[, 颜色]` 教室格；`办公室, 办公室, X406[, 颜色]` 办公室格。
    /// 容错：第一列不是关键字但有两列以上时，按教室格处理（用户删了类型列也能导入）。
    static func parseClassrooms(_ grid: [[String]]) -> [ClassroomFloor] {
        var floors: [ClassroomFloor] = []
        var current: ClassroomFloor? = nil
        var pendingRow: [ClassroomCell] = []
        var inExtraRow = false

        func flushExtraRow() {
            if inExtraRow, !pendingRow.isEmpty {
                current?.extraRows.append(ClassroomRow(cells: pendingRow))
            }
            pendingRow = []
        }
        func flushFloor() {
            flushExtraRow()
            if let f = current, !f.cells.isEmpty || !f.extraRows.isEmpty { floors.append(f) }
            current = nil
            inExtraRow = false
        }

        for row in grid {
            let cells = row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let first = cells.first ?? ""
            if first.isEmpty { flushExtraRow(); continue }      // 空行只做分隔

            if first == "楼层" || first == "层" {
                flushFloor()
                let title = cells.count > 1 && !cells[1].isEmpty ? cells[1] : "新楼层"
                current = ClassroomFloor(title: title, cells: [], extraRows: [])
                continue
            }
            if first == "附加行" || first == "新行" {
                flushExtraRow()
                inExtraRow = true
                continue
            }
            guard current != nil else { continue }

            let isOffice = (first == "办公室" || first == "教师办公室")
            var klass: String
            let room: String
            var color: String? = nil
            if first == "教室" || isOffice {
                klass = cells.count > 1 ? cells[1] : ""
                room = cells.count > 2 ? cells[2] : ""
                if cells.count > 3 { color = normalizeHex(cells[3]) }
            } else {
                // 容错：当成「名称, 房号[, 颜色]」
                klass = first
                room = cells.count > 1 ? cells[1] : ""
                if cells.count > 2 { color = normalizeHex(cells[2]) }
            }
            if isOffice && klass.isEmpty { klass = "办公室" }
            let cell = ClassroomCell(kind: isOffice ? .office : .room,
                                     klass: klass, room: room, color: color)
            if inExtraRow { pendingRow.append(cell) } else { current?.cells.append(cell) }
        }
        flushFloor()
        return floors
    }

    /// 颜色：统一成不含 # 的大写 hex；认不出返回 nil
    static func normalizeHex(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .uppercased()
        guard s.count == 6, s.allSatisfy({ $0.isHexDigit }) else { return nil }
        return s
    }

    func exportClassroom() {
        let panel = makeSavePanel("下载教室分布", defaultName: "教室分布.xlsx")
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try XLSX.write(exportClassroomRows(), to: url)
            } catch {
                showAlert("导出失败", error.localizedDescription)
            }
        }
    }

    private func exportClassroomRows() -> [[String]] {
        var rows: [[String]] = []
        for f in ClassroomStore.shared.floors {
            rows.append(["楼层", f.title])
            for c in f.cells { rows.append(classroomCellRow(c)) }
            for r in f.extraRows {
                rows.append(["附加行"])
                for c in r.cells { rows.append(classroomCellRow(c)) }
            }
            rows.append([""])
        }
        return rows
    }

    private func classroomCellRow(_ c: ClassroomCell) -> [String] {
        let kind = c.kind == .office ? "办公室" : "教室"
        let name = c.klass.isEmpty && c.kind == .office ? "办公室" : c.klass
        var row = [kind, name, c.room]
        if let hex = c.color, !hex.isEmpty { row.append(hex) }
        return row
    }

    /// 解析工位：以「办公室」开头的行分段，随后每行 = 一排座位；「颜色」段可读回自定义色
    /// 「楼层」行（`楼层, 三楼`）写在「办公室」行的**上一行**，给紧随其后的办公室定楼层；
    /// 旧模板没有楼层行 → 全部落在「未分组」。
    static func parseOffices(_ grid: [[String]]) -> [OfficeBlock] {
        var out: [OfficeBlock] = []
        var current: OfficeBlock? = nil
        var inColorSection = false
        var pendingFloor = ""
        let cols = OfficeLayoutStore.seatColumns

        func flush() {
            if var c = current {
                if c.seats.isEmpty { c.seats = Array(repeating: Array(repeating: "", count: cols), count: 4) }
                out.append(c)
            }
            current = nil
        }

        for row in grid {
            let cells = row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let first = cells.first else { continue }
            if first == "楼层" || first == "层" {
                pendingFloor = cells.count > 1 ? cells[1] : ""
                continue
            }
            if first == "办公室" {
                flush()
                inColorSection = false
                let title = cells.count > 1 ? cells[1] : "办公室\(out.count + 1)"
                current = OfficeBlock(title: title, seats: [], floor: pendingFloor)
                pendingFloor = ""
                // 同一行后面若还有姓名，视为第一排
                let extra = Array(cells.dropFirst(2)).filter { !$0.isEmpty }
                if !extra.isEmpty { current?.seats.append(padded(extra, cols)) }
                continue
            }
            if first == "颜色" { flush(); inColorSection = true; continue }
            if inColorSection {
                // [办公室名, "行-列", hex]
                guard cells.count >= 3 else { continue }
                if let i = out.firstIndex(where: { $0.title == cells[0] }) {
                    let rc = cells[1].split(separator: "-").map(String.init)
                    if rc.count == 2, let r = Int(rc[0]), let c = Int(rc[1]) {
                        out[i].setSeatColor(cells[2], row: r, col: c)
                    }
                }
                continue
            }
            if current == nil { current = OfficeBlock(title: "办公室\(out.count + 1)", seats: []) }
            let rowVals = Array(cells.filter { !$0.isEmpty })   // 允许首列为排号时忽略空值
            current?.seats.append(padded(rowVals, cols))
        }
        flush()
        return out

        func padded(_ arr: [String], _ n: Int) -> [String] {
            // 导入不再截断超过默认 4 列的办公室；短行仍补齐到默认宽度。
            var a = Array(arr.prefix(max(n, arr.count)))
            while a.count < n { a.append("") }
            return a
        }
    }

    func exportOffice() {
        let panel = makeSavePanel("下载办公室工位布局", defaultName: "办公室工位布局.xlsx")
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try XLSX.write(exportOfficeRows(), to: url)
            } catch {
                showAlert("导出失败", error.localizedDescription)
            }
        }
    }

    private func exportOfficeRows() -> [[String]] {
        var rows: [[String]] = []
        for o in OfficeLayoutStore.shared.offices {
            // 「楼层」写在同一间办公室的上一行；未分组则不写（旧模板/旧版本照样能读）
            if !o.floor.isEmpty { rows.append(["楼层", o.floor]) }
            rows.append(["办公室", o.title])
            for r in o.seats { rows.append(r) }
            rows.append([""])
        }
        var colorRows: [[String]] = []
        for o in OfficeLayoutStore.shared.offices {
            for (key, hex) in o.seatColors.sorted(by: { $0.key < $1.key }) {
                colorRows.append([o.title, key, hex])
            }
        }
        if !colorRows.isEmpty {
            rows.append(["颜色"])
            rows.append(contentsOf: colorRows)
        }
        return rows
    }

    // MARK: 班级学生座位安排：导入 / 下载
    func importSeating() {
        let panel = makeOpenPanel("导入班级学生座位安排")
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let grid = try XLSX.read(url)
                let parsed = AppCoordinator.parseSeating(grid)
                guard !parsed.groups.isEmpty || !parsed.pool.isEmpty else {
                    showAlert("没认出座位数据",
                              "文件格式：以「小组」开头的行分段，下面每行是一排学生姓名；可选「待用栏」「性别」两段。\n也可以直接粘贴一张纯姓名网格（每排一行）。")
                    return
                }
                SeatingStore.shared.replaceAll(groups: parsed.groups, pool: parsed.pool, genders: parsed.genders)
                showAlert("导入完成",
                          "共导入 \(parsed.groups.count) 个座位块、待用栏 \(parsed.pool.count) 人（已按行铺进一张大表）。")
            } catch {
                showAlert("导入失败", error.localizedDescription)
            }
        }
    }

    /// 解析座位表：「小组」分段 +「待用栏」+「性别」；无关键字时整张表当一个小组
    static func parseSeating(_ grid: [[String]])
        -> (groups: [SeatGroup], pool: [String], genders: [String: String]) {
        var groups: [SeatGroup] = []
        var pool: [String] = []
        var genders: [String: String] = [:]
        var current: SeatGroup? = nil
        var mode = "seat"          // seat / pool / gender
        var plainRows: [[String]] = []   // 无关键字时的纯网格

        func flush() {
            if let c = current, !c.seats.isEmpty { groups.append(c) }
            current = nil
        }

        var isFirstRow = true
        for row in grid {
            defer { isFirstRow = false }
            var cells = row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            // 文件首行的标题（整行只有 1 个非空格，如「班级座位表」）→ 跳过
            if isFirstRow, cells.filter({ !$0.isEmpty }).count == 1 { continue }
            // 兼容「导出文件」格式：跳过「空 + 列号（数字 1/2/3 或旧版字母 A/B/C）」的列头行、剥掉行首行号
            if isSeatingColumnHeader(cells) { continue }
            if cells.count > 1, let f = cells.first, isRowNumber(f) {
                cells.removeFirst()
            }
            guard let first = cells.first, !first.isEmpty || cells.count > 1 else { continue }

            if first == "小组" {
                flush()
                mode = "seat"
                let title = cells.count > 1 && !cells[1].isEmpty ? cells[1] : "第\(groups.count + 1)小组"
                current = SeatGroup(title: title, seats: [])
                continue
            }
            if first == "待用栏" {
                flush()
                mode = "pool"
                pool.append(contentsOf: cells.dropFirst().filter { !$0.isEmpty })
                continue
            }
            if first == "性别" {
                flush()
                mode = "gender"
                if cells.count >= 3 { genders[cells[1]] = cells[2] }
                continue
            }

            switch mode {
            case "pool":
                pool.append(contentsOf: cells.filter { !$0.isEmpty })
            case "gender":
                if cells.count >= 2 {
                    let g = cells[1]
                    if g == "男" || g == "女" { genders[cells[0]] = g }
                }
            default:
                let vals = cells.filter { !$0.isEmpty && $0 != "讲台" }
                if vals.isEmpty {
                    // 讲台行：只跳过，不切分分组（否则整张表会被切成几块、铺进大表时串位）
                    if cells.contains("讲台") { continue }
                    flush(); continue
                }
                if current == nil {
                    current = SeatGroup(title: "第\(groups.count + 1)小组", seats: [])
                }
                current?.seats.append(vals)
                plainRows.append(cells)
            }
        }
        flush()

        if groups.isEmpty, !plainRows.isEmpty {
            // 纯姓名网格 → 一个小组
            let maxCols = plainRows.map(\.count).max() ?? 0
            let padded = plainRows.map { r -> [String] in
                var a = r
                while a.count < maxCols { a.append("") }
                return a
            }
            groups = [SeatGroup(title: "第1小组", seats: padded)]
        }

        // 组内各行补齐到统一列数
        var normalized: [SeatGroup] = []
        for g in groups {
            let maxCols = g.seats.map(\.count).max() ?? 0
            guard maxCols > 0 else { continue }
            normalized.append(SeatGroup(title: g.title,
                                        seats: g.seats.map { r in
                                            var a = r
                                            while a.count < maxCols { a.append("") }
                                            return a
                                        }))
        }
        return (normalized, pool, genders)
    }

    /// 导出的座位表列头行：「首格为空 + 其余都是 1~3 个大写字母（A/B/C…）」
    /// 列头行（首格空 + 其余全是列号）。列号有两种写法，都要认：
    /// 新版 = 纯数字「1 / 2 / 3…」，旧版 = Excel 式字母「A / B / AA」。
    /// 不认出来就会把整行列号当成学生姓名吃进座位表。
    private static func isSeatingColumnHeader(_ cells: [String]) -> Bool {
        guard cells.count > 1, cells[0].isEmpty else { return false }
        let rest = Array(cells.dropFirst())
        guard rest.contains(where: { !$0.isEmpty }) else { return false }
        return rest.allSatisfy { cell in
            if cell.isEmpty { return true }
            guard cell.count <= 3 else { return false }
            if cell.allSatisfy({ $0.isNumber }) { return true }               // 新版列号：1 / 2 / 3…
            return cell.allSatisfy({ $0.isLetter && $0.isUppercase })          // 旧版列号：A / B / AA
        }
    }

    /// 行号列（纯数字）：用于剥掉导出文件每行开头的 1 / 2 / 3…
    private static func isRowNumber(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isNumber }
    }

    func exportSeating() {
        let store = SeatingStore.shared
        guard store.seatedCount > 0 || !store.pool.isEmpty else {
            showAlert("没有可导出的座位数据", "先安排座位或导入学生名单。")
            return
        }
        let panel = makeSavePanel("下载班级学生座位安排", defaultName: "班级学生座位安排.xlsx")
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try XLSX.write(exportSeatingRows(), to: url)
            } catch {
                showAlert("导出失败", error.localizedDescription)
            }
        }
    }

    private func exportSeatingRows() -> [[String]] {
        let store = SeatingStore.shared
        var rows: [[String]] = []
        // 整张表原样导出：第一行是列号 1/2/3…（首格留空），之后每行 = 行号 + 各列姓名。
        // 讲台只在其起始格写「讲台」，被它覆盖的其余格子留空。
        rows.append([""] + (0..<store.cols).map { SeatingStore.columnLabel($0) })
        for r in 0..<store.rows {
            var line: [String] = ["\(r + 1)"]
            for c in 0..<store.cols {
                let k = SeatingStore.key(r, c)
                if store.isPodium(k) {
                    line.append(c == store.podium?.col ? "讲台" : "")
                } else {
                    line.append(store.name(at: k) ?? "")
                }
            }
            rows.append(line)
        }
        if !store.pool.isEmpty {
            rows.append(["待用栏"] + store.pool)
        }
        if !store.genders.isEmpty {
            rows.append(["性别"])
            for (k, v) in store.genders.sorted(by: { $0.key < $1.key }) {
                rows.append([k, v])
            }
        }
        return rows
    }

    func importStaffFile() {
        importFile("导入年级师资安排", grid: importStaff)
    }

    // MARK: 延时&监考：导入 / 下载（分段式：每段一行「子表, 名称」+ 表头行 + 数据行）
    func importExtendFile() {
        let panel = makeOpenPanel("导入延时&监考")
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let grid = try XLSX.read(url)
                let blocks = AppCoordinator.parseExtendBlocks(grid)
                guard !blocks.isEmpty else {
                    showAlert("没认出延时/监考数据",
                              "文件格式：每个子表一段 —— 第一列写「子表」、第二列写名称（名称含「监考」归为监考块），下一行是表头，再往下是数据行。可先下载模板查看格式。")
                    return
                }
                let store = ExtendScheduleStore.shared
                let snap = store.blocks
                store.blocks = blocks
                store.save()
                UndoService.shared.register("导入延时&监考") {
                    store.blocks = snap
                    store.save()
                }
                let delayCount = blocks.filter { $0.kind == "delay" }.count
                let examCount = blocks.filter { $0.kind == "exam" }.count
                showAlert("导入完成", "共导入 \(blocks.count) 个子表（延时 \(delayCount) 个、监考 \(examCount) 个）。")
            } catch {
                showAlert("导入失败", error.localizedDescription)
            }
        }
    }

    /// 解析延时&监考：以「子表」开头的行分段，名称含「监考」→ exam，否则 delay；
    /// 段内第一行 = 表头，其余 = 数据行（自动补齐列宽、跳过空行）
    static func parseExtendBlocks(_ grid: [[String]]) -> [ExtendBlock] {
        var out: [ExtendBlock] = []
        var current: ExtendBlock? = nil

        func flush() {
            if var b = current {
                b.rows = b.rows.filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
                if !b.header.isEmpty { out.append(b) }
            }
            current = nil
        }

        for row in grid {
            let cells = row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let first = cells.first else { continue }
            if first == "子表" {
                flush()
                let title = cells.count > 1 && !cells[1].isEmpty ? cells[1] : "子表\(out.count + 1)"
                current = ExtendBlock(title: title,
                                      kind: title.contains("监考") ? "exam" : "delay",
                                      header: [], rows: [])
                continue
            }
            if cells.allSatisfy({ $0.isEmpty }) { continue }   // 空行仅作分隔，靠「子表」分段
            guard var b = current else { continue }
            if b.header.isEmpty {
                b.header = cells.filter { !$0.isEmpty }.isEmpty ? ["第几周", "班级"] : cells
            } else {
                var r = cells
                if r.count > b.header.count { r = Array(r.prefix(b.header.count)) }
                while r.count < b.header.count { r.append("") }
                b.rows.append(r)
            }
            current = b
        }
        flush()
        return out
    }

    func exportExtend() {
        let store = ExtendScheduleStore.shared
        guard !store.blocks.isEmpty else {
            showAlert("没有可下载的数据", "当前没有延时/监考子表，可先添加或导入数据。")
            return
        }
        let panel = makeSavePanel("下载延时&监考", defaultName: "延时监考.xlsx")
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try XLSX.write(exportExtendRows(), to: url)
            } catch {
                showAlert("下载失败", error.localizedDescription)
            }
        }
    }

    private func exportExtendRows() -> [[String]] {
        var rows: [[String]] = []
        for b in ExtendScheduleStore.shared.blocks {
            rows.append(["子表", b.title])
            rows.append(b.header)
            for r in b.rows { rows.append(r) }
            rows.append([""])
        }
        return rows
    }

    func importStudentFile() {
        importFile("导入学生信息", grid: importStudent)
    }

    /// 跳过模板顶部的「标题行」：整行只有 ≤1 个非空格（如「学生信息」「班级课表」）。
    /// 真实数据首行总是多列的表头，不会被误删。
    static func dropTitleRows(_ rows: [[String]]) -> [[String]] {
        var out = rows
        while out.count > 1 {
            let nonEmpty = out[0].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if nonEmpty.count <= 1 { out.removeFirst() } else { break }
        }
        return out
    }

    // 学生信息：首行=表头，其余行=学生数据（自动补齐列宽、跳过空行）
    private func importStudent(_ grid: [[String]]) {
        var rows = grid.filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
        rows = AppCoordinator.dropTitleRows(rows)
        guard let header = rows.first else { return }
        rows.removeFirst()

        let store = StudentStore.shared
        var headers = header.map { $0.trimmingCharacters(in: .whitespaces) }
        if headers.isEmpty { headers = StudentDefaultData.headers }
        let width = headers.count
        store.headers = headers
        store.rows = rows.map { line in
            var cells = Array(repeating: "", count: width)
            for i in 0..<min(width, line.count) { cells[i] = line[i].trimmingCharacters(in: .whitespaces) }
            return StudentRow(cells: cells)
        }
        store.save()
    }

    func exportStudent() {
        let panel = makeSavePanel("下载学生信息", defaultName: "学生信息.xlsx")
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try XLSX.write(exportStudentRows(), to: url)
            } catch {
                showAlert("导出失败", error.localizedDescription)
            }
        }
    }

    private func exportStudentRows() -> [[String]] {
        let store = StudentStore.shared
        var rows: [[String]] = [store.headers]
        for r in store.rows { rows.append(r.cells) }
        return rows
    }

    private func importFile(_ title: String, grid: ([[String]]) -> Void) {
        let panel = makeOpenPanel(title)
        if panel.runModal() == .OK, let url = panel.url {
            do {
                grid(try XLSX.read(url))
            } catch {
                showAlert("导入失败", error.localizedDescription)
            }
        }
    }

    private func importPersonal(_ grid: [[String]]) {
        let store = ScheduleStore.shared
        var newGrid = ScheduleStore.emptyGrid(periods: store.periods)
        let rows = AppCoordinator.dropTitleRows(grid)
        // 星期列定位：**先认表头**（「周一 / 星期一 / 周天」都认），认不出再按位置兜底。
        // ⚠️ 不能只按位置取：旧模板（节次 + 6 天）的第 6 个数据列是**周日**，
        //    按位置取会把周日的内容灌进新的周六列。
        let dayCols = rows.first.map { ScheduleWeek.headerColumnMap($0) } ?? [:]
        for row in rows.dropFirst() {
            guard row.count > 0 else { continue }
            let label = row[0].trimmingCharacters(in: .whitespaces)
            guard let pIdx = store.periods.firstIndex(of: label) else { continue }
            for d in 0..<ScheduleStore.days.count {
                guard let col = dayCols[d] ?? ScheduleWeek.fallbackColumn(dayIndex: d, rowWidth: row.count),
                      col > 0, col < row.count else { continue }
                newGrid[pIdx][d] = row[col]
            }
        }
        store.grid = newGrid
        store.save()
    }

    private func importClass(_ grid: [[String]]) {
        let store = ClassScheduleStore.shared
        var newCells: [String: [String]] = [:]
        let ordered = store.orderedPeriods
        for p in ordered {
            newCells[p] = Array(repeating: "", count: ClassLayout.days.count)
        }
        let rows = AppCoordinator.dropTitleRows(grid)
        // 星期列定位：先认表头、再按位置兜底（旧模板第 6 个数据列是周日，不能傻按位置取）
        let dayCols = rows.first.map { ScheduleWeek.headerColumnMap($0) } ?? [:]
        for row in rows.dropFirst() {
            guard row.count > 0 else { continue }
            let raw = row[0].trimmingCharacters(in: .whitespaces)
            // 文件里的节次标签（1 / 五 / 第5节 / 晚1 …）→ 全表连续序号 → 对应节次
            guard let ord = ClassLayout.periodOrdinal(raw), ord >= 1, ord <= ordered.count else { continue }
            let label = ordered[ord - 1]
            var dayVals = Array(repeating: "", count: ClassLayout.days.count)
            for d in 0..<ClassLayout.days.count {
                guard let col = dayCols[d] ?? ScheduleWeek.fallbackColumn(dayIndex: d, rowWidth: row.count),
                      col > 0, col < row.count else { continue }
                // 清理特殊字符：换行/回车→"·"，便于单行显示
                let cleaned = row[col]
                    // HTML 实体（xlsx 中常以 &#10; 表示换行）
                    .replacingOccurrences(of: "&#10;", with: "·")
                    .replacingOccurrences(of: "&#13;", with: "·")
                    .replacingOccurrences(of: "&#9;", with: "")
                    .replacingOccurrences(of: "&nbsp;", with: " ")
                    // 真实换行
                    .replacingOccurrences(of: "\r\n", with: "·")
                    .replacingOccurrences(of: "\n", with: "·")
                    .replacingOccurrences(of: "\r", with: "·")
                    .replacingOccurrences(of: "\t", with: "")
                    .trimmingCharacters(in: .whitespaces)
                dayVals[d] = cleaned
            }
            newCells[label] = dayVals
        }
        store.cells = newCells
        store.save()
    }

    // 师资：首行=表头（第 1 列「班级」固定），其余行=班级数据
    private func importStaff(_ grid: [[String]]) {
        var rows = grid.filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
        rows = AppCoordinator.dropTitleRows(rows)
        guard let header = rows.first else { return }
        rows.removeFirst()

        let store = StaffStore.shared
        var headers = header.map { $0.trimmingCharacters(in: .whitespaces) }
        if headers.isEmpty { headers = StaffStore.defaultHeaders }
        if headers[0].isEmpty { headers[0] = "班级" }
        // 补齐/截断到表头长度
        let width = headers.count
        store.headers = headers
        store.rows = rows.map { line in
            var cells = Array(repeating: "", count: width)
            for i in 0..<min(width, line.count) { cells[i] = line[i].trimmingCharacters(in: .whitespaces) }
            return StaffRow(cells: cells)
        }
        store.save()
    }

    // MARK: 导出 / 下载
    func exportPersonal() {
        let panel = makeSavePanel("下载本人课表", defaultName: "本人课表.xlsx")
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try XLSX.write(exportPersonalRows(), to: url)
            } catch {
                showAlert("导出失败", error.localizedDescription)
            }
        }
    }

    func exportClass() {
        let store = ClassScheduleStore.shared
        let name = store.current.isEmpty ? "班级课表" : store.current
        let panel = makeSavePanel("下载「\(name)」课表", defaultName: "\(name)课表.xlsx")
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try XLSX.write(exportClassRows(), to: url)
            } catch {
                showAlert("导出失败", error.localizedDescription)
            }
        }
    }

    /// 导出全校班级课表（行=节次、列=班级、按星期分块，与「定稿」文件同构）
    func exportWholeSchool() {
        let store = ClassScheduleStore.shared
        guard !store.classes.isEmpty else {
            showAlert("没有可导出的班级", "请先导入全校课表，或在班级下拉里新建班级。")
            return
        }
        let panel = makeSavePanel("下载全校班级课表（\(store.classes.count) 个班）", defaultName: "全校班级课表.xlsx")
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try XLSX.write(store.wholeSchoolRows(), to: url)
            } catch {
                showAlert("导出失败", error.localizedDescription)
            }
        }
    }

    func exportStaff() {
        let panel = makeSavePanel("下载年级师资安排", defaultName: "年级师资安排.xlsx")
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try XLSX.write(exportStaffRows(), to: url)
            } catch {
                showAlert("导出失败", error.localizedDescription)
            }
        }
    }

    private func exportStaffRows() -> [[String]] {
        let store = StaffStore.shared
        var rows: [[String]] = [store.headers]
        for r in store.rows { rows.append(r.cells) }
        return rows
    }

    private func exportPersonalRows() -> [[String]] {
        let store = ScheduleStore.shared
        var rows: [[String]] = []
        rows.append(["节次"] + ScheduleStore.days)
        for (i, p) in store.periods.enumerated() where i < store.grid.count {
            rows.append([p] + store.grid[i])
        }
        return rows
    }

    private func exportClassRows() -> [[String]] {
        let store = ClassScheduleStore.shared
        var rows: [[String]] = []
        rows.append(["节次"] + ClassLayout.days)
        for group in store.groups {
            rows.append([group.title] + Array(repeating: "", count: ClassLayout.days.count))
            for p in group.periods {
                rows.append([p] + (store.cells[p] ?? []))
            }
        }
        return rows
    }

    // MARK: 下载填写模板（新机器数据为空：下载模板 → 填写 → 从对应「导入」导入）
    // 每个模板都带结构锚点，空机器上也能看懂怎么填：
    //   个人/班级课表 → 标题行 +「节次」；学生/师资 → 标题行 + 列名；
    //   工位 →「办公室」；座位 →「小组」；延时监考 →「子表」+「第几周」；
    //   教室分布 →「楼层」+「教室/办公室」。
    // ⚠️ 标题行统一为「整行只有 1 个非空格」，导入侧用 dropTitleRows 跳过（见下方）。
    enum ImportTemplate { case personal, classSheet, teacher, student, staff, office, seating, extend, classroom }

    func downloadTemplate(_ kind: ImportTemplate) {
        let (rows, name) = AppCoordinator.templateRows(kind)
        let panel = makeSavePanel("下载模板", defaultName: "\(name).xlsx")
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try XLSX.write(rows, to: url)
            } catch {
                showAlert("下载失败", error.localizedDescription)
            }
        }
    }

    /// 生成模板内容（纯函数，便于自检）：返回 (行数据, 文件名)
    static func templateRows(_ kind: ImportTemplate) -> ([[String]], String) {
        let rows: [[String]]
        let name: String
        switch kind {
        case .personal:
            // 没有任何节次时回落到默认布局（上午5/下午4/晚自习4），模板永远是完整空表
            let periods = ScheduleStore.shared.periods.isEmpty
                ? ScheduleStore.defaultGroups.flatMap { $0.periods }
                : ScheduleStore.shared.periods
            rows = [["本人课表"],
                    ["节次"] + ScheduleStore.days]
                + periods.map { [$0] + Array(repeating: "", count: ScheduleStore.days.count) }
            name = "本人课表模板"
        case .classSheet:
            let store = ClassScheduleStore.shared
            let blocks = store.groups.isEmpty ? ClassLayout.defaultGroups : store.groups
            rows = [["班级课表"],
                    ["节次"] + ClassLayout.days]
                + blocks.flatMap { g in
                    [[g.title] + Array(repeating: "", count: ClassLayout.days.count)]
                        + g.periods.map { [$0] + Array(repeating: "", count: ClassLayout.days.count) }
                }
            name = "班级课表模板"
        case .teacher:
            // 与学校给的「课表定稿（长表）」同格式：姓名 | 节次 | 周一…周天。
            // 示范 1 位教师 × 5 节课，填好直接导入；单元格写「班级 科目」（如 初一-18 数学）。
            rows = [["姓名", "节次"] + TeacherBlock.days]
                + (0..<5).map { i -> [String] in
                    var line: [String] = [i == 0 ? "张老师" : "", "第\(i + 1)节课"]
                    line += Array(repeating: "", count: TeacherBlock.days.count)
                    if i == 0 { line[2] = "初一-18 数学" }      // 周一第1节 示例
                    return line
                }
            name = "他人课表模板"
        case .student:
            rows = [["学生信息"],
                    StudentDefaultData.headers]
            name = "学生信息模板"
        case .staff:
            rows = [["年级师资安排"],
                    StaffStore.defaultHeaders]
            name = "年级师资安排模板"
        case .office:
            let cols = OfficeLayoutStore.seatColumns
            // 「楼层」行可选：写了，紧跟其后的办公室就归到该楼层（不写 = 未分组）
            rows = [["楼层", "三楼"], ["办公室", "办公室1"]]
                + Array(repeating: Array(repeating: "", count: cols), count: 4)
                + [[""], ["楼层", "四楼"], ["办公室", "办公室2"]]
                + Array(repeating: Array(repeating: "", count: cols), count: 4)
            name = "办公室工位模板"
        case .seating:
            // 与「下载」导出的格式完全一致：标题行 + 列号 1/2/3… + 每行「行号 + 姓名」。
            // 最后一行中间 3 格写着「讲台」，用来示范「讲台在表格里面」（可自行改位置或删掉）。
            // 分组功能已取消：不再有「小组」分段，整张表就是一张座位表。
            let seatCols = SeatingStore.defaultSize
            let podiumRow = seatCols - 1
            let podiumCol = (seatCols - 3) / 2
            rows = [["班级座位表"],
                    [""] + (0..<seatCols).map { SeatingStore.columnLabel($0) }]
                + (0..<seatCols).map { r -> [String] in
                    var line: [String] = ["\(r + 1)"]
                    for c in 0..<seatCols {
                        line.append(r == podiumRow && c == podiumCol ? "讲台" : "")
                    }
                    return line
                }
                + [["待用栏"], ["性别"]]
            name = "班级座位表模板"
        case .extend:
            rows = [["子表", "周二延时"],
                    ["第几周", "班级", "节次"],
                    ["1", "7", "8节"],
                    ["2", "8", "9节"],
                    ["3", "7", "9节"],
                    [""],
                    ["子表", "周日监考"],
                    ["第几周", "班级", "考试科目", "姓名"],
                    ["1", "4", "数学", "张老师"],
                    ["7", "5", "语文+历史", "李老师"]]
            name = "延时监考模板"
        case .classroom:
            rows = [["教室分布"],
                    ["楼层", "X栋4楼"],
                    ["教室", "19班", "X401"],
                    ["教室", "23班", "X402"],
                    ["教室", "25班", "X403"],
                    ["办公室", "办公室", "X406"],
                    ["教室", "26班", "X407"],
                    ["教室", "28班", "X408"],
                    ["附加行"],
                    ["教室", "1班", "X501"],
                    ["教室", "2班", "X502"],
                    [""],
                    ["楼层", "S栋5楼"],
                    ["教室", "3班", "S501"],
                    ["教室", "4班", "S502"],
                    ["办公室", "办公室", "S507"]]
            name = "教室分布模板"
        }
        return (rows, name)
    }

    private func showAlert(_ title: String, _ msg: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = msg
        a.alertStyle = .warning
        PanelHelper.prepare()
        PanelHelper.bringFront(a)
        a.runModal()
    }

    /// 准备 NSOpenPanel：聚焦 app、把独立窗口收起来、置顶
    private func makeOpenPanel(_ message: String) -> NSOpenPanel {
        PanelHelper.prepare()
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [xlsxType]
        panel.message = message
        PanelHelper.bringFront(panel)
        return panel
    }

    /// 准备 NSSavePanel：聚焦 app、把独立窗口收起来、置顶
    private func makeSavePanel(_ message: String, defaultName: String) -> NSSavePanel {
        PanelHelper.prepare()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [xlsxType]
        panel.nameFieldStringValue = defaultName
        panel.message = message
        PanelHelper.bringFront(panel)
        return panel
    }
}
