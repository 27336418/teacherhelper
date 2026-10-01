#!/bin/bash
# 在 macOS 上交叉编译 Windows 单文件 exe（纯 Go，无 CGO）
#   用法：./build-win.sh            → 编译 GUI 版 + 调试版到 dist/
#         ./build-win.sh --clean    → 先清理 dist/ 再编译
set -e
cd "$(dirname "$0")"
export GOOS=windows
export CGO_ENABLED=0

if [ "$1" = "--clean" ]; then rm -rf dist; fi
mkdir -p dist

for arch in amd64 arm64; do
  echo "▸ 编译 $arch"
  GOARCH=$arch go build -ldflags "-H windowsgui -s -w" -o "dist/教师助手.exe" . 2>/dev/null \
    || GOARCH=$arch go build -ldflags "-H windowsgui -s -w" -o dist/TeacherHelper.exe .
  if [ "$arch" = "amd64" ]; then
    GOARCH=$arch go build -o dist/教师助手_调试版.exe .
  fi
done

ls -la dist/
echo
echo "✓ 完成。把 dist/教师助手.exe 拷到 Windows 即可双击运行（首次弹窗需在 SmartScreen 里点「仍要运行」）。"
echo "  便携模式：在 exe 同目录建一个 data\\ 文件夹，把 macOS 数据目录里的 17 个 json 拷进去。"
