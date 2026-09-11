import Foundation

// MARK: - 中国大陆身份证号校验（GB 11643-1999）
// 支持 18 位（含末位校验码 X）与 15 位旧版；空串返回 nil（不校验）。
enum IdCardValidator {
    struct Result {
        let valid: Bool
        let message: String   // 供 tooltip 提示
    }

    private static let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
    private static let checkChars = Array("10X98765432")

    /// nil = 空串（不做校验）；valid=false 时 message 说明原因
    static func validate(_ raw: String) -> Result? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }

        switch s.count {
        case 18:
            return validate18(s)
        case 15:
            return validate15(s)
        default:
            return Result(valid: false, message: "长度应为 15 或 18 位，当前 \(s.count) 位")
        }
    }

    // MARK: 18 位
    private static func validate18(_ s: String) -> Result {
        let prefix = String(s.prefix(17))
        guard prefix.allSatisfy(\.isNumber) else {
            return Result(valid: false, message: "前 17 位必须为数字")
        }
        guard let last = s.last, last.isNumber || last == "X" else {
            return Result(valid: false, message: "末位校验码必须为数字或 X")
        }
        // 出生日期（第 7~14 位 yyyyMMdd）
        let y = String(s.dropFirst(6).prefix(4))
        let m = String(s.dropFirst(10).prefix(2))
        let d = String(s.dropFirst(12).prefix(2))
        guard isValidDate(y: y, m: m, d: d) else {
            return Result(valid: false, message: "出生日期 \(y)-\(m)-\(d) 不合法")
        }
        // 校验码
        var sum = 0
        for (ch, w) in zip(prefix, weights) {
            sum += (ch.wholeNumberValue ?? 0) * w
        }
        let expect = checkChars[sum % 11]
        if expect == last {
            return Result(valid: true, message: "身份证号有效")
        }
        return Result(valid: false, message: "校验码错误：应为 \(expect)，实际为 \(last)")
    }

    // MARK: 15 位（无校验码；出生日期 yyMMdd）
    private static func validate15(_ s: String) -> Result {
        guard s.allSatisfy(\.isNumber) else {
            return Result(valid: false, message: "15 位身份证必须全为数字")
        }
        let yy = String(s.dropFirst(6).prefix(2))
        let m = String(s.dropFirst(8).prefix(2))
        let d = String(s.dropFirst(10).prefix(2))
        guard let yyNum = Int(yy) else {
            return Result(valid: false, message: "出生年份不合法")
        }
        let cal = Calendar.current
        let curYY = cal.component(.year, from: Date()) % 100
        let year = (yyNum <= curYY) ? 2000 + yyNum : 1900 + yyNum
        guard isValidDate(y: String(year), m: m, d: d) else {
            return Result(valid: false, message: "出生日期 \(year)-\(m)-\(d) 不合法")
        }
        return Result(valid: true, message: "15 位旧版身份证，格式有效")
    }

    /// 校验 yyyy / mm / dd 是否为合法公历日期
    private static func isValidDate(y: String, m: String, d: String) -> Bool {
        guard y.count == 4, m.count == 2, d.count == 2,
              let yy = Int(y), let mm = Int(m), let dd = Int(d) else { return false }
        guard (1900...2100).contains(yy), (1...12).contains(mm) else { return false }
        let daysInMonth: [Int] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        var maxDay = daysInMonth[mm - 1]
        if mm == 2 {
            let leap = (yy % 4 == 0 && yy % 100 != 0) || yy % 400 == 0
            if leap { maxDay = 29 }
        }
        return (1...maxDay).contains(dd)
    }
}
