#if MIZAR_DEMO
import Foundation
import MizarKit

// MARK: - 演示模式（编译期开关）
//
// # 它为什么存在
//
// 这个应用的每一个页签都要先连上**用户自己的** Phecda 服务端才有内容。
// 审核员没有那台机器，于是打开它看到的是一句"连不上这台服务端" ——
// 而 Apple 对"需要额外硬件或服务才能使用"的应用经常直接拒
// （"We were unable to review your app because it requires additional
// hardware"）。演示模式回答的就是这一条：**没有服务端也能走完四个页签**。
//
// # 为什么假数据从**传输层**进去
//
// `AppModel.init(directory:tokens:makeTransport:)` 里那个 `makeTransport`
// 是生产代码本来就有的注入点（它存在的理由是让状态机能在
// `swift test` 里被验证）。演示数据放在那里，意味着它走的是与真实网络
// **完全相同**的那条路：
//
//	ServerPool → ServerSession（候选地址竞速、401 改判、角色同步）
//	→ KernelClient → KernelAPI（契约解码）→ AppModel → 每一个视图
//
// 好处有两个，第二个比第一个重要得多：
//
//	1. 没有任何一个视图需要知道演示模式存在 —— 四个页签、DNS 的区域与
//	   记录、站点日志、连"重启站点"这个写操作，跑的都是既有代码。
//	2. 因此**不存在"只有演示模式才走"的代码路径**。那类路径是最危险的一种
//	   代码：没人会去测它，而它一旦与真实路径分叉，演示通过并不代表真的能用。
//
// # 为什么整个文件都在 #if 里
//
// 生产构建里这个文件**编译成零**：没有类型、没有字符串、没有分支。
// 这不是"相信编译器会摇树"——Release 下它是真的不存在，可以验证：
// `Scripts/archive.sh` 在归档产物里搜 `DemoData` / `DemoTransport`
// 这两个符号与几个演示域名（`blog.example.com` 这类），搜到就失败。

