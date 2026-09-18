# 08 - VPN 抓包路线专项评估（基于官方文档的补充）

> 依据：华为官方文档《连接VPN - Network Kit》（developer.huawei.com/consumer/cn/doc/harmonyos-guides/net-vpnextension）
> 结论先行：**技术上完整可行，权限从"不可能"降级为"高门槛可申请"。建议作为与路线 B 并行的专项预研，不进入一期主线。**

## 1. 官方能力概述

HarmonyOS NEXT 通过 `@kit.NetworkKit` 的 `vpnExtension` 模块提供完整 VPN 能力：

- **VpnExtensionAbility**：Stage 模型 ExtensionAbility，`module.json5` 中声明 `"type": "vpn.extension"`；
- **启动**：`startVpnExtensionAbility(want)`，系统弹出用户授权框（与 Android VpnService 一致的体验）；
- **建隧道**：`vpnExtension.createVpnConnection(context)` 得到 `VpnConnection`，调用 `create(VpnConfig)` 建立 tun 设备并返回 **tun fd**；
- **VpnConfig**：配置 tun 地址、路由、DNS、MTU、按应用过滤（trustedApplications/blockedApplications）；
- **protect(socketFd)**：保护socket绕过 VPN（与 Android `VpnService.protect` 对应，抓包栈必需）；
- **destroy()**：销毁隧道。

这套 API 与 Android VpnService 的能力模型几乎一一对应，意味着 **Android 侧 Kotlin 抓包栈的设计可以直接映射到 ArkTS 实现**。

## 2. 权限现状（相对此前评估的重要更新）

| 项 | 内容 |
|---|---|
| 权限 | `ohos.permission.MANAGE_VPN` |
| 等级 | `system_basic`，`system_grant` |
| ACL 开放 | **API 12 起为 true** —— 三方应用可通过受限权限申请通道获取（HarmonyOS 6 / API 20 满足） |
| 申请方式 | AGC 提交受限权限申请（说明使用场景），华为审批后加入 allowlist，发布 Profile 携带权限 |
| 实际门槛 | 实践案例（奇安信 VPN 等）显示通常需**企业开发者资质**或与华为对接；个人开发者基本不可行；抓包/调试类场景的过审口径暂无公开先例 |

**修正此前结论**：路线 A 从"正规渠道基本不可行"修正为"**技术可行，权限可申请但门槛高、周期不可控**"。

## 3. 与现有架构的映射关系

Android 侧抓包栈的数据通路：

```
App 流量 -> VpnService tun fd -> Kotlin 解析 IP/TCP/UDP 报文
        -> 会话重建 -> 转发到本机 127.0.0.1:9099 (ProxyServer Dart 内核)
```

鸿蒙侧映射（Dart 内核零改动，与路线 B 共用）：

```
App 流量 -> VpnExtensionAbility tun fd -> ArkTS/C++ 解析 IP/TCP/UDP 报文
        -> 会话重建 -> 转发到本机 127.0.0.1:9099 (ProxyServer Dart 内核)
```

需重写的部分（对照 `android/app/src/main/kotlin/com/network/proxy/vpn/`）：

| Android 侧 | 鸿蒙侧 | 规模 |
|---|---|---|
| ProxyVpnThread（tun 读写循环） | ArkTS 或 C++(NDK) 读 tun fd | 中 |
| IP4Header/TCPHeader/UDPHeader/Packet 报文解析 | 可逐文件翻译为 ArkTS | 大（约 10 文件） |
| Connection/ConnectionManager/ConnectionHandler 会话管理 | 同上 | 大（约 5 文件） |
| ProtectSocket/protect 逻辑 | `VpnConnection.protect(fd)` | 小 |
| ProcessInfoManager（按应用过滤） | VpnConfig 的 trusted/blockedApplications 或系统接口 | 中 |

**副带收益**：VpnExtensionAbility 拥有合法的后台常驻能力 —— 若此路线走通，**路线 B 的头号风险 R1（后台保活）同时被解决**。

## 4. 限制与约束

1. 同一时刻系统仅允许一个活跃 VPN 连接，与其他 VPN 应用互斥；
2. 应用只能启动自己声明的 VPN Extension；
3. 启动需用户每次/首次授权弹窗；
4. CA 证书仍无法程序化安装，需引导用户手动安装；目标 App 对用户 CA 的信任策略限制与 Android 7+ 类似问题依旧存在；
5. 上架审核对"抓包工具"类场景的接受度无公开先例，存在驳回风险（功能敏感类目）。

## 5. 建议的推进方式（预研专项，不占主线资源）

| 步骤 | 内容 | 产出 |
|---|---|---|
| S1 | **立即发起 ACL 受限权限申请**（周期不可控，越早越好） | 申请结论：可行/不可行 |
| S2 | 用调试证书 + DevEco ACL 调试白名单搭建最小 PoC：VpnExtensionAbility 建 tun、读 fd、转发本机回显服务 | 验证 API 链路可用 |
| S3 | 将 Kotlin 报文解析层翻译为 ArkTS/C++，对接本机 ProxyServer | 真机抓到鸿蒙本机 App 的 HTTP 包 |
| S4 | 评估上架口径（"网络调试工具"场景陈述） | 上架可行性结论 |

## 6. 决策建议

- **一期主线不变**（路线 B，本地代理服务模式）；
- S1（ACL 申请）建议与一期**并行启动**，因为它不影响代码且周期最长；
- 若 S1 获批：路线 A 提升为二期/三期主线，产品形态升级为"支持本机抓包 + 局域网抓包"双模式；
- 若 S1 被拒：路线 B 即为最终形态，关闭本专项。
