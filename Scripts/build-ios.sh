#!/usr/bin/env bash
#
# 构建 iOS / iPadOS 应用（模拟器）。
#
# 这里用 xcodebuild 而不是 swift build：SwiftPM 不产出 .app。
# 但**绝大部分代码不经过这一步** —— 它们在包里，由 Scripts/test.sh 的
# `swift build` 在 macOS 上编译。这一步只验证 Xcode 工程本身
# （Info.plist、entitlements、包依赖的链接）。
#
# 用法：
#
#	./Scripts/build-ios.sh           生产构建（默认）
#	./Scripts/build-ios.sh --demo    演示构建（MIZAR_DEMO=1，见下）
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DEMO=0
for arg in "$@"; do
  case "$arg" in
    --demo) DEMO=1 ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：${arg}（只认 --demo）" >&2; exit 2 ;;
  esac
done

DEST="${MIZAR_IOS_DEST:-platform=iOS Simulator,name=iPad (A16)}"

# 演示构建走**独立的 DerivedData**。
#
# Xcode 会缓存 Package.swift 的求值结果，而 `MIZAR_DEMO` 正是那次求值的一个
# 输入（见 Package.swift）。共用一份 DerivedData 时，先建演示再建生产，
# 生产那一遍可能仍然拿到缓存的"演示开着" —— 而那意味着**演示数据被归档**。
# 两条路各用一份目录之后，这种串味在物理上不可能发生。
#
# 第二层兜底在 Scripts/archive.sh：它在归档产物里搜演示字符串，搜到就失败。
if [ "$DEMO" = "1" ]; then
  export MIZAR_DEMO=1
  DD="${MIZAR_DEMO_DERIVED_DATA:-$ROOT/Build/DerivedData-demo}"
  echo "==> 演示构建（MIZAR_DEMO=1）"
  echo "    DerivedData：$DD"
else
  unset MIZAR_DEMO
  DD=""
  echo "==> 生产构建"
fi

# `-derivedDataPath` 只在演示那一遍才加：生产构建保持原来的行为（用系统
# 默认的 DerivedData），这样 MIZAR_IOS_DEST / 增量缓存 / 别人本地的习惯
# 都不受影响。
build() {
  if [ -n "$DD" ]; then
    xcodebuild -project App/ISC-Mizar.xcodeproj -scheme Mizar \
      -destination "$DEST" -configuration Debug -derivedDataPath "$DD" "$@"
  else
    xcodebuild -project App/ISC-Mizar.xcodeproj -scheme Mizar \
      -destination "$DEST" -configuration Debug "$@"
  fi
}

echo "==> xcodebuild（${DEST}）"
build build | grep -E "error:|warning: .*(unused|deprecated)|BUILD" || true

# 让构建失败**真的**失败：上面的 grep 会吃掉退出码。
build build >/dev/null

if [ "$DEMO" = "1" ]; then
  echo "✅ iOS 演示构建通过（假数据已编译进去；生产构建不受影响）"
else
  echo "✅ iOS 应用构建通过"
fi
