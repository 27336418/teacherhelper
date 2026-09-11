import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 导入/导出协调器（菜单栏 app 的面板交互）
final class AppCoordinator: ObservableObject {
    static let shared = AppCoordinator()

    private let xlsxType = UTType(filenameExtension: "xlsx") ?? .data

    // MARK: 导入（由用户在选择时指定类型）
    func importPersonalFile() {
        importFile("导入个人课表", grid: importPersonal)
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
                a.informativeText = "尚未内置 GitHub 仓库地址，请把 GitHubUpdateService 顶部的 owner / repo 改成您的仓库后重新打包。"
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
        case .update(let ver, _, let page, _, let assetURL):
            // 自动检查时：同一版本每天只自动打开一次，避免每次启动都弹浏览器
            if !manual, !shouldAutoPrompt(version: ver) { return }
            if !manual { markAutoPrompted(version: ver) }
            // 打开新版下载地址，用户在页面上自行选择是否下载
            if let u = URL(string: assetURL), !assetURL.isEmpty {
                NSWorkspace.shared.open(u)
            } else if let u = URL(string: page) {
                NSWorkspace.shared.open(u)
            }
        case .error(let msg):
            if manual {
                PanelHelper.prepare()
                let a = NSAlert()
                a.messageText = "检查更新失败"
                a.informativeText = msg
                PanelHelper.bringFront(a)
                a.runModal()
            }
        }
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
                    // 认得出的星期 → 切块；「星期六」等表里没有的日期 → nil，跳过该块
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

        // 4) 组装每班数据（补齐所有节次 × 6 天）
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

    /// 依据文件里出现的节次顺序生成分组（白天前 4 节为上午，其余白天为下午，晚X 为晚自习）
    static func makeGroups(from periodOrder: [String]) -> [ClassGroup] {
        let dayLabels = periodOrder.filter { !$0.hasPrefix("晚") }
        let eveLabels = periodOrder.filter { $0.hasPrefix("晚") }
        var groups: [ClassGroup] = []
        if !dayLabels.isEmpty {
            let cut = min(4, dayLabels.count)
            groups.append(ClassGroup(title: "上午", periods: Array(dayLabels[0..<cut])))
            if dayLabels.count > cut {
                groups.append(ClassGroup(title: "下午", periods: Array(dayLabels[cut...])))
            }
        }
        if !eveLabels.isEmpty {
            groups.append(ClassGroup(title: "晚自习", periods: eveLabels))
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

    /// 解析工位：以「办公室」开头的行分段，随后每行 = 一排座位；「颜色」段可读回自定义色
    static func parseOffices(_ grid: [[String]]) -> [OfficeBlock] {
        var out: [OfficeBlock] = []
        var current: OfficeBlock? = nil
        var inColorSection = false
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
            if first == "办公室" {
                flush()
                inColorSection = false
                let title = cells.count > 1 ? cells[1] : "办公室\(out.count + 1)"
                current = OfficeBlock(title: title, seats: [])
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
            var a = Array(arr.prefix(n))
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
                          "共导入 \(parsed.groups.count) 个小组、待用栏 \(parsed.pool.count) 人（已铺进一张大表，每组一个色块区域）。")
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

        for row in grid {
            let cells = row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
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
                let vals = cells.filter { !$0.isEmpty }
                if vals.isEmpty { flush(); continue }
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
        // 每个分组区域：按包围盒逐行导出（区域外格子跳过）
        let regions = store.regions.sorted {
            let a = $0.bounds, b = $1.bounds
            return (a.minR, a.minC) < (b.minR, b.minC)
        }
        for rg in regions {
            rows.append(["小组", rg.title])
            let b = rg.bounds
            for r in b.minR...b.maxR {
                var line: [String] = []
                for c in b.minC...b.maxC {
                    let k = SeatingStore.key(r, c)
                    if rg.cells.contains(k) { line.append(store.name(at: k) ?? "") }
                }
                if line.contains(where: { !$0.isEmpty }) { rows.append(line) }
            }
            rows.append([""])
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

    // 学生信息：首行=表头，其余行=学生数据（自动补齐列宽、跳过空行）
    private func importStudent(_ grid: [[String]]) {
        var rows = grid.filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
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
        for row in grid.dropFirst() {
            guard row.count > 0 else { continue }
            let label = row[0].trimmingCharacters(in: .whitespaces)
            if let pIdx = store.periods.firstIndex(of: label) {
                for d in 0..<ScheduleStore.days.count {
                    // 个人课表去周六：列顺序 周一~周五(0-4)、周日(5)
                    // 旧模板（7 列）周日在 index 6；新模板（6 列）周日在 index 5
                    let col: Int
                    if row.count >= 7 {
                        col = d < 5 ? d + 1 : 6   // 旧：周五→col=5，周日→col=6
                    } else {
                        col = d + 1
                    }
                    if col < row.count { newGrid[pIdx][d] = row[col] }
                }
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
        for row in grid.dropFirst() {
            guard row.count > 0 else { continue }
            let label = row[0].trimmingCharacters(in: .whitespaces)
            guard ordered.contains(label) else { continue }
            var dayVals = Array(repeating: "", count: ClassLayout.days.count)
            for d in 0..<ClassLayout.days.count {
                let col = d + 1
                if col < row.count {
                    // 清理特殊字符：换行/回车→"·"，便于单行显示
                    let raw = row[col]
                    let cleaned = raw
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
            }
            newCells[label] = dayVals
        }
        store.cells = newCells
        store.save()
    }

    // 师资：首行=表头（第 1 列「班级」固定），其余行=班级数据
    private func importStaff(_ grid: [[String]]) {
        var rows = grid.filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
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
        let panel = makeSavePanel("下载个人课表", defaultName: "个人课表.xlsx")
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
    enum ImportTemplate { case personal, classSheet, student, staff, office, seating, extend }

    func downloadTemplate(_ kind: ImportTemplate) {
        let rows: [[String]]
        let name: String
        switch kind {
        case .personal:
            rows = [["节次"] + ScheduleStore.days]
                + ScheduleStore.shared.periods.map { [$0] + Array(repeating: "", count: ScheduleStore.days.count) }
            name = "个人课表模板"
        case .classSheet:
            let store = ClassScheduleStore.shared
            let blocks = store.groups.isEmpty ? ClassLayout.defaultGroups : store.groups
            rows = [["节次"] + ClassLayout.days]
                + blocks.flatMap { g in
                    [[g.title] + Array(repeating: "", count: ClassLayout.days.count)]
                        + g.periods.map { [$0] + Array(repeating: "", count: ClassLayout.days.count) }
                }
            name = "班级课表模板"
        case .student:
            rows = [StudentDefaultData.headers]
            name = "学生信息模板"
        case .staff:
            rows = [StaffStore.defaultHeaders]
            name = "年级师资安排模板"
        case .office:
            let cols = OfficeLayoutStore.seatColumns
            rows = [["办公室", "办公室1"]]
                + Array(repeating: Array(repeating: "", count: cols), count: 4)
                + [[""], ["办公室", "办公室2"]]
                + Array(repeating: Array(repeating: "", count: cols), count: 4)
            name = "办公室工位模板"
        case .seating:
            rows = [["小组", "第1小组"]]
                + Array(repeating: Array(repeating: "", count: 6), count: 5)
                + [[""], ["待用栏"], ["性别"]]
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
        }
        let panel = makeSavePanel("下载模板", defaultName: "\(name).xlsx")
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try XLSX.write(rows, to: url)
            } catch {
                showAlert("下载失败", error.localizedDescription)
            }
        }
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
