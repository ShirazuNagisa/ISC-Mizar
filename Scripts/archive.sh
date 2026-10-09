#!/usr/bin/env bash
#
# 归档 App Store 包（并可选导出）。
#
# 用法：
#
#	./Scripts/archive.sh                归档；产出 Build/ISC-Mizar-<版本>.xcarchive
#	./Scripts/archive.sh --demo         归档**演示构建**（假数据在里面，见下）
#	./Scripts/archive.sh --export       归档之后再导出（**需要用户的 Apple 账号**）
#	./Scripts/archive.sh --unsigned     归档但不签名（见下）
#	./Scripts/archive.sh --skip-checks  跳过前置的测试与两个构建
#	./Scripts/archive.sh --buildNumber 3  指定构建号（TestFlight 每次上传必须递增）
#	./Scripts/archive.sh --help
#
# # 默认归档出来的是**生产**构建：里面没有演示代码
#
# 那是对的默认值，但它带来一个必须由人来决定的问题：审核员打开生产构建时
# 手上没有 Phecda 服务端，于是他看到的还是"连不上这台服务端"。演示模式要
# 解决的正是这件事，因此**要过审就得归档并上传演示构建**：
#
#	./Scripts/archive.sh --demo --export
#
# 两个方向的正确性都由这个脚本自己验证，不靠人记得：
#
#	生产归档：产物里**搜不到**演示字符串，搜到就失败；
#	演示归档：产物里**必须搜得到**，搜不到同样失败 —— 那说明这一遍没有
#	          真的打开演示模式，而这个包会被当成演示包上传，审核员打开
#	          照样是"连不上"。
#
# # 为什么默认**只归档不导出**
#
# 导出（`-exportArchive`）要用户的 Apple 账号：自动签名会去证书与
# provisioning profile 里取签名身份，而那份凭据只在那个人自己的钥匙串里。
# 把它做成默认动作有两个坏结果 —— 在 CI 上它每次都失败，在本地它会弹一个
# 钥匙串授权框，而失败信息（`No signing certificate`）看起来像工程配置
# 错了，实际只是"这台机器上没有你的账号"。
#
# 因此导出必须由人显式要求：`--export`。
#
# # `--unsigned` 是什么
#
# 在没有开发者账号的机器上（CI、以及任何不是打包者本人的环境）验证
# **归档管线本身**：能不能 build、能不能 assemble 出 .xcarchive、里面的
# 结构对不对。产物**没有签名，不能上传**，它证明不了"这个包能上架"。
#
# # 它为什么在归档之前跑一遍测试与两个构建
#
# 归档是整个流程里最慢的一步，也是最晚的一步。让它去发现一个单元测试
# 就能发现的问题（版本号不一致、隐私清单缺了、手表编译不过）是把一次
# 五分钟的等待换成一次三十秒的等待。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

EXPORT=0
UNSIGNED=0
SKIP_CHECKS=0
DEMO=0
# `--buildNumber` 带值，因此不能用上面的 for-case 逐字比对。
BUILD_NUMBER_ARG=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "--buildNumber" ]; then BUILD_NUMBER_ARG="$arg"; fi
  prev="$arg"
done

# 第二趟必须**跳过** --buildNumber 后面那个值。
#
# 不跳过的症状很具体：`--buildNumber 2` 里的 `2` 会掉进 `*)` 分支，被当成
# 未知参数 —— 也就是说这个开关**从来没生效过**，而它是 TestFlight 每次上传
# 都要用的那一个（构建号必须递增）。这条路径平时不走，所以一直没被发现。
consumed_value=0
for arg in "$@"; do
  if [ "$consumed_value" = "1" ]; then consumed_value=0; continue; fi
  case "$arg" in
    --demo) DEMO=1 ;;
    --export) EXPORT=1 ;;
    --unsigned) UNSIGNED=1 ;;
    --skip-checks) SKIP_CHECKS=1 ;;
    -h|--help) sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --buildNumber) consumed_value=1 ;;     # 值在上面那一趟取走了
    # `${arg}` 的花括号不是风格问题：bash 3.2（macOS 自带）在 `$arg` 后面
    # 紧跟一个多字节字符时会把它们一起当成变量名，于是这一行在报错路径上
    # 自己抛 "unbound variable"，把真正的问题盖掉。
    *) echo "未知参数：${arg}（用 --help 看用法）" >&2; exit 2 ;;
  esac
done

