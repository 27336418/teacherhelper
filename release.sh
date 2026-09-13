#!/bin/bash
# ============================================================================
# 教师助手 · 发布流水线
# ----------------------------------------------------------------------------
# 阶段一（本地，全自动）：
#   改版本号 → 双架构编译 → 合成 universal → 签名 → 同步三份副本 → 校验
#   → 打 DMG → 写 version.json → 本地 git 提交      【绝不推送】
# 阶段二（对外，需人工确认后才允许跑）：
#   git push → 清 jsDelivr 缓存 → 三通道验证
#
# 用法：
#   ./release.sh --check                   只体检，不改动任何文件
#   ./release.sh -v 2.2.1 -n "更新说明文字"  阶段一（结束时提示「待确认」）
#   ./release.sh -v 2.2.1 --same-notes      阶段一（沿用 version.json 里的旧说明）
#   ./release.sh --push                    阶段二（推送 + 清缓存 + 验证）
#
# ⚠️ 铁律：推送到 GitHub 是对外动作，必须先问过用户。本脚本把「推送」单独
#    拆成 --push，阶段一跑完就停下；不要擅自连着跑 --push。
# ============================================================================
set -uo pipefail

PROJECT="/Users/a123/WorkBuddy/2026-09-07-11-19-53"
REPO="27336418/teacherhelper"
BRANCH="main"
MASTER="$PROJECT/教师助手.app"
SRC="$PROJECT/ScheduleBar"
COPIES=(
  "$PROJECT/教师助手.app"
  "/Users/a123/Desktop/自编app/教师助手.app"
  "/Applications/教师助手.app"
)
GIT_ID=(-c user.name=27336418 -c user.email=27336418@163.com)
PY="/Users/a123/.workbuddy/binaries/python/versions/3.13.12/bin/python3"
[ -x "$PY" ] || PY="/usr/bin/python3"

step() { printf '\n\033[1;36m▸ %s\033[0m\n' "$1"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$1"; }
die()  { printf '\n\033[1;31m✗ %s\033[0m\n' "$1"; exit 1; }

plist_get() { plutil -extract "$2" raw "$1" 2>/dev/null; }

# 仓库工作树体积 —— jsDelivr 对 /gh/ 仓库有 50MB 总大小上限，超了会 403 拒发新文件
repo_size_bytes() { git ls-files -z | xargs -0 stat -f '%z' 2>/dev/null | awk '{s+=$1} END {print s+0}'; }
human_size()     { awk -v b="${1:-0}" 'BEGIN{printf "%.1f MB", b/1048576}'; }
size_guard() {
  local RS; RS=$(repo_size_bytes)
  printf '  仓库工作树大小：%s（jsDelivr 上限 50 MB）\n' "$(human_size "$RS")"
  if [ "$RS" -gt 47185920 ]; then
    warn "已超过 jsDelivr 上限 —— 新文件会被它 403 拒绝，下载会退回 raw 与加速镜像"
    git ls-files '*.dmg' | while read -r f; do
      [ -f "$f" ] && printf '      %6s  %s\n' "$(du -h "$f" | cut -f1)" "$f"
    done
    echo "      建议：仓库里只留最新一个 dmg（旧版 git rm，历史仍在 git 中可按需取回）"
  else
    ok "体积未超限"
  fi
}

# ---------------------------------------------------------------- 参数解析
MODE="build"; NEWVER=""; NOTES=""; SAME_NOTES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check)      MODE="check" ;;
    --push)       MODE="push" ;;
    -v|--version) NEWVER="${2:-}"; shift ;;
    -n|--notes)   NOTES="${2:-}"; shift ;;
    --same-notes) SAME_NOTES=1 ;;
    *) die "未知参数：$1" ;;
  esac
  shift
done

cd "$PROJECT" || die "找不到项目目录 $PROJECT"

