#!/usr/bin/env bash
#
# 对着**真实内核**跑一遍 Mizar 的配对与连接。
#
# 单元测试用的是假传输，因此证明不了"真的能连上" —— 而这条链路上最可能
# 出问题的一环（自签证书的公钥固定、TLS 握手、候选地址）恰好只有真链路
# 才能验证。
#
# 需要 ISC-Core 的 isc 二进制；默认 /tmp/isc-acc/isc。
#   CGO_ENABLED=0 go build -o /tmp/isc-acc/isc ./cmd/isc   （在 ISC-Core 里）
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BIN="${ISC_BIN:-/tmp/isc-acc/isc}"
PORT="${MIZAR_TEST_PORT:-18789}"
pass=0; fail=0
ok()   { printf '  ✅ %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  ❌ %s\n' "$1"; fail=$((fail+1)); }
head_() { printf '\n=== %s ===\n' "$1"; }

if [ ! -x "$BIN" ]; then
  echo "找不到 $BIN" >&2
  echo "先构建：cd ../ISC-Core && CGO_ENABLED=0 go build -o $BIN ./cmd/isc" >&2
  exit 2
fi

DIR="$(mktemp -d "${TMPDIR:-/tmp}/mizar-acc.XXXXXX")"
STATE="$(mktemp -d "${TMPDIR:-/tmp}/mizar-state.XXXXXX")"
export ISC_DATA_DIR="$DIR"
DPID=""
cleanup() {
  [ -n "$DPID" ] && kill "$DPID" 2>/dev/null
  wait "$DPID" 2>/dev/null
  rm -rf "$DIR" "$STATE"
}
trap cleanup EXIT

json_field() { python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1],""))' "$1"; }

head_ "启用远程访问并生成配对会话"

# 端口必须真的空着。
#
# 上一轮没退干净的守护进程会占着它（`kill` 之后进程偶尔还活得比你想象的
# 久），而那时的症状是"配对失败：服务器身份与配对码里固定的不一致" ——
# 看起来像客户端的 bug，实际是本机还跑着上一轮的内核。多这一句，
# 环境问题就不会被读成代码问题。
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "❌ 端口 $PORT 已被占用：多半是上一轮没有退出的内核" >&2
  lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >&2
  exit 2
fi

"$BIN" daemon run >"$DIR/daemon.log" 2>&1 &
DPID=$!
for _ in $(seq 1 60); do "$BIN" status >/dev/null 2>&1 && break; sleep 0.25; done
"$BIN" status >/dev/null 2>&1 || { bad "内核没有起来"; sed -n '1,30p' "$DIR/daemon.log"; exit 1; }
ok "内核就绪"

"$BIN" remote enable --port "$PORT" --json >/dev/null || bad "开启远程访问失败"
PAIR="$("$BIN" remote pair --role operator --label "mizar-acceptance" --json)"
# 配对密钥从二维码载荷里取 —— 它是唯一的配对凭证（六位码已删除）。
CODE="$(printf '%s' "$PAIR" | python3 -c 'import json,sys; print(json.loads(json.load(sys.stdin)["qr_payload"])["secret"])')"
PAYLOAD="$(printf '%s' "$PAIR" | json_field qr_payload)"
[ -n "$CODE" ] && ok "配对会话已生成（密钥 ${CODE:0:8}…）" || { bad "没有拿到配对码"; exit 1; }

head_ "MizarKit：扫码路径 —— 真 TLS + 二维码里的公钥指纹"
if swift run --quiet MizarAcceptance pair-qr "$PAYLOAD" "$STATE" "127.0.0.1:$PORT" 2>&1 | sed 's/^/  /'; then
  ok "扫码配对通过（TLS 层比对了二维码里的指纹）"
else
  bad "扫码配对失败"
fi

head_ "MizarKit：配对链接 —— 与扫码走同一条路径"
# 六位码那条路已删除。配对链接就是它的替代：与二维码装的是同一份载荷，
# 只是载体不同 —— 传过去、粘一次即可。会话是一次性的，因此单独开一个。
PAIR2="$("$BIN" remote pair --role viewer --label "mizar-link" --json)"
LINK2="$(printf '%s' "$PAIR2" | json_field qr_link)"
STATE2="$(mktemp -d "${TMPDIR:-/tmp}/mizar-state2.XXXXXX")"
if swift run --quiet MizarAcceptance pair-link "$LINK2" "$STATE2" 2>&1 | sed 's/^/  /'; then
  ok "配对链接通过（与扫码同一条路径）"
else
  bad "配对链接失败"
fi
rm -rf "$STATE2"

head_ "MizarKit：重连并读取真实数据"
if swift run --quiet MizarAcceptance status "$STATE" 2>&1 | sed 's/^/  /'; then
  ok "真链路读取通过"
else
  bad "真链路读取失败"
fi

head_ "吊销之后必须变成「需要重新配对」"
"$BIN" remote devices --json | python3 -c '
import json,sys
items = json.load(sys.stdin)["items"]
print([d["id"] for d in items if d["label"] == "mizar-acceptance"][0])
' > "$STATE/device" 2>/dev/null
DEVICE="$(cat "$STATE/device" 2>/dev/null || true)"
if [ -n "$DEVICE" ]; then
  # 吊销**必须确认生效**，然后再去问客户端。
  #
  # 原来这里是 `revoke ... >/dev/null`：退出码被丢掉了，于是"吊销根本没
  # 执行"与"客户端判错了"在输出上长得一模一样 —— 一次内核侧的偶发失败
  # 会被读成客户端的 bug（这个坑真的踩到过：客户端报 online，而设备表里
  # 那台设备的 revoked_at 是空的）。设备表里的 revoked_at 是唯一的证据，
  # 因此这里直接把它读出来看一眼。
  if ! "$BIN" remote revoke "$DEVICE" --json >/dev/null 2>&1; then
    bad "吊销命令没有成功（这一步不成立时，下面的判断必然是 online）"
  fi
  MARKED="$("$BIN" remote devices --json 2>/dev/null | python3 -c '
import json,sys
items = json.load(sys.stdin)["items"]
hit = [d for d in items if d["id"] == sys.argv[1]]
print((hit[0].get("revoked_at") or "") if hit else "")
' "$DEVICE" 2>/dev/null || true)"
  [ -n "$MARKED" ] || bad "服务端没有把设备 $DEVICE 标记为已吊销"

  if swift run --quiet MizarAcceptance expect "$STATE" needsPairing 2>&1 | sed 's/^/  /'; then
    ok "吊销后客户端立刻改判为需要重新配对"
  else
    bad "吊销之后客户端仍然以为在线"
  fi
else
  bad "设备列表里找不到刚配对的设备"
fi

printf '\n========================================\n'
printf '  通过 %d 项，失败 %d 项\n' "$pass" "$fail"
printf '========================================\n'
[ "$fail" -eq 0 ]
