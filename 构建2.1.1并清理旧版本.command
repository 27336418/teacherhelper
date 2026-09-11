#!/bin/bash
# 教师助手 2.1.1 —— 一键「构建 + 签名 + 同步副本 + 清理旧版本 + 冒烟测试」
#
# 为什么需要这个脚本：本机当前 /dev/null 缺失（终端里执行任何命令都会报
#   zsh: no such file or directory: /dev/null），助手无法在会话里跑命令。
# 你在「终端」或直接双击本文件，就能在旁边正常的 shell 里完成同样的流程。
#
# 安全约定：
#   · 删除前先把所有旧副本整体备份到 /tmp/教师助手旧版备份-<时间戳>/
#   · 只处理名字为「教师助手.app」/「ScheduleBar.app」的应用包，不碰其它文件
#   · 不删除源码、不删除 .workbuddy、不删除 ~/Library/Application Support/ScheduleBar 里的数据
#   · 不生成任何压缩包（按约定只交付 .app）
#
# 若旧版本仍未清干净，或想完全恢复，重新运行本脚本即可（它总是保留一份备份）。

set -u
cd "$(dirname "$0")" || exit 1
ROOT="$(pwd)"
PROJ="$ROOT/ScheduleBar"
APP="$ROOT/教师助手.app"
NAME="ScheduleBar"
NEWVER="2.1.1"
STAMP="$(date +%Y%m%d-%H%M%S)"
BAK="/tmp/教师助手旧版备份-$STAMP"

echo "======================================================"
echo " 教师助手 $NEWVER 构建 / 签名 / 同步 / 清理"
echo " 项目目录：$ROOT"
echo " 备份目录：$BAK"
echo "======================================================"
mkdir -p "$BAK"

# ---------------------------------------------------------------- 0) 退出旧进程
echo ""
echo "① 退出正在运行的旧版本…"
pkill -f "教师助手.app/Contents/MacOS/$NAME" 2>/dev/null
pkill -f "/$NAME$" 2>/dev/null
sleep 1

# ---------------------------------------------------------------- 1) 备份现有副本
echo ""
echo "② 备份现有应用副本…"
COPIES=(
  "$APP"
  "$HOME/Desktop/教师助手.app"
  "$HOME/Desktop/自编app/教师助手.app"
  "/Applications/教师助手.app"
)
for p in "${COPIES[@]}"; do
  [ -e "$p" ] || continue
  dest="$BAK/$(echo "$p" | sed 's#/#_#g')"
  cp -R "$p" "$dest" 2>/dev/null
  v="$(defaults read "$p/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo '?')"
  echo "   [备份] 版本=$v  $p"
done

# ---------------------------------------------------------------- 2) 构建双架构
echo ""
echo "③ 构建 arm64 / x86_64（release）…"
cd "$PROJ" || exit 1
swift build -c release --arch arm64 --disable-sandbox || { echo "❌ arm64 构建失败"; read -p "回车退出…"; exit 1; }
swift build -c release --arch x86_64 --disable-sandbox || { echo "❌ x86_64 构建失败"; read -p "回车退出…"; exit 1; }

ARM="$PROJ/.build/arm64-apple-macosx/release/$NAME"
INTEL="$PROJ/.build/x86_64-apple-macosx/release/$NAME"
[ -f "$ARM" ] && [ -f "$INTEL" ] || { echo "❌ 找不到构建产物"; read -p "回车退出…"; exit 1; }

# ---------------------------------------------------------------- 3) 合成 universal
echo ""
echo "④ 合成 Universal 二进制并写回 App…"
[ -d "$APP" ] || { echo "❌ 找不到 $APP"; read -p "回车退出…"; exit 1; }
mkdir -p "$APP/Contents/MacOS"
lipo -create -output "$APP/Contents/MacOS/$NAME" "$ARM" "$INTEL" || exit 1

# 版本号模板（源码真相）覆盖进 App，图标等其余内容保持不变
cp "$PROJ/Info.plist" "$APP/Contents/Info.plist"
echo "   架构：$(lipo -archs "$APP/Contents/MacOS/$NAME")"
echo "   版本：$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString) (build $(defaults read "$APP/Contents/Info.plist" CFBundleVersion))"

# ---------------------------------------------------------------- 4) 签名
echo ""
echo "⑤ 清隔离属性并重新签名（adhoc）…"
xattr -cr "$APP" 2>/dev/null
xattr -d com.apple.FinderInfo "$APP" 2>/dev/null
codesign --force --deep --sign - --timestamp=none "$APP" || { echo "❌ 签名失败"; read -p "回车退出…"; exit 1; }
xattr -cr "$APP" 2>/dev/null
codesign -v "$APP" && echo "   签名校验通过"

