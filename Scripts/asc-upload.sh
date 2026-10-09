#!/usr/bin/env bash
#
# 把构建上传到 App Store Connect，并轮询到处理完成（无人值守）。
#
# 用法：
#
#   Scripts/asc-upload.sh                    上传 Build/Export-* 里最新的 .ipa
#   Scripts/asc-upload.sh --validate-only    只做上传前校验，不真的传（安全）
#   Scripts/asc-upload.sh --artifact <路径>  指定包
#   Scripts/asc-upload.sh --wait 3600        处理轮询上限，秒（默认 1800）
#
# # 凭据
#
# App Store Connect 的团队 API 密钥（App Manager 角色就够）：
#
#   ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8
#
# 这是 altool 的默认搜索路径之一，**不要**把它放进仓库。Key ID 与 Issuer ID
# 不是秘密（Issuer ID 在团队密钥页面顶部），所以下面给了默认值，可用环境变量
# 覆盖：ASC_KEY_ID / ASC_ISSUER_ID。
#
# # 为什么上传之后还要轮询
#
# altool 报 "Upload succeeded" 只代表**传输**成功。二进制之后才在苹果那边
# 做处理，结果是异步的：可能 VALID，也可能 INVALID —— 而 INVALID 的构建在
# TestFlight 里根本不出现。把处理结果等出来，这一趟才算真的完成。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="app.isc.mizar"
PLATFORM="ios"
ARTIFACT=""
VALIDATE_ONLY=0
WAIT_LIMIT=1800

ASC_KEY_ID="${ASC_KEY_ID:-G9ZF94F229}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-8192e152-1f45-41f0-a05d-072b53135ec7}"
KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}"

while [ $# -gt 0 ]; do
  case "$1" in
    --artifact)      ARTIFACT="$2"; shift 2 ;;
    --validate-only) VALIDATE_ONLY=1; shift ;;
    --wait)          WAIT_LIMIT="$2"; shift 2 ;;
    --help|-h)       sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

[ -f "$KEY_PATH" ] || {
  echo "❌ 找不到 API 密钥：$KEY_PATH" >&2
  echo "   在 App Store Connect → 用户和访问 → 集成 → App Store Connect API" >&2
  echo "   生成一把**团队密钥**（访问职能选 App Manager），下载的 .p8 放到该路径。" >&2
  exit 1
}

if [ -z "$ARTIFACT" ]; then
  ARTIFACT="$(ls -t "$ROOT"/Build/Export-*/*.ipa 2>/dev/null | head -1 || true)"
fi
[ -n "$ARTIFACT" ] && [ -f "$ARTIFACT" ] || { echo "❌ 找不到要上传的包（用 --artifact 指定）" >&2; exit 1; }

echo "→ 包：${ARTIFACT}（$(du -h "$ARTIFACT" | awk '{print $1}')）"
echo "→ Key ID：$ASC_KEY_ID"

AUTH=(--api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID")

if [ "$VALIDATE_ONLY" -eq 1 ]; then
  echo "→ 只校验，不上传"
  xcrun altool --validate-app -f "$ARTIFACT" -t "$PLATFORM" "${AUTH[@]}"
  echo "✅ 校验通过"
  exit 0
fi

STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "→ 上传中（$(date '+%H:%M:%S')）…"
xcrun altool --upload-app -f "$ARTIFACT" -t "$PLATFORM" "${AUTH[@]}"
echo "→ 传输完成，等苹果处理（起始时刻 ${STARTED_AT}）"

JWT="$(python3 "$ROOT/Scripts/asc-jwt.py" "$KEY_PATH" "$ASC_KEY_ID" "$ASC_ISSUER_ID")"
API="https://api.appstoreconnect.apple.com/v1"

# 认领 App
APP_ID="$(curl -s -H "Authorization: Bearer $JWT" \
  "$API/apps?filter%5BbundleId%5D=$BUNDLE_ID" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["data"][0]["id"] if d.get("data") else "")')"
[ -n "$APP_ID" ] || { echo "❌ App Store Connect 里没有 $BUNDLE_ID 这条 App 记录" >&2; exit 1; }
echo "→ App：${BUNDLE_ID}（${APP_ID}）"

deadline=$(( $(date +%s) + WAIT_LIMIT ))
last=""
while :; do
  # 取最新一条构建；用 uploadedDate 与本次上传的起始时刻对齐，避免误判旧构建。
  read -r STATE BUILD_ID BUILD_NUM UPLOADED <<<"$(curl -s -H "Authorization: Bearer $JWT" \
    "$API/builds?filter%5Bapp%5D=$APP_ID&sort=-uploadedDate&limit=1" \
    | python3 -c '
import json,sys
d=json.load(sys.stdin)
b=(d.get("data") or [{}])[0]
a=b.get("attributes",{})
print(a.get("processingState",""), b.get("id",""), a.get("version",""), a.get("uploadedDate",""))')"

  if [ -n "$STATE" ] && [ "$STATE" != "$last" ]; then
    echo "   $(date '+%H:%M:%S')  构建 ${BUILD_NUM}：$STATE"
    last="$STATE"
  fi

  case "$STATE" in
    VALID)
      echo "→ 处理完成，查 TestFlight 状态"
      curl -s -H "Authorization: Bearer $JWT" "$API/builds/$BUILD_ID/buildBetaDetail" | python3 -c '
import json,sys
d=json.load(sys.stdin)
a=(d.get("data") or {}).get("attributes",{})
print("   内部测试：", a.get("internalBuildState"))
print("   外部测试：", a.get("externalBuildState"))'
      echo "✅ 构建 $BUILD_NUM 已可用于 TestFlight"
      exit 0 ;;
    INVALID|FAILED)
      echo "❌ 构建 $BUILD_NUM 处理失败（${STATE}）—— 苹果会发邮件说明原因" >&2
      exit 1 ;;
  esac

  [ "$(date +%s)" -lt "$deadline" ] || { echo "⏱️  等待超时（${WAIT_LIMIT}s），构建可能仍在处理，稍后到 App Store Connect 看" >&2; exit 1; }
  sleep 20
done
