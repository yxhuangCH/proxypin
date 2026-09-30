# 09 - 应用白名单与 VPN 路线实施

> 依据：本文档承接 08 号评估，是「鸿蒙应用白名单抓包」的落地实施方案（分期）。
> 状态：**第 0 期 PoC 已通过**（分支 `feature/ohos-vpn-poc`，2026-09-29）。四项致命假设全部验证，结论见 §4.5。

## 1. 背景与目标

Android 版 ProxyPin 的「应用白名单」：只代理白名单内 App 的流量，enforcement 由 `VpnService.Builder.addAllowedApplication()` 在系统路由层完成（`android/.../ProxyVpnService.kt:396-408`）。

鸿蒙当前为路线 B（局域网代理服务，ProxyServer 监听 0.0.0.0:9099 供局域网设备连入），流量不携带应用身份，白名单无生效抓手。实现该功能 = 实施路线 A：**VpnExtensionAbility 本机 VPN 抓包**，白名单由 `VpnConfig.trustedApplications`/`blockedApplications` 原生字段承载（与 Android 语义一一对应）。

**产品形态（已拍板）：FAB=VPN 开关，双模式共存**

- FAB（启动按钮）从「代理服务启停」切换为「VPN 启停」（`lib/ui/mobile/mobile.dart:465-493` 的 `vpnLaunch` 逻辑，`supportVpn()` 放开 ohos 后自动生效）；
- 代理服务常驻（`configuration.startup=true` 自启，持续监听 0.0.0.0:9099），局域网设备（路线 B）照常连入；
- 本机 App 流量经 VPN tun 转发到 127.0.0.1:9099，两种模式天然共存；
- `mobile.dart:479` host 取值：ohos 走 else 分支 `"127.0.0.1"`（现有代码已正确）。

## 2. 对 08 号评估的修正（基于官方文档核实）

| 08 号结论 | 修正后事实 |
|---|---|
| 需要 `ohos.permission.MANAGE_VPN`（system_basic，ACL 申请） | **三方 VPN（`@ohos.net.vpnExtension`）仅需已有的 `ohos.permission.INTERNET`**（normal）。MANAGE_VPN 只被系统接口模块 `@ohos.net.vpn` 使用 |
| module.json5 声明 `"type": "vpn.extension"` | **type 为 `"vpn"`**（离线官方文档与 OpenHarmony 源码文档一致） |
| ACL 受限权限申请是先决条件（S1） | 权限申请步骤取消；真正的硬约束变为「上架审核口径」（见 §6 R2） |

其余关键事实：

- `trustedApplications`/`blockedApplications` **互斥**（不能同时配置），各上限 256 个（API 23 前 64）；
- **手机上三方应用无法枚举已安装应用列表**（`getBundleInfo` 查他人包需 `GET_BUNDLE_INFO_PRIVILEGED` 企业权限；`getInstalledBundleList` 仅 PC/2in1）→ 白名单 UI 必须降级为手动输入 + 预置清单；
- tun fd 为原生 fd，ArkTS 无 read/write API → **隧道栈必须 C++ NDK**；
- ~~VpnConfig 无 excludeRoutes 对应物~~ **修正**：`RouteInfo.isExcludedRoute`（API 20+，SDK d.ts 已核实）可表达排除路由，`proxyPassDomains` CIDR 排除后续可基于此实现（非 MVP）；
- VpnExtensionAbility 生命周期仅 onCreate/onDestroy；系统在发起方进程退出时断开 VPN → 仍需路线 B 已有的 dataTransfer 长时任务辅助保活；
- 同一时刻系统仅允许一个活跃 VPN（错误码 2203002）。

## 3. 分期总览

| 期 | 内容 | 工作量 | 状态 |
|---|---|---|---|
| 第 0 期 | PoC：tun fd 可读写 + trustedApplications 生效 | 2-3 天 | ✅ 2026-09-29 真机通过 |
| 第 1 期 | 隧道栈全量移植（C++ NDK，约 2500-3000 行） | 2-3 周 | ✅ 2026-09-30 真机通过（§5） |
| 第 2 期 | 白名单 UI 接入 + Dart 门禁放开 | 3-5 天 | ✅ 2026-09-30 真机通过（§6） |

三期已全部完成，功能在 `feature/ohos-vpn-poc` 分支上落地；尚未合并 main。**上架决策：现阶段不做 AppGallery 上架**，以本地开发/侧载（hdc）为准（见 R2）。

## 4. 第 0 期：PoC —— 验证三个致命假设

不解析任何报文，只验证：(a) C++ 层能 read/write tun fd；(b) `trustedApplications` 过滤真实生效；(c) 转发不成环。

### 新增文件

