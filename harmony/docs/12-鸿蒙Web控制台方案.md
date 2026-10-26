# 12 - 鸿蒙 Web 控制台方案（手机代理 + 手机提供浏览器控制台）

> 状态：已实现（M1–M3 后端 + 前端 + App 设置页），待真机验收
> 日期：2026-10-24
> 分支：feature/harmony_fix_remote_proxy
> 关联：[01-可行性分析](01-可行性分析.md)、[02-总体架构与产品边界](02-总体架构与产品边界.md)、[06-鸿蒙平台适配要点](06-鸿蒙平台适配要点.md)、[09-应用白名单与VPN路线实施](09-应用白名单与VPN路线实施.md)、[11-原生重写可行性评估](11-原生重写可行性评估.md)

## 1. 背景

当前鸿蒙端已经具备两种抓包能力：

- 路线 A：手机本机 VPN 抓包；
- 路线 B：手机运行代理服务，监听 `0.0.0.0:9099`，供局域网其他设备连入。

在现有“远程设备”用法中，手机连接桌面 ProxyPin，由桌面端代理并展示抓包数据。但在公司内网场景下存在新的约束：

1. 公司电脑不允许安装 ProxyPin；
2. 公司电脑只能做用户级设置，不能依赖管理员权限；
3. 希望在公司电脑浏览器里查看、重发、编辑和改写抓包数据；
4. 抓包数据不应离开公司局域网。

因此需要回答的问题不是“如何把 Mac 桌面端完整搬进浏览器”，而是：

> **如何让公司电脑只用浏览器，就能操作鸿蒙手机已经抓到的数据？**

## 2. 结论摘要

1. **不做 Mac 桌面端的 Flutter Web 全量移植。** 代理内核依赖 `dart:io`、`ServerSocket`、本地文件、证书和原生插件，浏览器无法承载；能 Web 化的只是展示与操作层。
2. **推荐“手机做代理 + 手机提供 Web 控制台”。** 鸿蒙 App 复用现有 `9099` 端口，新增 `/console` 静态页面和 `/api/console/*` JSON 接口。公司电脑浏览器直接访问 `http://手机IP:9099/console`，不需要安装任何软件，也不依赖 Mac。
3. **数据不出公司局域网。** 公司电脑的业务流量由手机代理，抓包数据保存在手机上，控制台页面也由手机提供，不把记录推送到公网或云端服务。
4. **第一版范围：浏览 + 重发/编辑 + 响应改写。** 包括请求列表、搜索、详情、复制 cURL、HAR 导出、原样重发、编辑后重发，以及响应重写规则管理。
5. **控制台默认关闭。** 在 App 内手动开启，使用随机 token 认证，并复用现有 IP 白名单限制来源。
6. **方案有明确网络前提。** 公司电脑必须能访问 `手机IP:9099`；只能抓显式配置代理的流量；HTTPS 解密仍需要目标端信任 CA；手机必须保持代理与控制台存活。

## 3. 方案对比

| 方案 | 做法 | 主要问题 | 结论 |
|---|---|---|---|
| Mac 桌面端整体 Web 化 | 把现有 Flutter 桌面应用构建为 Web 应用 | 代理内核需要 raw socket、本地文件、动态证书和原生插件，浏览器无法运行；UI 与内核耦合，改造成全量重写 | 不采用 |
| 独立远端 Web 服务 | 手机把抓包记录推送到云/家里 Mac，公司电脑访问远端页面 | 需要额外服务器和公网可达；公司流量记录离开内网；远端服务不能直接代理公司内网目标 | 不采用 |
| **手机内嵌 Web 控制台** | 手机同时提供代理和浏览器页面 | 依赖手机与公司电脑网络互通；手机需要保活 | **推荐** |

独立远端 Web 服务可以作为未来的扩展方向，但不应作为公司内网场景的第一版：它增加部署、认证、合规和数据外发问题，而手机本地控制台已经能满足“浏览器操作抓包数据”的核心目标。

## 4. 总体架构与数据流

### 4.1 两个入口，共用一个端口

手机在同一个 `9099` 端口上提供两类能力：