# ============================================================
#  体检模式
# ============================================================
if [ "$MODE" = "check" ]; then
  step "环境体检（不改动任何文件）"
  PVER="$(plist_get "$MASTER/Contents/Info.plist" CFBundleShortVersionString || echo '?')"
  PBUILD="$(plist_get "$MASTER/Contents/Info.plist" CFBundleVersion || echo '?')"
  ok "本地 .app 版本：$PVER (build $PBUILD)"
  ok "version.json 版本：$(plist_get "$PROJECT/version.json" version 2>/dev/null || $PY -c "import json;print(json.load(open('$PROJECT/version.json'))['version'])")"

  printf '  · 三份副本：\n'
  for d in "${COPIES[@]}"; do
    if [ -d "$d" ]; then
      printf '      %s  ver=%s build=%s [%s] md5=%s\n' "$d" \
        "$(plist_get "$d/Contents/Info.plist" CFBundleShortVersionString)" \
        "$(plist_get "$d/Contents/Info.plist" CFBundleVersion)" \
        "$(lipo -archs "$d/Contents/MacOS/ScheduleBar" 2>/dev/null)" \
        "$(md5 -q "$d/Contents/MacOS/ScheduleBar" 2>/dev/null | cut -c1-8)"
    else
      warn "缺少副本：$d"
    fi
  done

  step "推送通道"
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=12 -T git@github.com >/tmp/_ssh.out 2>&1 || true
  if grep -q "successfully authenticated" /tmp/_ssh.out; then
    ok "SSH 认证通过（$(grep -o 'Hi [0-9]*' /tmp/_ssh.out)）"
  else
    warn "SSH 认证失败：$(head -1 /tmp/_ssh.out)  —— 检查 ~/.ssh/config（22 端口国内常被切断，需走 443）"
  fi
  git fetch -q origin "$BRANCH" 2>/dev/null || warn "fetch 失败"
  LOC=$(git rev-parse HEAD); REM=$(git rev-parse "origin/$BRANCH" 2>/dev/null || echo none)
  [ "$LOC" = "$REM" ] && ok "本地与远端一致（${LOC}）" || warn "本地与远端不一致（本地 ${LOC:0:7} / 远端 ${REM:0:7}），有未推送提交"

  step "线上清单"
  ONLINE=$(curl -sL --max-time 15 -H 'Cache-Control: no-cache' \
    "https://cdn.jsdelivr.net/gh/$REPO@$BRANCH/version.json" 2>/dev/null \
    | $PY -c "import sys,json;d=json.load(sys.stdin);print(d['version'],d['download'])" 2>/dev/null || echo "读取失败")
  ok "jsDelivr 线上：$ONLINE"
  DLNAME=$(echo "$ONLINE" | awk '{print $2}')
  if [ -n "$DLNAME" ] && [ "$DLNAME" != "读取失败" ]; then
    CODE=$(curl -sIL --max-time 20 -o /dev/null -w '%{http_code}' \
      "https://cdn.jsdelivr.net/gh/$REPO@$BRANCH/$DLNAME")
    [ "$CODE" = "200" ] && ok "线上安装包可下载（200 ${DLNAME}）" || warn "线上安装包 $CODE  $DLNAME"
  fi
  step "仓库体积"
  size_guard
  echo; ok "体检结束"
  exit 0
fi

