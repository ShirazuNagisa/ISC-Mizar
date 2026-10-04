#!/usr/bin/env bash
#
# 构建 iOS / iPadOS 应用（模拟器）。
#
# 这里用 xcodebuild 而不是 swift build：SwiftPM 不产出 .app。
# 但**绝大部分代码不经过这一步** —— 它们在包里，由 Scripts/test.sh 的
# `swift build` 在 macOS 上编译。这一步只验证 Xcode 工程本身
# （Info.plist、entitlements、包依赖的链接）。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DEST="${MIZAR_IOS_DEST:-platform=iOS Simulator,name=iPad (A16)}"
echo "==> xcodebuild（${DEST}）"
xcodebuild -project App/ISC-Mizar.xcodeproj -scheme Mizar \
  -destination "$DEST" -configuration Debug build \
  | grep -E "error:|warning: .*(unused|deprecated)|BUILD" || true

# 让构建失败**真的**失败：上面的 grep 会吃掉退出码。
xcodebuild -project App/ISC-Mizar.xcodeproj -scheme Mizar \
  -destination "$DEST" -configuration Debug build >/dev/null
echo "✅ iOS 应用构建通过"
