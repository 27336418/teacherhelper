import SwiftUI

// MARK: - 颜色工具

extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, opacity: opacity)
    }

    /// 从 hex 字符串创建（如 "E74C3C" / "FFE27A"）；解析失败回退中性灰
    init(hexString s: String?, opacity: Double = 1.0) {
        guard var hex = s, !hex.isEmpty else { self = Color(hex: 0x95A5A6, opacity: opacity); return }
        hex = hex.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        if let v = UInt32(hex, radix: 16) {
            self = Color(hex: v, opacity: opacity)
        } else {
            self = Color(hex: 0x95A5A6, opacity: opacity)
        }
    }
}

// MARK: - 全局配色（校历 / 当前周高亮 / 学期等共用）

/// 当前周高亮：行底淡黄 + 周数文字深琥珀
let weekRowYellow = Color(hex: 0xFFE27A)
let weekAmber     = Color(hex: 0x9A6700)

/// 学期强调色：第一学期暖橙、第二学期青绿
let semester1Color = Color(hex: 0xE67E22)
let semester2Color = Color(hex: 0x2FA37C)

// MARK: - 班级配色（个人课表用：不同班级 → 不同颜色）

/// 数字班调色板（按班号取色，相邻班号颜色差异大）
private let classPalette: [UInt32] = [
    0x16A085, 0xE67E22, 0x3498DB, 0xE74C3C, 0x8E44AD, 0x27AE60,
    0xF39C12, 0x2980B9, 0xD35400, 0x1ABC9C, 0xC0392B, 0x9B59B6,
    0x2C3E50, 0xE84393, 0x00897B, 0x5D4037, 0x3949AB, 0x7CB342,
    0xFB8C00, 0x00ACC1, 0x8D6E63, 0x6A1B9A, 0x2E7D32, 0x0277BD,
]

/// 非数字班的固定色（巡课等）
private let classFixedColors: [String: UInt32] = [
    "巡1-15班": 0x8E44AD,
    "巡1-15":   0x8E44AD,
    "巡16-30":  0x2980B9,
    "巡16-30班": 0x2980B9,
]

/// 单元格 → 班级标识列表（"7" → ["7班"]；"7/巡16-30" → ["7班", "巡16-30"]）
func classTokens(_ text: String) -> [String] {
    let t = text.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty else { return [] }
    let seps: [Character] = ["/", "／", "+", "＋", "&", ",", "，", "、", "\n", "\t"]
    var parts: [String] = []
    var cur = ""
    for ch in t {
        if seps.contains(ch) {
            if !cur.isEmpty { parts.append(cur); cur = "" }
        } else {
            cur.append(ch)
        }
    }
    if !cur.isEmpty { parts.append(cur) }

    var out: [String] = []
    for p in parts {
        let n = normalizeClass(p)
        if !n.isEmpty && !out.contains(n) { out.append(n) }
    }
    return out
}

/// 规范化班级标识："7" / "7班" → "7班"；"巡16-30" 保留原样
private func normalizeClass(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespaces)
    guard !s.isEmpty else { return "" }
    if s.hasPrefix("巡") { return s }
    if s.hasSuffix("班") { s.removeLast() }
    if let n = Int(s), n > 0 { return "\(n)班" }
    return s                                  // 其他自定义文字（如「合班」）
}

/// 单个班级标识 → 颜色（带缓存）
private var classColorCache: [String: Color] = [:]

func classTokenColor(_ token: String) -> Color {
    if let c = classColorCache[token] { return c }
    let c = computeClassColor(token)
    classColorCache[token] = c
    return c
}

private func computeClassColor(_ token: String) -> Color {
    if let hex = classFixedColors[token] { return Color(hex: hex) }
    var s = token
    if s.hasSuffix("班") { s.removeLast() }
    if let n = Int(s), n > 0 {
        return Color(hex: classPalette[(n - 1) % classPalette.count])
    }
    // 巡课 / 自定义文字：稳定 DJB2 哈希取色（同一文本每次启动颜色一致）
    var h: UInt64 = 5381
    for u in token.utf8 { h = ((h &<< 5) &+ h) &+ UInt64(u) }
    return Color(hex: classPalette[Int(h % UInt64(classPalette.count))])
}