/// 演示模式的全部数据：一份假内核，以及让它跑起来的最小本机状态。
nonisolated enum DemoData {

    // MARK: - 身份

    /// 演示服务端在 `servers.json` 里的 id。
    static let serverID = "demo-phecda"

    /// 演示设备令牌。
    ///
    /// 名字里写死"not a real credential"：它只在本机内存里存在，不会发给
    /// 任何地方（假传输不联网），而万一日后有人把它抄进别处，这句话是
    /// 唯一能在事后说明"这不是真令牌"的东西。
    static let token = "demo-token-not-a-real-credential"

    /// 演示用凭据 id / 区域名 —— 与下面那些载荷里的取值必须一致。
    static let credentialID = "cred-demo"
    static let zoneID = "example.com"
    static let siteBlogID = "site-blog"
    static let siteAPIID = "site-api"
    static let siteGrafanaID = "site-grafana"
    static let ddnsTaskID = "ddns-home"

    /// 这台假服务端的显示名。
    ///
    /// 会出现在侧栏、导航标题与设置页 —— 审核员第一眼看到的就是它。
    /// 用 `demoTr` 而不是 `tr`：见下面那个函数的说明。
    static var serverName: String { demoTr("书房的 Mac mini", "Study Mac mini") }

    // MARK: - 本机状态

    /// 演示模式使用的数据目录。
    ///
    /// # 为什么**不能**用真实的应用支持目录
    ///
    /// 那里面是用户自己保存的服务端列表（`servers.json`）。演示模式往里
    /// 写一条假服务端，用户就会在列表里真的看到它 —— 而且删不掉的话
    /// 更糟。缓存目录是另一回事：它是"随时可以被系统清掉"的位置，
    /// 与用户的真实配置没有交集。
    static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ISC Mizar Demo", isDirectory: true)
    }

    /// 把演示服务端写进本机记录。
    ///
    /// 在 `AppModel.init` 里同步调用一次。**每次启动都重写**：演示状态
    /// 必须是确定的 —— 审核员第二次打开应用时看到的应该与第一次一模一样，
    /// 而不是上一轮留下的残留（比如被他点过"停止"的那个站点）。
    ///
    /// 编码参数与 `ServerStore.makeEncoder()` 逐字一致（ISO8601 日期 +
    /// 排序键）：不一致的话，`ServerStore` 读回来会得到一份空列表，
    /// 而症状是"演示模式里一台服务器都没有"。
    static func prepare() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode([record]) else { return }
        let url = directory.appendingPathComponent("servers.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// 那条演示服务端记录。
    ///
    /// 候选地址给两条（局域网 + 公网子域名），而不是一条：竞速、地址降级、
    /// "上次可用"那几个分支只有多地址时才画得出来。假传输不区分地址，
    /// 因此第一个回应的必然胜出。
    static var record: ServerRecord {
        ServerRecord(
            id: serverID,
            name: serverName,
            scheme: "https",
            addresses: ["192.168.1.10:8443"],
            spkiSHA256: "wuVv74npNUHvHVLN-c2CTY4OWYMg4NkCF6PckSLuGvc",
            role: "operator",
            lastGoodAddress: "192.168.1.10:8443",
            lastSeenAt: Date(),
            createdAt: Date().addingTimeInterval(-45 * 86_400),
            notificationsEnabled: true,
            publicHost: "mizar-demo.invalid",
            publicPort: nil)
    }

    // MARK: - 载荷
    //
    // 下面这些是**契约形状的 JSON 字面量**，与内核真的会返回的东西同构
    // （键是 snake_case，时间戳是 ISO8601）。它们不经过任何"演示专用"的
    // 解码路径 —— `KernelAPI.send` 用与生产完全相同的那一个
    // `JSONDecoder.mizar` 解它们。因此字段名写错、类型写错、少一个必填
    // 字段，都会在演示模式里变成一次真实的解码失败，而不是被悄悄放过。
    //
    // 时间戳一律**相对当下**算出来（`demoISO(days:)`）：写死一个日期的话，
    // "证书 12 天后到期"过一阵子就变成"已过期"，而那张卡片的颜色与建议
    // 都跟着反过来 —— 审核员看到的是一个处处报错的应用。

    /// `GET /v1/remote/self`。
    ///
    /// 角色给 `operator`：审核员要能点到写操作的界面（否则他看到的是一堆
    /// "这台设备是只读的"）。
    ///
    /// # `public` 这一段为什么在，但 `targets` 是空的
    ///
    /// 它同时喂两处，而两处要的正好相反：
    ///
    ///   * **公网子域名**（`host`）：必须给。`connectAndRefresh` 会把它写进
    ///     本机记录，而本机记录原来是 `nil` 的话，那条 `setPublicHost(nil,…)`
    ///     会把演示记录里预置的公网地址**抹掉** —— 候选地址于是从两条变成
    ///     一条，设置页的地址表也少一行。
    ///   * **可达性探测计划**（`targets`）：必须空。有目标时设置页会画出
    ///     「测试公网可达性」按钮，而那个按钮会去连**真实网络**。
    ///     演示模式不该产生任何真实流量。
    static var remoteSelf: String {
        """
        {
          "role": "operator",
          "device": {
            "id": "demo-device",
            "label": "iPad",
            "role": "operator",
            "notifications_enabled": false,
            "os_version": "27.0",
            "model": "iPad"
          },
          "server": {
            "name": "\(serverName)",
            "version": "1.4.2",
            "api_version": "v1",
            "platform": "darwin",
            "spki_sha256": "\(record.spkiSHA256)",
            "fingerprint_short": "C2E5-6FEF",
            "apns_topic": "app.isc.mizar"
          },
          "public": {
            "host": "mizar-demo.invalid",
            "port": 8443,
            "targets": [],
            "lan_addresses": ["192.168.1.10:8443"]
          }
        }
        """
    }

    /// `GET /v1/metrics` —— 概览页与资源页的全部数字。
    ///
    /// 两个口径都填（`host` 是整机、`footprint` 是内核 + 站点）：
    /// 界面刻意并排显示它们并注明区别，只给一个的话那一层说明就白写了。
    static var metrics: String {
        """
        {
          "host": {
            "at": "\(demoISO(seconds: -5))",
            "cpu_percent": 21.8,
            "memory_used_bytes": 19327352832,
            "memory_total_bytes": 34359738368,
            "net_rx_bytes_per_sec": 1258291.2,
            "net_tx_bytes_per_sec": 348160.0,
            "backend": "nettop",
            "disks": [
              {
                "mount_point": "/",
                "fs_type": "apfs",
                "total_bytes": 994662584320,
                "used_bytes": 412316860416,
                "free_bytes": 553648128000
              },
              {
                "mount_point": "/Volumes/Backup",
                "fs_type": "apfs",
                "total_bytes": 2000398934016,
                "used_bytes": 1800000000000,
                "free_bytes": 128000000000
              }
            ],
            "gpu": {
              "backend": "ioreg",
              "name": "Apple M4 Pro",
              "utilization_percent": 8.5
            }
          },
          "footprint": {
            "at": "\(demoISO(seconds: -5))",
            "cpu_percent": 12.4,
            "memory_bytes": 536870912,
            "net_rx_bytes_per_sec": 184320.0,
            "net_tx_bytes_per_sec": 96256.0,
            "net_backend": "nettop",
            "processes": 5
          },
          "apps": [
            {
              "app_id": "\(siteAPIID)",
              "pid": 4122,
              "cpu_percent": 3.8,
              "memory_bytes": 134217728,
              "uptime_seconds": 273600
            },
            {
              "app_id": "\(siteGrafanaID)",
              "pid": 4180,
              "cpu_percent": 1.2,
              "memory_bytes": 100663296,
              "uptime_seconds": 39600
            },
            {
              "app_id": "\(siteBlogID)",
              "pid": 0,
              "cpu_percent": 0,
              "memory_bytes": 0,
              "uptime_seconds": 0
            }
          ],
          "history": [\(historyPoints)]
        }
        """
    }

    /// 最近 24 个 CPU 采样点（概览与资源页各画一条迷你曲线）。
    ///
    /// 用一条正弦而不是随机数：随机的每次刷新都会跳，而"这台机器很闲"的
    /// 读法恰恰来自那条曲线**平缓**。整数化到一位小数，免得界面上出现
    /// 一长串无意义的小数位。
    private static var historyPoints: String {
        (0..<24).map { index in
            let cpu = 18.0 + 9.0 * sin(Double(index) / 3.2)
            return """
            {"at": "\(demoISO(seconds: -5 * Double(24 - index)))", \
            "cpu_percent": \((cpu * 10).rounded() / 10), \
            "memory_used_bytes": 19327352832, \
            "memory_total_bytes": 34359738368, \
            "net_rx_bytes_per_sec": 1258291.2, \
            "net_tx_bytes_per_sec": 348160.0}
            """
        }.joined(separator: ",")
    }

    /// `GET /v1/advisories` —— 概览页最上面那张"需要处理"卡。
    ///
    /// 两条，且都与下面的数据**对得上**：证书那条对应
    /// `api.example.com` 的到期日，磁盘那条对应 `/Volumes/Backup` 的剩余
    /// 空间。假数据最容易被看穿的地方就是"建议说的事在别处查不到"。
    static var advisories: String {
        """
        {
          "items": [
            {
              "id": "adv-cert",
              "severity": "warning",
              "title": "\(demoTr("api.example.com 的证书 12 天后到期", "The certificate for api.example.com expires in 12 days"))",
              "detail": "\(demoTr("在 Phecda 上点一次「续期」即可，其余不用动。", "Renew once from Phecda; nothing else needs to change."))"
            },
            {
              "id": "adv-disk",
              "severity": "warning",
              "title": "\(demoTr("备份盘快满了", "The backup volume is nearly full"))",
              "detail": "\(demoTr("写满之后动态解析会开始失败。", "Dynamic DNS will start failing once it fills up."))"
            }
          ]
        }
        """
    }

    /// `GET /v1/apps` —— 服务页的站点列表。
    ///
    /// 三个站点刻意长得不一样，因为界面上的三条分支各需要一个样本：
    ///   * `blog` 是**静态站点**（`kind` 为空、`pid` 为 0）—— 内核直接托管，
    ///     没有独立进程，服务页与资源页各有一条"没有可测的占用"的说明；
    ///   * `api` 有域名、有重启次数，且证书快到期（与上面那条建议同一件事）；
    ///   * `grafana` 没有域名，于是列表上显示的是 `:3001` 那个本地端口。
    static var apps: String {
        "{\"items\":[\(siteJSON.map(\.json).joined(separator: ","))]}"
    }

    /// `GET /v1/apps/{id}`。
    static func app(id: String) -> String? {
        siteJSON.first { $0.id == id }?.json
    }

    private static var siteJSON: [(id: String, json: String)] {
        [
            (siteBlogID, """
            {
              "id": "\(siteBlogID)",
              "name": "\(demoTr("个人博客", "Personal blog"))",
              "preset_id": "static-site",
              "kind": "",
              "source_path": "/Users/isc/Sites/blog",
              "local_port": 8080,
              "state": "running",
              "health": "healthy",
              "restart_count": 0,
              "domains": [
                {"name": "blog.example.com", "route_ready": true,
                 "cert_expires_at": "\(demoISO(days: 62))", "cert_needs_renew": false}
              ],
              "created_at": "\(demoISO(days: -45))",
              "updated_at": "\(demoISO(days: -2))"
            }
            """),
            (siteAPIID, """
            {
              "id": "\(siteAPIID)",
              "name": "Phecda API",
              "preset_id": "node",
              "kind": "node",
              "source_path": "/Users/isc/Sites/api",
              "local_port": 3000,
              "state": "running",
              "health": "healthy",
              "restart_count": 2,
              "domains": [
                {"name": "api.example.com", "route_ready": true,
                 "cert_expires_at": "\(demoISO(days: 12))", "cert_needs_renew": true}
              ],
              "created_at": "\(demoISO(days: -30))",
              "updated_at": "\(demoISO(days: -4))"
            }
            """),
            (siteGrafanaID, """
            {
              "id": "\(siteGrafanaID)",
              "name": "Grafana",
              "preset_id": "docker",
              "kind": "docker",
              "source_path": "/Users/isc/Sites/grafana",
              "local_port": 3001,
              "state": "running",
              "health": "healthy",
              "restart_count": 0,
              "domains": [],
              "created_at": "\(demoISO(days: -12))",
              "updated_at": "\(demoISO(days: -1))"
            }
            """)
        ]
    }

    /// `GET /v1/apps/{id}/logs?tail=…` —— 服务详情页那个日志 sheet。
    static var appLogs: String {
        """
        {
          "lines": [
            "\(demoISO(seconds: -3600))  INFO  listening on 127.0.0.1:3000",
            "\(demoISO(seconds: -3500))  INFO  GET /v1/health 200 1ms",
            "\(demoISO(seconds: -2800))  WARN  slow upstream: /v1/report took 1240ms",
            "\(demoISO(seconds: -1800))  INFO  reloaded config (3 routes)",
            "\(demoISO(seconds: -900))   INFO  GET /v1/apps 200 4ms",
            "\(demoISO(seconds: -120))   INFO  GET /v1/metrics 200 6ms"
          ]
        }
        """
    }

    /// `GET /v1/ip/current` —— 概览页的地址卡。
    ///
    /// 公网地址用 **TEST-NET-3（203.0.113.0/24）与 2001:db8::/32**：
    /// 它们是 RFC 5737 / RFC 3849 留给文档的地址段，永远不会属于某台真机器。
    /// 随手编一个看起来像公网的地址是有可能撞到别人真实 IP 的，而这个应用
    /// 恰恰是拿地址去连东西的。
    static var ipStatus: String {
        """
        {
          "ipv4": ["203.0.113.42"],
          "ipv6": ["2001:db8::42"],
          "global_ipv6": ["2001:db8::42"],
          "interfaces": [
            {"name": "en0", "ipv4": ["192.168.1.10"], "global_ipv6": ["2001:db8::42"], "is_up": true},
            {"name": "utun4", "ipv4": [], "global_ipv6": ["2001:db8:1::7"], "is_up": true}
          ]
        }
        """
    }

    /// `GET /v1/credentials` —— DNS 页的凭据列表。
    ///
    /// `last_verify_ok` 为 true：凭据验证失败是个"该去做点什么"的状态，
    /// 而演示里没有那个可做的动作。
    static var credentials: String {
        """
        {
          "items": [
            {
              "id": "\(credentialID)",
              "provider": "cloudflare",
              "label": "Cloudflare · example.com",
              "last_verify_ok": true
            }
          ]
        }
        """
    }

    /// `GET /v1/credentials/{id}/zones`。
    static var zones: String {
        """
        {
          "items": [
            {"id": "\(zoneID)", "name": "\(zoneID)", "status": "active"}
          ]
        }
        """
    }

    /// `GET /v1/credentials/{id}/zones/{zone}/records` —— DNS 页的记录列表。
    ///
    /// 四条覆盖了界面上会分叉的几种取值：带代理的 A、指向目标的 CNAME、
    /// 不带代理的 A、以及一条 TXT。`ttl` 有的有有的没有 ——
    /// 那一行是可选显示的。
    static var records: String {
        """
        {
          "items": [
            {"id": "rec-apex", "name": "@", "type": "A", "content": "203.0.113.42",
             "ttl": 300, "proxied": true, "comment": "\(demoTr("主站", "Main site"))"},
            {"id": "rec-www", "name": "www", "type": "CNAME", "content": "example.com",
             "ttl": 300, "proxied": true},
            {"id": "rec-api", "name": "api", "type": "A", "content": "203.0.113.42",
             "ttl": 120, "proxied": false},
            {"id": "rec-spf", "name": "@", "type": "TXT", "content": "v=spf1 -all",
             "ttl": 3600}
          ]
        }
        """
    }

    /// 新增/修改记录之后的回执（`POST`/`PUT`）。
    static var recordReceipt: String {
        """
        {"id": "rec-new", "name": "@", "type": "A", "content": "203.0.113.42",
         "ttl": 300, "proxied": true}
        """
    }

    /// `GET /v1/ddns-tasks` —— DNS 页的动态解析任务。
    static var ddnsTasks: String {
        "{\"items\":[\(ddnsTask)]}"
    }

    /// 一条动态解析任务。同时用作 `enable`/`disable` 的回执。
    static var ddnsTask: String {
        """
        {
          "id": "\(ddnsTaskID)",
          "credential_id": "\(credentialID)",
          "label": "\(demoTr("家里公网地址", "Home public address"))",
          "enabled": true,
          "last_run_at": "\(demoISO(seconds: -660))",
          "last_status": "ok",
          "last_message": "\(demoTr("已把 A 记录更新为 203.0.113.42", "Updated the A record to 203.0.113.42"))",
          "last_ipv4": "203.0.113.42",
          "last_ipv6": "2001:db8::42"
        }
        """
    }

    /// `GET /v1/certs` —— 概览页的证书卡。
    static var certificates: String {
        """
        {
          "items": [
            {"domains": ["blog.example.com"], "not_after": "\(demoISO(days: 62))", "staging": false},
            {"domains": ["api.example.com"], "not_after": "\(demoISO(days: 12))", "staging": false}
          ]
        }
        """
    }

    /// `GET /v1/proxy/status`。
    static var proxyStatus: String {
        "{\"running\": true, \"port\": 443, \"tls\": true, \"routes\": 3}"
    }

    /// `GET /v1/health` 与 `GET /v1/meta`。
    ///
    /// 界面不直接调它们（是验收工具在用），但一个"健康检查答不上来"的
    /// 假内核会给后来的人留一个陷阱。
    static var health: String {
        "{\"status\": \"ok\", \"uptime_seconds\": 273600, \"version\": \"1.4.2\"}"
    }

    static var meta: String {
        """
        {
          "version": "1.4.2",
          "api_version": "v1",
          "commit": "demo",
          "os": "darwin",
          "arch": "arm64",
          "started_at": "\(demoISO(days: -3))",
          "capabilities": {
            "remote": {"available": true, "backend": "builtin"},
            "metrics_gpu": {"available": true, "backend": "ioreg"}
          }
        }
        """
    }

    /// 手表派生（`POST /v1/remote/self/derive`）。
    static var derivedDevice: String {
        "{\"device_id\": \"demo-watch\", \"token\": \"\(token)-watch\", \"role\": \"viewer\"}"
    }

    /// 可达性自检的回执。演示里没有公网探测计划，因此这个接口只会被
    /// 误调到；回一份"没开"的状态，而不是 404。
    static var publicStatus: String {
        "{\"enabled\": false, \"ready\": false}"
    }

    /// 不返回内容的那些接口（启停站点、跑一次动态解析、删记录…）。
    static let empty = "{}"

    // MARK: - 小工具

    /// 相对当下算一个 ISO8601 时间戳。
    static func demoISO(days: Double = 0, seconds: Double = 0) -> String {
        Date().addingTimeInterval(days * 86_400 + seconds).formatted(.iso8601)
    }
}