1. **代理入口（现有）**  
   公司电脑浏览器/应用把 HTTP、HTTPS 代理设置为 `手机IP:9099`，业务请求进入手机代理引擎，再由手机访问公司内网或外网目标。

2. **控制台入口（新增）**  
   公司电脑浏览器访问 `http://手机IP:9099/console`，手机返回 HTML/JS/CSS；页面再调用 `/api/console/*` 获取抓包数据或执行操作。

业务数据流：

```text
公司电脑浏览器
    │  HTTP/HTTPS 代理：手机IP:9099
    ▼
鸿蒙 ProxyPin 代理引擎
    │  转发
    ▼
公司内网 / 外网目标服务器
```

控制台数据流：

```text
鸿蒙 ProxyPin 代理引擎
    │  onRequest / onResponse
    ▼
手机上的控制台抓包数据存储
    │  /api/console/*
    ▼
公司电脑浏览器里的 /console 页面
```

### 4.2 为什么不会形成代理循环

现有代码已经把“请求本服务”和“代理转发”分开：

- `lib/network/handle/http_proxy_handle.dart:38-43`：当目标 Host 属于本机 IP，且端口等于当前监听端口时，进入 `ProxyHelper.localRequest`；
- `lib/network/util/proxy_helper.dart:43-152`：集中处理 `/config`、`/share/quick`、`/ping` 等本地请求。

因此：

- 浏览器直接访问 `http://手机IP:9099/console`，会命中本地分支；
- 浏览器已经把手机设为代理，再访问同一地址，也会命中本地分支；
- 控制台请求不会进入目标服务器转发，也不应出现在抓包列表中。

新增控制台路由应复用这个本地分支，而不是另起一套与代理竞争端口的服务。

### 4.3 与“远程设备”模式的区别

现有远程设备模式：

```text
手机 → 连接桌面远程设备 → 桌面代理并展示抓包
```

本方案：

```text
公司电脑 → 手机代理
公司电脑浏览器 → 手机 Web 控制台
```

手机不再需要连接 Mac。原模式是“手机把流量交给远端代理”，本方案是“手机自己代理，并自己提供展示与操作页面”。

## 5. 第一版功能范围

### 5.1 抓包浏览

- 请求列表：方法、URL、状态码、耗时、大小、时间、内容类型；
- 搜索/过滤：URL 关键字、域名、方法、状态码；
- 请求详情：General、请求头、请求体；
- 响应详情：状态、响应头、响应体；
- body 展示：JSON 格式化、纯文本、二进制 base64/hex；
- 大 body：截断或按需加载，并明确标记 `truncated`；
- 操作：复制 cURL、导出 HAR、清空控制台数据。

### 5.2 重发与编辑后发送

- 原样重发：对选中请求再次发送；
- 编辑后重发：在网页中修改 method、URL、headers、body 后发送；
- 发送结果应能在控制台列表中观察，便于复现和对比。

### 5.3 响应改写

- 查看、新增、编辑、启停、删除重写规则；
- 支持替换响应状态码、响应头、响应体；
- 支持响应头和响应 body 的增删改；
- 可从抓包列表选中请求，预填响应改写规则；
- 第一版只做文本 body，不做文件型 body 上传；
- Web 与手机 App 共用同一份重写配置。

### 5.4 明确后置

- 断点暂停/恢复；
- 脚本管理；
- 多用户与细粒度权限；
- 公网访问、端口映射、云端转发；
- 完整桌面端功能对齐。

断点需要“暂停事件 → 网页确认 → 恢复执行”的完整状态机，脚本还涉及 QuickJS 运行态管理，均不适合并入第一版。

## 6. 详细设计

### 6.1 路由与接口

建议在本地请求处理中增加独立 console handler，避免继续把逻辑堆进 `ProxyHelper.localRequest`。