| 文件 | 作用 |
|---|---|
| `ohos/entry/src/main/ets/vpnability/ProxyPinVpnAbility.ets` | VpnExtensionAbility 子类：`onCreate` 里 `vpnExtension.createVpnConnection(this.context)` + `create(VpnConfig)`。VpnConfig：addresses=`10.0.0.2/32`、routes=`0.0.0.0/0`、mtu=1500、`isBlocking=true`、`trustedApplications=["<预置包名>"]` |
| `ohos/entry/src/main/ets/plugins/ProxyPinVpnPlugin.ets` | 雏形插件（channel `com.proxy/proxyVpn`，与 Android 同名同协议）：`startVpn` → `vpnExtension.startVpnExtensionAbility(want)`；`stopVpn` → `stopVpnExtensionAbility(want)`。仿照 `ProxyPinKeepAlivePlugin.ets` 的 FlutterPlugin + MethodCallHandler 模式 |
| `ohos/entry/src/main/cpp/napi_init.cpp` + `CMakeLists.txt` | 最小 napi 模块：`readTun(fd): ArrayBuffer` / `writeTun(fd, data)` / `pollTun(fd, timeoutMs)`。循环 poll+read，把 IP 头目的地址打到 hilog |

### 修改文件

- `ohos/entry/src/main/module.json5`：`abilities` 段之后新增 `extensionAbilities: [{"name":"ProxyPinVpnAbility","srcEntry":"./ets/vpnability/ProxyPinVpnAbility.ets","type":"vpn"}]`；**权限无需新增**（INTERNET 已有）；
- `ohos/entry/build-profile.json5`：`buildOption` 增加 `externalNativeOptions`（path 指 `./src/main/cpp/CMakeLists.txt`，abiFilters `["arm64-v8a"]`）；
- `ohos/entry/src/main/ets/entryability/EntryAbility.ets`：`configureFlutterEngine` 注册 `ProxyPinVpnPlugin`；
- `lib/utils/platform.dart:36`：`supportVpn()` 加 `|| isOhos()`（使 FAB 变 VPN 开关以触发 PoC）。`supportAppFilter()` 不动（UI 接入是第 2 期）。

### 配置传递机制

Plugin → ExtensionAbility 同进程，配置经 `want.parameters` 传递：`startVpnExtensionAbility({bundleName, abilityName:"ProxyPinVpnAbility", parameters:{proxyPort, trustedApps, blockedApps}})` → `onCreate(want)` 读参数 → `createVpnConnection(this.context).create(VpnConfig)`。首次启动系统弹授权框（对齐 Android `prepareVpn` 语义）。trustedApps/blockedApps 二选一，对应 Dart 侧 `allowApps`/`disallowApps` 既有取值逻辑（`lib/native/vpn.dart:15-20`，白名单非空则用白名单、否则用黑名单——语义天然兼容）。

### 验收标准（全部通过才进入第 1 期）

- [x] `startVpnExtensionAbility` 弹系统授权框，授权后 `create()` 返回合法 fd（>0）——实测 fd=29/32，二次启动不再弹框（授权被记住）
- [x] C 层 `read(fd)` 能读到 IP 报文（hilog 可见目的 IP）——IPv4 头解析正确：UDP `10.0.0.2:xxxxx -> 223.5.5.5:53`、TCP SYN `-> 49.4.19.209:443`
- [x] **白名单生效**：trustedApplications=[com.huawei.hmos.browser] → 浏览器未启动时 tun 静默 20s+（空白名单时系统 App 每 2s 的 DNS 重试噪音完全消失）；浏览器启动后爆发 283 个报文（全是浏览器主页加载的 SYN）
- [x] 双模式共存：VPN 运行中 `curl -x 192.168.3.188:9099 http://<Mac>:8888/` 返回 HTTP 200，路线 B 不受影响
- [~] ProxyPin 自身流量进 tun：**部分验证**——发往局域网目的（192.168.3.96）的自身连接**未**进 tun（局域网被系统排除在 VPN 路由外）；发往公网目的的自身流量待第 1 期端到端验证，届时按 Android 做法实现自身排除（空白名单时 `blockedApplications=[自身包名]`，见 `ProxyVpnService.kt:402`）
- [x] `flutter build hap` 通过；五平台构建零影响（新增代码全在 ohos/ + platform.dart 一处运行时分支）

### 第 0 期实测发现（影响第 1 期设计）

