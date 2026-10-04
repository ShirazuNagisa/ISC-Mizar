#!/usr/bin/env bash
#
# Mizar 的逻辑层测试。
#
# 它只跑 **MizarKit**（纯 Foundation）：传输、契约解析、配对码、指纹固定、
# 多服务端持久化。这些都是"错了之后症状与原因隔得很远"的东西，而它们
# 恰好全都不需要模拟器 —— 因此在 macOS 上跑得又快又能断言。
#
# 界面层不在这里：SwiftUI 的布局问题靠单元测试断言不出来，
# 它由 Scripts/build-ios.sh 的构建与真机清单覆盖。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> swift build"
swift build

echo "==> swift test"
swift test

# 格式检查。Swift 没有官方的格式化器，因此这里只挡住最低级的一类：
# 文件末尾缺换行、以及行尾的空格。
if grep -rn " $" --include="*.swift" Sources Tests 2>/dev/null | head -5; then
  echo "❌ 上面这些行有行尾空格" >&2
  exit 1
fi

# 版本号只有唯一一个事实来源（MizarKit 里的 MizarVersion.current），
# 而 Info.plist 是系统必须看到的那一份 —— 两者不一致时症状是
# "设置页显示的版本和 App Store 上的不一样"，那是最难被发现的一类偏差。
VERSION="$(sed -n 's/.*public static let current = "\(.*\)"/\1/p' Sources/MizarKit/Version.swift)"
for plist in App/Mizar-iOS/Info.plist App/Mizar-watchOS/Info.plist; do
  PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || echo '')"
  if [ "$PLIST_VERSION" != "$VERSION" ]; then
    echo "❌ $plist 的版本是 \"$PLIST_VERSION\"，而 MizarVersion.current 是 \"$VERSION\"" >&2
    exit 1
  fi
done
echo "✅ 版本一致：${VERSION}（MizarVersion.current 与两个 Info.plist）"

echo "✅ MizarKit 全部通过"
