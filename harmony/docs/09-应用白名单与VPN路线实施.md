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

| 期 | 内容 | 工作量 | 一票否决点 |
|---|---|---|---|
| 第 0 期 | PoC：tun fd 可读写 + trustedApplications 生效 | 2-3 天 | ✅ 失败则不进入第 1 期 |
| 第 1 期 | 隧道栈全量移植（C++ NDK，约 2500-3000 行） | 2-3 周 | — |
| 第 2 期 | 白名单 UI 接入 + Dart 门禁放开 | 3-5 天 | — |

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

### 翻译蓝本对照（`android/.../vpn/`，约 3351 行）

| Android 文件 | 鸿蒙处置 | 说明 |
|---|---|---|
| `ProxyVpnThread.kt` | 必译 → `tun_pump.cpp` | tun fd 读写主循环，poll 阻塞读 + 写队列 |
| `ConnectionHandler.kt`（634 行，核心） | 必译 → `connection_handler.cpp` | 报文分发 + TCP 会话状态机，工作量最大 |
| `ConnectionManager.kt` + `Connection.kt` | 必译 → `connection.cpp/h` | 会话表（key: 协议+源/目的 IP:端口） |
| `transport/protocol/*`（IP4/TCP/UDP 头、TCPPacketFactory） | 必译 → `packet/` | 纯位运算，机械翻译 |
| `socket/SocketNIODataService.java` + `SocketChannelReader/Writer.java` | 必译简化 → `forwarder.cpp` | Java NIO Selector → C++ poll 多路复用，上行 socket 连 127.0.0.1:9099 |
| `socket/ClientPacketWriter.kt` | 必译 | 写回 tun fd 队列 |
| `util/PacketUtil.kt`、`SimpleCache.kt`、`TLS.kt`、`Tag.kt` | 必译 | 校验和、SNI 判定 |
| `transport/icmp/*` | **裁剪** | ICMP 回复仅用于连通性测试，MVP 直接丢弃 |
| `util/ProcessInfoManager.kt` | **改写** → `port_map.cpp` | 不解析 /proc/net；隧道栈天然知道每条会话原始目的地址，维护 `localPort → remoteHost:remotePort` 映射供 channel 查询（对应 Dart 侧 `_fixAndroidVpnPort` 需求） |
| `socket/ProtectSocket*` | 有条件裁剪 | 若 PoC 确认自身不在 trustedApplications 内则无需 protect；否则用 `protectProcessNet()`（API 22+，真机 API 24 满足） |

**UDP 取舍**：不能整体裁剪——白名单 App 的 DNS（UDP/53）走 tun，丢弃会导致域名解析失败。MVP 只实现 UDP/53 转发（`udp_dns.cpp`），其余 UDP 端口丢弃（QUIC 失败会自动回退 TCP，后续迭代补全）。

### 目录结构（新建 `ohos/entry/src/main/cpp/`）

```
cpp/
├── CMakeLists.txt
├── napi_init.cpp            # napi 薄接口
├── tunnel/
│   ├── tun_pump.cpp         # tun fd poll 读循环 + 写队列
│   ├── connection_handler.cpp
│   ├── connection.cpp/h
│   ├── forwarder.cpp        # 上行 socket poll 多路复用 → 127.0.0.1:9099
│   └── udp_dns.cpp          # UDP/53 最小转发
├── packet/
│   ├── ip4.cpp / tcp.cpp / udp.cpp
│   └── checksum.cpp
└── port_map.cpp
```

### napi 接口契约

```
napi_start_tunnel(tun_fd: number, proxy_host: string, proxy_port: number): boolean
napi_stop_tunnel(): void
napi_get_remote_by_port(local_port: number): string | null   // "host:port"，查 port_map
```

隧道栈在独立线程跑 poll 循环（tun fd + 全部上行 socket），与 ArkTS/Flutter 线程无锁交互（仅经 port_map 互斥表）。

### 原生侧补全

- `ProxyPinVpnPlugin.ets` 补全 `restartVpn`（stop+start）/`isRunning`；
- 新增 `ProxyPinProcessInfoPlugin.ets`：实现 `com.proxy/processInfo` 的 `getRemoteAddressByPort`（查 C++ port_map）；
- EntryAbility 注册两个插件。

### 验收标准

- [ ] 白名单=浏览器：浏览器访问 HTTPS 站点 → ProxyPin 请求列表出现解密记录
- [ ] 白名单外 App 联网 → 不出现记录
- [ ] 清空白名单 + 黑名单配浏览器：浏览器流量消失，其余 App 正常被抓
- [ ] 明文 HTTP 非标准端口请求端口修正正确（port_map 路径）

## 6. 第 2 期：白名单 UI 与门禁接入

