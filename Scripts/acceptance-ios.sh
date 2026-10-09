#!/usr/bin/env bash
#
# 在 **iOS 模拟器**上跑一遍真实配对。
#
# # 为什么这一步不能省
#
# macOS 上跑通的 TLS 公钥固定，证明不了 iOS 上也通 —— ATS 是 iOS 特有的
# 一层约束。这条脚本把整个应用装进模拟器，用一条配对链接驱动它，
# 再截图看结果：连接真的建立了，还是被 ATS 悄悄挡掉了。
#
# 需要 ISC-Core 的 isc 二进制与一个已启动的 iOS 模拟器。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BIN="${ISC_BIN:-/tmp/isc-acc/isc}"
DEVICE="${MIZAR_IOS_DEVICE:-iPad (A16)}"
PORT="${MIZAR_TEST_PORT:-18790}"
pass=0; fail=0
ok()   { printf '  ✅ %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  ❌ %s\n' "$1"; fail=$((fail+1)); }
head_() { printf '\n=== %s ===\n' "$1"; }

[ -x "$BIN" ] || { echo "找不到 $BIN" >&2; exit 2; }

DIR="$(mktemp -d "${TMPDIR:-/tmp}/mizar-ios.XXXXXX")"
export ISC_DATA_DIR="$DIR"
DPID=""
cleanup() {
  [ -n "$DPID" ] && kill "$DPID" 2>/dev/null
  wait "$DPID" 2>/dev/null
  rm -rf "$DIR"
}
trap cleanup EXIT

json_field() { python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1],""))' "$1"; }

head_ "启动内核并开启远程访问（:${PORT}）"
"$BIN" daemon run >"$DIR/daemon.log" 2>&1 &
DPID=$!
for _ in $(seq 1 60); do "$BIN" status >/dev/null 2>&1 && break; sleep 0.25; done
"$BIN" remote enable --port "$PORT" --json >/dev/null && ok "远程访问已开启" || bad "开启失败"

head_ "构建并安装应用"
DEST="platform=iOS Simulator,name=$DEVICE"
xcodebuild -project App/ISC-Mizar.xcodeproj -scheme Mizar -destination "$DEST" -configuration Debug build >/dev/null 2>&1 \
  && ok "构建通过" || { bad "构建失败"; exit 1; }
APP_DIR=$(xcodebuild -project App/ISC-Mizar.xcodeproj -scheme Mizar -destination "$DEST" -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}' | head -1)
xcrun simctl boot "$DEVICE" >/dev/null 2>&1 || true
sleep 8
xcrun simctl terminate "$DEVICE" app.isc.mizar >/dev/null 2>&1 || true
xcrun simctl uninstall "$DEVICE" app.isc.mizar >/dev/null 2>&1 || true
xcrun simctl install "$DEVICE" "$APP_DIR/ISC Mizar.app" >/dev/null 2>&1 \
  && ok "已安装到模拟器" || { bad "安装失败"; exit 1; }

head_ "用配对链接驱动它（真实 TLS + 公钥固定）"
# 二维码里的地址是局域网地址，而模拟器与内核在同一台机器上 ——
# 用回环把它换掉，去掉一个与代码无关的失败源（防火墙）。
PAIR="$("$BIN" remote pair --role operator --label "ios-simulator" --json)"
PAYLOAD="$(printf '%s' "$PAIR" | json_field qr_payload)"
LINK=$(python3 - "$PAYLOAD" <<'PY'
import base64, json, sys
p = json.loads(sys.argv[1])
p["addresses"] = ["127.0.0.1:%s" % p["addresses"][0].rsplit(":", 1)[1]]
raw = json.dumps(p, separators=(",", ":")).encode()
print("isc-remote://pair?d=" + base64.urlsafe_b64encode(raw).decode().rstrip("="))
PY
)

# 用 SIMCTL_CHILD_ 前缀把链接作为环境变量交给应用。
#
# 不走 `simctl openurl`：那会弹出系统的"在 ISC Mizar 中打开？"确认框，
# 而 simctl 没有点击能力 —— 脚本会卡在一个谁也点不掉的弹窗上。
SIMCTL_CHILD_MIZAR_HEADLESS=1 SIMCTL_CHILD_MIZAR_PAIR_LINK="$LINK" \
  xcrun simctl launch "$DEVICE" app.isc.mizar >/dev/null 2>&1 \
  && ok "已启动应用并注入配对链接" || bad "启动失败"