| # | 发现 | 影响与对策 |
|---|---|---|
| P1 | **VpnExtensionAbility 跑在独立进程** `com.network.proxy:vpn`（pid 与主进程不同），ArkTS 静态变量跨进程不可见 | `VpnAbilityState.isRunning` 在插件侧永远读到 false；第 1 期需 IPC（commonEvent 或 WantAgent 回调）同步运行状态，否则 `launch.dart:205` 恢复 FAB 状态会误判 |
| P2 | **息屏后约 1 分钟 VPN 被系统销毁**（netmanager 触发 onDestroy + 进程 terminate），时间点与息屏吻合 | VPN 模式未申请长时任务（`launch.dart:301` 只在 serverLaunch 分支调用 `_applyOhosKeepAlive`）；第 2 期需在 VPN 模式补调用，或验证 dataTransfer 长时任务能否延长 VPN 存活 |
| P3 | tun 中有 IPv6 报文（len 76/96/116，version nibble=6）进入，尽管 `isIPv6Accepted=false` | 第 1 期隧道栈必须显式丢弃非 IPv4 报文（Android 侧同样只看 IPv4），不能假设 tun 只出 IPv4 |
| P4 | `RouteInfo.gateway` 是**必填**字段（`hasGateway=false` 时也需占位值），ArkTS 编译期强校验 | 已在实现中处理：`gateway: { address: '0.0.0.0', family: 1 }` |
| P5 | hilog 的 `%{public}zu` 不生效（打印为 `}zu`），size_t 需转 int 用 `%{public}d` | 仅日志可读性问题，第 1 期顺手修正 |
| P6 | 空白名单时手机断网（全部应用流量进 tun 且 PoC 不回包）——符合预期，但说明 UI 必须有明确提示 | 第 2 期白名单页补充"白名单为空将抓取所有应用"提示（已有）+ VPN 开关状态提示 |
| P7 | 局域网目的流量不进 tun | 第 1 期无需为局域网转发做特殊处理；但同时意味着"抓本机访问局域网服务的请求"在 VPN 模式下抓不到（文档化限制） |

**结论：第 0 期四项致命假设通过，可进入第 1 期隧道栈移植。**

## 5. 第 1 期：隧道栈移植（C++ NDK）

目标：tun fd ↔ 本机 127.0.0.1:9099 透明转发，HTTPS 抓包端到端跑通。转发模型与 Android 一致（透明代理，Dart 侧经 SNI/Host 嗅探目标 + 端口映射修正）。

### 最终目录结构（已实现，`ohos/entry/src/main/cpp/`）

```
cpp/
├── CMakeLists.txt
├── napi_init.cpp      # napi 薄接口（startTunnel/stopTunnel/isTunnelRunning/getRemoteByPort）
├── packet.h/.cpp      # IPv4/TCP/UDP 解析与构造 + 校验和 + TLS/HTTP 嗅探（对照 transport/protocol/*、PacketUtil、TLS）
├── session.h          # 会话状态结构（对照 Connection.kt）
├── tunnel.h/.cpp      # 单线程 poll 循环：tun 读写 + 上行 socket + TCP 状态机 + UDP 转发 + 控制通道
└── port_map.h/.cpp    # 本地上行端口 → 原始目标映射（对照 ProcessInfoManager.localPortCache，免 /proc）
```

**与蓝本的差异（实现时拍板）**：

- **三线程合并为单线程 poll 循环**。Android 用「VPN 阻塞读线程 + NIO Selector 线程 + 客户端写队列线程」+ ReentrantLock；本实现把 tun fd、全部上行 socket、控制监听 fd 一并交给一个 poll 线程，回包也由该线程直接写 tun，会话表无锁。语义等价，代码量约为蓝本 1/2。
- **UDP 全量转发**（任意端口直连），非计划中「仅 UDP/53」。上行 UDP 用 `connect()` 的 datagram socket，双向转发；QUIC 流量因此也能正常回落。
- **新增 127.0.0.1:9109 控制通道**：扩展进程（隧道所在）跑一个 loopback TCP 服务，主进程插件经它查询 isRunning（解决 P1 静态状态跨进程不可见）与 port_map。协议为定长小报文（magic+op+arg → status+port+host）。
- **protectProcessNet()**（API 22+）在 `create()` 后调用，保护扩展进程内全部后续 socket；黑名单模式始终自排除本应用（对齐 Android `addDisallowedApplication(self)`）。
- **IPv6 / 分片 / ICMP 显式丢弃**。注意 IPv4 flags 位：Android `IP4Header` 的 `mayFragment(0x4000)/lastFragment(0x2000)` 实为 DF/MF，分片判定必须用 MF+offset，不能用 DF（DF 在真实 TCP 报文上几乎恒置位）。
- **地址字节序**：`read_be32` 解析出的是大端解释值（127.0.0.1 → 0x7F000001），赋给 `sin_addr.s_addr` 前必须 `htonl()`（直连与 UDP 路径都用得到；Android 走 `InetSocketAddress(string)` 隐式正确）。
- **idle 回收**：UDP 会话 60s 空闲回收、TCP 半开会话 120s 回收（Android 不回收 UDP，长跑会漏 fd）。
- **MSS 恒为 0**：Android `TCPHeader.handleTcpOptions` 从未被调用，下行分片恒走 1024 兜底（`push_data_to_client`），本实现保持同样行为。

### napi 接口契约（已实现）