| 方法与路径 | 用途 |
|---|---|
| `GET /console` | 控制台 HTML |
| `GET /console/app.js` | 页面脚本 |
| `GET /console/app.css` | 页面样式 |
| `GET /api/console/status` | 开关、版本、代理端口、当前 revision |
| `GET /api/console/requests?since=<revision>` | 增量请求列表 |
| `GET /api/console/requests/{id}` | 单条完整请求/响应详情 |
| `POST /api/console/requests/{id}/repeat` | 原样重发 |
| `POST /api/console/send` | 编辑后发送 |
| `GET /api/console/har` | 导出 HAR |
| `POST /api/console/clear` | 清空控制台数据 |
| `GET /api/console/rewrites` | 完整重写规则（含 items） |
| `POST /api/console/rewrites` | 新增规则 |
| `PUT /api/console/rewrites/{index}` | 更新规则及 items |
| `DELETE /api/console/rewrites/{index}` | 删除规则 |
| `POST /api/console/requests/{id}/rewrite` | 从选中请求预填响应改写规则 |

控制台关闭时，上述路径统一返回 404，不改变现有代理、`/ping`、`/ssl`、`/config` 和远程设备行为。

### 6.2 捕获数据存储

新增一个独立于 Flutter UI 的 `EventListener`，通过 `ProxyServer.addListener` 注册（`lib/network/bin/server.dart:163-166`）：

- `onRequest`：按 `HttpRequest.requestId` 建条目；
- `onResponse`：按同一 ID 回填响应；
- 保存请求/响应对象引用，不复制 body；
- 使用有上限的环形缓冲，限制条数和总字节；
- 列表接口只返回摘要，body 在详情接口按需读取；
- 维护单调递增 `revision`，供浏览器增量轮询；
- 清空操作同时递增 revision，避免客户端把旧数据重新合并回来。

不直接读取 `MobileApp.container`，避免网络层反向依赖 UI。控制台存储与手机列表可以共享同一批事件，但不要求二者有相同的清理节奏。

### 6.3 实时更新

第一版采用短轮询或长轮询，不引入 WebSocket/SSE：

```text
GET /api/console/requests?since=123
→ 返回 revision=124 之后的增量条目和最新 revision
```

原因：

- 现有服务端没有现成的 WebSocket 升级与帧写出路径；
- `writeAndClose` 会关闭连接，不适合直接当 SSE 使用；
- 轮询对公司浏览器、代理和网络环境最稳妥；
- 抓包列表并不要求毫秒级实时性，1–2 秒刷新足够。

### 6.4 序列化与大 body

- 文本 body：按字符集解码后以 UTF-8 返回；
- 二进制 body：返回 base64，并携带 `contentType`、`size`、`encoding`；
- 不直接复用 `HttpRequest.toJson` 的 body 序列化作为 Web 传输格式，因为其 `String.fromCharCodes` 对二进制不安全；
- HAR 导出复用 `lib/utils/har.dart`，保持二进制 base64 语义；
- 详情接口设置 body 展示上限，超出时返回截断内容和原始大小；
- 列表不携带 body，避免长时间抓包后接口膨胀。

### 6.5 重发与编辑后发送

原样重发复用现有路径：

- `HttpClients.proxyRequest`（`lib/network/http/http_client.dart:154`）；
- 与手机 UI 的重发逻辑保持一致，必要时通过本机 `127.0.0.1:9099` 代理发送，使重发请求继续经过现有拦截器并出现在抓包列表中。

编辑后发送接收结构化 JSON：

```json
{
  "method": "POST",
  "url": "http://example.com/api",
  "headers": {"Content-Type": "application/json"},
  "bodyText": "{}",
  "bodyBase64": null
}
```

`bodyText` 与 `bodyBase64` 二选一。服务端负责构造 `HttpRequest`，而不是让网页直接拼接原始 HTTP 报文。

### 6.6 响应改写

复用 `RequestRewriteManager`（`lib/network/components/manager/request_rewrite_manager.dart`），不在 Web 端重新实现 URL 匹配和改写逻辑：

- `toFullJson()`：输出规则及 items；
- `addRule()`：新增；
- `updateRule()`：更新；
- `removeIndex()`：删除；
- `flushRequestRewriteConfig()`：持久化。

规则模型复用 `lib/network/components/manager/rewrite_rule.dart`：

- `RuleType.responseReplace`：替换状态码、响应头、响应体；
- `RuleType.responseUpdate`：响应头和 body 的增删改；
- `RewriteItem.fromResponse()`：从抓包响应预填状态码、响应头、响应体。

