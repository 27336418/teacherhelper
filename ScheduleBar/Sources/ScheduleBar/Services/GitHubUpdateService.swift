import Foundation
import AppKit


// MARK: - GitHub Release 自动更新检查
//
// ⚠️⚠️ 只需改这两行：填成你托管教师助手源码的 GitHub 仓库 ⚠️⚠️
//     （仓库需为公开，且至少发布过一个 release；release 附件放 教师助手.dmg）
//
// 应用不再提供「设置仓库」界面，仓库地址直接内置。改完重新打包即可。
enum GitHubRepoConfig {
    static let owner = "27336418"
    static let repo  = "teacher-helper"
    /// 可选：GitHub 个人访问令牌（public_repo 只读即可），填了可把 API 限额提到 5000 次/小时。
    /// 留空 = 不带认证（限额 60 次/小时，个人使用通常够用）。
    static let token = ""
}

// 运行逻辑：调 `https://api.github.com/repos/<owner>/<repo>/releases/latest`，
// 把 tag_name (如 "v1.7.0") 与本地 Info.plist 的 CFBundleShortVersionString 比较；
// 有新版本时直接打开下载地址（release 附件的下载链接），由用户自行决定是否下载。
final class GitHubUpdateService {
    static let shared = GitHubUpdateService()

    /// 用户可改（第一次进入面板会提示设置）
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var repoIdentifier: String {
        "\(GitHubRepoConfig.owner)/\(GitHubRepoConfig.repo)"
    }

    /// 是否已配置（owner/repo 已改成真实值）
    var isConfigured: Bool {
        let o = GitHubRepoConfig.owner
        let r = GitHubRepoConfig.repo
        return !o.isEmpty && !r.isEmpty && o != "your-github-username"
    }

    /// 本地当前版本（来自 Info.plist）
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    /// 异步检查更新；返回 nil 表示「已是最新 / 检查失败」，具体结果通过回调
    /// result: .latest / .update(version, body, url, assetName) / .error(msg) / .notConfigured
    func checkForUpdates(auto: Bool, _ completion: @escaping (Result) -> Void) {
        guard isConfigured, let url = apiURL() else {
            SeatingStore.seatLog("升级：未配置仓库，前往前去「教师助手 → 设置仓库」")
            completion(.notConfigured)
            return
        }
        SeatingStore.seatLog("升级：正在查询 \(repoIdentifier) 最新 release（auto=\(auto)）")

        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // 可选：填入 Token 可把 GitHub API 限额从 60 次/小时 提到 5000 次/小时（留空即不带）
        let token = GitHubRepoConfig.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                if let err {
                    SeatingStore.seatLog("升级：网络错误 \(err.localizedDescription)")
                    completion(.error("网络连接失败：\(err.localizedDescription)"))
                    return
                }
                let http = resp as? HTTPURLResponse
                let code = http?.statusCode ?? -1
                if code == 403 || code == 429 {
                    let msg = "GitHub 接口访问过于频繁（限额 60 次/小时），请稍后再试；或在代码里填一个 GitHub Token 提高限额。"
                    SeatingStore.seatLog("升级：限流 HTTP \(code)")
                    completion(.error(msg))
                    return
                }
                if code == 404 {
                    let msg = "仓库或 release 不存在（请确认仓库已公开、且已创建过 release）。"
                    SeatingStore.seatLog("升级：404 \(self.repoIdentifier)")
                    completion(.error(msg))
                    return
                }
                guard (200..<300).contains(code), let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    let msg = "GitHub 返回异常（HTTP \(code)）"
                    SeatingStore.seatLog("升级：\(msg)")
                    completion(.error(msg))
                    return
                }
                let tag = (json["tag_name"] as? String) ?? ""
                let body = (json["body"] as? String) ?? "(无说明)"
                let html = (json["html_url"] as? String) ?? ""
                let assets = (json["assets"] as? [[String: Any]]) ?? []
                // 优先选发布附件中的 dmg；没有附件时退回 release 页面，避免误下源码压缩包。
                let dmg = assets.first { asset in
                    ((asset["name"] as? String) ?? "").lowercased().hasSuffix(".dmg")
                }
                let asset = dmg ?? assets.first ?? [:]
                let assetName = (asset["name"] as? String) ?? "打开 release 页面"
                let assetURL = (asset["browser_download_url"] as? String) ?? ""

                let remoteVer = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                if Self.compare(remoteVer, self.currentVersion) == .orderedDescending {
                    SeatingStore.seatLog("升级：发现新版本 \(remoteVer)（当前 \(self.currentVersion)）→ \(html)")
                    completion(.update(version: remoteVer, notes: body, page: html, assetName: assetName, assetURL: assetURL))
                } else {
                    SeatingStore.seatLog("升级：当前 \(self.currentVersion) 已是最新")
                    completion(.latest(current: self.currentVersion))
                }
            }
        }.resume()
    }

    /// 自动下载 release 附件到临时目录；下载完成后打开 dmg，由用户拖动覆盖旧 App。
    func downloadUpdate(from urlString: String, suggestedName: String,
                        completion: @escaping (Swift.Result<URL, Error>) -> Void) {
        guard let url = URL(string: urlString), !urlString.isEmpty else {
            completion(.failure(NSError(domain: "ScheduleBar.Update", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: "没有可下载的 dmg 附件"])))
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let token = GitHubRepoConfig.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        URLSession.shared.downloadTask(with: request) { tempURL, response, error in
            DispatchQueue.main.async {
                if let error { completion(.failure(error)); return }
                guard let tempURL, let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    completion(.failure(NSError(domain: "ScheduleBar.Update", code: 2,
                                                userInfo: [NSLocalizedDescriptionKey: "下载更新失败"])))
                    return
                }
                let name = suggestedName.lowercased().hasSuffix(".dmg") ? suggestedName : "教师助手-更新.dmg"
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent("教师助手-更新-\(UUID().uuidString)-\(name)")
                do {
                    try FileManager.default.moveItem(at: tempURL, to: destination)
                    completion(.success(destination))
                } catch { completion(.failure(error)) }
            }
        }.resume()
    }

    /// 比对 "1.2.3" 这种 semver；前导 v 自动忽略；空 < 任何版本
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let A = a.split(separator: ".").compactMap { Int($0) }
        let B = b.split(separator: ".").compactMap { Int($0) }
        let n = max(A.count, B.count)
        for i in 0..<n {
            let av = i < A.count ? A[i] : 0
            let bv = i < B.count ? B[i] : 0
            if av != bv { return av < bv ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private func apiURL() -> URL? {
        URL(string: "https://api.github.com/repos/\(repoIdentifier)/releases/latest")
    }

    enum Result {
        case notConfigured
        case latest(current: String)
        case update(version: String, notes: String, page: String, assetName: String, assetURL: String)
        case error(String)
    }
}