```
startTunnel(tunFd: number, proxyHost: string, proxyPort: number): boolean   // 扩展进程
stopTunnel(): void                                                            // 扩展进程
isTunnelRunning(): boolean                                                    // 主进程，跨进程查询
getRemoteByPort(localPort: number): {remoteHost: string, remotePort: number} | null  // 主进程
```

### 原生侧补全（已实现）

- `ProxyPinVpnPlugin.ets`：`isRunning` 改为经隧道控制通道跨进程查询；`startVpn` 透传 `proxyHost`。
- 新增 `ProxyPinProcessInfoPlugin.ets`：实现 `com.proxy/processInfo` 的 `getRemoteAddressByPort`（经隧道控制通道查 port_map）；`getProcessByPort` 恒返回 null。
- EntryAbility 注册两个插件。
- Dart：`lib/native/process_info.dart` 的 `getRemoteAddressByPort` 与 `lib/network/channel/channel_dispatcher.dart` 的 `_fixAndroidVpnPort` 放开 ohos；`lib/ui/launch/launch.dart` 的 VPN 启动分支补 `_applyOhosKeepAlive()`（修复 P2 息屏断 VPN）。

### 本地自测（不上真机即可回归）

`ohos/entry/src/main/cpp/` 下代码与平台头解耦（仅 hilog 需打桩），可用宿主机直接编译验证（用 `AF_UNIX SOCK_DGRAM` socketpair 冒充 tun fd，本机 TCP/UDP 服务冒充代理与目标）。曾在本机验证 11 个场景全过：SYN→SYN-ACK、数据→ACK、TLS 嗅探走代理、port_map 登记与跨进程查询、上行回包 PSH、FIN/RST/未知会话、UDP 双向、IPv6/畸形/分片丢弃、DF 位不丢弃、直连不走代理、非标准端口 HTTP 走代理且 port_map 记录。期间借此发现并修复：DF 位误丢弃、直连地址未 htonl、控制通道 accept 继承 O_NONBLOCK（macOS/BSD 特有）。

### 验收标准（2026-09-30 真机通过）

- [x] 白名单=浏览器：浏览器访问 HTTPS 站点 → ProxyPin 请求列表出现解密记录
      实测：`GET https://www.baidu.com/sugrec [200] TEXT`、`m.baidu.com [200]`、`ext.baidu.com [403]`、`gips2.baidu.com [304] IMAGE`，条目右侧为绿色解密标记
- [x] 白名单外 App 联网 → 不出现记录
      实测：启动应用市场（大量联网，QUIC/h3 有实际收发字节）期间 tun 零报文 —— 系统级 `trustedApplications` 过滤生效
- [x] 清空白名单 + 黑名单配浏览器：浏览器流量消失，其余 App 正常被抓
      实测：`blocked=[com.huawei.hmos.browser]` 时浏览器访问 baidu 期间 tun 零报文；改为 `blocked=[com.fake.nonexistent]`（等价全量抓包）后浏览器访问知乎成功解密（域名列表出现 `https://www.zhihu.com` 且无 ssl error）
- [x] 明文 HTTP 非标准端口请求端口修正正确（port_map 路径）
      实测：`http://portquiz.net:8080/` 经隧道走代理成功（`proxied TCP|10.0.0.2:xxxxx->35.180.139.74:8080`，port_map 登记），ProxyPin 列表出现 `http://portquiz.net:8080` 4 次
- [x] 双模式共存：VPN 开启时 Mac 经 `curl -x 192.168.3.188:9099` 访问 HTTP/HTTPS 均 200，路线 B 不受影响

`_fixAndroidVpnPort` 的**端口覆盖分支**（Host 头不带端口 + 目标非 80）真机上无法自然构造（浏览器总会带端口），该分支由本地单测覆盖（tunnel_test 场景 11 + port_map 跨进程查询）。

### 第 1 期真机实测发现