# 生产归档里演示模式**绝不能**开着。
#
# Package.swift 用 MIZAR_DEMO 这个环境变量决定要不要定义编译条件。如果
# 打包者的终端里恰好 export 过它（他刚刚在调演示模式），那么这一遍归档
# 出来的就是**带假数据的应用** —— 而且它会一路通过、上传、被审核看到。
# 这里显式 unset；下面还有一道"在产物里搜演示字符串"的兜底。
#
# 演示归档反过来：这里**显式**设置它，而不是指望调用者的环境。这样
# `--demo` 就是唯一的事实来源，而下面那个正对照会验证它真的生效了。
if [ "$DEMO" = "1" ]; then
  export MIZAR_DEMO=1
else
  unset MIZAR_DEMO
fi

# ---------------------------------------------------------------- 版本号
#
# 从 Sources/MizarKit/Version.swift **读**出来，不写死。
#
# 写死过一次的教训：acceptance-ios.sh 里曾经硬编码 v0.2.0，于是每次发版
# 那条检查都会失败，而它失败的样子与"版本号根本没上报"一模一样 ——
# 下一个人会去查上报链路，而真正要改的是脚本里那个字符串。
VERSION="$(sed -n 's/.*public static let current = "\(.*\)"/\1/p' Sources/MizarKit/Version.swift)"

# 构建号：默认取工程里的 CURRENT_PROJECT_VERSION，可用 --buildNumber 覆盖。
#
# TestFlight 要求每次上传的构建号递增，而"每次上传都去改工程文件"是个
# 会忘记的动作。允许从命令行传，CI 里就能自动递增。
BUILD_NUMBER="$BUILD_NUMBER_ARG"
if [ -z "$BUILD_NUMBER" ]; then
  BUILD_NUMBER="$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([0-9]*\);.*/\1/p' App/ISC-Mizar.xcodeproj/project.pbxproj | head -1)"
fi
if [ -z "$BUILD_NUMBER" ]; then
  echo "❌ 读不出 CURRENT_PROJECT_VERSION" >&2
  exit 2
fi
if [ -z "$VERSION" ]; then
  echo "❌ 读不出 MizarVersion.current —— 脚本与源码已经脱节" >&2
  exit 2
fi

# 版本号一致这一点**不跳过**：无论 --skip-checks 与否它都是几十毫秒的事，
# 而它挡住的是"归档出来的包与仓库里那一份对不上"。
for plist in App/Mizar-iOS/Info.plist App/Mizar-watchOS/Info.plist; do
  PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || echo '')"
  if [ "$PLIST_VERSION" != "$VERSION" ]; then
    echo "❌ $plist 的版本是 \"$PLIST_VERSION\"，而 MizarVersion.current 是 \"$VERSION\"" >&2
    exit 1
  fi
done
echo "==> 版本：v${VERSION}（MizarVersion.current 与两个 Info.plist 一致）"

# ---------------------------------------------------------------- 前置检查
if [ "$SKIP_CHECKS" = "0" ]; then
  echo "==> 前置：单元测试"
  ./Scripts/test.sh
  echo "==> 前置：iOS 构建"
  # 归档演示包时这一遍也走演示构建：否则前置构建通过、归档那一遍才是真正
  # 决定"演示代码在不在里面"的一步，前置就白跑了。
  if [ "$DEMO" = "1" ]; then
    ./Scripts/build-ios.sh --demo
  else
    ./Scripts/build-ios.sh
  fi
  echo "==> 前置：watchOS 构建"
  ./Scripts/build-watch.sh
else
  echo "==> 已跳过前置测试与构建（--skip-checks）"
fi

# ---------------------------------------------------------------- 归档
#
# 归档用**独立的 DerivedData**，与日常构建分开。
#
# 理由与 build-ios.sh --demo 是同一件事的另一面：Xcode 缓存 Package.swift
# 的求值结果，而 MIZAR_DEMO 是那个求值的一个输入。共用一份 DerivedData
# 时，方向是**反的**那一次最危险 —— 先建演示再建生产，生产那一遍可能仍然
# 拿到缓存的"演示开着"，于是归档出来的是假数据。独立目录让这种串味在物理
# 上不可能发生，而下面那一步会再验一遍。
#
# 演示归档再单独一份：两个方向的缓存都不共用。
if [ "$DEMO" = "1" ]; then
  DD="${MIZAR_ARCHIVE_DERIVED_DATA:-$ROOT/Build/ArchiveDerivedData-demo}"
  ARCHIVE_PATH="$ROOT/Build/ISC-Mizar-${VERSION}-demo.xcarchive"
  echo "==> 归档模式：演示（假数据在里面；这份是给审核员的）"
else
  DD="${MIZAR_ARCHIVE_DERIVED_DATA:-$ROOT/Build/ArchiveDerivedData}"
  ARCHIVE_PATH="$ROOT/Build/ISC-Mizar-${VERSION}.xcarchive"
  echo "==> 归档模式：生产（演示代码必须不在里面）"
