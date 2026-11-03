# Web 控制台常见问题（FAQ）

按「启动 → 连接 → 使用」的顺序排查。多数问题先看启动窗口里的提示，再对照本文。

## 启动阶段

### 双击「启动控制台.command」报 `no such file or directory`，路径开头的 `/` 丢了

**现象**：终端里显示 `zsh: no such file or directory: Users/yxhuang/...`（路径少了开头的 `/`），命令尾部带着 `; exit;`。

**原因**：`.command` 文件的默认打开方式被 iTerm2 接管。iTerm2 以文本命令方式执行脚本文件，把 `file:///Users/...` 去掉 scheme 时连首斜杠一起吃掉了。脚本本身没有被执行到。

**解决**：把默认打开方式改回 macOS 自带「终端」：

1. Finder 选中任一 `.command` 文件 → `⌘I` 显示简介；
2. 展开「打开方式」→ 选择 **终端（Terminal.app）**；
3. 点 **「全部更改…」**（所有 `.command` 文件一起恢复）。

### 启动时报「无法监听 127.0.0.1:8899：Address already in use」

**原因 A（最常见）**：之前启动的 `serve.py` 实例还在跑（终端窗口被直接关掉等原因留下了进程）。新版启动器会自动识别并提示「已有控制台实例在运行」，直接打开页面退出，无需处理。

旧版本或识别失败时手动清理：

```bash
lsof -nP -iTCP:8899 -sTCP:LISTEN   # 找到 PID
kill <PID>
```

**原因 B**：端口被其他程序占用。换个本机端口：

```bash
PROXYPIN_LOCAL_PORT=8900 python3 serve.py
```

或在配置文件中改 `localPort`。

### 启动时报「未找到 hdc / adb」

安装对应工具，或用环境变量指定路径：

```bash
HDC=/path/to/hdc python3 serve.py
ADB=/path/to/adb python3 serve.py
```

鸿蒙：DevEco Studio 或 command-line-tools 自带 `hdc`；Android：`brew install --cask android-platform-tools`。

### USB 模式报「未检测到设备 / 未检测到已授权设备」

1. 手机已开开发者模式与 USB 调试；
2. 数据线已连接（不是仅充电线）；
3. **首次连接时手机上弹出的「允许本机调试」要点允许**（Android 还有 RSA 指纹弹窗）；
4. 用 `hdc list targets` / `adb devices` 确认识别到设备后再启动。

### USB 转发建立失败，提示本机 9099 被占用

```bash
PROXYPIN_USB_LOCAL_PORT=19099 python3 serve.py
```

已有转发可用 `hdc fport ls` / `adb forward --list` 查看，`hdc fport rm ...` / `adb forward --remove ...` 清理。

## 连接与认证

### 页面提示「认证失败」（API 返回 401）

**原因**：本地保存的 token 与手机当前 token 不一致。手机端 token 存在 App 数据里，**重装/更新 App、清除应用数据后会重新生成**，本地 `.console_config.json` 里还是旧的。

**解决**：

1. 在 App 设置页查看当前 Web 控制台 token；
2. 更新 `web/.console_config.json`（Android 为 `.console_config.android.json`）里的 `token`，或删掉该文件重新双击启动脚本按提示填写；
3. 如果还跑着旧实例，先杀掉再重启（见上「Address already in use」）。

**验证 token 是否有效**（USB 模式）：

```bash
curl "http://127.0.0.1:9099/api/console/status?token=你的token"
# 返回 JSON = 有效；401 = token 已失效
```

**注意**：浏览器 localStorage 也会缓存旧 token。经启动器打开带新 token 的地址会自动覆盖；仍失败时清除该站点（`127.0.0.1:8899`）的站点数据再试。

### 启动时警告「暂时无法连接手机控制台」

**WiFi 模式**：

- 手机与电脑在同一局域网，手机代理地址（`IP:端口`）填对；
- 公司网络常有客户端隔离，手机电脑互相不通 → 改用 USB 模式。

**USB 模式**：

- 转发是否建立（启动日志里应有「USB 转发已存在/已建立」）；
- 手机 App 代理服务在运行、设置里「Web 控制台」开关已打开。

页面打开后 App 侧恢复可用时会自动恢复，无需重启。

### 浏览器打开是空白或 404

确认访问的是 `http://127.0.0.1:8899/console?token=...`（带 `/console` 路径），根路径 `/` 也可以。直接访问手机时地址是 `http://手机IP:9099/console?token=...`。

## 使用阶段

### 选中列表中的请求后，列表跳动、选中项「不见了」

旧版本前端每轮轮询（1.5s）整列重建 DOM，滚动位置被重置；服务端淘汰旧记录还会被误判为「清空」导致选中项被清掉。**已修复**：列表改为增量更新、清空判定改为服务端显式标记。遇到此问题请更新到最新代码，浏览器强制刷新（`⌘⇧R`）确保加载新 `app.js`。

### 列表一直不刷新 / 状态栏显示「离线」

- 手机 App 代理服务是否在运行、抓包列表有没有新数据；
- 「Web 控制台」开关是否打开；
- 浏览器开发者工具 → Network 看 `/api/console/requests` 请求的状态码（401 见上文认证失败；502 是手机连不上）。

### 「编辑后发送」提示二进制 body 不能编辑

二进制请求体无法在文本框编辑，请用「原样重发」。这是预期行为。

### 改写规则保存了但没生效

- 规则只影响保存之后的新请求，不回改历史记录；
- 确认规则的 URL 匹配模式确实命中目标请求；
- 规则与手机 App 共用同一份配置，可在 App 里确认规则已同步。

## 其他

### 想彻底重置本地配置

删除配置文件后重新双击启动脚本即可：

```bash
rm web/.console_config.json           # 鸿蒙
rm web/.console_config.android.json   # Android
```

配置文件含 token，已加入 `.gitignore`，**不要提交、不要外发**。

### token 疑似泄露

带 token 的控制台地址等于抓包数据的读取权限。泄露后在 App 设置页关闭再重新开启「Web 控制台」（或重装/清除数据）使 token 重新生成，然后按上文更新本地配置。

### 公司电脑无法双击运行脚本（安全策略限制）

用「手动运行」方式，见 `README.md` 的手动运行章节：

```bash
cd web
PROXYPIN_TRANSPORT=usb PROXYPIN_TOKEN=xxxx python3 serve.py
```
