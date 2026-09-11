#!/bin/bash
# 给 GitHub release / version.json 用的 dmg 打包脚本（在工作目录运行）
# 用法： ./make-dmg.sh                     # 版本号自动取 .app 里的 Info.plist
#       VERSION=1.7.0 ./make-dmg.sh       # 强制指定版本
# 产物： 工作目录/教师助手_v${VERSION}.dmg （无加密，无压缩，访达双击即可挂载）
set -e

PROJECT="/Users/a123/WorkBuddy/2026-09-07-11-19-53"
APP="$PROJECT/教师助手.app"
WORK="$PROJECT"
# 默认版本号直接读 .app 的 Info.plist，避免脚本里的写死值与实际打包版本不一致
PLIST_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 1.0.0)"
VERSION="${VERSION:-$PLIST_VER}"
VOL="教师助手 v${VERSION}"
DMG="$WORK/教师助手_v${VERSION}.dmg"
STAGE="$WORK/.dmg-stage-$VERSION"

if [ ! -d "$APP" ]; then
  echo "找不到 $APP，请先构建"
  exit 1
fi

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/教师助手.app"
# 把「一键运行教师助手.command」也带上（Gatekeeper 麻烦时用）
if [ -f "$WORK/一键运行教师助手.command" ]; then
  cp "$WORK/一键运行教师助手.command" "$STAGE/"
fi

# 建 dmg（UDRO 读模式，未压缩）
hdiutil create -ov "$DMG" \
  -srcfolder "$STAGE" \
  -volname "$VOL" \
  -fs HFS+ \
  -format UDRO \
  -nospotlight
rm -rf "$STAGE"

echo "已生成：$DMG"
ls -lh "$DMG"
echo
echo "▸ 方式 A（推荐，不用 git、不用 Token）：浏览器打开"
echo "    https://github.com/27336418/teacherhelper"
echo "  用 Add file → Upload files 上传两个文件："
echo "    · version.json（把里面的 version / download 改成新版本号与 dmg 文件名）"
echo "    · 教师助手_v${VERSION}.dmg"
echo "  上传后应用内「检查更新」即可检测到新版本并自动下载。"
echo
echo "▸ 方式 B（正式 Release）："
echo "  gh release create v${VERSION} '$DMG#教师助手 ${VERSION}' --title '教师助手 v${VERSION}' --notes-from-tag --repo 27336418/teacherhelper"
