#!/usr/bin/env bash
#
# 演示模式的验收截图：四个页签各一张，外加一张横幅特写。
#
# 用法：
#
#	./Scripts/demo-screenshots.sh                默认 iPad (A16)
#	./Scripts/demo-screenshots.sh "iPhone 17 Pro" 换设备
#
# 产出到 Build/screens/。
#
# # 它为什么存在
#
# 演示模式是"审核员能不能用"的唯一依据，而它的验收判据是**画面**：
# 四个页签里都得有真实可信的数据，而且顶上那条"演示数据"横幅必须看得见。
# 这个脚本把那套动作固定下来 —— 手工做一遍要十几条命令，而漏掉一步
# （比如忘了带 MIZAR_HEADLESS，引导页会盖住整屏）得到的是几张废图。
#
# # 页签为什么用环境变量切
#
# `xcrun simctl` 没有点击能力，而 Xcode 27 里 Simulator 不再是
# Developer/Applications 下那个可以脚本化的独立 app（`open -a Simulator`
# 在这台机器上找不到它）。因此演示构建里留了一个 `MIZAR_DEMO_TAB` 入口
# （见 Sources/MizarScreens/RootView.swift 的 TabsView），它只在
# `#if MIZAR_DEMO` 里 —— 生产构建没有这一段。
#
# # MIZAR_HEADLESS 为什么必须带
#
# 全新安装带着"还没走过首启引导"的标记，引导页会盖在整个界面上。
# `MIZAR_HEADLESS=1` 是应用壳为脚本驱动留的入口（它同时关掉引导页）。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DEVICE="${1:-${MIZAR_IOS_DEVICE:-iPad (A16)}}"
DD="${MIZAR_DEMO_DERIVED_DATA:-$ROOT/Build/DerivedData-demo}"
OUT="$ROOT/Build/screens"

echo "==> 构建演示版本"
./Scripts/build-ios.sh --demo

echo "==> 找到产物"
APP_DIR="$(xcodebuild -project App/ISC-Mizar.xcodeproj -scheme Mizar \
  -destination "platform=iOS Simulator,name=$DEVICE" -configuration Debug \
  -derivedDataPath "$DD" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}' | head -1)"
APP="$APP_DIR/ISC Mizar.app"
if [ ! -d "$APP" ]; then
  echo "❌ 找不到构建产物：$APP" >&2
  exit 1
fi

echo "==> 启动模拟器：$DEVICE"
xcrun simctl boot "$DEVICE" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null 2>&1 || true

# 先卸再装：否则上一轮的引导标记会留下来，而那是引导页出不出现的判据。
xcrun simctl terminate "$DEVICE" app.isc.mizar >/dev/null 2>&1 || true
xcrun simctl uninstall "$DEVICE" app.isc.mizar >/dev/null 2>&1 || true
xcrun simctl install "$DEVICE" "$APP"

mkdir -p "$OUT"

# 四个页签，顺序与 TabsView 里的 tag 一致。
TABS="overview services resources dns"
INDEX=0
for name in $TABS; do
  xcrun simctl terminate "$DEVICE" app.isc.mizar >/dev/null 2>&1 || true
  SIMCTL_CHILD_MIZAR_HEADLESS=1 SIMCTL_CHILD_MIZAR_DEMO_TAB="$INDEX" \
    xcrun simctl launch "$DEVICE" app.isc.mizar >/dev/null
  # 等首屏数据到位。演示传输是即时的，这几秒是留给 SwiftUI 画完第一帧与
  # 那一轮指标刷新（`startMetricsPolling` 的第一次）的。
  sleep 7
  xcrun simctl io "$DEVICE" screenshot "$OUT/$((INDEX + 1))-$name.png" >/dev/null 2>&1
  echo "    $((INDEX + 1))-$name.png"
  INDEX=$((INDEX + 1))
done

echo "==> 横幅特写"
# 横幅在最顶上（状态栏之下），因此要**从顶部**裁一条。
#
# 为什么不用 `sips -c`：它只从中心裁，而 `--cropOffset` 并不是"从左上角
# 偏移"—— 实测顶不上去（给一个能让它到顶的负偏移会得到全黑的越界图）。
# 为什么不用 Python + Pillow：这台机器的 python3 没有装它，而"跑不通就
# 跳过横幅"会让验收要求的五张图少一张。`Scripts/crop-top.swift` 用的是
# 这个仓库本来就依赖的 Swift 工具链（Package.swift 的 tools-version 6.4）。
HEIGHT="$(sips -g pixelHeight "$OUT/1-overview.png" | awk -F': ' '/pixelHeight/{print $2}')"
# 顶部的 10.5%：状态栏 + 横幅。按比例算而不是写死像素 —— 换设备时截图
# 高度差很多（iPhone 与 iPad 完全不是一回事）。
TOP="$((HEIGHT * 105 / 1000))"
if swift "$ROOT/Scripts/crop-top.swift" "$OUT/1-overview.png" "$OUT/5-demo-banner.png" "$TOP"; then
  echo "    5-demo-banner.png（顶部 $TOP 行）"
else
  echo "    ❌ 横幅特写裁不出来" >&2
  exit 1
fi

echo
echo "✅ 截图在 $OUT"
ls -la "$OUT"
