//go:build windows

// 教师助手 Windows 版 —— 单 exe（纯 Go，无 CGO，目标机零运行库依赖）。
//
// 形态：托盘常驻；左键点托盘图标 → 在屏幕右下角弹出面板窗口（用系统自带 Edge 的
// app 模式承载，无地址栏，观感等同原生窗口）；再点一次或按 Esc 收起。
// 提醒到点 → 弹置顶提醒窗（默认 30 分钟后再提醒 / 等会处理 / 马上处理）。
//
// 数据：与 macOS 版共用同一套 JSON（可以互相拷贝）。
//   · 便携模式：exe 同目录放一个 data\ 文件夹（机房/U 盘直接跑）
//   · 默认：%APPDATA%\ScheduleBar\
package main

import (
	"embed"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

//go:embed web
var webFS embed.FS

//go:embed assets/app.ico
var appICO []byte

const (
	appName    = "教师助手"
	appVersion = "2.5.13-win1"
	panelTitle = "教师助手"
)

var baseURL string

type appState struct {
	mu           sync.Mutex
	lastPing     time.Time
	panelPID     int
	trayHWND     uintptr
	alertPIDs    map[string]int          // 提醒 id → 弹窗进程 pid
	alertOpened  map[string]time.Time    // 提醒 id → 弹窗打开时刻（给「关窗检测」留启动宽限）
	alertFired   map[string]string       // 提醒 id → 已弹的「日期 时刻」键
	snoozed      map[string]time.Time    // 提醒 id → 稍后再弹的时间
	doneToday    map[string]string       // 提醒 id → 今天已处理
}

var st = &appState{
	alertPIDs:   map[string]int{},
	alertOpened: map[string]time.Time{},
	alertFired:  map[string]string{},
	snoozed:     map[string]time.Time{},
	doneToday:   map[string]string{},
}

func main() {
	defer func() {
		if r := recover(); r != nil {
			logf("panic: %v", r)
			showMsg(appName+" 启动失败", fmt.Sprintf("程序内部错误：\n%v\n\n日志：%s", r, logPath))
		}
	}()

	args := os.Args[1:]
	if hasFlag(args, "--help") || hasFlag(args, "-h") {
		showMsg(appName, "用法：\n  教师助手.exe             常驻托盘\n  教师助手.exe --show      直接打开面板（不常驻）\n  教师助手.exe --data=DIR  指定数据目录\n  教师助手.exe --test-alert 立刻弹一次测试提醒")
		return
	}
	if dir := flagValue(args, "--data"); dir != "" {
		_ = os.Setenv("SCHEDULEBAR_DATA_DIR", dir)
	}

	dataDir := db.resolve()
	db.snapshot()
	logf("启动 %s（build %s），数据目录：%s", appName, appVersion, dataDir)

	port, err := startServer()
	if err != nil {
		showMsg(appName+" 启动失败", "本地服务启动失败："+err.Error())
		return
	}
	baseURL = fmt.Sprintf("http://127.0.0.1:%d", port)
	logf("本地服务已启动：%s", baseURL)

	startReminderEngine()

	if hasFlag(args, "--test-alert") {
		go func() { time.Sleep(time.Second); fireTestAlert() }()
	}
	if hasFlag(args, "--show") {
		openPanel()
		// --show 模式也保持常驻（便于后续提醒），直接进消息循环
	}
	if hasFlag(args, "--no-tray") {
		select {}
	}

	if !acquireSingleInstance("TeacherHelperWin_SingleInstance_v1") {
		// 已有实例在跑：把它的面板叫出来，然后退出
		if h := findWindowByTitle(panelTitle); h != 0 {
			makeTopmostFocus(h)
		} else {
			notifyExisting()
		}
		return
	}

	hwnd, err := createMsgWindow("TeacherHelperMsgWnd", wndProc)
	if err != nil {
		showMsg(appName+" 启动失败", "创建消息窗口失败："+err.Error())
		return
	}
	st.trayHWND = hwnd
	tray := newTrayIcon(hwnd, appICO, appName)
	defer tray.remove()

	runMessageLoop()
	logf("正常退出")
}

// notifyExisting：第二个实例通过「写一个唤醒标记文件」通知第一个实例打开面板
func notifyExisting() {
	p := filepath.Join(db.resolve(), ".show-request")
	_ = os.WriteFile(p, []byte(time.Now().Format(time.RFC3339)), 0o644)
}

// ---------- 托盘消息处理 ----------

func wndProc(hwnd uintptr, msg uint32, w, l uintptr) uintptr {
	switch msg {
	case wmApp + 1: // 托盘回调：l 是鼠标消息
		switch uint32(l) {
		case wmLButtonUp:
			togglePanel()
		case wmRButtonUp, wmLButtonDown + 1000:
			showTrayMenu(hwnd)
		}
		return 0
	case wmCommand:
		id := int(w & 0xFFFF)
		handleMenuCommand(id)
		return 0
	case wmDestroy:
		return 0
	}
	return 0
}

func showTrayMenu(hwnd uintptr) {
	showMenu(hwnd, []string{
		"打开面板",
		"立刻弹一次测试提醒",
		"打开数据文件夹",
		autostartItemLabel(),
		"退出",
	}, handleMenuCommand)
}

func handleMenuCommand(index int) {
	switch index {
	case 0:
		openPanel()
	case 1:
		fireTestAlert()
	case 2:
		_ = exec.Command("explorer", db.resolve()).Start()
	case 3:
		toggleAutostart()
	case 4:
		logf("用户从托盘退出")
		os.Exit(0)
	}
}

// ---------- 面板窗口（Edge app 模式） ----------

// togglePanel：面板开着就关掉，关着就打开（与 macOS 版点图标切换一致）
func togglePanel() {
	if panelAlive() {
		closePanel()
		return
	}
	openPanel()
}

func panelAlive() bool {
	st.mu.Lock()
	pid, ping := st.panelPID, st.lastPing
	st.mu.Unlock()
	if pid != 0 && len(enumWindowHandles(pid)) > 0 {
		return true
	}
	return time.Since(ping) < 6*time.Second
}

func openPanel() {
	if panelAlive() {
		if h := findWindowByTitle(panelTitle); h != 0 {
			makeTopmostFocus(h)
		}
		return
	}
	wa := workArea()
	w := 940
	h := int(wa.Bottom-wa.Top) - 24
	if h > 780 {
		h = 780
	}
	if h < 520 {
		h = 520
	}
	x := int(wa.Right) - w - 10
	y := int(wa.Bottom) - h - 10
	pid, err := launchBrowserApp(baseURL+"/", w, h, x, y)
	if err != nil {
		logf("打开面板失败：%v", err)
		showMsg(appName, "打开面板失败："+err.Error())
		return
	}
	st.mu.Lock()
	st.panelPID = pid
	st.lastPing = time.Now()
	st.mu.Unlock()
	logf("面板窗口已启动（pid=%d）", pid)
}

func closePanel() {
	st.mu.Lock()
	pid := st.panelPID
	st.lastPing = time.Time{}
	st.mu.Unlock()
	if pid == 0 {
		return
	}
	for _, h := range enumWindowHandles(pid) {
		closeWindow(h)
	}
}

// launchBrowserApp：用 Edge / Chrome 的 --app 模式打开一个无地址栏窗口，返回进程 pid
func launchBrowserApp(url string, w, h, x, y int) (int, error) {
	exe := findBrowser()
	if exe == "" {
		// 没有 Edge/Chrome：退回默认浏览器（有地址栏，但至少能用）
		if err := exec.Command("rundll32", "url.dll,FileProtocolHandler", url).Start(); err != nil {
			return 0, err
		}
		return 0, nil
	}
	profileDir := filepath.Join(db.resolve(), "browser-profile")
	_ = os.MkdirAll(profileDir, 0o755)
	args := []string{
		"--app=" + url,
		"--user-data-dir=" + profileDir,
		"--no-first-run",
		"--no-default-browser-check",
		"--disable-features=msEdgeSidebarV2,msUndersideButton",
		fmt.Sprintf("--window-size=%d,%d", w, h),
		fmt.Sprintf("--window-position=%d,%d", x, y),
	}
	cmd := exec.Command(exe, args...)
	if err := cmd.Start(); err != nil {
		return 0, err
	}
	pid := 0
	if cmd.Process != nil {
		pid = cmd.Process.Pid
	}
	// 让窗口尽快置顶并在找得到时聚焦
	go func() {
		for i := 0; i < 40; i++ {
			time.Sleep(250 * time.Millisecond)
			hs := enumWindowHandles(pid)
			if len(hs) > 0 {
				makeTopmostFocus(hs[0])
				return
			}
		}
	}()
	return pid, nil
}

func findBrowser() string {
	cands := []string{
		filepath.Join(os.Getenv("ProgramFiles(x86)"), `Microsoft\Edge\Application\msedge.exe`),
		filepath.Join(os.Getenv("ProgramFiles"), `Microsoft\Edge\Application\msedge.exe`),
		filepath.Join(os.Getenv("LOCALAPPDATA"), `Microsoft\Edge\Application\msedge.exe`),
		filepath.Join(os.Getenv("ProgramFiles"), `Google\Chrome\Application\chrome.exe`),
		filepath.Join(os.Getenv("ProgramFiles(x86)"), `Google\Chrome\Application\chrome.exe`),
		filepath.Join(os.Getenv("LOCALAPPDATA"), `Google\Chrome\Application\chrome.exe`),
	}
	for _, c := range cands {
		if c == "" || strings.HasPrefix(c, "Microsoft") {
			continue
		}
		if _, err := os.Stat(c); err == nil {
			return c
		}
	}
	return ""
}

// ---------- 本地 HTTP 服务 ----------

func startServer() (int, error) {
	mux := http.NewServeMux()

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			serveStatic(w, r)
			return
		}
		serveWebFile(w, "web/app.html", "text/html; charset=utf-8")
	})
	mux.HandleFunc("/alert", func(w http.ResponseWriter, r *http.Request) {
		serveWebFile(w, "web/alert.html", "text/html; charset=utf-8")
	})
	mux.HandleFunc("/api/data", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, db.All())
	})
	mux.HandleFunc("/api/meta", func(w http.ResponseWriter, r *http.Request) {
		wa := workArea()
		writeJSON(w, map[string]interface{}{
			"version": appVersion,
			"dataDir": db.resolve(),
			"workArea": map[string]int{"x": int(wa.Left), "y": int(wa.Top),
				"w": int(wa.Right - wa.Left), "h": int(wa.Bottom - wa.Top)},
		})
	})
	mux.HandleFunc("/api/save", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", http.StatusMethodNotAllowed)
			return
		}
		file := r.URL.Query().Get("file")
		body, err := io.ReadAll(io.LimitReader(r.Body, 32<<20))
		if err != nil {
			writeJSON(w, map[string]interface{}{"ok": false, "error": err.Error()})
			return
		}
		if err := db.Write(file, body); err != nil {
			logf("保存 %s 失败：%v", file, err)
			writeJSON(w, map[string]interface{}{"ok": false, "error": err.Error()})
			return
		}
		writeJSON(w, map[string]interface{}{"ok": true})
	})
	mux.HandleFunc("/api/ping", func(w http.ResponseWriter, r *http.Request) {
		st.mu.Lock()
		st.lastPing = time.Now()
		st.mu.Unlock()
		writeJSON(w, map[string]interface{}{"ok": true, "version": appVersion})
	})
	mux.HandleFunc("/api/hide", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]interface{}{"ok": true})
		go func() { time.Sleep(80 * time.Millisecond); closePanel() }()
	})
	mux.HandleFunc("/api/open", func(w http.ResponseWriter, r *http.Request) {
		target := r.URL.Query().Get("target")
		url := r.URL.Query().Get("url")
		switch {
		case target == "datadir":
			_ = exec.Command("explorer", db.resolve()).Start()
		case target == "url" && url != "":
			_ = exec.Command("rundll32", "url.dll,FileProtocolHandler", url).Start()
		}
		writeJSON(w, map[string]interface{}{"ok": true})
	})
	mux.HandleFunc("/api/notify/test", func(w http.ResponseWriter, r *http.Request) {
		fireTestAlert()
		writeJSON(w, map[string]interface{}{"ok": true})
	})
	mux.HandleFunc("/api/alert/action", handleAlertAction)
	mux.HandleFunc("/api/alert/close", func(w http.ResponseWriter, r *http.Request) {
		id := r.URL.Query().Get("id")
		closeAlert(id)
		writeJSON(w, map[string]interface{}{"ok": true})
	})
	mux.HandleFunc("/api/undo/hint", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]interface{}{"ok": true})
	})

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	go func() {
		_ = http.Serve(ln, mux)
	}()
	return ln.Addr().(*net.TCPAddr).Port, nil
}

func serveStatic(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimPrefix(r.URL.Path, "/")
	switch {
	case strings.HasSuffix(name, ".css"):
		serveWebFile(w, "web/"+filepath.Base(name), "text/css; charset=utf-8")
	case strings.HasSuffix(name, ".js"):
		serveWebFile(w, "web/"+filepath.Base(name), "application/javascript; charset=utf-8")
	default:
		http.NotFound(w, r)
	}
}

func serveWebFile(w http.ResponseWriter, name, ctype string) {
	b, err := webFS.ReadFile(name)
	if err != nil {
		http.Error(w, "missing "+name, 500)
		return
	}
	w.Header().Set("Content-Type", ctype)
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(b)
}

func writeJSON(w http.ResponseWriter, v interface{}) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(v)
}

// ---------- 命令行小工具 ----------

func hasFlag(args []string, f string) bool {
	for _, a := range args {
		if a == f {
			return true
		}
	}
	return false
}

func flagValue(args []string, f string) string {
	for _, a := range args {
		if strings.HasPrefix(a, f+"=") {
			return strings.TrimPrefix(a, f+"=")
		}
	}
	return ""
}

func atoi(s string) int { n, _ := strconv.Atoi(s); return n }