从抓包记录创建规则时，预填 URL、method 和当前响应内容。保存后由现有 `RequestRewriteInterceptor` 自动应用到后续流量，无需重启代理。

注意：

- 规则只影响之后的请求，不回改历史记录；
- 抓包列表展示的是代理实际处理后的结果，测试时应对照“开规则/关规则”两次请求；
- 第一版仅支持文本 body，不开放文件路径和文件上传；
- 所有改写接口必须校验 token，并在页面明确提示规则会修改后续响应。

### 6.7 认证与访问控制

控制台不能依赖代理鉴权：本地请求分支在 `Proxy-Authorization` 校验之前执行，直接访问 `/console` 不会天然带代理认证头。因此需要独立认证：

1. 控制台默认关闭；
2. App 设置中手动开启；
3. 开启时生成随机 token；
4. App 展示完整 URL，例如 `http://192.168.x.x:9099/console?token=...`；
5. 首次访问校验 token 后，种植 `HttpOnly; SameSite=Strict` Cookie；
6. 后续静态资源和 API 使用同源 Cookie；
7. 所有写操作（重发、发送、清空、改写）必须校验认证；
8. 支持关闭控制台和重置 token；
9. 复用 `AccessControl` 的 IP 白名单，在 socket accept 时限制来源（`lib/network/channel/network.dart:89-93`）。

控制台只绑定现有局域网监听地址，不新增公网映射，不默认暴露到其他端口。

### 6.8 配置与 App 设置

配置层需要保存：

- 控制台开关；
- token（或改为安全存储/SharedPreferences，实施时统一决策）；
- 可选：控制台列表保留条数、body 展示上限（无明确需求前不增加过多配置）。

App 设置页提供：

- 「Web 控制台」开关；
- 当前访问地址；
- 复制链接、二维码；
- 重置 token；
- 与访问控制设置的跳转；
- “仅在公司内网使用，抓包内容敏感”的提示。

静态页面放在 `assets/web/`，通过 `rootBundle` 读取，并在 `pubspec.yaml` 注册。前端第一版不引入重型构建链，使用原生 HTML/JS/CSS 即可。

### 6.9 生命周期与保活

控制台与代理服务同生命周期：

- 代理服务停止时，控制台也不可用；
- 沿用现有鸿蒙保活逻辑，不另起后台任务；
- 公司使用时应保持 App 保活/亮屏；
- 如果灭屏后系统冻结网络栈，代理与控制台会同时失效，这属于使用前提，不是控制台单独能解决的问题。

## 7. 公司内网使用流程

1. 手机连接公司 Wi-Fi，确认公司电脑能访问 `手机IP:9099`。
2. 打开鸿蒙 ProxyPin，确认代理服务运行。
3. 在 App 设置中开启 Web 控制台，复制带 token 的访问地址。
4. 公司电脑浏览器设置 HTTP/HTTPS 代理为 `手机IP:9099`。
5. 需要解密 HTTPS 时，下载并信任 ProxyPin CA。
6. 浏览器新开控制台地址，查看列表和详情。
7. 选中请求进行重发、编辑后发送，或建立响应改写规则。
8. 再次访问目标接口，验证抓包和改写结果。

### 7.1 浏览器选择

只有用户级权限时优先 Firefox：

- 代理设置在 Firefox 内完成，不改系统代理；
- Firefox 使用自己的证书库，可在用户级导入 CA；
- 不需要在公司电脑安装 ProxyPin。

Chrome/Edge 可通过启动参数指定代理，但信任 CA 往往涉及系统证书库。无法导入 CA 时，只能抓 HTTP，或只能看到 HTTPS 的连接目标/隧道，不能解密正文。

### 7.2 连通性预检

在正式配置前，先确认：

- 公司电脑能 ping 通或建立到 `手机IP:9099` 的 TCP 连接；
- `http://手机IP:9099/console` 能打开；
- 公司 Wi-Fi 没有 AP 隔离/客户端隔离；
- 公司 VPN 不会绕过浏览器代理。

如果控制台地址本身都打不开，先解决网络互通，不要先排查抓包或证书。

## 8. 限制与风险

