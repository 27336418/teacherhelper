#!/bin/bash
# 教师助手 —— 一键解除 Gatekeeper 拦截并启动 + 启动诊断
# 用法：把本文件和「教师助手.app」放在同一个文件夹，双击运行本文件即可。
# 启动失败时会把崩溃原因（dyld 错误、缺失库等）写入桌面日志，方便排查。

cd "$(dirname "$0")" || exit 1

APP="教师助手.app"
LOG="$HOME/Desktop/教师助手-诊断日志.txt"

if [ ! -d "$APP" ]; then
  echo "❌ 在当前文件夹里没找到「教师助手.app」。"
  echo "请把本文件和 教师助手.app 放在同一个文件夹里再双击运行。"
  read -p "按回车键退出…"
  exit 1
fi

{
  echo "======================================"
  echo "  教师助手 启动诊断"
  echo "  时间: $(date)"
  echo "  系统: $(sw_vers -productVersion) ($(uname -m))"
  echo "  架构: $(uname -p)"
  echo "======================================"
} > "$LOG"

echo "① 正在清除隔离属性…"
xattr -cr "$APP" 2>>"$LOG"
sudo -n xattr -rd com.apple.provenance "$APP" 2>/dev/null

echo "② 正在重新签名…"
if command -v codesign >/dev/null 2>&1; then
  codesign --remove-signature "$APP" 2>/dev/null
  codesign --force --deep --sign - --timestamp=none "$APP" 2>>"$LOG"
else
  echo "   （未安装开发者工具，跳过签名步骤）"
fi

echo "③ 正在启动应用…"

# 直接运行可执行文件，把 stderr 写入日志（dyld / Swift 运行时错误会从这里出来）
EXEC="$APP/Contents/MacOS/ScheduleBar"
if [ ! -x "$EXEC" ]; then
  echo "❌ 找不到可执行文件：$EXEC" | tee -a "$LOG"
  open "$LOG"
  read -p "按回车键退出…"
  exit 1
fi

nohup "$EXEC" >>"$LOG" 2>&1 &
PID=$!
disown 2>/dev/null

# 等 5 秒，看进程是否还活着
sleep 5
if kill -0 $PID 2>/dev/null; then
  echo "" | tee -a "$LOG"
  echo "✅ 应用已启动（PID $PID）。" | tee -a "$LOG"
  echo "" | tee -a "$LOG"
  echo "请看菜单栏右上角「教师助手」图标，已自动弹出面板。" | tee -a "$LOG"
  echo "（启动日志保留在桌面：教师助手-诊断日志.txt）" | tee -a "$LOG"
else
  echo "" | tee -a "$LOG"
  echo "❌ 应用启动后立即退出，原因可能写在日志里。" | tee -a "$LOG"
  echo "请打开桌面上的「教师助手-诊断日志.txt」查看具体报错，" | tee -a "$LOG"
  echo "把里面的红色 dyld / 错误信息发给我即可定位问题。" | tee -a "$LOG"
  open "$LOG"
fi

echo ""
echo "如果菜单栏没看到图标且启动后立刻退出，请把诊断日志的内容发给我。"
echo "另外可以再看一眼：~/Library/Logs/教师助手.log（应用内部的启动日志）。"
echo ""
read -p "按回车键关闭本窗口…"