# ============================================================
#  阶段二：推送 + 清缓存 + 验证
# ============================================================
if [ "$MODE" = "push" ]; then
  V=$(cat version.json | $PY -c "import sys,json;print(json.load(sys.stdin)['version'])")
  D=$(cat version.json | $PY -c "import sys,json;print(json.load(sys.stdin)['download'])")
  step "推送 ${V} 到 GitHub（仓库 $REPO 分支 ${BRANCH}）"
  git push origin "$BRANCH" 2>&1 | tail -4 | sed 's/^/  /'
  LOC=$(git rev-parse HEAD); REM=$(git ls-remote origin "$BRANCH" | awk '{print $1}')
  [ "$LOC" = "$REM" ] || die "推送后远端($REM) 与本地($LOC) 不一致"
  ok "推送成功，远端 HEAD = ${LOC:0:7}"

  step "清 CDN 缓存（jsDelivr 对 @main 的缓存长达 12h）"
  for P in "version.json" "$D"; do
    ENC=$(printf '%s' "$P" | $PY -c "import sys,urllib.parse;print(urllib.parse.quote(sys.stdin.read()))")
    R=$(curl -s --max-time 25 "https://purge.jsdelivr.net/gh/$REPO@$BRANCH/$ENC" 2>/dev/null)
    echo "$R" | grep -q 'finished' && ok "已刷新 $P" || warn "$P 刷新返回：$(echo "$R" | head -c 90)"
  done

  step "三通道验证（以 App 真实读取路径为准）"
  for i in 1 2 3 4 5 6 7 8; do
    J=$(curl -sL --max-time 15 -H 'Cache-Control: no-cache' \
        "https://cdn.jsdelivr.net/gh/$REPO@$BRANCH/version.json" 2>/dev/null \
        | $PY -c "import sys,json;print(json.load(sys.stdin)['version'])" 2>/dev/null || echo '?')
    R=$(curl -sL --max-time 15 -H 'Cache-Control: no-cache' \
        "https://raw.githubusercontent.com/$REPO/$BRANCH/version.json" 2>/dev/null \
        | $PY -c "import sys,json;print(json.load(sys.stdin)['version'])" 2>/dev/null || echo '?')
    printf '  · 第 %d 次：jsDelivr=%s  raw=%s\n' "$i" "$J" "$R"
    [ "$J" = "$V" ] && [ "$R" = "$V" ] && break
    [ "$i" = "8" ] || sleep 20
  done
  ENC=$(printf '%s' "$D" | $PY -c "import sys,urllib.parse;print(urllib.parse.quote(sys.stdin.read()))")
  for U in "https://cdn.jsdelivr.net/gh/$REPO@$BRANCH/$ENC" "https://raw.githubusercontent.com/$REPO/$BRANCH/$ENC"; do
    C=$(curl -sIL --max-time 25 -o /dev/null -w '%{http_code}' "$U")
    if [ "${U#*jsdelivr}" != "$U" ]; then HOST="jsDelivr"; else HOST="raw"; fi
    printf '  · dmg HTTP %s（%s）\n' "$C" "$HOST"
    [ "$C" = "200" ] || [ "$HOST" != "jsDelivr" ] || warn "jsDelivr 拒绝该文件（多为仓库超 50MB）；App 会自动退回 raw 与加速镜像"
  done

  echo
  ok "已发布：${V}；App 内「检查更新」现在能检测到它"
  echo "  同事的机器上：菜单栏面板 → 检查更新 → 下载安装（可稍等 1~5 分钟让缓存彻底过期）"
  exit 0
fi

# ============================================================
#  阶段一：本地构建 → 打包 → 提交（不推送）
# ============================================================
[ -n "$NEWVER" ] || die "请用 -v 指定新版本号，例如：./release.sh -v 2.2.1 -n \"更新说明\""

CUR_VER="$(plist_get "$MASTER/Contents/Info.plist" CFBundleShortVersionString)"
CUR_BUILD="$(plist_get "$MASTER/Contents/Info.plist" CFBundleVersion)"
if [ "$NEWVER" = "$CUR_VER" ]; then
  warn "版本号与当前相同（${CUR_VER}），仅递增 build 号"
fi
NEWBUILD=$(( ${CUR_BUILD:-0} + 1 ))
if [ -n "$NOTES" ]; then
  NOTE_TEXT="$NOTES"
elif [ "$SAME_NOTES" = "1" ]; then
  NOTE_TEXT="$(cat version.json | $PY -c "import sys,json;print(json.load(sys.stdin).get('notes',''))")"
