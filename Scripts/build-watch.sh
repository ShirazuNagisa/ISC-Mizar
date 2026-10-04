#!/usr/bin/env bash
#
# 构建 watchOS 应用（模拟器）。
#
# 手表应用与手机应用共享 MizarApp（状态机）与 MizarKit，但**不**链接
# MizarScreens —— 平台上不可用的 API 因此不会出现在手表的编译里，
# 而那条边界由 target 划分来守（不是靠每个文件里的 #if）。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DEST="${MIZAR_WATCH_DEST:-platform=watchOS Simulator,name=Apple Watch Series 12 (46mm)}"
echo "==> xcodebuild（${DEST}）"
xcodebuild -project App/ISC-Mizar.xcodeproj -scheme MizarWatch \
  -destination "$DEST" -configuration Debug build >/dev/null
echo "✅ watchOS 应用构建通过"
