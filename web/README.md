# ProxyPin Web 控制台（前端 + 本地启动器）

浏览器里查看、重发、编辑和改写鸿蒙手机代理抓到的数据。同一套前端文件有三种使用方式：

1. **手机直接提供**：鸿蒙 App 在设置中开启「Web 控制台」后，访问 `http://手机IP:9099/console?token=...`。
2. **Mac 本地启动（推荐用于公司电脑/调试）**：双击 `启动控制台.command`，由本机 `serve.py` 提供页面并把 `/api/console/*` 转发到手机。
3. **USB 连接（公司网络隔离 WiFi 时）**：手机数据线连电脑，`serve.py` 自动执行 `hdc fport` 转发，浏览器访问本机回环地址。

## 双击启动

1. 鸿蒙 ProxyPin 代理服务运行中。
2. 在 App 设置中开启「Web 控制台」，记下 token。
3. 双击 `启动控制台.command`，按提示选择连接方式：
   - **WiFi**：手机与电脑在同一局域网，再填手机代理地址（如 `192.168.3.96:9099`）；
   - **USB**：数据线连接，启动器自动执行 `hdc fport tcp:9099 tcp:9099`，无需填手机地址。
4. 再填 Web 控制台 token 与本机端口（默认 `8899`）。
5. 浏览器自动打开 `http://127.0.0.1:8899/console?token=...`。

配置保存在 `web/.console_config.json`（已加入 `.gitignore`，含 token，不要提交）。
需要修改时删除该文件后重新双击即可。

## USB 模式说明

USB 模式适合公司 WiFi 有客户端隔离、手机与电脑无法直连的场景：

1. 手机：设置 → 关于本机连点版本号开开发者模式 → 开发人员选项打开 USB 调试；
2. 电脑：安装 DevEco Studio 或 command-line-tools（自带 `hdc`，绿色软件），首次连接时在手机上允许本机调试；
3. 双击启动脚本选 USB，启动器会自动：
   - 检测 `hdc list targets` 是否识别到手机；
   - 建立 `hdc fport tcp:9099 tcp:9099`（已存在则跳过；本机 9099 被占用时设 `PROXYPIN_USB_LOCAL_PORT` 换端口）；
4. 浏览器代理设 `127.0.0.1:9099`，控制台地址同上。

USB 模式下代理流量与控制台流量走同一条转发；`hdc` 找不到时可用环境变量 `HDC` 指定路径。

## 手动运行

WiFi：

```bash
PROXYPIN_PHONE=192.168.3.96:9099 PROXYPIN_TOKEN=xxxx python3 serve.py
```

USB：

```bash
PROXYPIN_TRANSPORT=usb PROXYPIN_TOKEN=xxxx python3 serve.py
```

或写入 `web/.console_config.json`：

```json
{"transport": "wifi", "phone": "192.168.3.96:9099", "token": "xxxx", "localPort": 8899}
{"transport": "usb", "token": "xxxx", "localPort": 8899, "devicePort": 9099}
```

## 安全边界

- `serve.py` 只监听 `127.0.0.1`，不对外暴露端口。
- 手机侧控制台默认关闭，开启后仍需 token，并复用代理的 IP 白名单（USB 转发来源为回环地址，始终放行）。
- 抓包内容可能含敏感数据，不要截图外传或把带 token 的地址发给无关人员。

## 目录

| 文件 | 说明 |
|---|---|
| `console/index.html`、`app.js`、`app.css` | 控制台前端，同时作为 App 内置资源（`pubspec.yaml` 的 `web/console/`） |
| `serve.py` | 本地静态服务 + `/api/console/*` 反向代理 + USB 模式 `hdc fport` 自动建立 |
| `启动控制台.command` | macOS 双击启动脚本 |
