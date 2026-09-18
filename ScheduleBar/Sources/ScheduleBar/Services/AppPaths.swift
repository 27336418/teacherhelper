import Foundation

// MARK: - 统一数据目录（AppPaths）
//
// 2026-09-18 新增。此前只有 SeatingStore / StaffStore 认 `SCHEDULEBAR_DATA_DIR`，
// 其余 9 个 store 直接写死「真实」的 Application Support 目录。
//
// ⚠️ 这曾经造成一次真实的数据安全事故（务必理解后再改）：
//    `ReminderStore.init` 里有一次性的「星期错位修正」迁移，原先用
//    `UserDefaults.standard.bool(forKey:)` 当开关。直接跑 `.build/…/ScheduleBar`
//    时进程没有 App bundle，偏好域与正常启动的 App **不是同一个**，开关读不到
//    → 迁移被当成「首次运行」重跑一次 → 用户提醒的星期整体又错位一天。
//
//    两个教训：
//      ① 一次性迁移**不要用 UserDefaults 当开关**（偏域不同就重跑），
//         要用「数据本身」表达幂等（见 Reminder.oneShotDay 的做法），
//         或者干脆在修复发布后就删掉那段迁移；
//      ② 自检必须能把**所有** store 的数据目录重定向到临时目录 —— 只要漏一个，
//         它在 init 里的迁移/清洗就会写用户的真实数据。
//
// 所以：所有 store 一律通过 `AppPaths.file(_:)` 取文件路径，不要再自己拼目录。
enum AppPaths {
    /// 数据目录。设了 `SCHEDULEBAR_DATA_DIR`（自检用）就重定向到那里 —— 绝不触碰真实数据。
    static var dataDir: URL {
        if let dir = ProcessInfo.processInfo.environment["SCHEDULEBAR_DATA_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScheduleBar", isDirectory: true)
    }

    /// 数据目录下的某个文件（不负责创建目录，写盘时各自 createDirectory）
    static func file(_ name: String) -> URL {
        dataDir.appendingPathComponent(name)
    }
}
