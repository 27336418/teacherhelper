import Foundation
import AppKit
import UniformTypeIdentifiers

// MARK: - 全量备份 / 恢复
// 备份 = 一个 .json 容器文件，包含：
//   1) 数据目录（~/Library/Application Support/ScheduleBar）下的全部 .json（课表/学生/座位/提醒/备注/布局/导航等）
//   2) 应用自己的 UserDefaults 域（第1周日期、视角、Dock 开关等所有设置）
// 恢复 = 把文件写回 + 覆盖设置域，然后自动重启应用生效。
enum BackupService {
    struct Container: Codable {
        var app: String
        var version: Int
        var created: String
        var files: [String: String]          // 文件名 → 文本内容
        var defaults: [String: String]       // 设置键 → plist XML 文本
    }

    static var dataDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScheduleBar", isDirectory: true)
    }

    // MARK: 导出
    static func exportBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmm"
        panel.nameFieldStringValue = "教师助手备份_\(f.string(from: Date()))"
        panel.message = "备份全部数据与设置（课表 / 学生 / 座位 / 提醒 / 备注 / 布局 / 各项设置）"
        PanelHelper.prepare()
        PanelHelper.bringFront(panel)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            var files: [String: String] = [:]
            if FileManager.default.fileExists(atPath: dataDir.path) {
                for item in try FileManager.default.contentsOfDirectory(at: dataDir, includingPropertiesForKeys: nil) {
                    if item.pathExtension.lowercased() == "json",
                       let text = try? String(contentsOf: item, encoding: .utf8) {
                        files[item.lastPathComponent] = text
                    }
                }
            }
            var defaults: [String: String] = [:]
            if let bid = Bundle.main.bundleIdentifier,
               let domain = UserDefaults.standard.persistentDomain(forName: bid) {
                for (k, v) in domain {
                    if let data = try? PropertyListSerialization.data(fromPropertyList: v, format: .xml, options: 0),
                       let xml = String(data: data, encoding: .utf8) {
                        defaults[k] = xml
                    }
                }
            }
            let container = Container(app: "ScheduleBar", version: 1,
                                      created: f.string(from: Date()),
                                      files: files, defaults: defaults)
            let data = try JSONEncoder().encode(container)
            try data.write(to: url, options: .atomic)
            SeatingStore.seatLog("备份：已导出 \(files.count) 个数据文件 + \(defaults.count) 项设置 → \(url.path)")
            showAlert("备份完成",
                      "已保存 \(files.count) 个数据文件和 \(defaults.count) 项设置。\n\(url.path)")
        } catch {
            SeatingStore.seatLog("备份：导出失败 \(error.localizedDescription)")
            showAlert("备份失败", error.localizedDescription)
        }
    }

    // MARK: 导入恢复
    static func importBackup() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json]
        panel.message = "选择之前导出的「教师助手备份_….json」文件"
        PanelHelper.prepare()
        PanelHelper.bringFront(panel)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let container = try JSONDecoder().decode(Container.self, from: data)
            guard container.app == "ScheduleBar" else {
                showAlert("不是有效的备份文件", "该文件不是教师助手导出的备份。")
                return
            }

            // 1) 写回数据文件
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            for (name, text) in container.files {
                // 只接受纯文件名，防路径穿越
                guard !name.contains("/"), name.hasSuffix(".json") else { continue }
                try text.data(using: .utf8)?.write(to: dataDir.appendingPathComponent(name), options: .atomic)
            }

            // 2) 恢复设置域
            if let bid = Bundle.main.bundleIdentifier {
                var domain: [String: Any] = [:]
                for (k, xml) in container.defaults {
                    if let d = xml.data(using: .utf8),
                       let v = try? PropertyListSerialization.propertyList(from: d, format: nil) {
                        domain[k] = v
                    }
                }
                UserDefaults.standard.setPersistentDomain(domain, forName: bid)
                UserDefaults.standard.synchronize()
            }

            SeatingStore.seatLog("备份：已恢复 \(container.files.count) 个数据文件 + \(container.defaults.count) 项设置（来自 \(url.lastPathComponent)），即将重启生效")
            let a = NSAlert()
            a.messageText = "恢复完成"
            a.informativeText = "已恢复 \(container.files.count) 个数据文件和 \(container.defaults.count) 项设置。\n点击「立即重启」让数据生效。"
            a.addButton(withTitle: "立即重启")
            a.addButton(withTitle: "稍后手动重启")
            PanelHelper.prepare()
            PanelHelper.bringFront(a)
            if a.runModal() == .alertFirstButtonReturn { restartApp() }
        } catch {
            SeatingStore.seatLog("备份：恢复失败 \(error.localizedDescription)")
            showAlert("恢复失败", error.localizedDescription)
        }
    }

    /// 退出并重新启动应用（重启后各 Store 重新从磁盘加载数据）
    static func restartApp() {
        let bundlePath = Bundle.main.bundleURL.path
        if FileManager.default.fileExists(atPath: bundlePath) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 0.6; open \"\(bundlePath)\""]
            try? p.run()
        }
        NSApp.terminate(nil)
    }

    private static func showAlert(_ title: String, _ msg: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = msg
        PanelHelper.prepare()
        PanelHelper.bringFront(a)
        a.runModal()
    }
}
