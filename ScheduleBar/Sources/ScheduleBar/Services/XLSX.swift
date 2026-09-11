import Foundation

// MARK: - 极简 XLSX 读写（无第三方依赖）
// 读：调用系统 unzip 解包后解析 XML
// 写：生成最小合法 xlsx 并用系统 zip 打包

enum XLSXError: LocalizedError {
    case invalidFile
    case parseFailed
    case writeFailed
    var errorDescription: String? {
        switch self {
        case .invalidFile: return "无法读取 Excel 文件"
        case .parseFailed: return "解析 Excel 失败"
        case .writeFailed: return "写入 Excel 失败"
        }
    }
}

struct XLSX {
    // MARK: 读取第一个工作表 -> 二维数组（行 × 列），空单元格为 ""
    static func read(_ url: URL) throws -> [[String]] {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("xlsx_in_\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-o", "-q", url.path, "-d", tmp.path]
        try unzip.run(); unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw XLSXError.invalidFile }

        var shared: [String] = []
        if let ssData = FileManager.default.contents(atPath: tmp.appendingPathComponent("xl/sharedStrings.xml").path),
           let ssStr = String(data: ssData, encoding: .utf8) {
            shared = parseSharedStrings(ssStr)
        }
        guard let sheetData = FileManager.default.contents(atPath: tmp.appendingPathComponent("xl/worksheets/sheet1.xml").path),
              let sheetStr = String(data: sheetData, encoding: .utf8) else {
            throw XLSXError.parseFailed
        }
        let map = parseCells(sheetStr, shared: shared)

