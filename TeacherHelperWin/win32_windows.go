//go:build windows

// Win32 直调层（纯标准库 syscall，无 CGO）。
// ⚠️ 坑位提醒（见 skill §2）：GDI 函数挂 gdi32.dll，窗口/消息函数挂 user32.dll，
// 挂错 DLL 会在首次 .Call() 时 panic「Failed to find ... procedure」= exe 一启动就报错。
package main

import (
	"encoding/binary"
	"syscall"
	"unsafe"
)

var (
	user32   = syscall.NewLazyDLL("user32.dll")
	shell32  = syscall.NewLazyDLL("shell32.dll")
	kernel32 = syscall.NewLazyDLL("kernel32.dll")
	gdi32    = syscall.NewLazyDLL("gdi32.dll")
)

var (
	pRegisterClassExW    = user32.NewProc("RegisterClassExW")
	pCreateWindowExW     = user32.NewProc("CreateWindowExW")
	pDefWindowProcW      = user32.NewProc("DefWindowProcW")
	pDestroyWindow       = user32.NewProc("DestroyWindow")
	pGetMessageW         = user32.NewProc("GetMessageW")
	pTranslateMessage    = user32.NewProc("TranslateMessage")
	pDispatchMessageW    = user32.NewProc("DispatchMessageW")
	pPostQuitMessage     = user32.NewProc("PostQuitMessage")
	pPostMessageW        = user32.NewProc("PostMessageW")
	pMessageBoxW         = user32.NewProc("MessageBoxW")
	pSystemParametersInfoW = user32.NewProc("SystemParametersInfoW")
	pFindWindowW         = user32.NewProc("FindWindowW")
	pEnumWindows         = user32.NewProc("EnumWindows")
	pGetWindowThreadProcessId = user32.NewProc("GetWindowThreadProcessId")
	pIsWindowVisible     = user32.NewProc("IsWindowVisible")
	pGetWindowTextW      = user32.NewProc("GetWindowTextW")
	pSetForegroundWindow = user32.NewProc("SetForegroundWindow")
	pSetWindowPos        = user32.NewProc("SetWindowPos")
	pShowWindow          = user32.NewProc("ShowWindow")
	pCreatePopupMenu     = user32.NewProc("CreatePopupMenu")
	pAppendMenuW         = user32.NewProc("AppendMenuW")
	pTrackPopupMenu      = user32.NewProc("TrackPopupMenu")
	pDestroyMenu         = user32.NewProc("DestroyMenu")
	pGetCursorPos        = user32.NewProc("GetCursorPos")
	pCreateIconFromResourceEx = user32.NewProc("CreateIconFromResourceEx")
	pLoadIconW           = user32.NewProc("LoadIconW")
	pLoadCursorW         = user32.NewProc("LoadCursorW")
	pGetSystemMetrics    = user32.NewProc("GetSystemMetrics")

	pShellNotifyIconW = shell32.NewProc("Shell_NotifyIconW")

	pCreateMutexW = kernel32.NewProc("CreateMutexW")
	pGetModuleHandleW = kernel32.NewProc("GetModuleHandleW")
)

// ---- 常量 ----
const (
	wmDestroy     = 0x0002
	wmClose       = 0x0010
	wmCommand     = 0x0111
	wmApp         = 0x8000
	wmRButtonUp   = 0x0205
	wmLButtonUp   = 0x0202
	wmRButtonDown = 0x0204
	wmLButtonDown = 0x0201

	spiGetWorkArea = 0x0030

	swShow    = 5
	hwndTopmost = ^uintptr(6) // HWND_TOPMOST = -1
	swpNoSize     = 0x0001
	swpNoMove     = 0x0002
	swpNoActivate = 0x0010
	swpShowWindow = 0x0040

	mfString   = 0x0000
	tpmReturnCmd = 0x0100
	tpmRightAlign = 0x0008
	tpmBottomAlign = 0x0020

	nimAdd    = 0x0000
	nimModify = 0x0001
	nimDelete = 0x0002

	nifMessage = 0x0001
	nifIcon    = 0x0002
	nifTip     = 0x0004

	idiApplication = 32512
)

type point struct{ X, Y int32 }

type rect struct {
	Left, Top, Right, Bottom int32
}

type msgT struct {
	Hwnd    uintptr
	Message uint32
	WParam  uintptr
	LParam  uintptr
	Time    uint32
	Pt      point
	Private uint32
}

type wndClassExW struct {
	CbSize        uint32
	Style         uint32
	LpfnWndProc   uintptr
	CbClsExtra    int32
	CbWndExtra    int32
	HInstance     uintptr
	HIcon         uintptr
	HCursor       uintptr
	HbrBackground uintptr
	LpszMenuName  *uint16
	LpszClassName *uint16
	HIconSm       uintptr
}

