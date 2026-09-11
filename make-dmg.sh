#!/bin/bash
# 给 GitHub release 用的 dmg 打包脚本（在工作目录运行）
# 用法： ./make-dmg.sh                     # 打包当前 .app（默认名 教师助手_v1.6.0.dmg）
#       VERSION=1.7.0 ./make-dmg.sh       # 打指定版本
# 产物： 工作目录/教师助手_v${VERSION}.dmg （无加密，无压缩，访达双击即可挂载）
set -e

PROJECT="/Users/a123/WorkBuddy/2026-09-07-11-19-53"
APP="$PROJECT/教师助手.app"
WORK="$PROJECT"
VERSION="${VERSION:-1.6.0}"   # 默认与 Info.plist 一致
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
echo "上传命令（先安装 GitHub CLI 后执行）："
echo "  gh release create v${VERSION} '$DMG#教师助手 ${VERSION}' --title '教师助手 v${VERSION}' --notes-from-tag --repo <owner>/<repo>"
