import SwiftUI
import Combine

// MARK: - 校历备注存储（按周号 "week-N" 存键；用户改写覆盖默认值；自动保存）
final class CalendarRemarkStore: ObservableObject {
    static let shared = CalendarRemarkStore()

    @Published var overrides: [String: String] = [:]   // 键 = "week-N"（保存去抖，见 set）

    private init() { load() }

    // 该周当前显示的备注：用户改写过则用用户的，否则用默认
    func remark(forWeek n: Int) -> String {
        overrides["week-\(n)"] ?? (ChongqingCalendar.defaultRemarks[n] ?? "")
    }

    func set(_ value: String, forWeek n: Int) {
        overrides["week-\(n)"] = value
        scheduleSave()   // 用户编辑 → 只标脏（落盘交给 SaveHub）
    }

    // MARK: 按天备注（右键日历某天 → 备注；键 = "day-yyyy-MM-dd"；自动同步到系统日历）
    func remark(forDay d: Date) -> String {
        overrides["day-\(Self.dayKey(d))"] ?? ""
    }

    func set(_ value: String, forDay d: Date) {
        let key = "day-\(Self.dayKey(d))"
        let ekKey = "ek-\(Self.dayKey(d))"
        let oldEventID = overrides[ekKey]
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { overrides.removeValue(forKey: key) } else { overrides[key] = t }
        scheduleSave()   // 用户编辑 → 只标脏（落盘交给 SaveHub）

        // 自动同步到系统日历（全天事件）；拿到事件标识后记录，下次改备注更新同一条事件
        CalendarSyncService.shared.syncDayRemark(t, day: d, eventID: oldEventID) { [weak self] newID in
            guard let self else { return }
            if let newID {
                self.overrides[ekKey] = newID
            } else {
                self.overrides.removeValue(forKey: ekKey)
            }
            self.scheduleSave()
        }
    }

    private static func dayKey(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    // MARK: 旧键迁移（"0-开学"/"1-三" → "week-N"）
    private static func migrateKey(_ old: String) -> Int? {
        guard old.contains("-") else { return nil }
        let parts = old.split(separator: "-", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let semester = Int(parts[0]) ?? 0
        let label = String(parts[1])
        guard let ordinal = chineseOrdinal(label) else { return nil }
        return semester == 0 ? ordinal : Self.semester1WeekCountOld + ordinal
    }
    // 旧版第一学期行数（24），迁移用
    private static let semester1WeekCountOld = 24

    private static func chineseOrdinal(_ s: String) -> Int? {
        if s == "开学" { return 1 }
        let digits: [Character: Int] = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
                                        "六": 6, "七": 7, "八": 8, "九": 9]
        if s.count == 1, let d = digits[s.first!] { return d }
        if s == "十" { return 10 }
        if s.hasPrefix("十"), let d = digits[s.dropFirst().first ?? " "] { return 10 + d }
        if s.hasPrefix("二十") {
            let rest = s.dropFirst(2)
            if rest.isEmpty { return 20 }
            if let d = digits[rest.first ?? " "] { return 20 + d }
        }
        return nil
    }

    // MARK: 持久化
    private static var fileURL: URL {
        // 统一走 AppPaths：自检可用 SCHEDULEBAR_DATA_DIR 把数据目录重定向到
        // 临时目录 —— 所有 store 都必须支持，否则它在 init 里的迁移会写真实数据。
        AppPaths.file("calendar_remarks.json")
    }

    private func load() {
        let url = Self.fileURL
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            // 没有本地数据 → 用内置的默认备注
            overrides = DefaultData.calendarRemarks
            return
        }
        var migrated: [String: String] = [:]
        for (k, v) in decoded {
            if k.hasPrefix("week-") || k.hasPrefix("day-") || k.hasPrefix("ek-") {
                migrated[k] = v
            } else if let weekKey = Self.migrateKey(k), migrated["week-\(weekKey)"] == nil {
                migrated["week-\(weekKey)"] = v
            }
        }
        overrides = migrated
    }

    /// 用户编辑 → 只标脏；真正的落盘由 SaveHub 统一负责
    /// （点「保存」/ ⌘S / 停手 8 秒 / 收起面板 / 退出前）。
    func scheduleSave() {
        SaveHub.shared.markDirty("校历备注")
    }

    func save() {
        let url = Self.fileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(overrides)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[ScheduleBar] 校历备注保存失败: \(error)")
        }
    }
}