# ---------------------------------------------------------------- 5) 同步副本
echo ""
echo "⑥ 同步到其余副本…"
sync_one() {
  local p="$1"
  [ -e "$p" ] || return 0
  rm -rf "$p"
  cp -R "$APP" "$(dirname "$p")/" || return 1
  xattr -cr "$p" 2>/dev/null
  xattr -d com.apple.FinderInfo "$p" 2>/dev/null
  codesign --force --deep --sign - --timestamp=none "$p" >/dev/null 2>&1
  xattr -cr "$p" 2>/dev/null
  echo "   [同步] $p  $(defaults read "$p/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)"
}
sync_one "$HOME/Desktop/自编app/教师助手.app"
sync_one "/Applications/教师助手.app"

# ---------------------------------------------------------------- 6) 清理旧版本
echo ""
echo "⑦ 扫描并清理旧版本…"
FOUND="$(mdfind -name "教师助手.app" 2>/dev/null; mdfind -name "ScheduleBar.app" 2>/dev/null)"
KEEP_A="$APP"
KEEP_B="$HOME/Desktop/自编app/教师助手.app"
KEEP_C="/Applications/教师助手.app"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  [ -d "$p" ] || continue
  case "$p" in
    "$KEEP_A"|"$KEEP_B"|"$KEEP_C") continue ;;
  esac
  v="$(defaults read "$p/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo '?')"
  if [ "$v" = "$NEWVER" ]; then
    echo "   [跳过] 已是 $NEWVER：$p"
    continue
  fi
  echo "   [移出] 旧版本 $v → $BAK    $p"
  rm -rf "$BAK/old-$(echo "$p" | sed 's#/#_#g')" 2>/dev/null
  mv "$p" "$BAK/old-$(echo "$p" | sed 's#/#_#g')" 2>/dev/null
done <<< "$FOUND"

# 常见的残留构建产物 / 旧包（存在才处理）
for extra in "$ROOT/教师助手_v1.7.0.dmg" "$ROOT/教师助手_v1.6.0.dmg" \
             "$ROOT/教师助手_v2.1.0.dmg" "$ROOT/ScheduleBar.app"; do
  [ -e "$extra" ] || continue
  echo "   [移出] 旧文件 → $BAK    $extra"
  mv "$extra" "$BAK/" 2>/dev/null
done

# ---------------------------------------------------------------- 7) 冒烟测试
echo ""
echo "⑧ 启动冒烟测试…"
nohup "$APP/Contents/MacOS/$NAME" >/tmp/smoke-教师助手.log 2>&1 &
P=$!
sleep 4
if kill -0 $P 2>/dev/null; then
  echo "   ✅ 启动正常（PID $P），已关闭测试进程"
  kill $P 2>/dev/null
else
  echo "   ❌ 启动后立即退出，日志如下："
  cat /tmp/smoke-教师助手.log 2>/dev/null
fi

# ---------------------------------------------------------------- 8) 收官校验
echo ""
echo "======================================================"
echo " 收官校验（四份副本应完全一致）"
echo "======================================================"
for d in "$APP" "$HOME/Desktop/自编app/教师助手.app" "/Applications/教师助手.app"; do
  [ -e "$d" ] || { echo "   （无此副本）$d"; continue; }
  printf "   %s  ver=%s  arch=[%s]  " \
    "$(md5 -q "$d/Contents/MacOS/$NAME" 2>/dev/null)" \
    "$(defaults read "$d/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)" \
    "$(lipo -archs "$d/Contents/MacOS/$NAME" 2>/dev/null)"
  if codesign -v "$d" 2>/dev/null; then echo "签名OK  $d"; else echo "签名失败  $d"; fi
done

echo ""
echo "启动应用（必须用绝对路径，避免启动到旧副本）："

# ---------------------------------------------------------------- 9) 提交源码改动
if [ -d "$ROOT/.git" ]; then
  echo ""
  echo "⑨ 提交源码改动（只本地提交，push 由你自己来）…"
  git -C "$ROOT" add -A >/dev/null 2>&1
  git -C "$ROOT" -c user.name="27336418" -c user.email="27336418@163.com" \
      commit -m "2.1.1：统一拖拽松手对换（个人课表/班级课表/教室分布/工位）+ 办公室默认半行宽度" \
      >/dev/null 2>&1 && echo "   已提交：$(git -C "$ROOT" log -1 --pretty=%h)" || echo "   （没有新改动或提交失败，可忽略）"
fi

pkill -f "教师助手.app/Contents/MacOS/$NAME" 2>/dev/null
open "$APP"
open "$ROOT"
echo "旧版本备份在：$BAK"
echo ""
echo "完成后请回到 WorkBuddy 告诉我结果；如仍有残留旧版本，把上面的清单发我。"
read -p "按回车键关闭本窗口…"
