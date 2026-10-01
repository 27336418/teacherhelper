// 与平台无关的纯逻辑：提醒判定规则、周次计算、日志。
// 放在无 build tag 的文件里 → 可以在 macOS 上直接 `go test` 验证规则正确性
// （Windows 专有代码在 *_windows.go 里，见那些文件的说明）。
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// ---------- 日志 ----------

var logPath string

// logf 追加一行日志（%LOCALAPPDATA%\ScheduleBar\log.txt 或 exe 同目录）
func logf(format string, args ...interface{}) {
	if logPath == "" {
		base := os.Getenv("LOCALAPPDATA")
		if base == "" {
			if exe, err := os.Executable(); err == nil {
				base = filepath.Dir(exe)
			} else {
				base = os.TempDir()
			}
		}
		dir := filepath.Join(base, "ScheduleBar")
		_ = os.MkdirAll(dir, 0o755)
		logPath = filepath.Join(dir, "log.txt")
	}
	f, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "[%s] %s\n", time.Now().Format("2006-01-02 15:04:05"), fmt.Sprintf(format, args...))
}

// ---------- 提醒模型（字段名与 macOS 版逐一对齐） ----------

type Reminder struct {
	ID          string  `json:"id"`
	Title       string  `json:"title"`
	Hour        int     `json:"hour"`
	Minute      int     `json:"minute"`
	Weekdays    []int   `json:"weekdays"`
	URL         string  `json:"url"`
	OneShotDay  *string `json:"oneShotDay,omitempty"`
	LongCycle   *string `json:"longCycle,omitempty"` // monthly / halfYearly / yearly
	FiredOn     *string `json:"firedOn,omitempty"`   // 历史字段（macOS 2.5.10 起退役，仅保留读写）
	CompletedOn *string `json:"completedOn,omitempty"`
}

const dayLayout = "2006-01-02"

func dayString(t time.Time) string { return t.Format(dayLayout) }

// IsOneShot：没勾星期、也没长周期 = 一次性提醒
func (r Reminder) IsOneShot() bool { return len(r.Weekdays) == 0 && r.LongCycle == nil }

// IsCompleted：点过「马上处理」才算完成（与 macOS 2.5.9 起的语义一致）
func (r Reminder) IsCompleted() bool { return r.IsOneShot() && r.CompletedOn != nil }

func (r Reminder) fires(weekday int) bool {
	for _, w := range r.Weekdays {
		if w == weekday {
			return true
		}
	}
	return false
}

// ReminderWeekday：⚠️ 数据里的星期编号沿用 macOS 的 Calendar 语义 —— 1=周日 … 7=周六，
// 而 Go 的 time.Weekday() 是 0=周日 … 6=周六，必须 +1，否则整周错位一天。
func ReminderWeekday(t time.Time) int { return int(t.Weekday()) + 1 }

// OneShotDayFor：一次性提醒日推断（与 macOS 2.5.13 同规则）
// 时刻今天还没到 → 今天；已经过了（含此刻）→ 明天。避免「设了个过去的时间 → 当场弹窗」。
func OneShotDayFor(hour, minute int, now time.Time) string {
	target := time.Date(now.Year(), now.Month(), now.Day(), hour, minute, 0, 0, now.Location())
	if now.Before(target) {
		return dayString(now)
	}
	return dayString(now.AddDate(0, 0, 1))
}

// MatchesLongCycle：长周期循环是否命中 date（锚点由 OneShotDay 的月/日决定）
func (r Reminder) MatchesLongCycle(date time.Time) bool {
	if r.LongCycle == nil || r.OneShotDay == nil {
		return false
	}
	anchor, err := time.ParseInLocation(dayLayout, *r.OneShotDay, date.Location())
	if err != nil {
		return false
	}
	aM, aD := int(anchor.Month()), anchor.Day()
	d := date.Day()
	switch *r.LongCycle {
	case "monthly":
		return d == aD
	case "halfYearly":
		m2 := ((aM - 1 + 6) % 12) + 1
		return d == aD && (int(date.Month()) == aM || int(date.Month()) == m2)
	case "yearly":
		return d == aD && int(date.Month()) == aM
	}
	return false
}