else
  die "请用 -n \"更新说明\" 写明本次改了什么（会写进 version.json 给用户看），或加 --same-notes 沿用旧说明"
fi

step "0/9 检查工作区"
if [ -n "$(git status --porcelain | grep -v '^??')" ]; then
  warn "有未提交的改动，会一并进入本次发布提交："
  git status --short | head -12 | sed 's/^/      /'
fi
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=12 -T git@github.com >/tmp/_ssh.out 2>&1 || true
grep -q "successfully authenticated" /tmp/_ssh.out && ok "推送通道正常（SSH/443）" \
  || warn "推送通道未就绪：阶段一不受影响，但阶段二会失败（检查 ~/.ssh/config 与 GitHub 公钥）"

step "1/9 备份当前 .app 并停掉运行中的实例"
BK="/tmp/教师助手旧版备份-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BK"
[ -e "$BK/教师助手-${CUR_VER}.app" ] || cp -R "$MASTER" "$BK/教师助手-${CUR_VER}.app"
ok "已备份 $CUR_VER → $BK"
ls -dt /tmp/教师助手旧版备份-* 2>/dev/null | tail -n +4 | while read -r d; do rm -rf "$d"; done
pkill -f '教师助手.app/Contents/MacOS/ScheduleBar' 2>/dev/null && ok "已退出旧实例" || true
sleep 1

step "2/9 编译 arm64 + x86_64（release）"
cd "$SRC" || die "找不到 $SRC"
find Sources -name "*.swift" -exec touch {} +      # 防 SwiftPM 假重编
for ARCH in arm64 x86_64; do
  printf '  · 正在编译 %s …\n' "$ARCH"
  swift build -c release --arch "$ARCH" --disable-sandbox >/tmp/build-$ARCH.log 2>&1 \
    || { tail -25 /tmp/build-$ARCH.log | sed 's/^/      /'; die "$ARCH 编译失败"; }
  ok "$ARCH 编译完成"
done
cd "$PROJECT" || exit 1

step "3/9 合成 universal + 签名 master"
lipo -create -output /tmp/ScheduleBar-univ \
  "$SRC/.build/arm64-apple-macosx/release/ScheduleBar" \
  "$SRC/.build/x86_64-apple-macosx/release/ScheduleBar" || die "lipo 失败"
cp /tmp/ScheduleBar-univ "$MASTER/Contents/MacOS/ScheduleBar"
plutil -replace CFBundleShortVersionString -string "$NEWVER" "$MASTER/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$NEWBUILD" "$MASTER/Contents/Info.plist"
xattr -d com.apple.FinderInfo "$MASTER" 2>/dev/null || true
find "$MASTER" -print0 | xargs -0 xattr -c 2>/dev/null || true
codesign --remove-signature "$MASTER" 2>/dev/null || true
SIGNED=0
for i in 1 2 3; do
  codesign --force --deep --sign - --timestamp=none "$MASTER" 2>/dev/null || true
  if codesign -v "$MASTER" 2>/dev/null; then SIGNED=1; break; fi
  warn "签名重试 $i"
done
[ "$SIGNED" = "1" ] || die "codesign 连续失败"
ok "universal $(lipo -archs "$MASTER/Contents/MacOS/ScheduleBar") 签名 OK"

step "4/9 同步到三份副本（ditto 整包，保证 md5 一致）"
for DST in "${COPIES[@]:1}"; do
  [ -d "$DST" ] || { warn "跳过不存在的副本：$DST"; continue; }
  chmod -R u+w "$DST" 2>/dev/null || true
  rm -rf "$DST"
  ditto "$MASTER" "$DST" || die "同步失败：$DST"
  ok "$DST"
done

