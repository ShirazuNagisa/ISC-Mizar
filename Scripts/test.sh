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

# 演示模式的测试住在 `#if MIZAR_DEMO` 里（Tests/MizarKitTests/DemoModeTests.swift），
# 因此上面那一遍**编译不到它们** —— 单独跑这一遍才会。
#
# 为什么值得多花两秒：那段代码决定的是审核员打开应用时看到什么，而它最
# 容易坏的方式不是崩溃，是"能编译、能启动、四个页签是空的"。那种坏法只有
# 断言数据真的到位才看得见（见 DemoModeTests 里那条核心测试）。
#
# 它同时证明演示构建**编译得过** —— 那也是一条真实的风险：演示代码在
# `#if` 里，日常构建不碰它，很容易在改别处时被顺手改坏而没人发现。
echo "==> swift test（MIZAR_DEMO=1：演示模式）"
MIZAR_DEMO=1 swift test

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

# 上架声明。与版本号同样的理由放在这里：它们是**声明**，而声明与代码
# 不一致时的症状出现在很远的地方 —— 上传阶段的一封拒绝邮件。
#
#   * 隐私清单（PrivacyInfo.xcprivacy）：App Store 自 2024 年春季起强制
#     要求，缺失会在上传时被拒（ITMS-91053 一类），而不是等到审核。
#   * ITSAppUsesNonExemptEncryption：少了它，每次上传都要重新回答一次
#     "你的应用用了加密吗"。
#
# 用 plistlib 而不是 PlistBuddy：下面要断言的是**结构**
# （数组里有没有那一项、理由码是什么），而 PlistBuddy 的输出是给人读的
# 文本，解析它只会把一条清晰的断言写成一段脆弱的字符串匹配。
echo "==> 上架声明"
python3 - <<'PY'
import plistlib, sys

failures = []

for path in ("App/Mizar-iOS/Info.plist", "App/Mizar-watchOS/Info.plist"):
    with open(path, "rb") as handle:
        plist = plistlib.load(handle)
    # `is not False` 而不是 `not plist.get(...)`：键缺失、值为字符串
    # "false"、值为 0 —— 三种都该失败，而它们都是假值。
    if plist.get("ITSAppUsesNonExemptEncryption") is not False:
        failures.append(f"{path}: 缺少 ITSAppUsesNonExemptEncryption=false"
                        "（只有标准 HTTPS 与 Keychain，属于豁免）")

for path in ("App/Mizar-iOS/PrivacyInfo.xcprivacy",
             "App/Mizar-watchOS/PrivacyInfo.xcprivacy"):
    with open(path, "rb") as handle:
        manifest = plistlib.load(handle)

    if manifest.get("NSPrivacyTracking") is not False:
        failures.append(f"{path}: NSPrivacyTracking 必须是 false")

    # 空数组是一个**明确的**声明（"我们不收集"），与"忘了填"不是一回事。
    if manifest.get("NSPrivacyCollectedDataTypes") != []:
        failures.append(f"{path}: 这个应用不收集任何数据，"
                        "NSPrivacyCollectedDataTypes 必须是空数组")

    accessed = {entry.get("NSPrivacyAccessedAPIType"): entry.get("NSPrivacyAccessedAPITypeReasons", [])
                for entry in manifest.get("NSPrivacyAccessedAPITypes", [])}
    reasons = accessed.get("NSPrivacyAccessedAPICategoryUserDefaults")
    if reasons is None:
        failures.append(f"{path}: 没有声明 UserDefaults"
                        "（ISCMizarApp.swift 里的 @AppStorage 用的就是它）")
    elif "CA92.1" not in reasons:
        failures.append(f"{path}: UserDefaults 的理由码应当是 CA92.1"
                        f"（读写本应用自己的偏好设置），实际 {reasons}")

    # 另外三类需要理由的 API 经 grep 确认未使用。这里**不**断言它们的
    # 缺席 —— "多声明一类没在用的"不会被拒，而"少声明一类在用的"会被拒，
    # 两者代价不对称，因此清单可以选择保守。

if failures:
    print("❌ 上架声明有问题：", file=sys.stderr)
    for item in failures:
        print("   -", item, file=sys.stderr)
    sys.exit(1)
print("✅ 隐私清单与出口合规声明齐全（两个 target 各一份）")
PY

echo "✅ MizarKit 全部通过"