// DueVerdict 与 macOS ReminderFirer.dueCheck 等价
type DueVerdict struct {
	Due         bool
	LateMinutes int
	Reason      string
}

// DueCheck：这条提醒在 now 这一刻该不该弹
//   - 勾了星期：命中勾选星期 + 已到点 + 错过仍在 3 分钟补弹窗口内
//   - 长周期：命中循环日 + 到点 + 同样的 3 分钟窗口
//   - 一次性：只在 OneShotDay 当天；当天不论迟多久都补弹一次（重启后未完成要能补弹，
//     这是 macOS 2.5.10 修「已弹窗却找不到窗口」死锁时定的规则，别退回去）
func DueCheck(r Reminder, now time.Time) DueVerdict {
	oneShot := r.IsOneShot()
	today := dayString(now)

	if oneShot {
		if r.OneShotDay == nil {
			return DueVerdict{Reason: "未设置提醒日"}
		}
		if *r.OneShotDay != today {
			if *r.OneShotDay < today {
				return DueVerdict{Reason: "一次性提醒已到期（原定 " + *r.OneShotDay + "）"}
			}
			return DueVerdict{Reason: "还没到提醒日（" + *r.OneShotDay + "）"}
		}
		if r.CompletedOn != nil && *r.CompletedOn == today {
			return DueVerdict{Reason: "今天已完成"}
		}
	} else if r.LongCycle != nil {
		if !r.MatchesLongCycle(now) {
			return DueVerdict{Reason: "今天不在「" + longCycleLabel(*r.LongCycle) + "」循环日"}
		}
	} else {
		if !r.fires(ReminderWeekday(now)) {
			return DueVerdict{Reason: "今天不在勾选的星期里"}
		}
	}

	target := time.Date(now.Year(), now.Month(), now.Day(), r.Hour, r.Minute, 0, 0, now.Location())
	if now.Before(target) {
		return DueVerdict{Reason: "还没到点"}
	}
	late := int(now.Sub(target).Minutes())
	if !oneShot && now.Sub(target) >= 3*time.Minute {
		return DueVerdict{Reason: "错过超过 3 分钟"}
	}
	if oneShot {
		if late < 1 {
			return DueVerdict{Due: true, Reason: "一次性提醒到点"}
		}
		return DueVerdict{Due: true, LateMinutes: late, Reason: fmt.Sprintf("一次性提醒补弹（已过 %d 分钟）", late)}
	}
	if late < 1 {
		return DueVerdict{Due: true, Reason: "到点提醒"}
	}
	return DueVerdict{Due: true, LateMinutes: late, Reason: fmt.Sprintf("补弹（已过 %d 分钟）", late)}
}

func longCycleLabel(c string) string {
	switch c {
	case "monthly":
		return "每月"
	case "halfYearly":
		return "每半年"
	case "yearly":
		return "每年"
	}
	return c
}

// ---------- 周次（校历，与 macOS ChongqingCalendar 一致：共 22 周） ----------

const totalWeeks = 22

// MondayOfWeek 第 n 周的周一（n 从 1 起）
func MondayOfWeek(n int, firstWeekMonday time.Time) time.Time {
	return firstWeekMonday.AddDate(0, 0, (n-1)*7)
}

// WeekNumber 某天属于第几周（不在 1..22 内返回 0）
func WeekNumber(d time.Time, firstWeekMonday time.Time) int {
	days := int(d.Sub(firstWeekMonday).Hours() / 24)
	if days < 0 {
		return 0
	}
	n := days/7 + 1
	if n > totalWeeks {
		return 0
	}
	return n
}

// ParseDay 解析 "yyyy-MM-dd"
func ParseDay(s string) (time.Time, bool) {
	t, err := time.ParseInLocation(dayLayout, strings.TrimSpace(s), time.Local)
	if err != nil {
		return time.Time{}, false
	}
	return t, true
}