step "5/9 校验三份副本一致性"
M0=""
FAIL=0
for d in "${COPIES[@]}"; do
  [ -d "$d" ] || continue
  M="$(md5 -q "$d/Contents/MacOS/ScheduleBar")"
  V="$(plist_get "$d/Contents/Info.plist" CFBundleShortVersionString)"
  B="$(plist_get "$d/Contents/Info.plist" CFBundleVersion)"
  A="$(lipo -archs "$d/Contents/MacOS/ScheduleBar")"
  SU="签名OK"; codesign -v "$d" 2>/dev/null || { SU="签名失败"; FAIL=1; }
  printf '  %s  ver=%s build=%s [%s] %s\n' "$(echo "$M" | cut -c1-8)" "$V" "$B" "$A" "$SU"
  [ -z "$M0" ] && M0="$M"
  [ "$M" = "$M0" ] || { warn "md5 不一致：$d"; FAIL=1; }
done
[ "$FAIL" = "0" ] || die "副本校验失败（md5/签名）"
ok "三份完全一致：$M0"

step "6/9 冒烟测试"
nohup "$MASTER/Contents/MacOS/ScheduleBar" >/tmp/smoke.log 2>&1 & SP=$!
sleep 4
if kill -0 $SP 2>/dev/null; then kill $SP 2>/dev/null; ok "启动正常"; else cat /tmp/smoke.log | tail -10; die "启动失败"; fi

step "7/9 生成 DMG"
rm -f "$PROJECT/教师助手_v${NEWVER}.dmg"
VERSION="$NEWVER" ./make-dmg.sh >/tmp/dmg.log 2>&1 || { tail -15 /tmp/dmg.log; die "DMG 生成失败"; }
DMG="$PROJECT/教师助手_v${NEWVER}.dmg"
hdiutil verify "$DMG" >/dev/null 2>&1 || die "DMG 校验失败"
ok "$(basename "$DMG")  $(du -h "$DMG" | cut -f1)  SHA256=$(shasum -a 256 "$DMG" | cut -c1-16)…"

step "8/9 更新 version.json"
NOTES="$NOTE_TEXT" VERSION="$NEWVER" DMGFILE="$(basename "$DMG")" $PY - "$PROJECT/version.json" <<'PYEOF'
import json, os, sys
p = sys.argv[1]
d = {"version": os.environ["VERSION"],
     "download": os.environ["DMGFILE"],
     "notes": os.environ["NOTES"]}
json.dump(d, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print("  version  =", d["version"])
print("  download =", d["download"])
PYEOF

step "9/9 本地提交（不推送）"
git add -A
git add -f "教师助手_v${NEWVER}.dmg"   # dmg 被 .gitignore 忽略，发布时必须强制入库
if git diff --cached --quiet; then
  warn "没有需要提交的改动"
else
  git "${GIT_ID[@]}" commit -q -m "教师助手 ${NEWVER}（build ${NEWBUILD}）：${NOTE_TEXT}

- version.json → ${NEWVER} / 教师助手_v${NEWVER}.dmg
- 双架构 universal、三份副本 md5 一致（${M0:0:8}）、签名与冒烟通过
- DMG hdiutil verify 通过" && ok "已提交 $(git log --oneline -1)"
fi

step "仓库体积检查（影响下载）"
size_guard

echo
printf '\033[1;33m════════════════════════════════════════════════════════\033[0m\n'
printf '\033[1;33m  阶段一完成：本地已全部就绪，但【尚未推送到 GitHub】\033[0m\n'
printf '\033[1;33m════════════════════════════════════════════════════════\033[0m\n'
echo "  新版本   ：$NEWVER (build $NEWBUILD)"
echo "  安装包   ：$DMG"
echo "  待推送   ：$(git log --oneline origin/$BRANCH..HEAD 2>/dev/null | wc -l | tr -d ' ') 个提交"
echo
echo "  要上传到 GitHub 吗？确认后执行：  ./release.sh --push"
echo
pkill -f '教师助手.app/Contents/MacOS/ScheduleBar' 2>/dev/null || true
sleep 1
open "$MASTER" && ok "已启动 $NEWVER"