### Dart 侧改动

| 文件 | 改动 |
|---|---|
| `lib/utils/platform.dart` | `supportAppFilter()`（:51）加 ohos（`supportVpn()` 第 0 期已放开）；新增 `supportInstalledApps()`（仅 Android true）供 UI 降级判断 |
| `lib/native/vpn.dart` | **不改**。channel 名与参数协议原样复用；ohos 插件忽略 `proxyPassDomains` |
| `lib/native/installed_apps.dart` | ohos 时 `getInstalledApps` 返回空 / `getAppInfo` 抛异常走既有 catchError 兜底（app_filter.dart:57-60 已能渲染"未知应用"） |
| `lib/native/process_info.dart` | `getRemoteAddressByPort` 放开 ohos |
| `lib/network/channel/channel_dispatcher.dart:218` | `_fixAndroidVpnPort` 条件改为 `!(isAndroid() \|\| isOhos())` |
| `lib/ui/mobile/mobile.dart:297` | ~~PiP 必须排除 ohos~~ **核实后无需改动**：:301 已有 `!Platforms.isAndroid() \|\| !pipEnabled` 保护，ohos 不会触碰 `com.proxy/pictureInPicture` channel。:335 的 `Vpn.isRunning()` 恢复逻辑 ohos 可用，保留。:465-493 FAB 逻辑无需改动 |
| `lib/ui/launch/launch.dart:287-293` | **VPN 模式保活补齐（实现期新发现）**：`_applyOhosKeepAlive()` 只在 `serverLaunch` 分支（:301）调用；VPN 模式下 FAB 走 `serverLaunch=false` 分支，首次启动不申请长时任务，仅靠 resumed 回调（:202）补。需在 `start()` 的 `serverLaunch=false` 分支补调 `_applyOhosKeepAlive()` |
| `lib/ui/mobile/widgets/remote_device.dart:266-268` | 远程设备 ipProxy 流程调 `Vpn.startVpn(remoteHost, ...)`——隧道栈天然支持，不改；验证阶段覆盖 |
| `lib/ui/mobile/menu/drawer.dart:399`、`menu.dart:60` | 无需改动，`supportAppFilter()` 放开后入口自动出现 |

### 白名单 UI 降级（`lib/ui/mobile/setting/app_filter.dart`）

鸿蒙无法枚举已安装应用，降级方案：

1. **新增 ohos 应用选择页**：ohos 时 "+" 按钮不再 push `InstalledAppsWidget`，改推新页面：顶部手动输入框（bundleName 格式校验 `^[a-zA-Z][\w.]*$`，至少两段）；下方「常见应用」预置清单（纯 Dart 常量，20-30 个常见 HarmonyOS NEXT 包名，放 `lib/ui/mobile/setting/ohos_preset_apps.dart`）。返回值协议与 `InstalledAppsWidget` 一致（`Navigator.pop(packageName)`），AppWhitelist/AppBlacklist 主体逻辑零改动；
2. **互斥提示**：鸿蒙 trusted/blocked 物理互斥（现有 vpn.dart:15-20 语义天然兼容）。ohos 且另一端名单非空时，页面顶部加 MaterialBanner：「鸿蒙系统限制：白名单与黑名单互斥，白名单非空时黑名单不生效」（黑名单页对称）。不新增配置字段，不改 Android 行为；
3. **数量上限**：添加第 257 个时 SnackBar 拒绝（鸿蒙上限 256）。

### 验收标准

- [ ] 鸿蒙 drawer 过滤器页出现白名单/黑名单入口，可手动输入/从预置清单添加
- [ ] 配置后 VPN 重启生效；互斥提示正确显示
- [ ] 五平台构建全绿；Android 白名单抓包回归无变化

## 7. 风险清单

| # | 风险 | 等级 | 缓解 |
|---|---|---|---|
| R1 | NDK 读 tun fd 不可行 | 高 | 第 0 期一票否决；备选：napi 桥接 ArrayBuffer 传 ArkTS（性能差但兜底） |
| R2 | AppGallery 对 VPN/抓包类审核严格 | 高 | 侧载/hdc 分发为主；保留路线 B 作为上架形态，VPN 能力可摘除 extensionAbilities 段回退 |
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
5. 端口修正回归：非标准端口明文 HTTP 请求，确认 `_fixAndroidVpnPort` 的 ohos 路径修正正确；
6. 回归：Android 真机白名单抓包一遍；macOS/Windows 启动验证桌面代理无碍；`flutter analyze` 0 error。

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
1. platform.dart 门禁 + channel_dispatcher/mobile.dart(PiP) + installed_apps 降级
2. ohos_preset_apps.dart + 应用选择页 + 互斥提示/上限
3. 五平台构建回归 + Android 真机回归