1. **未 connect 的 TCP 会话不能进 poll**（真机致命 bug，已修）。SYN 建会话后、首个数据报文触发 `init_proxy_connect` 之前，socket 尚未 connect；若此窗口内 poll 被唤醒（控制通道查询、其他会话活动），内核会对未连接 socket 报 `POLLHUP/POLLIN`，`read()` 返回 `ENOTCONN(107)` → 会话被误杀 → 后续报文全变 `unknown session`。现象：浏览器整页加载失败，日志刷屏 `read TCP|... failed errno=107`。修法：poll 注册时跳过 `protocol==TCP && !connecting && !connected` 的会话。已加本地回归用例（`1.5 poll wakeup before first data`）。
2. **同子网目标不走 VPN**：手机访问同 WiFi 网段的 `192.168.3.96:8100` 不经 tun（系统自动排除本地子网，避免回环）。验证明文抓包需用外网目标。
3. **华为自家服务会因证书 pinning 拒绝解密**：`httpdns.platform.dbankcloud.com`、`browsercfg-drcn.cloud.dbankcloud.cn`、`feeds-drcn.cloud.huawei.com.cn` 等持续报 `SSLV3_ALERT_CERTIFICATE_UNKNOWN`。这是客户端行为，与 Android 一致，不影响其它站点抓包；日志中这类失败数量会远高于成功数，勿据此判定整体失败。
4. **CA 安装路径（鸿蒙无 ADB 式一键安装）**：手机浏览器访问 `http://127.0.0.1:9099/ssl`（代理内置的 `requestUrl == 'http://127.0.0.1:<port>/ssl'` 分支，`lib/network/handle/http_proxy_handle.dart:34`）下载 `ProxyPinCA.crt` → 设置 → 隐私和安全 → 高级 → 证书与凭据 → 从存储设备安装 → CA 证书 → 选择下载目录中的 crt → 安装。**安装后必须重启目标 App**（本次为浏览器），否则该进程沿用旧信任库，继续报 `CERTIFICATE_UNKNOWN`。
5. **hilog 的 ArkTS 格式不支持 `%zu`**：`hilog.info(..., '%{public}zu', arr.length)` 会输出字面 `}zu`，导致误判名单为空。改用 `arr.join(',')` + `%{public}s` 打印内容（已修 `ProxyPinVpnPlugin.ets` / `ProxyPinVpnAbility.ets`）。
6. **FAB 点击与 extension 生命周期**：`aa force-stop` 主进程不会回收 `com.network.proxy:vpn` 子进程，此时 Dart 侧 `Vpn.isRunning()` 为 true，FAB 呈"停止"态，点击会**关闭** VPN 而非启动。脚本化验证时需先确认 FAB 状态（或观察 hilog 是否出现 `vpn extension stopped`）再决定点击次数。

## 6. 第 2 期：白名单 UI 与门禁接入

### Dart 侧改动

| 文件 | 改动 |
|---|---|
| `lib/utils/platform.dart` | `supportAppFilter()` 加 ohos（`supportVpn()` 第 0 期已放开）；新增 `supportInstalledApps()`（仅 Android true）供 UI 降级判断 |
| `lib/native/vpn.dart` | **不改**。channel 名与参数协议原样复用；ohos 插件忽略 `proxyPassDomains` |
| `lib/native/installed_apps.dart` | `getInstalledApps` 在 `!supportInstalledApps()` 时提前返回 `Future.value(const [])`，避免 channel 缺失抛 `MissingPluginException`（UI 已改用 `OhosAppPickerWidget`，走不到这里，属兜底） |
| `lib/native/process_info.dart` | `getRemoteAddressByPort` 放开 ohos |
| `lib/network/channel/channel_dispatcher.dart:218` | `_fixAndroidVpnPort` 条件改为 `!(isAndroid() \|\| isOhos())` |
| `lib/ui/mobile/mobile.dart:297` | ~~PiP 必须排除 ohos~~ **核实后无需改动**：:301 已有 `!Platforms.isAndroid() \|\| !pipEnabled` 保护，ohos 不会触碰 `com.proxy/pictureInPicture` channel。:335 的 `Vpn.isRunning()` 恢复逻辑 ohos 可用，保留。:465-493 FAB 逻辑无需改动 |
| `lib/ui/launch/launch.dart:287-293` | **VPN 模式保活补齐（已实现）**：`_applyOhosKeepAlive()` 原先只在 `serverLaunch` 分支调用；VPN 模式下 FAB 走 `serverLaunch=false` 分支，首次启动不申请长时任务，仅靠 resumed 回调补。已在 `start()` 的 `serverLaunch=false` 分支补调（字段命中 P2 息屏约 1 分钟断 VPN） |
| `lib/ui/mobile/widgets/remote_device.dart:266-268` | 远程设备 ipProxy 流程调 `Vpn.startVpn(remoteHost, ...)`——隧道栈天然支持，不改；验证阶段覆盖 |
| `lib/ui/mobile/menu/drawer.dart:399`、`menu.dart:60` | 无需改动，`supportAppFilter()` 放开后入口自动出现；`menu.dart` 仅把图标按平台切成 `phone_android` |

### 白名单 UI 降级（`lib/ui/mobile/setting/app_filter.dart`）

鸿蒙无法枚举已安装应用，降级方案：

