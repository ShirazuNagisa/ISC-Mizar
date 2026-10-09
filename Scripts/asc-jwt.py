#!/usr/bin/env python3
"""生成 App Store Connect API 的 ES256 JWT。

用法：asc-jwt.py <p8路径> <KeyID> <IssuerID>

为什么用 openssl 而不是某个库：本机不需要装任何东西。openssl 用 EC 私钥
签出来的是 DER 编码的 ECDSA 签名，而 JWT 要的是 raw r‖s（各 32 字节），
所以下面把 DER 拆开再拼回去 —— 这点转换是唯一的实现细节。
"""
import base64
import json
import subprocess
import sys
import time


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def der_to_raw(der: bytes) -> bytes:
    """DER SEQUENCE{INTEGER r, INTEGER s} → r‖s，各补/截到 32 字节。"""
    if der[0] != 0x30:
        raise SystemExit("不是 DER 序列")
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)   # 跳过 SEQUENCE 头
    parts = []
    for _ in range(2):
        if der[i] != 0x02:
            raise SystemExit("不是 DER 整数")
        n = der[i + 1]
        val = der[i + 2:i + 2 + n]
        i += 2 + n
        parts.append(val.lstrip(b"\x00").rjust(32, b"\x00"))  # 去掉符号位补的前导零
    return parts[0] + parts[1]


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit("用法: asc-jwt.py <p8> <KeyID> <IssuerID>")
    p8, key_id, issuer = sys.argv[1:]
    now = int(time.time())
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    payload = {"iss": issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}
    signing_input = (
        b64url(json.dumps(header, separators=(",", ":")).encode())
        + "."
        + b64url(json.dumps(payload, separators=(",", ":")).encode())
    )
    der = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", p8],
        input=signing_input.encode(), capture_output=True, check=True,
    ).stdout
    print(signing_input + "." + b64url(der_to_raw(der)))


if __name__ == "__main__":
    main()