fi

echo "==> xcodebuild archive（Release / generic/platform=iOS）"
rm -rf "$ARCHIVE_PATH"
mkdir -p "$ROOT/Build"

# `-destination 'generic/platform=iOS'`：归档必须是**设备**构建。
# 模拟器构建产出的是 x86_64/arm64-simulator 的可执行文件，App Store 不收。
ARCHIVE_ARGS=(
  -project App/ISC-Mizar.xcodeproj
  -scheme Mizar
  -configuration Release
  -destination 'generic/platform=iOS'
  -archivePath "$ARCHIVE_PATH"
  -derivedDataPath "$DD"
  # 构建号从这里传进去，而不是写在 Info.plist 里。
  #
  # TestFlight **要求每次上传的构建号比上一次大**，而写死在 plist 里意味着
  # 每次上传都要改两个文件、改完还可能忘记其中一个 —— 那时 App Store
  # Connect 的报错是 "bundle version must be higher than the previously
  # uploaded version"，而它指不出是哪个 plist。
  #
  # `CURRENT_PROJECT_VERSION` 由 `-buildNumber` 覆盖；不传时用工程里那个。
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
)
if [ "$UNSIGNED" = "1" ]; then
  # 不签名：在没有账号的机器上验证归档管线。产物不能上传。
  ARCHIVE_ARGS+=(
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGN_IDENTITY=""
  )
  echo "    （--unsigned：产物未签名，只用于验证管线）"
fi

xcodebuild "${ARCHIVE_ARGS[@]}" archive

if [ ! -d "$ARCHIVE_PATH" ]; then
  echo "❌ xcodebuild 声称成功，但 $ARCHIVE_PATH 不存在" >&2
  exit 1
fi
echo "✅ 归档：$ARCHIVE_PATH"

# ---------------------------------------------------------------- 归档产物自检
#
# # 这一步在验什么（两个方向都验）
#
# 演示模式的整套代码与数据都在 `#if MIZAR_DEMO` 里（见
# Sources/MizarApp/DemoMode.swift）。因此：
#
#	生产归档：产物里**不该**有它们 —— 这是"演示代码没有漏进发布包"
#	          唯一的、外部的证据。
#	演示归档：产物里**必须有**它们 —— 否则那一遍根本没打开演示模式，
#	          而这个包会被当成演示包上传，审核员打开还是"连不上"。
#
# 为什么不能靠"我们记得设/没设那个变量"：缓存、环境继承、以及别人手工跑
# xcodebuild 都不受这个脚本控制。把断言放在**产物**上，才能挡住所有那些
# 路径。第二个方向尤其重要 —— 它的失败是**静默**的：包能建、能上传、
# 能过审，只是审核员看到的东西不对。
#
# # 为什么用 `grep -aF` 而不是 `strings | grep`
#
# `strings` 默认只认可打印 ASCII，中文串会漏掉。而更要紧的是**短字符串**：
# Swift 会把 15 字节以内的字面量做小字符串优化，直接编成指令里的立即数，
# 那些字节根本不在数据段里 —— `strings` 与 `grep` 都搜不到"演示数据"
# （12 字节）。所以这里的哨兵一律选**长的 ASCII 串**：域名与公网子域名。
# 它们一定在 `__cstring` 里，而且它们正是演示数据最独特的特征。
#
# 那几个字符串不是专门造的哨兵，而是演示数据里真实存在的取值。
# DemoModeTests 里有一条测试盯着这份清单（改了演示域名而没改这里，
# 那条测试会先红）—— 否则这里会退化成一条"永远通过"的检查，
# 而它保护的恰恰是不能出错的那一件事。
IOS_APP="$ARCHIVE_PATH/Products/Applications/ISC Mizar.app"
WATCH_APP="$IOS_APP/Watch/ISC Mizar Watch.app"

DEMO_SENTINELS="blog.example.com api.example.com mizar-demo DemoTransport DemoData"

# 找到任何一个哨兵就打印出来并返回 0。
find_demo() {
  local binary="$1" label="$2"
  local found=""
  [ -f "$binary" ] || return 0
  for needle in $DEMO_SENTINELS; do
    if grep -qaF "$needle" "$binary" 2>/dev/null; then
      echo "$needle"
      found=1
    fi
  done
  [ -n "$found" ]
}

if [ ! -d "$IOS_APP" ]; then
  echo "❌ 归档里找不到 $IOS_APP" >&2
  exit 1
fi

