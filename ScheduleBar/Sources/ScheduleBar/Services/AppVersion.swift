import Foundation

// MARK: - 版本号（单一读取处）
//
// 2026-09-26 用户要求：「左上角教师助手后面跟上版本号；版本号字体调小一些」。
// 界面（侧栏标题旁的小字）与更新检查各自读 Info.plist 容易走样（一边读 2.5.4、
// 一边读 CFBundleVersion），所以统一从这里取。
//
// ⚠️ 命令行直跑二进制（例如 `./.build/release/ScheduleBar --selftest-*`）时
//    进程**没有 App bundle**，读出来是空串 —— 必须有兜底文案，
//    否则侧栏会显示成「教师助手 」后面一片空白，看着像 bug。
enum AppVersion {
    /// 形如 `2.5.4`（Info.plist 的 CFBundleShortVersionString）
    static var short: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
    }

    /// 形如 `75`（Info.plist 的 CFBundleVersion）
    static var build: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? ""
    }

    /// 侧栏标题旁显示用：正常是 `v2.5.4`；没有 bundle（直跑二进制 / 自检）时显示 `开发版`
    static var display: String {
        short.isEmpty ? "开发版" : "v\(short)"
    }

    /// 悬停提示：带 build 号，方便对「到底装的是哪一版」做取证（本项目踩过多次）
    static var tooltip: String {
        guard !short.isEmpty else { return "开发版（命令行直跑，未打包）" }
        return build.isEmpty ? "版本 \(short)" : "版本 \(short)（build \(build)）"
    }
}