1. **只能抓显式代理流量。** 没有配置代理的公司应用不会自动经过手机。
2. **公司 VPN 可能绕过代理。** 需要按实际 VPN 客户端和分流策略验证。
3. **公司 Wi-Fi 可能有客户端隔离。** 同 Wi-Fi 不等于能互访。
4. **HTTPS 解密仍受 CA 与证书固定限制。** 证书固定的应用即使经过代理，也可能只能看到连接目标。
5. **手机必须保活。** 灭屏、系统回收或网络冻结会同时影响代理与控制台。
6. **控制台是敏感入口。** 抓包内容、重发能力和响应改写能力都不能无认证暴露给同网段其他人。
7. **合规前提。** 在公司内网抓取和修改流量必须获得授权，只用于被允许的调试范围。
8. **数据不出内网是架构选择，不是加密保证。** 控制台第一版仍是局域网 HTTP + token，不能当作公网安全服务使用。

## 9. 实施拆解（若启动）

按“每期验收通过即独立提交”的方式推进，不攒成一次性大批次：

| 阶段 | 交付物 | 验收标准 |
|---|---|---|
| M1 只读控制台 | 开关/token、捕获存储、静态页、增量列表、详情、搜索、HAR | Mac 浏览器通过局域网打开手机控制台；能看到真实抓包；控制台关闭后 404；普通代理与 `/ping` 不受影响 |
| M2 重发与编辑 | 原样重发、编辑后发送、复制 cURL、清空 | 网页重发能在列表产生新记录；编辑 method/URL/headers/body 后结果正确；非法输入有明确错误 |
| M3 响应改写 | 规则 CRUD、从记录预填、启停、持久化 | 新增响应规则后，后续请求的状态码/响应头/响应体按规则变化；关闭规则后恢复；App 与 Web 看到同一份配置 |

主要涉及位置：

- 本地路由：`lib/network/util/proxy_helper.dart` 或新增独立 console handler；
- 捕获存储：新增网络层 listener/store，并在 `lib/network/bin/server.dart` 注册；
- 重发：`lib/network/http/http_client.dart` 现有能力；
- 响应改写：`lib/network/components/manager/request_rewrite_manager.dart`、`rewrite_rule.dart`；
- 配置：`lib/network/bin/configuration.dart`；
- 设置 UI：`lib/ui/mobile/setting/`；
- 静态资源：`assets/web/`、`pubspec.yaml`；
- 测试：控制台路由、认证、增量列表、序列化、重发、改写规则。

## 10. 验证方案

### 10.1 单元与组件测试

- 控制台关闭时所有 console 路径返回 404；
- token 缺失/错误时返回 401；
- `since` 增量列表无重复、无遗漏；
- 清空后旧 revision 不会重新拉回已清数据；
- 文本、二进制 base64、大 body 截断序列化正确；
- 重发与编辑发送参数构造正确；
- 改写规则 CRUD、启停、持久化正确；
- 未认证写操作全部被拒绝。

### 10.2 代理回归

- 普通 HTTP/HTTPS 代理不受影响；
- `/ping`、`/ssl`、`/config` 行为不变；
- 现有远程设备连接不受影响；
- 访问控制与代理鉴权行为不回退；
- ohos/macOS/iOS 可构建，保持既有平台约束。

### 10.3 真机验证

- 手机开启控制台，Mac 浏览器访问 `http://手机IP:9099/console`；
- 通过 `curl -x http://手机IP:9099` 产生请求，网页能看到列表和详情；
- 原样重发、编辑后发送均能产生新记录；
- HAR 可下载且能重新导入；
- 新增响应改写规则后，再次请求能看到状态码/响应头/响应体变化；
- 关闭规则后恢复；
- 控制台关闭后，网页和 API 均不可访问，但代理仍正常。

### 10.4 公司网络验证顺序

1. 只验证公司电脑到 `手机IP:9099` 的连通性；
2. 验证控制台页面和认证；
3. 验证 HTTP 代理抓包；
4. 验证 Firefox 用户级代理 + CA + HTTPS；
5. 验证重发与响应改写；
6. 最后验证公司 VPN、目标应用证书固定等具体边界。

不要在网络互通未确认前，直接排查 HTTPS 或改写规则。

## 11. 已确认与实施前待确认

已确认：