1. **新增 ohos 应用选择页**（`ohos_app_picker.dart`）：ohos 时 "+" 按钮不再 push `InstalledAppsWidget`，改推 `OhosAppPickerWidget`：顶部手动输入框（bundleName 格式校验 `^[a-zA-Z][\w]*(\.[a-zA-Z][\w]*)+$`，即至少两段）+ 搜索框；下方「常见应用」预置清单（纯 Dart 常量，`ohos_preset_apps.dart`，28 个常用 HarmonyOS NEXT 包名，含真机 `bm dump -a` 实测确认的 22 个）。返回值协议与 `InstalledAppsWidget` 一致（`Navigator.pop(packageName)`），AppWhitelist/AppBlacklist 主体逻辑零改动；
2. **互斥提示**：鸿蒙 trusted/blocked 物理互斥（现有 vpn.dart:15-20 语义天然兼容）。ohos 且另一端名单非空时，页面顶部加 MaterialBanner（`buildMutualExclusionBanner`，可「知道了」关闭）。不新增配置字段，不改 Android 行为；
3. **数量上限**：`ohosAppListLimit = 256`，添加到第 257 个时 SnackBar 拒绝；
4. **顺带修正的既有 bug**：`_loadApps()` 原先在 `initState` 里调用，而它第一步就读 `Localizations`，此时依赖尚未建立，异常被 async 函数吞掉后 `isLoading` 永远为 true（真机表现为页面一直转圈）。已改到 `didChangeDependencies` + `_loaded` 幂等守卫。Android 同样受益。

### 验收标准（2026-09-30 真机通过）

- [x] 鸿蒙过滤器页出现白名单/黑名单入口：drawer（`bottomNavigation=false` 时）→「代理过滤」页 → 应用白名单/应用黑名单两项均在；`bottomNavigation=true`（默认）时抽屉不存在，白名单入口在首页 ⋮ 菜单（黑名单入口见下方 F2）
- [x] 从预置清单添加：选择器列出常见应用并**排除本页已添加项**，点选后回落到名单，显示预置中文名（`浏览器 Browser / com.huawei.hmos.browser`）
- [x] 手动输入校验：输入 `ABC` → 输入框红框 + `包名格式不正确，示例：com.example.app`
- [x] 非预置包名显示回落：`com.example.test` 显示名 = 包名本身（`ohosPresetAppName` 返回 null 的回落分支）
- [x] 互斥提示：白名单页（黑名单 2 项）与黑名单页（白名单 2 项）对称显示 banner，文案带对方条目数与后果，「知道了」可关闭
- [x] 落盘：UI 添加后返回上一页（触发 `dispose`）→ `config.cnf` 中 `appBlacklist` 已含新条目
- [x] 构建回归：`flutter analyze` 0 error（230 条历史 info 级问题，与改动前一致）；`flutter build hap --release` ✅（并已 `hdc install` 到真机冒烟：白名单页正常渲染）、`flutter build macos --debug` ✅、`flutter build ios --debug --no-codesign` ✅（首次失败于 `zstandard_ios` pod 的 `Sync zstd`/`Remove synced zstd` 两个 script phase 竞态，重跑即过，与本期改动无关）、`flutter build apk --debug` ✅（此前失败只因本机缺 `android/key.properties`，补齐本地签名配置后即通过）
- [x] Android 白名单回归（2026-09-30 真机 LIO-AN00 / Android 12 API 31）
      1. 菜单入口 `应用白名单` 图标为 Android 机器人（`isOhos() ? phone_android : android_rounded` 按平台取值正确），**未出现鸿蒙互斥 banner**（ohos-only 分支未泄漏）
      2. 白名单页正常渲染：空名单时显示"未设置白名单应用时会对所有应用抓包"，`isLoading` 正常收敛——`initState → didChangeDependencies` 的修正对 Android 同样生效
      3. 「+」仍进 `InstalledAppsWidget`：枚举出真实已装应用与真实图标（大众点评 / 58同城 / UC浏览器 / 微信输入法 …），搜索框与"显示系统应用"开关都在
      4. 添加 UC浏览器 → 列表显示真实图标 + 包名；`run-as` 直读 `config.cnf` 确认 `appWhitelist:["com.UCMobile"]`、`appWhitelistEnabled:true` 已落盘
      5. 白名单生效：UC浏览器访问 `portquiz.net:8080` 等 → ProxyPin 出现记录（HTTP/HTTPS 均有，含非标准端口 `:8080` 明文 HTTP 走 port_map 路径）；未列入的 58同城 前台运行 18s → **请求列表零新增**，且该时段 ProxyPin 进程 logcat 中 `wuba|58.com` 匹配数为 0

### Android 白/黑名单双向隔离回归（2026-09-30，LIO-AN00 / Android 12 API 31）

上一轮 Android 回归只验了白名单。本轮补验**黑名单**，并把抓包链路收敛到「仅 VPN」以排除system proxy 干扰：

- 隔离手法：`config.cnf` 置 `enableSystemProxy:false`，重启 App 后点 FAB 起 VPN；`logcat` 中 `ProxyVpnService: startVpn` 打印的 `allowPackages` 即生效名单，`connectivity` 出现 `Transports: WIFI|VPN` 网络代理与 `tun0` 即隧道已建，`settings get global http_proxy` 为 `null` 即无系统代理旁路。
- **白名单模式**（`appWhitelistEnabled:true`, `appWhitelist:["com.UCMobile"]`）：UC浏览器前台 18s → `pdds-cdn.uc.cn` 等 `[200] HTTP` 解密记录成片出现；未列入的高德地图前台 22s、京东 15s → **请求列表零新增**。
- **黑名单模式**（`appWhitelistEnabled:false`, `appBlacklist:["com.UCMobile"]`）：58同城前台 20s → `app.58.com` / `empower.58.com` / `rentercenter.58.com` 等记录出现；随后 UC浏览器前台 15s → **无任何 `com.UCMobile` 记录**。