        var maxRow = 0, maxCol = 0
        for (ref, _) in map {
            let (c, r) = coord(of: ref)
            maxCol = max(maxCol, c); maxRow = max(maxRow, r)
        }
        guard maxRow > 0 else { return [] }
        var grid = Array(repeating: Array(repeating: "", count: max(maxCol, 1)), count: maxRow)
        for (ref, val) in map where !val.isEmpty {
            let (c, r) = coord(of: ref)
            grid[r - 1][c - 1] = val
        }
        return grid
    }

    // MARK: 写出二维数组为 xlsx
    static func write(_ rows: [[String]], to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("xlsx_out_\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var sheetRows = ""
        for (rIdx, row) in rows.enumerated() {
            let r = rIdx + 1
            var cells = ""
            for (cIdx, val) in row.enumerated() {
                let ref = letters(cIdx + 1) + String(r)
                let esc = val.replacingOccurrences(of: "&", with: "&amp;")
                            .replacingOccurrences(of: "<", with: "&lt;")
                            .replacingOccurrences(of: ">", with: "&gt;")
                cells += #"<c r="\#(ref)" t="inlineStr"><is><t xml:space="preserve">\#(esc)</t></is></c>"#
            }
            sheetRows += #"<row r="\#(r)">\#(cells)</row>"#
        }
        let sheet = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\#(sheetRows)</sheetData></worksheet>"#
        let wsDir = tmp.appendingPathComponent("xl").appendingPathComponent("worksheets")
        try FileManager.default.createDirectory(at: wsDir, withIntermediateDirectories: true)
        try sheet.write(to: wsDir.appendingPathComponent("sheet1.xml"), atomically: true, encoding: .utf8)

        let contentTypes = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>"#
        let rels = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#
        let workbook = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="课表" sheetId="1" r:id="rId1"/></sheets></workbook>"#
        let wbRels = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>"#

        let xl = tmp.appendingPathComponent("xl")
        let tmpRels = tmp.appendingPathComponent("_rels")
        try FileManager.default.createDirectory(at: xl, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: xl.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmpRels, withIntermediateDirectories: true)
        try contentTypes.write(to: tmp.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try rels.write(to: tmp.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)
        try workbook.write(to: xl.appendingPathComponent("workbook.xml"), atomically: true, encoding: .utf8)
        try wbRels.write(to: xl.appendingPathComponent("_rels/workbook.xml.rels"), atomically: true, encoding: .utf8)

        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-r", "-X", "-q", url.path, "."]
        zip.currentDirectoryURL = tmp
        try zip.run(); zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw XLSXError.writeFailed }
    }

    // MARK: - 解析辅助
    private static func parseSharedStrings(_ xml: String) -> [String] {
        var out: [String] = []
        let siRe = try! NSRegularExpression(pattern: #"<si>(.*?)</si>"#, options: [.dotMatchesLineSeparators])
        let sis = siRe.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
        for m in sis {
            guard let r = Range(m.range(at: 1), in: xml) else { continue }
            let si = String(xml[r])
            let tRe = try! NSRegularExpression(pattern: #"<t[^>]*>(.*?)</t>"#, options: [.dotMatchesLineSeparators])
            let ts = tRe.matches(in: si, range: NSRange(si.startIndex..., in: si))
            var s = ""
            for tm in ts {
                if let tr = Range(tm.range(at: 1), in: si) { s += String(si[tr]) }
            }
            out.append(decodeEntities(s))
        }
        return out
    }

    /// 还原 XML 实体：&#10; 之类的换行引用必须解出来，否则单元格里的换行会变成字面量
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        out = out.replacingOccurrences(of: "&lt;", with: "<")
        out = out.replacingOccurrences(of: "&gt;", with: ">")
        out = out.replacingOccurrences(of: "&quot;", with: "\"")
        out = out.replacingOccurrences(of: "&apos;", with: "'")
        out = out.replacingOccurrences(of: "&amp;", with: "&")
        if out.contains("&#"), let re = try? NSRegularExpression(pattern: "&#(x?)([0-9A-Fa-f]+);") {
            let src = out as NSString
            let ms = re.matches(in: out, range: NSRange(location: 0, length: src.length))
            let result = NSMutableString(string: out)
            for m in ms.reversed() {
                let isHex = src.substring(with: m.range(at: 1)) == "x"
                let numStr = src.substring(with: m.range(at: 2))
                guard let code = UInt32(numStr, radix: isHex ? 16 : 10),
                      let scalar = UnicodeScalar(code) else { continue }
                result.replaceCharacters(in: m.range, with: String(Character(scalar)))
            }
            out = result as String
        }
        return out
    }

    private static func parseCells(_ xml: String, shared: [String]) -> [String: String] {
        var map: [String: String] = [:]
        // 仅匹配 <c> 起始标签；内容单独截取，避免自闭合空单元格 <c .../> 造成错位
        let cRe = try! NSRegularExpression(pattern: #"<c\s+r="([A-Z]+\d+)"([^>]*)>"#, options: [])
        let ms = cRe.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
        for m in ms {
            let ref = xml.substring(m.range(at: 1))
            let attrs = xml.substring(m.range(at: 2))
            // 自闭合空单元格（只有样式没有值）跳过
            if xml.substring(m.range(at: 0)).hasSuffix("/>") { continue }
            guard let openRange = Range(m.range(at: 0), in: xml) else { continue }
            let rest = String(xml[openRange.upperBound...])
            guard let closeRange = rest.range(of: "</c>") else { continue }
            let inner = String(rest[..<closeRange.lowerBound])
            var value = ""
            if let vm = inner.range(of: #"<v>(.*?)</v>"#, options: .regularExpression) {
                value = inner.substring(NSRange(vm, in: inner))
                value = value.replacingOccurrences(of: "<v>", with: "")
                             .replacingOccurrences(of: "</v>", with: "")
            }
            if value.isEmpty {
                if let im = inner.range(of: #"<t[^>]*>(.*?)</t>"#, options: .regularExpression) {
                    var t = inner.substring(NSRange(im, in: inner))
                    t = t.replacingOccurrences(of: #"<t[^>]*>"#, with: "", options: .regularExpression)
                           .replacingOccurrences(of: "</t>", with: "")
                    value = decodeEntities(t)
                }
            }
            if attrs.contains(#"t="s""#), let idx = Int(value), idx < shared.count {
                value = shared[idx]
            }
            if !value.isEmpty { map[ref] = value }
        }
        return map
    }

    private static func coord(of ref: String) -> (col: Int, row: Int) {
        var i = ref.startIndex
        var colStr = "", rowStr = ""
        while i < ref.endIndex, ref[i].isLetter { colStr.append(ref[i]); i = ref.index(after: i) }
        while i < ref.endIndex, ref[i].isNumber { rowStr.append(ref[i]); i = ref.index(after: i) }
        return (colFromLetters(colStr), Int(rowStr) ?? 0)
    }

    private static func colFromLetters(_ s: String) -> Int {
        var n = 0
        for ch in s { n = n * 26 + (Int(ch.asciiValue ?? 65) - 64) }
        return n
    }

    private static func letters(_ n: Int) -> String {
        var n = n, s = ""
        while n > 0 {
            let rem = (n - 1) % 26
            s = String(Character(UnicodeScalar(65 + rem)!)) + s
            n = (n - 1) / 26
        }
        return s
    }
}

extension String {
    func substring(_ range: NSRange) -> String {
        if let r = Range(range, in: self) { return String(self[r]) }
        return ""
    }
}