if [ "$DEMO" = "1" ]; then
  echo "==> 正对照：演示归档里**必须**搜得到演示数据"
  HITS="$(find_demo "$IOS_APP/ISC Mizar" "iOS 可执行文件" || true)"
  if [ -z "$HITS" ]; then
    echo "❌ 这一遍标着 --demo，但产物里搜不到任何演示字符串。" >&2
    echo "   说明 MIZAR_DEMO 没有真的传到编译（检查 Build/ArchiveDerivedData-demo" >&2
    echo "   是不是被上一遍的求值缓存住了）。**这个包不能上传**：" >&2
    echo "   审核员打开它看到的仍然是「连不上这台服务端」。" >&2
    exit 1
  fi
  echo "✅ 演示数据确实在产物里（$(echo "$HITS" | tr '\n' ' ')）"
else
  echo "==> 自检：生产归档产物里没有演示代码"
  for pair in "$IOS_APP/ISC Mizar|iOS 可执行文件" "$WATCH_APP/ISC Mizar Watch|watchOS 可执行文件"; do
    BIN="${pair%|*}"
    LABEL="${pair#*|}"
    HITS="$(find_demo "$BIN" "$LABEL" || true)"
    if [ -n "$HITS" ]; then
      echo "❌ $LABEL 里搜到了演示模式的东西：$(echo "$HITS" | tr '\n' ' ')" >&2
      echo "   Build/ArchiveDerivedData 的 Package.swift 求值缓存可能还留着" >&2
      echo "   上一次演示构建的结果。删掉那个目录再归档一次。" >&2
      exit 1
    fi
  done
  echo "✅ 演示数据与演示类型都不在归档产物里"
fi

# 隐私清单必须**在包里**（不是只在仓库里）。
#
# 它是一个资源，靠 App/Mizar-iOS/ 那个 Xcode 同步文件夹进包；如果有人
# 不小心把它加进 membershipExceptions，文件还在仓库里、测试也可能过，
# 而上传时会被拒。因此这里看的是**包内**。
for manifest in "$IOS_APP/PrivacyInfo.xcprivacy" "$WATCH_APP/PrivacyInfo.xcprivacy"; do
  if [ ! -f "$manifest" ]; then
    echo "❌ 包里没有隐私清单：$manifest" >&2
    exit 1
  fi
done
echo "✅ 隐私清单在两个包里"

# 出口合规声明也要真的落到包里（Info.plist 会被 Xcode 处理一遍）。
ENC="$(/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$IOS_APP/Info.plist" 2>/dev/null || echo '')"
if [ "$ENC" != "false" ]; then
  echo "❌ 归档包的 Info.plist 里没有 ITSAppUsesNonExemptEncryption=false（实际 \"$ENC\"）" >&2
  exit 1
fi
echo "✅ 出口合规声明在包里"

# 构建号也要真的落到包里，而且等于这次要求的那个。
#
# # 为什么值得单独断言
#
# `CURRENT_PROJECT_VERSION` 是从命令行传进 `xcodebuild` 的，而 Info.plist 里
# 写的是 `$(CURRENT_PROJECT_VERSION)`。中间任何一环没生效（拼错变量名、
# 参数被解析掉、plist 没被处理），产物里的构建号就还是工程里那个旧值 ——
# 而 App Store Connect 会以 "bundle version must be higher than the
# previously uploaded version" 拒绝，报错里**不会**告诉你它看到的是几。
#
# 顺带：这个开关曾经因为参数解析的 bug 完全没生效（见文件顶部的说明），
# 这一条断言就是那种 bug 的探测器。
PLIST_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$IOS_APP/Info.plist" 2>/dev/null || echo '')"
PLIST_BUILD_WATCH="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$WATCH_APP/Info.plist" 2>/dev/null || echo '')"
if [ "$PLIST_BUILD" != "$BUILD_NUMBER" ]; then
  echo "❌ 归档包的构建号是 \"$PLIST_BUILD\"，而这次要求的是 \"$BUILD_NUMBER\"" >&2
  exit 1
fi
if [ "$PLIST_BUILD_WATCH" != "$BUILD_NUMBER" ]; then
  echo "❌ watch 子包的构建号是 \"$PLIST_BUILD_WATCH\"，而这次要求的是 \"$BUILD_NUMBER\"" >&2
  echo "   两个包的构建号必须一致，否则上传会被拒。" >&2
  exit 1
fi
echo "✅ 构建号 $BUILD_NUMBER 已落到 iOS 与 watch 两个包里"

