import Foundation

// MARK: - 学生信息内置默认数据（已清空，发给别人安装时让对方自己导入 xlsx 填写）
// 仅保留表头 22 列作为新表的初始列；无本地 students.json 时加载这里的空数据。
enum StudentDefaultData {
    static let headers: [String] = [
        "序号", "新班级", "新班主任", "姓名", "原班级", "备注", "性别", "民族", "身份证号码", "所属省市", "出生日期", "年龄", "住址", "监护人1", "监护人1电话", "监护人2", "监护人2电话", "残疾", "特殊疾病", "单亲", "贫困或父母有残疾", "智学网账号"
    ]

    static let rows: [[String]] = []
}
