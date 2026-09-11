import Foundation
import AppKit

// MARK: - 在线更新检查（GitHub Release + 仓库内 version.json 双通道）
//
// ⚠️⚠️ 只需改这里：填成你托管「教师助手」的 GitHub 仓库（公开仓库即可） ⚠️⚠️
//
// 检查顺序（任一通道有数据就能检测到更新，全部失败才提示）：
//   ① https://api.github.com/repos/<owner>/<repo>/releases/latest
//      —— 正式 Release（附件放 .dmg）
//   ② 仓库根目录的 version.json —— **不需要创建 Release，也不需要 Token**
//      依次尝试：api.github.com 内容接口 → jsDelivr CDN → raw.githubusercontent.com
//      国内网络实测：api.github.com 与 cdn.jsdelivr.net 可直连，raw.githubusercontent.com 常被墙
//   ③ GitHubRepoConfig.feedURL（可选：任意 https 地址上的 version.json，留空即跳过）
//
// version.json 内容示例：
//   {
//     "version": "2.1.1",
//     "download": "教师助手_v2.1.1.dmg",   // 相对文件名 → 自动解析（jsDelivr CDN 优先）；也可写完整 https 链接
//     "notes": "本次更新内容……"             // 可选
//   }
enum GitHubRepoConfig {
    static let owner = "27336418"
    static let repo  = "teacherhelper"
    /// version.json 所在分支（main / master）
    static let branch = "main"
    /// 可选：GitHub 个人访问令牌（留空 = 不带认证，限额 60 次/小时；填了提到 5000 次/小时）
    static let token = ""
    /// 可选：自定义更新清单地址（任意 https 上的 version.json；留空即跳过该通道）
    static let feedURL = ""
}

final class GitHubUpdateService {
    static let shared = GitHubUpdateService()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var repoIdentifier: String {
        "\(GitHubRepoConfig.owner)/\(GitHubRepoConfig.repo)"
    }

    var repoPageURL: String {
        "https://github.com/\(repoIdentifier)"
    }

    /// 是否已配置（owner/repo 已改成真实值）
    var isConfigured: Bool {
        let o = GitHubRepoConfig.owner
        let r = GitHubRepoConfig.repo
        return !o.isEmpty && !r.isEmpty && !r.contains("<") && o != "your-github-username"
    }

    /// 本地当前版本（来自 Info.plist）
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    // MARK: - 对外结果

    /// 单条更新信息来源
    struct RemoteInfo {
        var version: String
        var notes: String
        var page: String
        var assetName: String
        var assetURL: String
        /// 备用下载地址（主地址失败时依次重试，例如 CDN 换成 raw）
        var fallbackURLs: [String] = []
        var source: String
    }

    enum Result {
        case notConfigured
        case latest(current: String)
        case update(RemoteInfo)
        /// 仓库可达但没有任何版本信息（既没有 Release，也没有 version.json）
        case noSource(hint: String)
        case error(String)
    }

    private enum FetchOutcome {
        case json([String: Any])
        case notFound
        case httpError(Int)
        case failure(String)
    }

    // MARK: - 主流程

    /// ① Release → ② version.json → ③ 自定义清单；都没有版本信息时回 .noSource
    func checkForUpdates(auto: Bool, _ completion: @escaping (Result) -> Void) {
        guard isConfigured else {
            SeatingStore.seatLog("升级：未配置有效仓库地址")
            completion(.notConfigured)
            return
        }
        SeatingStore.seatLog("升级：检查更新（auto=\(auto)）repo=\(repoIdentifier)")

        fetch(releaseAPIURL, accept: "application/vnd.github+json") { [weak self] outcome in
            guard let self else { return }
            if case .json(let json) = outcome, let info = Self.infoFromRelease(json) {
                self.finish(info, auto: auto, completion)
                return
            }
            let reason = Self.describe(outcome, label: "Release 接口")
            SeatingStore.seatLog("升级：\(reason)，改用 version.json 更新清单")
            self.tryFeeds(auto: auto, tried: reason, index: 0, errors: [], completion: completion)
        }
    }