sleep 12
xcrun simctl io "$DEVICE" screenshot "$DIR/paired.png" >/dev/null 2>&1

head_ "结果"
# 截图留档：这一条检查的判据是**界面上有没有出现那台服务器**，
# 而那是图像，不是文本 —— 因此把它存下来供人（或下一次运行）复核。
echo "  截图：$DIR/paired.png"
if [ -f "$DIR/paired.png" ]; then
  cp "$DIR/paired.png" "$ROOT/Build/paired-ios.png" 2>/dev/null || {
    mkdir -p "$ROOT/Build" && cp "$DIR/paired.png" "$ROOT/Build/paired-ios.png"
  }
  ok "已保存截图到 Build/paired-ios.png"
else
  bad "没有拿到截图"
fi

head_ "手表应用：装得上、起得来、说得出话"
# 手表没有摄像头也没有键盘，因此它**从不自己配对** —— 配置全部来自
# 手机。这一节验证的是它至少能在没有配置时把用户指回手机，
# 而不是留一个空白屏（那会让用户以为手表坏了）。
WATCH_DEVICE="${MIZAR_WATCH_DEVICE:-Apple Watch Series 12 (46mm)}"
WATCH_DEST="platform=watchOS Simulator,name=$WATCH_DEVICE"
if xcodebuild -project App/ISC-Mizar.xcodeproj -scheme MizarWatch -destination "$WATCH_DEST" -configuration Debug build >/dev/null 2>&1; then
  ok "watchOS 应用构建通过"
  WATCH_DIR=$(xcodebuild -project App/ISC-Mizar.xcodeproj -scheme MizarWatch -destination "$WATCH_DEST" -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}' | head -1)
  xcrun simctl boot "$WATCH_DEVICE" >/dev/null 2>&1 || true
  sleep 20
  xcrun simctl install "$WATCH_DEVICE" "$WATCH_DIR/ISC Mizar Watch.app" >/dev/null 2>&1 \
    && ok "已安装到手表模拟器" || bad "安装失败"
  xcrun simctl launch "$WATCH_DEVICE" app.isc.mizar.watchkitapp >/dev/null 2>&1 \
    && ok "手表应用启动成功" || bad "启动失败"
  sleep 8
  xcrun simctl io "$WATCH_DEVICE" screenshot "$ROOT/Build/watch-os.png" >/dev/null 2>&1 \
    && ok "已保存截图到 Build/watch-os.png" || bad "没有拿到截图"
else
  bad "watchOS 构建失败"
fi

head_ "服务端侧的证据"
# 服务端侧的证据：设备列表里应当出现那台模拟器。
DEVICES="$("$BIN" remote devices --json)"
if printf '%s' "$DEVICES" | grep -q '"ios-simulator"'; then
  ok "服务端记录到了这台设备 —— 配对真的完成了（ATS 没有挡住自签证书）"
else
  bad "服务端没有这台设备：配对没有完成"
fi

# 版本号要真的走到服务端。
#
# 它是 `MizarVersion.current` 唯一能被**外部**观察到的地方 —— 常量写错、
# 忘了随设备信息上报、或者内核没存，三种情况在这里都会显形，而在客户端
# 内部怎么断言都看不出来。
# 版本号从 `Version.swift` **读**出来，而不是写死。
#
# 写死的版本号会在每次发版时变成一条永远失败的检查 —— 而它失败的样子
# 与"版本号根本没上报"一模一样，于是下一个人会去查上报链路，
# 而真正要改的是这个字符串。v0.2.0 发版时就是这样漏掉的。
EXPECTED="$(grep -o 'current = "[^"]*"' Sources/MizarKit/Version.swift | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
if [ -z "$EXPECTED" ]; then
  bad "读不出 MizarVersion.current —— 脚本与源码已经脱节"
elif printf '%s' "$DEVICES" | grep -q "\"app_version\": *\"$EXPECTED\""; then
  ok "服务端看到的是 Mizar v$EXPECTED"
else
  bad "服务端没有收到应用版本号（期望 v${EXPECTED}）"
fi

printf '\n========================================\n'
printf '  通过 %d 项，失败 %d 项\n' "$pass" "$fail"
printf '========================================\n'
[ "$fail" -eq 0 ]