# ---------------------------------------------------------------- 导出
# ---------------------------------------------------------------- 部署目标自检
#
# # 为什么必须验，而不是相信构建设置
#
# `Build/ArchiveDerivedData*` 是**持久**目录。实测踩到过：把
# `IPHONEOS_DEPLOYMENT_TARGET` 从 27.0 改成 26.0 之后重新归档，
# `-showBuildSettings` 已经是 26.0，而归档出来的二进制 `minos` 仍是 27.0 ——
# 缓存里的旧产物被沿用了。
#
# 这类错误**静默进包**：App Store 页面上写着"需要 iOS 27.0 或更高"，
# 而仓库里明明写着 26.0，两处对不上却没有任何提示。
#
# 所以从产物里把 minos 读出来跟工程设置比一遍。它只花几十毫秒。
EXPECTED_IOS="$(grep -m1 'IPHONEOS_DEPLOYMENT_TARGET = ' App/ISC-Mizar.xcodeproj/project.pbxproj | sed 's/.*= \(.*\);/\1/')"
APP_BIN="$ARCHIVE_PATH/Products/Applications/ISC Mizar.app/ISC Mizar"
if [ -f "$APP_BIN" ]; then
  ACTUAL_IOS="$(vtool -show-build "$APP_BIN" 2>/dev/null | sed -n 's/.*minos \(.*\)/\1/p' | head -1)"
  if [ "$ACTUAL_IOS" != "$EXPECTED_IOS" ]; then
    echo "❌ 归档产物的部署目标是 iOS ${ACTUAL_IOS}，而工程里是 ${EXPECTED_IOS}" >&2
    echo "   多半是 Build/ArchiveDerivedData 里的缓存。删掉它重新归档。" >&2
    exit 1
  fi
  echo "==> 部署目标自检：产物 minos ${ACTUAL_IOS} = 工程设置 ${EXPECTED_IOS}"
else
  echo "⚠️  找不到主程序，跳过部署目标自检" >&2
fi

if [ "$EXPORT" = "0" ]; then
  cat <<EOF

✅ 归档完成（未导出）。

   归档包：$ARCHIVE_PATH
   版本：  v$VERSION

   要导出 App Store 包，重跑一次并加 --export：

     ./Scripts/archive.sh --export

   那一步需要**你的** Apple 账号：自动签名会去钥匙串里取签名身份，
   并可能向 App Store Connect 要一份 provisioning profile。因此它
   做不到无人值守 —— 在 CI 上跑它只会得到一句
   "No signing certificate iOS Distribution found"。

   导出成功之后，上传仍然是在你的机器上完成的：

     xcrun altool --upload-app -f <导出的 .ipa> -t ios \\
       --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
     # 或者用 Xcode 的 Organizer（Window → Organizer → Distribute App）
EOF
  exit 0
fi

# 导出目录也带演示标记。
#
# # 这是踩到过的
#
# 一开始这里只有 `Export-${VERSION}`。于是 `--demo --export` 把**演示**的
# .ipa 写进了生产那个目录，**覆盖掉**上一次生产导出的产物 —— 而两个包
# 从文件名上完全分不出来。谁之后照着目录里的 .ipa 去上传，就会上传错的
# 那一个（在"演示包才是要交给审核员的"这个场景里，方向还正好相反）。
if [ "$DEMO" = "1" ]; then
  EXPORT_PATH="$ROOT/Build/Export-${VERSION}-demo"
else
  EXPORT_PATH="$ROOT/Build/Export-${VERSION}"
fi
echo "==> xcodebuild -exportArchive"
echo "    选项：Scripts/ExportOptions.plist（method = app-store-connect）"
rm -rf "$EXPORT_PATH"
if ! xcodebuild -exportArchive \
      -archivePath "$ARCHIVE_PATH" \
      -exportOptionsPlist Scripts/ExportOptions.plist \
      -exportPath "$EXPORT_PATH" \
      -allowProvisioningUpdates; then
  cat >&2 <<EOF

❌ 导出失败。

   最常见的原因是这台机器上没有你的 Apple 账号/签名身份 ——
   导出与归档不同，它**需要**凭据：

     * Xcode → Settings → Accounts 里登录开发者账号；
     * 确认那个账号能访问 team 5Q2A46685M；
     * 首次导出时 Xcode 可能会要一次钥匙串授权（只有人能点）。

   归档包本身是好的（${ARCHIVE_PATH}），可以在 Xcode 的
   Window → Organizer 里打开它，用图形界面走完剩下的两步。
EOF
  exit 1
fi

echo "✅ 导出：$EXPORT_PATH"
ls "$EXPORT_PATH"
echo
echo "下一步是上传（需要你的 Apple 账号）："
echo "  xcrun altool --upload-app -f \"$EXPORT_PATH\"/*.ipa -t ios --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>"