- 采用手机内嵌 Web 控制台，不做 Mac 桌面端整体 Web 化；
- 数据不主动转发到公网/云端；
- 第一版包含浏览、重发/编辑、响应改写；
- 控制台默认关闭，需要认证。

实施前仍需按实际环境确认：

- 公司电脑与手机是否能互通；
- 公司电脑可用浏览器及其 CA 导入能力；
- 公司 VPN 是否绕过代理；
- 第一版 token 的保存位置与是否需要独立控制台密码；
- 列表保留条数和 body 展示上限的默认值。

## 12. 已实现文件（2026-10-24）

后端：

- `lib/network/console/console_store.dart`：`ConsoleCaptureStore`，条数 + 字节双上限环形缓冲，单调递增 `revision`，清空后 revision 继续递增；
- `lib/network/console/web_console.dart`：`/console` 静态页 + `/api/console/*` 全部接口（status、增量列表、详情、HAR、清空、重发、编辑后发送、改写规则 CRUD、从记录预填）；
- `lib/network/util/proxy_helper.dart`：`localRequest` 入口接入控制台路由，非控制台路径行为不变；
- `lib/network/bin/server.dart`：`ProxyServer` 创建并注册捕获存储；
- `lib/network/bin/configuration.dart`：`webConsoleEnabled` / `webConsoleToken` 持久化。

前端与本地启动：

- `web/console/index.html`、`app.js`、`app.css`：无构建链的纯前端，同时通过 `pubspec.yaml`（`web/console/`）打进 App；
- `web/serve.py`：只监听 `127.0.0.1` 的静态服务 + `/api/console/*` 反向代理（自动补 token）；
- `web/启动控制台.command`：macOS 双击启动，首次运行询问手机地址与 token；
- `web/README.md`：使用说明。

App 设置：

- `lib/ui/mobile/setting/web_console.dart`：开关、访问地址、token、复制、二维码、重置 token、访问控制入口；
- 设置页与鸿蒙首页引导卡均已加入口。

测试：`test/web_console_test.dart` 覆盖路由/认证/静态资源/增量列表/序列化截断/二进制 base64/清空/重发与编辑发送参数/改写预填（35 项）。真机验收按 §10.3 执行。

## 13. 规则编辑器与 App 对齐（2026-10-24）

Web 端改写规则编辑由裸 JSON textarea 改为与 App 编辑页一致的结构化表单：

- 规则级字段：名称、启用、类型（替换响应/修改响应）、方法（任意/GET/POST/...）、URL（`*` 通配）；
- `responseReplace`：状态码 / 响应头（键值行增删）/ 响应体 三个分区，各自带启用开关，对齐 App 的三个 Tab；文件型 body 在 Web 端只读保留，提示到 App 编辑；
- `responseUpdate`：改写项列表（修改Body/添加头部/修改头部/删除头部），每项含启用、匹配、替换、正则开关，对齐 App 的 UpdateList；
- 序列化产出与 `RequestRewriteRule.formJson` / `RewriteItem.fromJson` 完全一致，表单未管理的 `values` 字段（如 `bodyFile`）原样保留；
- 非响应类规则（请求替换/修改、重定向）及高级场景仍可切到 JSON 模式编辑；表单 ↔ JSON 切换时双向同步内容。

## 14. 请求列表 Tab（2026-10-24）

左栏按鸿蒙 App 拆成两个 Tab：

- **全部请求**：原有平铺列表，按到达顺序展示；
- **域名列表**：按 `host` 聚合，显示域名、请求数、最后请求时间，最近活跃的域名排顶部；点击域名下钻该域名的请求列表（顶部返回行），再点请求照常看详情；
- 顶部过滤框在两个 Tab 下均生效：域名 Tab 过滤域名，全部/下钻过滤请求；
- 清空、增量轮询、选中态在两种视图下保持一致；无后端改动（复用列表摘要里的 `host` 字段）。

## 15. USB 接入（hdc fport，2026-10-25）

公司 WiFi 客户端隔离、手机与电脑无法直连时，走 USB 端口转发，代理流量与控制台流量共用一条转发：