// NOTIFYICONDATAW（V3 全字段，cbSize 用 unsafe.Sizeof 保证与结构体一致）
type notifyIconDataW struct {
	CbSize           uint32
	HWnd             uintptr
	UID              uint32
	UFlags           uint32
	UCallbackMessage uint32
	HIcon            uintptr
	SzTip            [128]uint16
	DwState          uint32
	DwStateMask      uint32
	SzInfo           [256]uint16
	UVersion         uint32
	SzInfoTitle      [64]uint16
	DwInfoFlags      uint32
	GuidItem         [16]byte
	HBalloonIcon     uintptr
}

func utf16Ptr(s string) *uint16 {
	p, err := syscall.UTF16PtrFromString(s)
	if err != nil {
		return nil
	}
	return p
}

func utf16Slice(s string, max int) []uint16 {
	out := make([]uint16, max)
	u := syscall.StringToUTF16(s)
	if len(u) > max {
		u = u[:max]
	}
	copy(out, u)
	return out
}

func hwndText(h uintptr) string {
	buf := make([]uint16, 512)
	n, _, _ := pGetWindowTextW.Call(h, uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	if n == 0 {
		return ""
	}
	return syscall.UTF16ToString(buf[:n])
}

// ---- 弹错误框（排错用：任何 panic 都会写日志 + 弹框，避免「双击没反应」） ----

func showMsg(title, text string) {
	pMessageBoxW.Call(0,
		uintptr(unsafe.Pointer(utf16Ptr(text))),
		uintptr(unsafe.Pointer(utf16Ptr(title))),
		0x00000040 /*MB_ICONINFORMATION*/)
}

// ---- 工作区（避开任务栏） ----

func workArea() rect {
	var r rect
	pSystemParametersInfoW.Call(spiGetWorkArea, 0, uintptr(unsafe.Pointer(&r)), 0)
	if r.Right == 0 && r.Bottom == 0 { // 兜底：取主屏尺寸
		w, _, _ := pGetSystemMetrics.Call(0)
		h, _, _ := pGetSystemMetrics.Call(1)
		r = rect{0, 0, int32(w), int32(h)}
	}
	return r
}

// ---- 进程 / 窗口工具 ----

func enumWindowHandles(pid int) []uintptr {
	var found []uintptr
	cb := syscall.NewCallback(func(h uintptr, lparam uintptr) uintptr {
		var wpid uint32
		pGetWindowThreadProcessId.Call(h, uintptr(unsafe.Pointer(&wpid)))
		if int(wpid) != pid {
			return 1 // continue
		}
		if vis, _, _ := pIsWindowVisible.Call(h); vis == 0 {
			return 1
		}
		if hwndText(h) == "" {
			return 1
		}
		found = append(found, h)
		return 1
	})
	pEnumWindows.Call(cb, 0)
	return found
}

func findWindowByTitle(title string) uintptr {
	h, _, _ := pFindWindowW.Call(0, uintptr(unsafe.Pointer(utf16Ptr(title))))
	return h
}

func closeWindow(h uintptr) {
	pPostMessageW.Call(h, wmClose, 0, 0)
}

func makeTopmostFocus(h uintptr) {
	pSetWindowPos.Call(h, hwndTopmost, 0, 0, 0, 0,
		uintptr(swpNoMove|swpNoSize|swpShowWindow))
	pSetForegroundWindow.Call(h)
}

// ---- 托盘图标 ----

type trayIcon struct {
	hwnd uintptr
	data notifyIconDataW
	onClick func()
	onMenu  func()
}

// newTrayIcon 注册托盘图标；iconData 为 .ico 文件原始字节（用 CreateIconFromResourceEx 加载，
// 这样 exe 单文件即可，不需要外部 .ico / .png）
func newTrayIcon(hwnd uintptr, iconData []byte, tip string) *trayIcon {
	t := &trayIcon{hwnd: hwnd}
	d := &t.data
	d.CbSize = uint32(unsafe.Sizeof(*d))
	d.HWnd = hwnd
	d.UID = 1
	d.UFlags = nifMessage | nifIcon | nifTip
	d.UCallbackMessage = wmApp + 1
	d.HIcon = loadIconFromICO(iconData)
	copy(d.SzTip[:], utf16Slice(tip, 128))
	pShellNotifyIconW.Call(nimAdd, uintptr(unsafe.Pointer(d)))
	return t
}

// loadIconFromICO 从 .ico 字节里挑最大的一张图，转成 HICON
func loadIconFromICO(b []byte) uintptr {
	const fallback = 0
	if len(b) < 22 {
		h, _, _ := pLoadIconW.Call(0, idiApplication)
		return h
	}
	count := int(binary.LittleEndian.Uint16(b[4:6]))
	bestOff, bestSize, bestPix := 0, 0, -1
	for i := 0; i < count; i++ {
		off := 6 + i*16
		if off+16 > len(b) {
			break
		}
		w := int(b[off])
		if w == 0 {
			w = 256
		}
		h := int(b[off+1])
		if h == 0 {
			h = 256
		}
		sz := int(binary.LittleEndian.Uint32(b[off+8 : off+12]))
		img := int(binary.LittleEndian.Uint32(b[off+12 : off+16]))
		if img+sz > len(b) {
			continue
		}
		if w*h > bestPix {
			bestPix, bestOff, bestSize = w*h, img, sz
		}
	}
	if bestSize == 0 {
		h, _, _ := pLoadIconW.Call(0, idiApplication)
		return h
	}
	hicon, _, _ := pCreateIconFromResourceEx.Call(
		uintptr(unsafe.Pointer(&b[bestOff])), uintptr(bestSize), 1 /*fIcon*/, 0x00030000, 0, 0, 0)
	if hicon == 0 {
		h, _, _ := pLoadIconW.Call(0, idiApplication)
		return h
	}
	return hicon
}

// remove 托盘退出前清理（否则图标会留在托盘里成幽灵图标）
func (t *trayIcon) remove() {
	pShellNotifyIconW.Call(nimDelete, uintptr(unsafe.Pointer(&t.data)))
}

// showMenu 右键菜单：打开面板 / 测试提醒 / 打开数据目录 / 退出
func showMenu(hwnd uintptr, items []string, handler func(index int)) {
	menu, _, _ := pCreatePopupMenu.Call()
	if menu == 0 {
		return
	}
	defer pDestroyMenu.Call(menu)
	ids := make([]uintptr, len(items))
	for i, s := range items {
		id := uintptr(1000 + i)
		ids[i] = id
		pAppendMenuW.Call(menu, mfString, id, uintptr(unsafe.Pointer(utf16Ptr(s))))
	}
	var pt point
	pGetCursorPos.Call(uintptr(unsafe.Pointer(&pt)))
	sel, _, _ := pTrackPopupMenu.Call(menu,
		tpmReturnCmd|tpmRightAlign|tpmBottomAlign,
		uintptr(pt.X), uintptr(pt.Y), 0, hwnd, 0)
	if sel == 0 {
		return
	}
	for i, id := range ids {
		if id == sel {
			handler(i)
			return
		}
	}
}

// ---- 单实例互斥 ----

func acquireSingleInstance(name string) bool {
	h, _, err := pCreateMutexW.Call(0, 0, uintptr(unsafe.Pointer(utf16Ptr(name))))
	if h == 0 {
		return true
	}
	// ERROR_ALREADY_EXISTS = 183 → 已有实例
	if errno, ok := err.(syscall.Errno); ok && errno == 183 {
		return false
	}
	return true
}

// ---- 消息窗口类（只用来收托盘回调 / 菜单命令） ----

var wndProcCallback uintptr

func createMsgWindow(className string, wndProc func(hwnd uintptr, msg uint32, w, l uintptr) uintptr) (uintptr, error) {
	hInst, _, _ := pGetModuleHandleW.Call(0)
	wndProcCallback = syscall.NewCallback(func(hwnd uintptr, msg uint32, w, l uintptr) uintptr {
		if r := wndProc(hwnd, msg, w, l); r != 0 {
			return r
		}
		r, _, _ := pDefWindowProcW.Call(hwnd, uintptr(msg), w, l)
		return r
	})
	cls := &wndClassExW{
		CbSize:        uint32(unsafe.Sizeof(wndClassExW{})),
		LpfnWndProc:   wndProcCallback,
		HInstance:     hInst,
		LpszClassName: utf16Ptr(className),
	}
	if atom, _, err := pRegisterClassExW.Call(uintptr(unsafe.Pointer(cls))); atom == 0 {
		return 0, err
	}
	hwnd, _, err := pCreateWindowExW.Call(
		0,
		uintptr(unsafe.Pointer(cls.LpszClassName)),
		uintptr(unsafe.Pointer(utf16Ptr("TeacherHelperMsg"))),
		0, 0, 0, 0, 0, 0, 0, hInst, 0)
	if hwnd == 0 {
		return 0, err
	}
	return hwnd, nil
}

func runMessageLoop() {
	var m msgT
	for {
		r, _, _ := pGetMessageW.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
		if int32(r) <= 0 {
			break
		}
		pTranslateMessage.Call(uintptr(unsafe.Pointer(&m)))
		pDispatchMessageW.Call(uintptr(unsafe.Pointer(&m)))
	}
}