/// 单元格主色（第一个班级标识的颜色）
func classColor(_ text: String) -> Color {
    guard let first = classTokens(text).first else { return Color(hex: 0x95A5A6) }
    return classTokenColor(first)
}

/// 单元格全部班级色（≥2 个时渲染为左右渐变，一眼看出是合班/跨班）
func classColors(_ text: String) -> [Color] {
    classTokens(text).map { classTokenColor($0) }
}

/// 「同班级高亮」比较键：7 / 7班 / 7/巡… 都归为 "7班"
func classKey(_ text: String) -> String {
    classTokens(text).first ?? ""
}

// MARK: - 课程调色板（7班课表用：相同课程=相同颜色）

/// 固定课程→颜色映射：常见课程用直觉色，新增课程再用稳定哈希分配
private let courseFixedColors: [String: UInt32] = [
    "数学":   0x3498DB,  // 蓝
    "语文":   0xE74C3C,  // 红
    "英语":   0x9B59B6,  // 紫
    "物理":   0x1ABC9C,  // 青
    "化学":   0x27AE60,  // 绿
    "历史":   0xF39C12,  // 橙黄
    "政治":   0xC0392B,  // 暗红
    "生物":   0x16A085,  // 蓝绿
    "地理":   0x2980B9,  // 钢蓝
    "体育":   0xE67E22,  // 橙
    "足球":   0xD35400,  // 暗橙
    "篮球":   0xE84393,  // 玫红
    "音乐":   0x8E44AD,  // 深紫
    "美术":   0x2C3E50,  // 墨蓝
    "教工会": 0x34495E,  // 深蓝灰
    "班会":   0x8E44AD,  // 深紫
    "延时":   0x7F8C8D,  // 灰
    "班主任": 0xF1C40F,  // 金黄
]

private let coursePalette: [Color] = [
    Color(hex: 0x3498DB), Color(hex: 0xE74C3C), Color(hex: 0x9B59B6), Color(hex: 0x1ABC9C),
    Color(hex: 0x27AE60), Color(hex: 0xF39C12), Color(hex: 0xC0392B), Color(hex: 0xE67E22),
    Color(hex: 0xD35400), Color(hex: 0x34495E), Color(hex: 0x8E44AD), Color(hex: 0x7F8C8D),
    Color(hex: 0xF1C40F), Color(hex: 0x16A085), Color(hex: 0x2980B9), Color(hex: 0x2C3E50),
]

/// 提取课程名（如 "语文·于理想" → "语文"），用于判断两个单元格是否同一科目
func courseKey(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    let separators: [Character] = ["·", "\n", "\r", "/", " ", "　", "（", "(", "【", "["]
    var course = trimmed
    for sep in separators {
        if let idx = course.firstIndex(of: sep) {
            course = String(course[..<idx])
        }
    }
    return course.trimmingCharacters(in: .whitespaces)
}

/// 按课程名着色：先按固定映射；新增课程用稳定 DJB2 哈希分配（带缓存，避免滚动时反复计算）
private var courseColorCache: [String: Color] = [:]

func courseColor(_ text: String) -> Color {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return Color(hex: 0x95A5A6) }
    if let cached = courseColorCache[trimmed] { return cached }
    let color = computeCourseColor(trimmed)
    courseColorCache[trimmed] = color
    return color
}

private func computeCourseColor(_ trimmed: String) -> Color {
    let separators: [Character] = ["·", "\n", "\r", "/", " ", "　", "（", "(", "【", "["]
    var course = trimmed
    for sep in separators {
        if let idx = course.firstIndex(of: sep) {
            course = String(course[..<idx])
        }
    }
    course = course.trimmingCharacters(in: .whitespaces)
    if course.isEmpty { return Color(hex: 0x95A5A6) }
    if let hex = courseFixedColors[course] {
        return Color(hex: hex)
    }
    // 稳定 DJB2 哈希（Swift 的 hashValue 每次启动会变，不能用于持久化颜色映射）
    var h: UInt64 = 5381
    for u in course.utf8 {
        h = ((h &<< 5) &+ h) &+ UInt64(u)
    }
    return coursePalette[Int(h % UInt64(coursePalette.count))]
}