- 手机开开发者模式 + USB 调试；电脑执行 `hdc fport tcp:9099 tcp:9099` 后，浏览器代理设 `127.0.0.1:9099`，控制台访问 `http://127.0.0.1:9099/console?token=...`；
- 现有代码零改动即可用：本地分支显式匹配 `127.0.0.1`（`lib/network/handle/http_proxy_handle.dart:39`），访问控制对回环始终放行（`lib/network/components/access_control.dart:16`）；
- 附带收益：`127.0.0.1` 是安全上下文，`navigator.clipboard` 直接可用；
- 启动器支持：`serve.py` 新增 `transport=usb` 配置（`PROXYPIN_TRANSPORT=usb` / `.console_config.json` 的 `transport`），启动时自动定位 hdc（PATH → 常见安装路径 → `HDC` 环境变量）、检测 `hdc list targets`、幂等建立 `hdc fport`；本机转发端口冲突时用 `PROXYPIN_USB_LOCAL_PORT` 更换；`启动控制台.command` 首次运行可选 WiFi/USB 模式；
- App 设置页「Web 控制台」新增 USB 连接说明块（hdc 命令一键复制）；
- 限制：公司 Windows 电脑首次可能要装华为 USB 驱动（可能需管理员）；以 `hdc list targets` 能否识别设备为准。

## 16. 详情区 Request/Response 双 Tab + 请求编辑（2026-10-25）

右栏详情对齐鸿蒙 App 的 `NetworkTabController`，拆成 Request / Response 两个 Tab，且两边都可编辑：

- Request Tab：Path / 请求时间 / 请求大小、请求参数（URL query 拆表）、请求头、请求体；「编辑（请求重写）」按钮以该请求预填 `requestReplace` 规则；
- Response Tab：状态码 / 耗时 / 响应大小 / 响应时间、响应头、响应体；「编辑（响应重写）」按钮预填 `responseReplace` 规则；响应未到达时显示占位；
- 后端 `/api/console/requests/{id}/rewrite` 新增 `?type=requestReplace` 查询参数：走 `RewriteItem.fromRequest` 生成 `replaceRequestLine` / `replaceRequestHeader` / `replaceRequestBody` 预填项，且不要求响应已到达（默认无参仍返回 `responseReplace`，行为不变）；
- 规则编辑器表单新增 `requestReplace` 类型：请求行（方法下拉「不改/GET/...」+ Path + URL参数，留空序列化为 `null`，对应后端 `item.method ?? request.method` 与 `Uri.replace` 的空值语义）/ 请求头（键值行）/ 请求体（文本，文件型只读保留）三个分区，与响应侧结构一致；
- 注意：该接口变更在手机端 Dart 代码中，旧版本 App 会忽略 `?type=` 回退为响应替换预填；需重新构建安装 App 后才生效。前端经 `serve.py` 直连仓库 `web/console/`，无需重新打包。

## 17. Android 支持（adb forward，2026-10-25）

控制台后端与前端无平台判断（`WebConsole` 在共享网络层、设置入口无条件展示、`web/console/` 无条件打包），Android App 开箱可用；本次补齐 USB 侧差异：

- `serve.py` 新增 `transport=adb`：`find_adb()`（`ADB` 环境变量 → PATH → `~/Library/Android/sdk/platform-tools/adb` 等常见路径）、`ensure_adb_forward()`（`adb devices` 只认已授权设备、多设备取第一台并 `-s` 指定、`forward --list` 幂等）；hdc 侧同步重命名为 `ensure_hdc_forward()`，行为不变；
- 新增 `启动控制台-Android.command`：与鸿蒙启动器同流程，USB 模式写 `transport: "adb"`；配置文件独立为 `.console_config.android.json`（`serve.py` 新增 `PROXYPIN_CONFIG` 环境变量指定配置路径，相对路径基于 `web/` 解析），两套配置互不覆盖；`.gitignore` 改为 `web/.console_config*.json`；
- App 设置页 USB 说明块按平台区分：Android 显示 `adb forward`，鸿蒙显示 `hdc fport`（`Platforms.isAndroid()` 判断，tooltip 同步改为「复制转发命令」）；
- 注意：hdc 与 adb 的本机转发不能同时占用 `9099`，双机同连时用 `PROXYPIN_USB_LOCAL_PORT` 给其中一路换端口。
