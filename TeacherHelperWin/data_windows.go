//go:build windows

// 数据层：与 macOS 版**完全共用同一套 JSON**（文件名、字段名一字不差）。
// 数据目录优先级：
//  1. 环境变量 SCHEDULEBAR_DATA_DIR（调试用）
//  2. exe 同目录下的 data\（便携模式：拷 U 盘/机房直接跑）
//  3. %APPDATA%\ScheduleBar\（默认）
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

// 与 macOS 版一致的 17 个数据文件
var dataFiles = []string{
	"personal.json",          // 我的课表（grid + groups）
	"class7.json",            // 班级课表（旧单班格式，兼容）
	"classes.json",           // 班级课表（多班 + 题库 bank）
	"teacher_schedules.json", // 他人课表
	"extend.json",            // 延时/监考
	"students.json",          // 学生信息
	"seating.json",           // 学生座位
	"reminders.json",         // 日程提醒
	"week.json",              // 第 1 周开始日
	"calendar_remarks.json",  // 校历备注（周/日/事件）
	"calendar_day_colors.json", // 校历日期颜色
	"calendar_events.json",   // 系统日历事件 id 映射（Windows 版仅保留，不写）
	"staff.json",             // 年级师资
	"offices.json",           // 教师工位
	"classrooms.json",        // 教室布局
	"titles.json",            // 板块改名
	"nav_prefs.json",         // 左栏顺序 / 隐藏
}

var validFile = regexp.MustCompile(`^[A-Za-z0-9_\-]+\.json$`)

type store struct {
	mu  sync.Mutex
	dir string
}

var db = &store{}

// resolveDataDir 决定数据目录，并保证存在
func (s *store) resolve() string {
	if s.dir != "" {
		return s.dir
	}
	if env := strings.TrimSpace(os.Getenv("SCHEDULEBAR_DATA_DIR")); env != "" {
		s.dir = env
	} else if exe, err := os.Executable(); err == nil {
		portable := filepath.Join(filepath.Dir(exe), "data")
		if st, err := os.Stat(portable); err == nil && st.IsDir() {
			s.dir = portable
		}
	}
	if s.dir == "" {
		if appdata := os.Getenv("APPDATA"); appdata != "" {
			s.dir = filepath.Join(appdata, "ScheduleBar")
		} else {
			s.dir = filepath.Join(os.TempDir(), "ScheduleBar")
		}
	}
	_ = os.MkdirAll(s.dir, 0o755)
	s.seedIfEmpty()
	return s.dir
}

func (s *store) path(name string) string { return filepath.Join(s.resolve(), name) }

// Read 读单个文件（不存在返回 nil, false）
func (s *store) Read(name string) ([]byte, bool) {
	b, err := os.ReadFile(s.path(name))
	if err != nil {
		return nil, false
	}
	return b, true
}

// ReadJSON 读单个文件并解析（解析失败返回 nil）
func (s *store) ReadJSON(name string) interface{} {
	b, ok := s.Read(name)
	if !ok {
		return nil
	}
	var v interface{}
	if json.Unmarshal(b, &v) != nil {
		return nil
	}
	return v
}

// All 打包所有数据文件（给前端一次性取走）
func (s *store) All() map[string]interface{} {
	out := make(map[string]interface{}, len(dataFiles))
	for _, f := range dataFiles {
		out[f] = s.ReadJSON(f)
	}
	// 顺带带上目录里其它 json（未来扩展的 store），保持与 macOS 侧同步可见
	if entries, err := os.ReadDir(s.resolve()); err == nil {
		for _, e := range entries {
			n := e.Name()
			if e.IsDir() || !strings.HasSuffix(n, ".json") {
				continue
			}
			if _, done := out[n]; done {
				continue
			}
			out[n] = s.ReadJSON(n)
		}
	}
	return out
}

