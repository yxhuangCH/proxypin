# ProxyPin Web 控制台（前端 + 本地启动器）

浏览器里查看、重发、编辑和改写鸿蒙手机代理抓到的数据。同一套前端文件有两种使用方式：

1. **手机直接提供**：鸿蒙 App 在设置中开启「Web 控制台」后，访问 `http://手机IP:9099/console?token=...`。
2. **Mac 本地启动（推荐用于公司电脑/调试）**：双击 `启动控制台.command`，由本机 `serve.py` 提供页面并把 `/api/console/*` 转发到手机。

## 双击启动

1. 手机与 Mac 在同一局域网，鸿蒙 ProxyPin 代理服务运行中。
2. 在 App 设置中开启「Web 控制台」，记下 token。
3. 双击 `启动控制台.command`，按提示填写：
   - 手机代理地址，例如 `192.168.3.96:9099`
   - Web 控制台 token
   - 本机端口（默认 `8899`）
4. 浏览器自动打开 `http://127.0.0.1:8899/console?token=...`。

配置保存在 `web/.console_config.json`（已加入 `.gitignore`，含 token，不要提交）。
需要修改时删除该文件后重新双击即可。

## 手动运行

```bash
PROXYPIN_PHONE=192.168.3.96:9099 PROXYPIN_TOKEN=xxxx python3 serve.py
```

或写入 `web/.console_config.json`：

```json
{"phone": "192.168.3.96:9099", "token": "xxxx", "localPort": 8899}
```

## 安全边界

- `serve.py` 只监听 `127.0.0.1`，不对外暴露端口。
- 手机侧控制台默认关闭，开启后仍需 token，并复用代理的 IP 白名单。
- 抓包内容可能含敏感数据，不要截图外传或把带 token 的地址发给无关人员。

## 目录

| 文件 | 说明 |
|---|---|
| `console/index.html`、`app.js`、`app.css` | 控制台前端，同时作为 App 内置资源（`pubspec.yaml` 的 `web/console/`） |
| `serve.py` | 本地静态服务 + `/api/console/*` 反向代理 |
| `启动控制台.command` | macOS 双击启动脚本 |