    /// 逐个尝试 version.json 通道（API → CDN → raw → 自定义地址）
    private func tryFeeds(auto: Bool, tried: String, index: Int,
                          errors: [String], completion: @escaping (Result) -> Void) {
        let candidates = feedCandidates
        guard index < candidates.count else {
            var parts = [tried]
            parts.append(contentsOf: errors)
            let hint = "仓库「\(repoIdentifier)」没有可用的版本信息（\(parts.joined(separator: "；"))）。"
            SeatingStore.seatLog("升级：无可用更新来源。\(hint)")
            completion(.noSource(hint: hint))
            return
        }
        let cand = candidates[index]
        fetch(cand.url, accept: cand.accept) { [weak self] outcome in
            guard let self else { return }
            if case .json(let json) = outcome,
               let info = Self.infoFromFeed(json, owner: GitHubRepoConfig.owner,
                                            repo: GitHubRepoConfig.repo,
                                            branch: cand.branch, page: self.repoPageURL) {
                self.finish(info, auto: auto, completion)
                return
            }
            var next = errors
            if case .json = outcome {
                next.append("\(cand.label) 里没有 version 字段")
            } else {
                next.append(Self.describe(outcome, label: cand.label))
            }
            self.tryFeeds(auto: auto, tried: tried, index: index + 1,
                          errors: next, completion: completion)
        }
    }

    private struct FeedCandidate {
        var url: String
        var accept: String
        var branch: String
        var label: String
    }