// Write 原子写单个文件（先写 .tmp 再 rename），并留一份 .bak 轮转备份
func (s *store) Write(name string, body []byte) error {
	if !validFile.MatchString(name) {
		return fmt.Errorf("非法文件名: %s", name)
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	dir := s.resolve()
	var v interface{}
	if err := json.Unmarshal(body, &v); err != nil {
		return fmt.Errorf("不是合法 JSON：%v", err)
	}
	// 统一用 2 空格缩进 + 保留中文（与 macOS 版可读性一致）
	pretty, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	dst := filepath.Join(dir, name)
	tmp := dst + ".tmp"
	if err := os.WriteFile(tmp, pretty, 0o644); err != nil {
		return err
	}
	if old, err := os.ReadFile(dst); err == nil {
		_ = os.WriteFile(dst+".bak", old, 0o644)
	}
	return os.Rename(tmp, dst)
}

// seedIfEmpty：首次运行（无任何数据文件）时写入与 macOS 版默认值一致的最小结构，
// 保证界面能正常渲染；用户把 macOS 的 17 个 json 拷进来后即完全接管。
func (s *store) seedIfEmpty() {
	dir := s.dir
	entries, err := os.ReadDir(dir)
	if err == nil {
		for _, e := range entries {
			if strings.HasSuffix(e.Name(), ".json") {
				return // 已有数据，不动
			}
		}
	}
	seed := map[string]string{
		"titles.json":         `{"personal":"我的课表","class":"班级课表","extend":"延时/周日/监考","office":"教师工位","nav_本人课表":"我的课表","nav_延时监考":"延时监考","nav_班级课表":"班级课表","nav_他人课表":"他人课表","nav_学生信息":"学生信息","nav_学生座位":"学生座位","nav_日程提醒":"定时提醒","nav_校历日历":"校历日历","nav_年级师资":"年级师资","nav_教师工位":"教师工位","nav_教室布局":"教室布局"}`,
		"nav_prefs.json":      `{"order":["本人课表","延时监考","班级课表","他人课表","学生信息","学生座位","日程提醒","校历日历","年级师资","教师工位","教室布局"],"hidden":[]}`,
		"week.json":           `"2026-08-31"`,
		"personal.json":       `{"grid":[["","","","","","",""],["","","","","","",""],["","","","","","",""],["","","","","","",""],["","","","","","",""],["","","","","","",""],["","","","","","",""],["","","","","","",""],["","","","","","",""],["","","","","","",""],["","","","","","",""]],"groups":[{"title":"上午","periods":["早自习","第1节","第2节","第3节","第4节","第5节"]},{"title":"下午","periods":["第6节","第7节","第8节","第9节"]},{"title":"晚自习","periods":["晚自习"]}]}`,
		"students.json":       `{"headers":["序号","姓名","原班级","备注","性别","民族","身份证号码","所属省市","出生日期","年龄","住址","监护人1","监护人1电话","监护人2","监护人2电话","残疾","特殊疾病","单亲","贫困或父母有残疾","智学网账号"],"rows":[]}`,
		"staff.json":          `{"headers":["班级","班主任","班型","语文","英语","政治","历史","数学","物理","化学","体育"],"rows":[]}`,
		"seating.json":        `{"version":1,"grid":[],"pool":[],"genders":{},"podium":{"row":0,"col":0,"span":3}}`,
		"reminders.json":      `[]`,
		"extend.json":         `[]`,
		"offices.json":        `[]`,
		"classrooms.json":     `[]`,
		"classes.json":        `{"defaultClass":"","bank":{},"classes":[]}`,
		"calendar_remarks.json": `{}`,
		"calendar_day_colors.json": `{}`,
		"calendar_events.json": `{}`,
	}
	names := make([]string, 0, len(seed))
	for k := range seed {
		names = append(names, k)
	}
	sort.Strings(names)
	for _, n := range names {
		_ = os.WriteFile(filepath.Join(dir, n), []byte(seed[n]), 0o644)
	}
	logf("首次运行：已在 %s 写入默认数据结构", dir)
}

// ---- 备份：每次 Write 已留 .bak；这里再提供「每日快照」供误操作回滚 ----

func (s *store) snapshot() {
	dir := s.resolve()
	day := time.Now().Format("2006-01-02")
	backupDir := filepath.Join(dir, "backups", day)
	if _, err := os.Stat(backupDir); err == nil {
		return // 今天已快照
	}
	if err := os.MkdirAll(backupDir, 0o755); err != nil {
		return
	}
	for _, f := range dataFiles {
		if b, ok := s.Read(f); ok {
			_ = os.WriteFile(filepath.Join(backupDir, f), b, 0o644)
		}
	}
	logf("已创建每日快照：%s", backupDir)
}
