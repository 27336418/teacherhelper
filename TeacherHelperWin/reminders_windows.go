//go:build windows

// 提醒引擎 + 置顶提醒弹窗。
// 规则与 macOS 版逐条对齐（见 logic.go 的 DueCheck，本机可用 go test 验证）：
//   · 按星期：命中勾选星期 + 到点 + 错过 3 分钟内补弹
//   · 一次性：只在提醒日当天；当天不论迟多久都补弹一次（重启后未完成必须能补弹）
//   · 长周期：命中循环日（月/半年/年）+ 同样的 3 分钟窗口
//   · 点「马上处理」才算完成（completedOn）；仅弹过窗（firedOn）不算
// 弹窗用 Edge app 窗口承载（样式与 macOS 版一致），启动后立刻 SetWindowPos 置顶+聚焦。
package main

import (
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

const alertSnoozeDefault = 30 * time.Minute

func startReminderEngine() {
	go func() {
		// 先跑一次（启动时补弹错过的提醒），之后每 10 秒轮询
		checkReminders()
		t := time.NewTicker(10 * time.Second)
		for range t.C {
			checkReminders()
		}
	}()
	go watchShowRequest()
}

// watchShowRequest：第二个实例留下的唤醒标记 → 打开面板
func watchShowRequest() {
	p := filepath.Join(db.resolve(), ".show-request")
	for {
		time.Sleep(2 * time.Second)
		if _, err := os.Stat(p); err == nil {
			_ = os.Remove(p)
			openPanel()
		}
	}
}

func loadReminders() []Reminder {
	b, ok := db.Read("reminders.json")
	if !ok {
		return nil
	}
	var list []Reminder
	if json.Unmarshal(b, &list) != nil {
		logf("reminders.json 解析失败")
		return nil
	}
	return list
}

func checkReminders() {
	now := time.Now()
	today := dayString(now)
	refreshReminders() // 每次都重读 JSON：macOS 侧改过的提醒也能被看到

	st.mu.Lock()
	defer st.mu.Unlock()

	// 1) 弹窗被用户直接关掉（点 X）→ 视为「等会处理」，按默认 30 分钟后再弹
	//    ⚠️ 必须留启动宽限：Edge 从 Start 到窗口出现要 1~3 秒，这期间窗口句柄还没生成，
	//    若立刻判定「已关闭」就会把刚弹的提醒误当成被关掉 → 无限重弹。
	for id, pid := range st.alertPIDs {
		if len(enumWindowHandles(pid)) == 0 {
			if opened, ok := st.alertOpened[id]; ok && time.Since(opened) < 15*time.Second {
				continue // 还在启动中
			}
			delete(st.alertPIDs, id)
			delete(st.alertOpened, id)
			if id == "test-alert" {
				continue
			}
			if !st.alertHandled(id) {
				st.snoozed[id] = now.Add(alertSnoozeDefault)
				logf("提醒弹窗被关闭 → %v 后重弹（id=%s）", alertSnoozeDefault, id)
			}
		}
	}

	// 2) 「等会处理」到点 → 再弹
	for id, when := range st.snoozed {
		if now.Before(when) {
			continue
		}
		delete(st.snoozed, id)
		var target *Reminder
		for i := range remindersCache {
			if remindersCache[i].ID == id {
				target = &remindersCache[i]
				break
			}
		}
		if target == nil {
			continue
		}
		st.openAlertWindow(*target, false)
	}

	// 3) 到点提醒（每条每天同一时刻只弹一次）
	for _, r := range remindersCache {
		v := DueCheck(r, now)
		if !v.Due {
			continue
		}
		key := today + " " + twoDigit(r.Hour, r.Minute)
		if st.alertFired[r.ID] == key {
			continue
		}
		if st.doneToday[r.ID] == today {
			continue
		}
		st.alertFired[r.ID] = key
		if v.LateMinutes >= 1 {
			logf("提醒：「%s」%s", r.Title, v.Reason)
		}
		st.openAlertWindow(r, false)
	}
}

// remindersCache 每次轮询刷新一次（文件可能被 macOS 版改动）
var remindersCache []Reminder

func refreshReminders() { remindersCache = loadReminders() }

func (s *appState) alertHandled(id string) bool {
	return s.doneToday[id+"#handled"] == "1"
}

func (s *appState) markHandled(id string) { s.doneToday[id+"#handled"] = "1" }

func twoDigit(h, m int) string {
	return pad2(h) + ":" + pad2(m)
}

func pad2(n int) string {
	if n < 10 {
		return "0" + itoa(n)
	}
	return itoa(n)
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b [8]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}

// openAlertWindow 打开一条提醒的置顶弹窗。
// ⚠️ 调用方需持有 st.mu。
func (s *appState) openAlertWindow(r Reminder, isTest bool) {
	if pid, ok := s.alertPIDs[r.ID]; ok {
		for _, h := range enumWindowHandles(pid) {
			makeTopmostFocus(h)
		}
		return
	}
	wa := workArea()
	w, h := 420, 220
	x := int(wa.Right) - w - 12
	y := int(wa.Top) + 12
	// 多个提醒纵向错开
	offset := len(s.alertPIDs) * 24
	url := baseURL + "/alert?id=" + r.ID
	if isTest {
		url += "&test=1"
	}
	pid, err := launchBrowserApp(url, w, h, x, y+offset)
	if err != nil {
		logf("弹提醒失败：%v", err)
		showMsg(appName+" · 提醒", r.Title)
		return
	}
	s.alertPIDs[r.ID] = pid
	s.alertOpened[r.ID] = time.Now()
	go func(id string, pid int) {
		// 确保弹窗一定置顶（Edge 启动完成后拿到 hwnd 再钉一次）
		for i := 0; i < 40; i++ {
			time.Sleep(250 * time.Millisecond)
			hs := enumWindowHandles(pid)
			if len(hs) > 0 {
				makeTopmostFocus(hs[0])
				return
			}
		}
	}(r.ID, pid)
}

func closeAlert(id string) {
	st.mu.Lock()
	defer st.mu.Unlock()
	pid, ok := st.alertPIDs[id]
	if !ok {
		return
	}
	delete(st.alertPIDs, id)
	for _, h := range enumWindowHandles(pid) {
		closeWindow(h)
	}
}

// fireTestAlert：托盘菜单 / 前端「测试弹窗」按钮用
func fireTestAlert() {
	st.mu.Lock()
	defer st.mu.Unlock()
	st.openAlertWindow(Reminder{
		ID:    "test-alert",
		Title: "这是一条测试提醒（用来确认弹窗正常）",
		Hour:  time.Now().Hour(),
		Minute: time.Now().Minute(),
	}, true)
}

// handleAlertAction：弹窗上的按钮回调
// POST /api/alert/action  {"id":"...","action":"done|snooze|open-url","seconds":1800}
func handleAlertAction(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	body, _ := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	var payload struct {
		ID      string `json:"id"`
		Action  string `json:"action"`
		Seconds int    `json:"seconds"`
	}
	if err := json.Unmarshal(body, &payload); err != nil {
		writeJSON(w, map[string]interface{}{"ok": false, "error": err.Error()})
		return
	}

	st.mu.Lock()
	switch payload.Action {
	case "done", "open-url":
		st.markHandled(payload.ID)
		st.doneToday[payload.ID] = dayString(time.Now())
	case "snooze":
		sec := payload.Seconds
		if sec <= 0 {
			sec = int(alertSnoozeDefault.Seconds())
		}
		st.snoozed[payload.ID] = time.Now().Add(time.Duration(sec) * time.Second)
		st.markHandled(payload.ID)
	}
	st.mu.Unlock()

	logf("提醒操作：%s → %s", payload.ID, payload.Action)
	closeAlert(payload.ID)
	writeJSON(w, map[string]interface{}{"ok": true})
}