    /// 候选更新清单：GitHub 内容接口（国内可直连）→ jsDelivr CDN → raw → 自定义地址
    private var feedCandidates: [FeedCandidate] {
        let o = GitHubRepoConfig.owner
        let r = GitHubRepoConfig.repo
        let b = GitHubRepoConfig.branch
        var list: [FeedCandidate] = [
            FeedCandidate(url: "https://api.github.com/repos/\(o)/\(r)/contents/version.json?ref=\(b)",
                          accept: "application/vnd.github.raw", branch: b, label: "version.json(API)"),
            FeedCandidate(url: "https://cdn.jsdelivr.net/gh/\(o)/\(r)@\(b)/version.json",
                          accept: "application/json", branch: b, label: "version.json(CDN)"),
            FeedCandidate(url: "https://raw.githubusercontent.com/\(o)/\(r)/\(b)/version.json",
                          accept: "application/json", branch: b, label: "version.json(raw)"),
        ]
        let custom = GitHubRepoConfig.feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            list.append(FeedCandidate(url: custom, accept: "application/json",
                                      branch: b, label: "自定义清单"))
        }
        return list
    }

    /// 统一收口：远端更新 → .update；否则 .latest
    private func finish(_ info: RemoteInfo, auto: Bool, _ completion: @escaping (Result) -> Void) {
        if Self.compare(info.version, currentVersion) == .orderedDescending {
            SeatingStore.seatLog("升级：发现新版本 \(info.version)（当前 \(currentVersion)，来源 \(info.source)）→ \(info.assetURL.isEmpty ? info.page : info.assetURL)")
            completion(.update(info))
        } else {
            SeatingStore.seatLog("升级：当前 \(currentVersion) 已是最新（来源 \(info.source)，远端 \(info.version)）")
            completion(.latest(current: currentVersion))
        }
    }

    // MARK: - 下载更新包

    /// 依次尝试「主地址 → 备用地址 → GitHub 加速镜像」，成功一个即回调。
    /// 国内网络下 github.com 的 release 附件与 raw 域名常被墙，镜像（ghproxy 等）可直连。
    func downloadUpdate(from urlString: String, fallbacks: [String] = [], suggestedName: String,
                        completion: @escaping (Swift.Result<URL, Error>) -> Void) {
        let attempts = Self.downloadAttempts(primary: urlString, fallbacks: fallbacks)
        guard !attempts.isEmpty else {
            completion(.failure(NSError(domain: "ScheduleBar.Update", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: "没有可下载的安装包地址"])))
            return
        }
        SeatingStore.seatLog("升级：开始下载更新，共 \(attempts.count) 个地址候选")
        tryDownload(attempts: attempts, index: 0, name: suggestedName,
                    lastError: nil, completion: completion)
    }

    private func tryDownload(attempts: [String], index: Int, name suggestedName: String,
                             lastError: Error?, completion: @escaping (Swift.Result<URL, Error>) -> Void) {
        guard index < attempts.count else {
            completion(.failure(lastError ?? NSError(domain: "ScheduleBar.Update", code: 2,
                                                     userInfo: [NSLocalizedDescriptionKey: "下载更新失败"])))
            return
        }
        let urlString = attempts[index]
        guard let url = URL(string: urlString) else {
            tryDownload(attempts: attempts, index: index + 1, name: suggestedName,
                        lastError: lastError, completion: completion)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("TeacherHelper/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let token = GitHubRepoConfig.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        URLSession.shared.downloadTask(with: request) { [weak self] tempURL, response, error in
            DispatchQueue.main.async {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                let ok = error == nil && tempURL != nil && (200..<300).contains(code)
                if ok, let tempURL {
                    let name = suggestedName.lowercased().hasSuffix(".dmg") ? suggestedName : "教师助手-更新.dmg"
                    let destination = FileManager.default.temporaryDirectory
                        .appendingPathComponent("教师助手-更新-\(UUID().uuidString)-\(name)")
                    do {
                        try FileManager.default.moveItem(at: tempURL, to: destination)
                        SeatingStore.seatLog("升级：下载完成 \(urlString.prefix(90))")
                        completion(.success(destination))
                    } catch {
                        completion(.failure(error))
                    }
                    return
                }
                let reason: String
                if let error { reason = error.localizedDescription }
                else { reason = "HTTP \(code)" }
                SeatingStore.seatLog("升级：地址不可用（\(reason)），换下一个")
                let err = NSError(domain: "ScheduleBar.Update", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "下载更新失败（\(reason)）"])
                self?.tryDownload(attempts: attempts, index: index + 1, name: suggestedName,
                                  lastError: err, completion: completion)
            }
        }.resume()
    }

    /// 候选地址：主地址 → 备用地址 → 各自的 GitHub 加速镜像（去重保序）
    static func downloadAttempts(primary: String, fallbacks: [String]) -> [String] {
        var list: [String] = []
        func add(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !list.contains(t) else { return }
            list.append(t)
        }
        for u in [primary] + fallbacks { add(u) }
        for u in [primary] + fallbacks {
            for m in mirrors(for: u) { add(m) }
        }
        return list
    }

    /// GitHub 直连域名 → 国内加速镜像
    static let mirrorPrefixes = ["https://ghproxy.net/", "https://gh-proxy.com/", "https://ghfast.top/"]

    static func mirrors(for urlString: String) -> [String] {
        let t = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("https://github.com/")
                || t.hasPrefix("https://raw.githubusercontent.com/")
                || t.hasPrefix("https://objects.githubusercontent.com/") else { return [] }
        return mirrorPrefixes.map { $0 + t }
    }

    // MARK: - 解析

    /// Release JSON → RemoteInfo（无 tag_name 视为无信息）
    static func infoFromRelease(_ json: [String: Any]) -> RemoteInfo? {
        let tag = (json["tag_name"] as? String) ?? ""
        guard !tag.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let body = (json["body"] as? String) ?? ""
        let html = (json["html_url"] as? String) ?? ""
        let assets = (json["assets"] as? [[String: Any]]) ?? []
        // 优先选 .dmg；没有则退回第一个附件；再没有就打开 release 页面
        let dmg = assets.first { (($0["name"] as? String) ?? "").lowercased().hasSuffix(".dmg") }
        let asset = dmg ?? assets.first ?? [:]
        let assetURL = (asset["browser_download_url"] as? String) ?? ""
        return RemoteInfo(version: stripV(tag),
                          notes: body,
                          page: html,
                          assetName: (asset["name"] as? String) ?? "打开 release 页面",
                          assetURL: assetURL,
                          fallbackURLs: [],
                          source: "GitHub Release")
    }

    /// version.json → RemoteInfo（无 version 视为无信息）
    static func infoFromFeed(_ json: [String: Any], owner: String, repo: String,
                             branch: String, page: String) -> RemoteInfo? {
        let rawVer = (json["version"] as? String) ?? (json["tag_name"] as? String) ?? ""
        let version = stripV(rawVer.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !version.isEmpty else { return nil }
        let notes = (json["notes"] as? String) ?? (json["body"] as? String)
            ?? (json["changelog"] as? String) ?? ""
        let rawDL = (json["download"] as? String) ?? (json["download_url"] as? String)
            ?? (json["dmg"] as? String) ?? (json["url"] as? String) ?? ""
        let resolved = resolveDownloadSet(rawDL, owner: owner, repo: repo, branch: branch)
        return RemoteInfo(version: version, notes: notes, page: page,
                          assetName: resolved.name, assetURL: resolved.primary,
                          fallbackURLs: resolved.fallbacks, source: "version.json")
    }

    /// 解析下载地址：绝对 URL 原样用；相对文件名 → jsDelivr CDN（备用 raw 域名）
    static func resolveDownloadSet(_ raw: String, owner: String, repo: String, branch: String)
        -> (name: String, primary: String, fallbacks: [String]) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return ("打开更新页面", "", []) }
        if t.lowercased().hasPrefix("http://") || t.lowercased().hasPrefix("https://") {
            return (URL(string: t)?.lastPathComponent ?? "下载更新", t, [])
        }
        let encoded = encodePath(t)
        let cdn = "https://cdn.jsdelivr.net/gh/\(owner)/\(repo)@\(branch)/\(encoded)"
        let rawURL = "https://raw.githubusercontent.com/\(owner)/\(repo)/\(branch)/\(encoded)"
        return (t, cdn, [rawURL])
    }

    /// 中文等字符按路径规则编码
    static func encodePath(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return path.split(separator: "/").map { part -> String in
            String(part).addingPercentEncoding(withAllowedCharacters: allowed) ?? String(part)
        }.joined(separator: "/")
    }

    /// 仓库内文件的 raw 地址
    static func rawURL(owner: String, repo: String, branch: String, path: String) -> String {
        "https://raw.githubusercontent.com/\(owner)/\(repo)/\(branch)/\(path)"
    }

    /// 仓库内文件的 jsDelivr CDN 地址（国内更快、常可直连）
    static func cdnURL(owner: String, repo: String, branch: String, path: String) -> String {
        "https://cdn.jsdelivr.net/gh/\(owner)/\(repo)@\(branch)/\(path)"
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

    static func stripV(_ s: String) -> String {
        s.hasPrefix("v") || s.hasPrefix("V") ? String(s.dropFirst()) : s
    }

    private static func describe(_ outcome: FetchOutcome, label: String) -> String {
        switch outcome {
        case .json:                 return "\(label) 数据格式不对"
        case .notFound:             return "\(label) 不存在（HTTP 404）"
        case .httpError(let code):
            if code == 403 || code == 429 { return "\(label) 被限流（HTTP \(code)）" }
            return "\(label) 返回 HTTP \(code)"
        case .failure(let msg):     return "\(label) 连不上（\(msg)）"
        }
    }

    // MARK: - 网络

    private var releaseAPIURL: String {
        "https://api.github.com/repos/\(repoIdentifier)/releases/latest"
    }

    private func fetch(_ urlString: String, accept: String,
                       completion: @escaping (FetchOutcome) -> Void) {
        guard let url = URL(string: urlString) else {
            completion(.failure("地址无效"))
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue("TeacherHelper/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let token = GitHubRepoConfig.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                if let err {
                    completion(.failure(err.localizedDescription))
                    return
                }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                if code == 404 {
                    completion(.notFound)
                    return
                }
                guard (200..<300).contains(code) else {
                    completion(.httpError(code))
                    return
                }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completion(.failure("返回内容不是合法 JSON"))
                    return
                }
                completion(.json(json))
            }
        }.resume()
    }
}
