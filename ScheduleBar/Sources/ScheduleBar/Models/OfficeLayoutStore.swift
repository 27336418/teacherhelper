import Foundation
import SwiftUI

// MARK: - 办公室工位布局（多间办公室，每间 = 标题 + 左门/右门 + 4 列座位 × N 行；可编辑）
// 持久化 offices.json。

struct OfficeBlock: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var seats: [[String]]        // 行 × 4 列座位
    var seatColors: [String: String] = [:]   // "行-列" → 自定义颜色 hex（如 "2-3" → "3498DB"）

    init(id: UUID = UUID(), title: String, seats: [[String]],
         seatColors: [String: String] = [:]) {
        self.id = id
        self.title = title
        self.seats = seats
        self.seatColors = seatColors
    }

    // 旧版 offices.json 无 seatColors 字段 → 默认空字典
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        seats = try c.decode([[String]].self, forKey: .seats)
        seatColors = try c.decodeIfPresent([String: String].self, forKey: .seatColors) ?? [:]
    }

    /// 某座位的自定义颜色（无则 nil）
    func seatColor(row r: Int, col c: Int) -> String? {
        seatColors["\(r)-\(c)"]
    }

    mutating func setSeatColor(_ hex: String?, row r: Int, col c: Int) {
        let key = "\(r)-\(c)"
        if let hex, !hex.isEmpty {
            seatColors[key] = hex
        } else {
            seatColors.removeValue(forKey: key)
        }
    }
}

final class OfficeLayoutStore: ObservableObject {
    static let shared = OfficeLayoutStore()

    @Published var offices: [OfficeBlock] {
        didSet { save() }
    }

    init() {
        self.offices = OfficeLayoutStore.load() ?? OfficeLayoutStore.defaults()
    }

    static let seatColumns = 4

    func addOffice() {
        offices.append(OfficeBlock(title: "新办公室", seats: Array(repeating: Array(repeating: "", count: Self.seatColumns), count: 4)))
    }
    func removeOffice(_ id: UUID) {
        let snap = offices
        let title = offices.first(where: { $0.id == id })?.title ?? ""
        offices.removeAll { $0.id == id }
        UndoService.shared.register("删除\(title.isEmpty ? "办公室" : "「\(title)」")") { [weak self] in
            guard let self else { return }
            self.offices = snap
            self.save()
        }
    }
    func addRow(_ officeID: UUID) {
        guard let i = offices.firstIndex(where: { $0.id == officeID }) else { return }
        offices[i].seats.append(Array(repeating: "", count: Self.seatColumns))
    }
    func removeRow(_ officeID: UUID, _ r: Int) {
        guard let i = offices.firstIndex(where: { $0.id == officeID }),
              offices[i].seats.count > 1 else { return }
        let snap = offices
        offices[i].seats.remove(at: r)
        UndoService.shared.register("删除工位行") { [weak self] in
            guard let self else { return }
            self.offices = snap
            self.save()
        }
    }

    // MARK: 默认数据（已固化为当前填写的数据，见 DefaultData.swift）
    static func defaults() -> [OfficeBlock] {
        return DefaultData.offices
    }

    // 早期预置数据（保留备用）
    static func presetOffices() -> [OfficeBlock] {
        [
            OfficeBlock(title: "X406办公室", seats: [
                ["12李诗语", "8冯鑫", "4王倩", "1柯娜娜"],
                ["13季富容", "9巫松", "5李丹", "2张竞丹"],
                ["14邓瑞珍", "10谭超", "6罗宇婷", "3朱先明"],
                ["15陆遥", "11周伟", "7聂思源", "水池"],
            ]),
            OfficeBlock(title: "初三S507办公室工位图", seats: [
                ["12陈永珍", "8邓雨蒙", "4李炎鸿", "1余燕"],
                ["13赵悦婷", "9陈雯雯", "5罗鑫", "2林科"],
                ["14李圆圆", "10易海燕", "6谭海连", "3王欢欢"],
                ["15官连浇", "11潘桃", "7刘庆超", "水池"],
            ]),
            OfficeBlock(title: "初三X506办公室工位图", seats: [
                ["12蔡亚南", "8魏静宜", "4詹道亮", "1于理想"],
                ["13袁欣茹", "9鲍思敏", "5刘璐", "2石玉霞"],
                ["14李琳", "10石桃", "6李雨阳", "3张静"],
                ["15李记", "11刘莉名", "7孙正", "水池"],
            ]),
            OfficeBlock(title: "初三z506办公室工位图", seats: [
                ["", "5代课周濛", "9陈乐怡", "13王淑慧"],
                ["2柳叶", "6刘梦涵", "10高兴", "14高筱杰"],
                ["3赖炳霖", "7王顺娜", "11刘东梅", "15张钊然"],
                ["4冉钦产假", "8范镔玲", "12陈坤权", "陈婷"],
            ]),
            OfficeBlock(title: "初三X406办公室工位图", seats: [
                ["1张苑琳", "杜著洋", "", "罗勇"],
                ["顾军", "6李晨曦", "", "13李毅"],
                ["3鞠在东", "蒋颖", "曹人予", "14于冰凌"],
                ["4王路曦", "", "水池", "15王雪梅"],
            ]),
            OfficeBlock(title: "初三Z505办公室工位图", seats: [
                ["1（空）", "5（陈方蕤）", "", ""],
                ["2王丹虹", "6俞子格", "", ""],
                ["3黄小桐", "", "", ""],
                ["4骆金辉", "8毛瑶瑶", "", ""],
            ]),
        ]
    }

    // MARK: 持久化
    func save() {
        do {
            let url = Self.fileURL()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(offices).write(to: url, options: .atomic)
        } catch {
            print("[ScheduleBar] 工位保存失败: \(error)")
        }
    }

    static func load() -> [OfficeBlock]? {
        guard let data = try? Data(contentsOf: fileURL()) else { return nil }
        return try? JSONDecoder().decode([OfficeBlock].self, from: data)
    }

    static func fileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ScheduleBar", isDirectory: true)
                  .appendingPathComponent("offices.json")
    }
}
