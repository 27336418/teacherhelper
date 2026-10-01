//go:build windows

// 开机自启：写 HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run，
// 不需要管理员权限（skill §6）。
package main

import (
	"os"
	"syscall"
	"unsafe"
)

var (
	advapi32 = syscall.NewLazyDLL("advapi32.dll")
	pRegOpenKeyExW  = advapi32.NewProc("RegOpenKeyExW")
	pRegSetValueExW = advapi32.NewProc("RegSetValueExW")
	pRegDeleteValueW = advapi32.NewProc("RegDeleteValueW")
	pRegQueryValueExW = advapi32.NewProc("RegQueryValueExW")
	pRegCloseKey    = advapi32.NewProc("RegCloseKey")
)

const (
	hkeyCurrentUser = 0x80000001
	keySetValue     = 0x0002
	keyQueryValue   = 0x0001
	keyWow64_64     = 0x0100
	regSZ           = 1
)

const runKey = `Software\Microsoft\Windows\CurrentVersion\Run`
const autostartName = "TeacherHelperWin"

func openRunKey(access uint32) uintptr {
	var hk uintptr
	pRegOpenKeyExW.Call(hkeyCurrentUser,
		uintptr(unsafe.Pointer(utf16Ptr(runKey))), 0,
		uintptr(access|keyWow64_64), uintptr(unsafe.Pointer(&hk)))
	return hk
}

func autostartEnabled() bool {
	hk := openRunKey(keyQueryValue)
	if hk == 0 {
		return false
	}
	defer pRegCloseKey.Call(hk)
	var typ, size uint32
	buf := make([]uint16, 512)
	size = uint32(len(buf) * 2)
	r, _, _ := pRegQueryValueExW.Call(hk,
		uintptr(unsafe.Pointer(utf16Ptr(autostartName))), 0,
		uintptr(unsafe.Pointer(&typ)), uintptr(unsafe.Pointer(&buf[0])),
		uintptr(unsafe.Pointer(&size)))
	return r == 0
}

func setAutostart(on bool) error {
	hk := openRunKey(keySetValue)
	if hk == 0 {
		return syscall.EINVAL
	}
	defer pRegCloseKey.Call(hk)
	if !on {
		pRegDeleteValueW.Call(hk, uintptr(unsafe.Pointer(utf16Ptr(autostartName))))
		return nil
	}
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	data := utf16Slice(`"`+exe+`"`, 512)
	n := 0
	for n < len(data) && data[n] != 0 {
		n++
	}
	bytes := (*[1024]byte)(unsafe.Pointer(&data[0]))[: (n+1)*2 : (n+1)*2]
	pRegSetValueExW.Call(hk,
		uintptr(unsafe.Pointer(utf16Ptr(autostartName))), 0, regSZ,
		uintptr(unsafe.Pointer(&bytes[0])), uintptr(len(bytes)))
	logf("开机自启 = %v", on)
	return nil
}

func autostartItemLabel() string {
	if autostartEnabled() {
		return "✓ 开机自动启动"
	}
	return "开机自动启动"
}

func toggleAutostart() {
	on := !autostartEnabled()
	_ = setAutostart(on)
	if on {
		showMsg(appName, "已设置开机自动启动（登录后自动常驻托盘）。")
	} else {
		showMsg(appName, "已取消开机自动启动。")
	}
}