/// 与 MizarApp 里的 `tr2` 同义，但这里是 `nonisolated`。
///
/// `tr2` 在 `AppModel.swift` 里，而那个 target 开了
/// `defaultIsolation(MainActor.self)` —— 它是主 actor 隔离的。演示数据却在
/// **传输层**被构造，那里是 nonisolated（`TransportFactory` 是 `@Sendable`
/// 的，从竞速的子任务里调用）。因此这里不能借用那个函数。
///
/// 只有这一行是重复的：取词规则本身（中文在前、跟着系统语言走）与
/// `tr2` / `tr` 逐字一致。
private nonisolated func demoTr(_ zh: String, _ en: String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("zh") == true ? zh : en
}

// MARK: - 假传输

/// 一个**不联网**的 `KernelTransport`：按路径回演示载荷。
///
/// # 它为什么不模拟延迟与失败
///
/// 因为那是测试该做的事，不是演示该做的事。审核员需要看到的是这个应用
/// **正常工作**的样子，而不是一个随机转圈的版本。唯一的例外是下面
/// `pollEvents` 里那个 10 秒的等待 —— 它不是装饰：`AppModel` 的事件循环是
/// 「拉一批 → 立刻再拉一批」的长轮询，如果这里瞬间返回空批，那个循环会
/// 变成一秒几百圈的空转（模拟器风扇会转起来，而界面上什么都没变）。
nonisolated struct DemoTransport: KernelTransport {

    /// 装进 `AppModel.init(makeTransport:)` 的那一个工厂。
    ///
    /// 忽略 `TransportSpec`（地址、令牌、超时）：假的传输没有"连哪一台"
    /// 这回事。刻意显式忽略而不是断言，是为了让"它不联网"这件事在签名上
    /// 就看得出来。
    static let factory: TransportFactory = { _ in DemoTransport() }

    func call(_ method: String, _ path: String, body: Data?) async throws -> KernelReply {
        let route = Self.route(from: path)
        guard let json = Self.reply(for: route, method: method) else {
            // 认不出的路径**明确报错**而不是回一个空对象：空对象会被
            // 上层解成"这份数据是空的"，而那看起来像"你的服务器上确实
            // 没有站点" —— 一个安静的假事实。404 至少在界面上会说出
            // 是哪条路径没准备数据。
            throw KernelError(code: "not_found", status: 404,
                              message: "演示模式没有为 \(method) \(route) 准备数据。")
        }
        return KernelReply(status: 200, body: try JSONValue.parse(json))
    }

    /// 事件长轮询。
    ///
    /// 演示模式没有事件源，因此永远回一个空批；那 10 秒等待的意义见类型
    /// 头部的说明。等待是可取消的 —— 用户切走时事件循环会 `cancel`，
    /// 而 `Task.sleep` 会立刻抛出，不会拖着一个已经没人要的任务。
    func pollEvents(since: Int64, timeoutMilliseconds: Int) async throws -> EventBatch {
        try await Task.sleep(for: .seconds(10))
        return EventBatch(events: [], next: since, gap: false)
    }

    /// 去掉查询串：`/v1/apps/site-api/logs?tail=300` 与不带查询的那条
    /// 是同一个路由，而 `KernelAPI` 里确实有一条带 `tail=` 的。
    static func route(from path: String) -> String {
        String(path.split(separator: "?", maxSplits: 1).first ?? "")
    }

    /// 路由表。
    ///
    /// 覆盖了 `KernelAPI` 里 Mizar 真正会调用的**全部**路径 ——
    /// 一个都不少，否则界面上会冒出一句"演示模式没有为…准备数据"。
    static func reply(for route: String, method: String) -> String? {
        switch route {
        case "/v1/health": return DemoData.health
        case "/v1/meta": return DemoData.meta
        case "/v1/remote/self": return DemoData.remoteSelf
        case "/v1/remote/self/derive": return DemoData.derivedDevice
        case "/v1/remote/self/push-token": return DemoData.empty
        case "/v1/remote/public/check": return DemoData.publicStatus
        case "/v1/metrics": return DemoData.metrics
        case "/v1/advisories": return DemoData.advisories
        case "/v1/apps": return DemoData.apps
        case "/v1/ip/current": return DemoData.ipStatus
        case "/v1/credentials": return DemoData.credentials
        case "/v1/credentials/\(DemoData.credentialID)/zones": return DemoData.zones
        case "/v1/credentials/\(DemoData.credentialID)/zones/\(DemoData.zoneID)/records":
            return DemoData.records
        case "/v1/ddns-tasks": return DemoData.ddnsTasks
        case "/v1/certs": return DemoData.certificates
        case "/v1/certs/renew": return DemoData.empty
        case "/v1/proxy/status": return DemoData.proxyStatus
        default: break
        }

        // 带参数的几条：这些路径里有一段是 id，因此只能按前缀 + 后缀认。
        if route.hasPrefix("/v1/apps/") {
            let rest = String(route.dropFirst("/v1/apps/".count))
            if rest.hasSuffix("/logs") { return DemoData.appLogs }
            if ["/start", "/stop", "/restart"].contains(where: rest.hasSuffix) { return DemoData.empty }
            return DemoData.app(id: rest)
        }
        if route.hasPrefix("/v1/ddns-tasks/") {
            // `run` 不回内容；`enable` / `disable` 都要回一份任务（界面拿它
            // 更新那一行）。两者都答同一份，写操作在演示里是幂等的。
            return route.hasSuffix("/run") ? DemoData.empty : DemoData.ddnsTask
        }
        if route.hasPrefix("/v1/credentials/") {
            if route.contains("/records") {
                // 删除不回内容，新增/修改回一条记录。
                return method == "DELETE" ? DemoData.empty : DemoData.recordReceipt
            }
            return DemoData.zones
        }
        return nil
    }
}

// MARK: - 假令牌

/// 演示模式下的令牌存放处：内存里那一份，**不碰钥匙串**。
///
/// 用 `InMemoryTokenStore` 是不行的：它的 `setToken` 是 `async`，而这条
/// 路径要在 `AppModel.init`（同步）里就位。这里返回一个常量，代价是
/// "任何 id 都能拿到令牌" —— 演示模式里只有一台服务端，这个宽泛度
/// 没有实际影响，而它换来的是"演示绝不写用户的钥匙串"。
nonisolated struct DemoTokenStore: TokenStore {
    func token(for serverID: String) async throws -> String? { DemoData.token }
    func setToken(_ token: String?, for serverID: String) async throws {}
    func removeAll() async throws {}
}

#endif