结论：Android 侧 `addAllowedApplication`/`addDisallowedApplication` 两条路径均按预期生效，白名单页 UI 改动未污染 Android 行为。

### 抓包能力边界：`-2` 与按应用证书固定（2026-09-30）

ProxyPin 中 `[-2]` 的语义是 `HttpStatus(-2, 'SSL handshake failed, 请检查证书安装是否正确')`（`lib/network/util/proxy_helper.dart:198`），响应体为原始异常文本。真机抓到的失败原文为 **`HandshakeException: Connection terminated during handshake`** —— 客户端在握手中途直接断连，是**证书固定（certificate pinning）**的典型特征，而非路由失败：该应用流量已成功进入隧道（记录里能看到 `CONNECT <host>`），只是 TLS 被应用自己掐断。设备无 root、CA 只能装用户证书链，Android 7+ 目标应用默认不信任用户 CA，因此这类应用**只能看到连接目标，无法解密**。

同族应用对照（同为 HSBC 内部/证书测试构建，同一台设备、同一时刻、同一份 ProxyPin 配置）：

| 包名 | 性质 | 结果 |
|---|---|---|
| `com.mns.mnsuk.android.cert` | M&S Bank 内部 cert 构建 | BioCatch 端点 `POST wup-happytest.eu.v2.customers.biocatch.com/client/v3...` → **`[200] JSON`，正文可读**（1.23 K / 21.51 K / 6.09 K 等），可正常抓包解密 |
| `hk.com.hsbc.hsbchkmobilebanking.cert` | HSBC HK UAT/预发 cert 构建（访问 `*.uat.hsbc.com.hk`、`*.preprod.eu`、`digitaldev.api.p2g.netd2.hsbc.com`） | 全部 `CONNECT [-2]`：`hsbc.edge.sdk.awswaf.com`（34 次）、`wup-69c80419.customers.biocatch.com`（4 次）、`digitaldev.api.p2g.netd2.hsbc.com`（5 次）**无一解密**；同族 BioCatch SDK 在 M&S 侧可解密、在此侧被固定，说明固定发生在**应用侧**而非端点侧 |

即：`.cert` 后缀不代表「一定可抓」，是否可解密取决于该应用自身的 pinning 配置，需按应用实测。

### 第 2 期真机实测发现

| # | 现象 | 影响与处置 |
|---|---|---|
| F1 | 真机默认拼音 IME 下，`uitest uiInput inputText` 输入的 ASCII 停留在 composing 态（控件收不到文本），候选词还会把 `.` 吃成空格 | 脚本无法输入 bundleName，故「合法包名」路径改用配置回放验证（结果同上）。用户手输不受影响（切换英文键盘即可）。已记入工具链笔记 |
| F2 | `应用黑名单` 的 UI 入口只在抽屉里，而抽屉仅在 `bottomNavigation=false` 时存在；默认 `bottomNavigation=true` 时黑名单无入口 | **既有产品行为，非本期引入**（Android 同样如此）。鸿蒙上白名单才是主场景，暂不处理；如需补齐，可在白名单页 AppBar 加跳到黑名单的入口 |
| F3 | 选择器的已添加过滤按**本页**作用域（白名单页的选择器不排除只在黑名单里的应用） | 与 Android `InstalledAppsWidget` 行为一致，不改 |
| F4 | 页面 `dispose` 才 `flushConfig`；`aa force-stop` 会跳过 dispose，此时 UI 上的改动不落盘 | 既有设计，非本期引入；脚本化验证时注意先进后退再读 `config.cnf` |
| F5 | 白名单条目若指向**未安装**的包名，Android 侧 `addAllowedApplication` 静默忽略、不报错，白名单也不会因此崩 | 脚本化验证前必须先用 `pm list packages -3` 核对条目已安装；本轮曾把未安装的 `com.hsbc.mobilebanking.pushmessagingdomainmodelplugin.sampleapp` 写进白名单，导致一次白名单测试实际只覆盖了 2 个应用而未被察觉 |
| F6 | 脚本化点击坐标目测不可靠：截图缩放会让目测的 FAB 位置偏上约 120px（实测 FAB 中心 = 原始像素 `(1043,1977)`，目测值 ≈ `(1044,1855)` 落在列表行上），表现为"点了没反应" | 坐标一律从 PNG 原始像素算目标 bbox（`FloatingActionButton` 外框、行文本带）再点击，不要靠目测换算 |
| F7 | VPN 起停只能走 UI：`am start-service .../ProxyVpnService` 被 `android.permission.BIND_VPN_SERVICE` 拒绝（`Error: Requires permission`），FAB 的 `FloatingActionButton(onPressed: null)` 只由内层 `SocketLaunch` 接管点击 | 无 root 时无法脚本化起 VPN，自动化必须点 FAB；启动成功以 `logcat` 的 `ProxyVpnService: startVpn ... allowPackages: [...]` + `connectivity` 出现 `Transports: WIFI\|VPN` 为准 |

