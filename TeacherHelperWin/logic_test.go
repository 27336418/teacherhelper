package main

import (
	"testing"
	"time"
)

// 基准时间：2026-09-29（周二）中午 12:00
func noon() time.Time {
	return time.Date(2026, 9, 29, 12, 0, 0, 0, time.Local)
}

func sp(s string) *string { return &s }

func TestReminderWeekdayMapping(t *testing.T) {
	// 2026-09-29 是周二 → macOS 编号应为 3
	if got := ReminderWeekday(noon()); got != 3 {
		t.Fatalf("周二应映射成 3，实得 %d", got)
	}
	// 2026-09-27 是周日 → 1
	sun := time.Date(2026, 9, 27, 10, 0, 0, 0, time.Local)
	if got := ReminderWeekday(sun); got != 1 {
		t.Fatalf("周日应映射成 1，实得 %d", got)
	}
	// 2026-10-03 是周六 → 7
	sat := time.Date(2026, 10, 3, 10, 0, 0, 0, time.Local)
	if got := ReminderWeekday(sat); got != 7 {
		t.Fatalf("周六应映射成 7，实得 %d", got)
	}
}

func TestOneShotDayFor(t *testing.T) {
	// 中午 12:00 视角
	cases := []struct {
		name         string
		now          time.Time
		hour, minute int
		want         string
	}{
		{"中午设 18:30（还没到）→ 今天", noon(), 18, 30, "2026-09-29"},
		{"中午设 11:59（已过 1 分钟）→ 明天", noon(), 11, 59, "2026-09-30"},
		{"中午设 12:00（正好此刻）→ 明天（不当场弹）", noon(), 12, 0, "2026-09-30"},
		// ⚠️ 用户 2026-09-28 实测场景：23:29 把提醒设成 17:30 → 必须是明天，绝不能当场补弹
		{"23:29 设 17:30（早于当前）→ 明天", lateNight(), 17, 30, "2026-09-29"},
		{"23:29 设 23:59（还没到）→ 今天", lateNight(), 23, 59, "2026-09-28"},
	}
	for _, c := range cases {
		if got := OneShotDayFor(c.hour, c.minute, c.now); got != c.want {
			t.Errorf("%s：hour=%d min=%d 期望 %s，实得 %s", c.name, c.hour, c.minute, c.want, got)
		}
	}
}

// 用户实测那一刻：2026-09-28 23:29
func lateNight() time.Time {
	return time.Date(2026, 9, 28, 23, 29, 0, 0, time.Local)
}

func TestDueCheck(t *testing.T) {
	yesterday, today, tomorrow := "2026-09-28", "2026-09-29", "2026-09-30"
	cases := []struct {
		name  string
		r     Reminder
		fire  bool
	}{
		// —— 一次性 ——
		{"一次性·今天·还没到点 → 不弹",
			Reminder{Title: "A", Hour: 18, Minute: 0, OneShotDay: sp(today)}, false},
		{"一次性·今天·已过 4 小时 → 补弹（重启后能补弹，别退）",
			Reminder{Title: "B", Hour: 7, Minute: 52, OneShotDay: sp(today)}, true},
		{"一次性·昨天 → 不弹",
			Reminder{Title: "C", Hour: 7, Minute: 52, OneShotDay: sp(yesterday)}, false},
		{"一次性·明天 → 不弹（正是「时刻已过→顺延明天」的结果）",
			Reminder{Title: "D", Hour: 17, Minute: 30, OneShotDay: sp(tomorrow)}, false},
		{"一次性·没日期（老数据） → 不弹",
			Reminder{Title: "E", Hour: 8, Minute: 0}, false},
		{"一次性·今天已完成 → 不弹",
			Reminder{Title: "F", Hour: 11, Minute: 59, OneShotDay: sp(today), CompletedOn: sp(today)}, false},
		{"一次性·弹过但没点完成（firedOn 有值） → 仍要弹",
			Reminder{Title: "G", Hour: 11, Minute: 59, OneShotDay: sp(today), FiredOn: sp(today)}, true},
		// —— 按星期 ——（周二 = 3）
		{"每周·今天(周二)命中·刚过点 1 分钟 → 弹",
			Reminder{Title: "H", Hour: 11, Minute: 59, Weekdays: []int{3}}, true},
		{"每周·今天命中·已过 5 分钟 → 不弹（3 分钟窗口）",
			Reminder{Title: "I", Hour: 11, Minute: 55, Weekdays: []int{3}}, false},
		{"每周·今天没勾 → 不弹",
			Reminder{Title: "J", Hour: 11, Minute: 59, Weekdays: []int{1, 2}}, false},
		// —— 长周期 ——（锚点 2026-01-29，每月 = 每月 29 日）
		{"长周期·每月·命中(29 日) 刚过点 → 弹",
			Reminder{Title: "K", Hour: 11, Minute: 59, LongCycle: sp("monthly"), OneShotDay: sp("2026-01-29")}, true},
		{"长周期·每月·不是 29 日 → 不弹",
			Reminder{Title: "L", Hour: 11, Minute: 59, LongCycle: sp("monthly"), OneShotDay: sp("2026-01-28")}, false},
		{"长周期·每年·锚点 1 月 29 日 → 9 月不弹",
			Reminder{Title: "M", Hour: 11, Minute: 59, LongCycle: sp("yearly"), OneShotDay: sp("2026-01-29")}, false},
		{"长周期·每半年·锚点 3 月 29 日 → 9 月命中（+6 月）",
			Reminder{Title: "N", Hour: 11, Minute: 59, LongCycle: sp("halfYearly"), OneShotDay: sp("2026-03-29")}, true},
	}
	for _, c := range cases {
		v := DueCheck(c.r, noon())
		if v.Due != c.fire {
			t.Errorf("%s：期望 %v，实得 %v（%s）", c.name, c.fire, v.Due, v.Reason)
		}
	}
}

func TestWeekMath(t *testing.T) {
	first, _ := ParseDay("2026-08-31") // 第 1 周周一
	if got := MondayOfWeek(1, first); dayString(got) != "2026-08-31" {
		t.Errorf("第 1 周周一应为 2026-08-31，实得 %s", dayString(got))
	}
	if got := MondayOfWeek(5, first); dayString(got) != "2026-09-28" {
		t.Errorf("第 5 周周一应为 2026-09-28，实得 %s", dayString(got))
	}
	d, _ := ParseDay("2026-09-29")
	if got := WeekNumber(d, first); got != 5 {
		t.Errorf("2026-09-29 应属第 5 周，实得 %d", got)
	}
	if got := WeekNumber(first.AddDate(0, 0, -1), first); got != 0 {
		t.Errorf("开学前应返回 0，实得 %d", got)
	}
}