## 7. 风险清单

| # | 风险 | 等级 | 缓解 |
|---|---|---|---|
| R1 | NDK 读 tun fd 不可行 | 高 | 第 0 期一票否决；备选：napi 桥接 ArrayBuffer 传 ArkTS（性能差但兜底） |
| R2 | AppGallery 对 VPN/抓包类审核严格 | 高 | **已决策不上架**（2026-09-30）：现阶段以本地开发 + hdc 侧载为准，不再为上架做形态妥协；保留路线 B 作为可回退形态，VPN 能力可摘除 extensionAbilities 段 |
| R3 | 转发成环 | 中 | PoC 验收项；兜底 `protectProcessNet()` |
| R4 | 五平台回归 | 中 | 新代码全在 ohos/ 或 `Platforms.isOhos()` 运行时分支；合并前全平台构建验证 |
| R5 | `proxyPassDomains` CIDR 排除不支持 | 低 | 文档化；ohos 隐藏该 UI 入口 |
| R6 | UDP 非 DNS（QUIC）被丢弃 | 低 | QUIC 自动回退 TCP；后续迭代补全 |
| R7 | ExtensionAbility 与 Flutter 引擎通信竞态 | 中 | 配置写静态区 + 事件回调；restartVpn = stop+start |

## 8. 端到端验证（Mate 80 Pro，HarmonyOS 6.1.1.120，API 24，hdc）

1. 构建安装：`flutter build hap`（ohos 引擎 ~/dev/flutter_ohos，注意 autofill 补丁 har 是否仍在缓存）→ `hdc install` 签名 hap；
2. PoC 白名单验证：trustedApplications 只配浏览器 → `hdc shell hilog` 观察浏览器有报文、微信无报文；blockedApplications 反向复验；
3. 全链路抓包：白名单=浏览器访问 HTTPS → 出现解密记录；名单外 App 不出现；清空白名单+黑名单=浏览器 → 浏览器流量消失；
4. 双模式共存：VPN 开启状态下，Mac 经 `curl -x 手机IP:9099` 抓包仍正常（路线 B 不受影响）；
5. 端口修正回归：非标准端口明文 HTTP 请求走通 port_map 路径。注意**真机只能验证明文 HTTP 非标准端口被正确代理**（浏览器总会把端口写进 Host 头，`_fixAndroidVpnPort` 的覆盖分支不触发，该分支由本地单测覆盖）；另注意同子网目标不经 tun，需用外网目标；
6. 回归：Android 真机白名单抓包 ✅（2026-09-30，LIO-AN00，见 §6 验收）；macOS/Windows 启动验证桌面代理无碍——macOS 仅验证了构建，**未启动跑行为**，Windows 本机无法构建（`flutter build windows` 只能在 Windows 上跑），**待补**；`flutter analyze` 0 error ✅。

## 9. 执行顺序

**第 0 期**（分支 `feature/ohos-vpn-poc`，验证通过才合入主线）：
1. module.json5 声明 extensionAbilities + ProxyPinVpnAbility.ets（先不接 napi，只验证授权框与 create() 返回 fd）
2. CMakeLists + napi_init.cpp（readTun/pollTun），Ability 拿到 fd 后起线程 poll 读 fd 打 hilog
3. ProxyPinVpnPlugin.ets 雏形 + EntryAbility 注册 + platform.dart 放开 supportVpn
4. 真机验收四项，结论回写本文档与 08 号评估

**第 1 期**：
1. `packet/`（纯位运算，先行 + 用 Android 侧抓包样本回放自测）
2. `connection.cpp/h` → `connection_handler.cpp` → `tun_pump.cpp` / `forwarder.cpp` → `udp_dns.cpp`
3. `port_map.cpp` + ProxyPinProcessInfoPlugin.ets + channel_dispatcher 改动
4. 插件补全 restartVpn/isRunning，真机端到端验收

**第 2 期**：
1. ~~platform.dart 门禁 + channel_dispatcher/mobile.dart(PiP) + installed_apps 降级~~ → 其中 mobile.dart 核实后无需改动（见 §6 表）
2. ohos_preset_apps.dart + 应用选择页 + 互斥提示/上限
3. 构建回归（ohos/macOS/iOS/Android 均已过，见 §6 验收）+ Android 真机回归 ✅（2026-09-30 完成）
