#!/usr/bin/env python3
"""ProxyPin 鸿蒙 Web 控制台本地启动器。

- 静态页面从本仓库 web/console/ 读取（改前端不用重新打包 App）。
- /api/console/* 反向代理到手机上的代理服务，token 自动补齐。
- 只监听 127.0.0.1，不对外暴露。

配置优先级：环境变量 > web/.console_config.json
  PROXYPIN_PHONE      手机代理地址，例如 192.168.3.96:9099（WiFi 模式）
  PROXYPIN_TOKEN      Web 控制台 token
  PROXYPIN_LOCAL_PORT 本机端口，默认 8899
  PROXYPIN_TRANSPORT  连接方式：wifi（默认）或 usb（hdc fport 转发，公司网络隔离 WiFi 时用）
  PROXYPIN_USB_LOCAL_PORT  USB 模式本机转发端口，默认 9099
  HDC                 hdc 可执行文件路径（不在 PATH 时指定）
"""

import json
import glob
import mimetypes
import os
import shutil
import subprocess
import sys
import threading
import traceback
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.abspath(__file__))
CONSOLE_DIR = os.path.join(ROOT, "console")
CONFIG_PATH = os.path.join(ROOT, ".console_config.json")

HOP_BY_HOP = {"connection", "keep-alive", "transfer-encoding", "content-length", "proxy-authenticate",
              "proxy-authorization", "te", "trailers", "upgrade"}


def load_config():
    config = {}
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, encoding="utf-8") as f:
                config = json.load(f)
        except (OSError, ValueError) as e:
            print("读取 %s 失败：%s" % (CONFIG_PATH, e))

    transport = (os.environ.get("PROXYPIN_TRANSPORT") or config.get("transport") or "wifi").lower()
    token = os.environ.get("PROXYPIN_TOKEN") or config.get("token") or ""
    port = os.environ.get("PROXYPIN_LOCAL_PORT") or config.get("localPort") or 8899
    usb_local_port = os.environ.get("PROXYPIN_USB_LOCAL_PORT") or config.get("usbLocalPort") or 9099
    device_port = config.get("devicePort") or 9099

    try:
        port = int(port)
    except (TypeError, ValueError):
        port = 8899
    try:
        usb_local_port = int(usb_local_port)
        device_port = int(device_port)
    except (TypeError, ValueError):
        usb_local_port, device_port = 9099, 9099

    if transport == "usb":
        # USB 模式：本机端口经 hdc fport 转发到手机代理端口，手机地址即本机回环
        phone = "http://127.0.0.1:%d" % usb_local_port
    else:
        phone = os.environ.get("PROXYPIN_PHONE") or config.get("phone") or ""
        if phone and "://" not in phone:
            phone = "http://" + phone
        phone = phone.rstrip("/")
    return transport, phone, token, port, usb_local_port, device_port


def find_hdc():
    """定位 hdc 可执行文件：环境变量 HDC > PATH > 常见安装路径。"""
    candidates = [os.environ.get("HDC"), shutil.which("hdc")]
    home = os.path.expanduser("~")
    candidates += [
        os.path.join(home, "command-line-tools", "sdk", "default", "openharmony", "toolchains", "hdc"),
        "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc",
        os.path.join(home, "Library", "OpenHarmony", "Sdk", "default", "openharmony", "toolchains", "hdc"),
    ]
    # OpenHarmony SDK 版本目录，例如 ~/Library/OpenHarmony/Sdk/20/toolchains/hdc
    candidates += sorted(glob.glob(os.path.join(home, "Library", "OpenHarmony", "Sdk", "*", "toolchains", "hdc")),
                         reverse=True)
    for path in candidates:
        if path and os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None


def ensure_usb_forward(local_port, device_port):
    """确保 hdc fport 转发存在；失败时打印可操作的诊断信息并返回 False。"""
    hdc = find_hdc()
    if not hdc:
        print("未找到 hdc。请安装 DevEco Studio / command-line-tools，或设置环境变量 HDC 指向 hdc 可执行文件。")
        return False

    try:
        targets = subprocess.run([hdc, "list", "targets"], capture_output=True, text=True, timeout=10)
    except Exception as e:
        print("执行 hdc 失败：%s" % e)
        return False
    devices = [line for line in targets.stdout.splitlines() if line.strip()]
    if not devices:
        print("hdc 未检测到设备。请确认：手机已开开发者模式与 USB 调试，USB 已连接，并在手机上允许本机调试。")
        return False

    wanted = "tcp:%d tcp:%d" % (local_port, device_port)
    existing = subprocess.run([hdc, "fport", "ls"], capture_output=True, text=True, timeout=10).stdout
    if wanted in existing:
        print("USB 转发已存在：%s" % wanted)
        return True

    result = subprocess.run([hdc, "fport", "tcp:%d" % local_port, "tcp:%d" % device_port],
                            capture_output=True, text=True, timeout=10)
    if result.returncode != 0:
        print("建立 USB 转发失败：%s%s（本机端口 %d 可能被占用，可用 PROXYPIN_USB_LOCAL_PORT 换端口）"
              % (result.stdout.strip(), result.stderr.strip(), local_port))
        return False
    print("USB 转发已建立：127.0.0.1:%d -> 手机:%d" % (local_port, device_port))
    return True


class ConsoleHandler(BaseHTTPRequestHandler):
    server_version = "ProxyPinConsole/1.0"
    phone = ""
    token = ""

    def log_message(self, fmt, *args):
        sys.stderr.write("[console] %s\n" % (fmt % args))

    # ---------- responses ----------
    def send_json(self, status, payload):
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def send_file(self, path):
        ctype = mimetypes.guess_type(path)[0] or "application/octet-stream"
        if path.endswith(".js"):
            ctype = "application/javascript"
        elif path.endswith(".css"):
            ctype = "text/css"
        with open(path, "rb") as f:
            data = f.read()
        self.send_response(200)
        self.send_header("Content-Type", ctype + ("; charset=utf-8" if ctype.startswith(("text/", "application/javascript")) else ""))
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    # ---------- routing ----------
    def do_GET(self):
        self.handle_request()

    def do_HEAD(self):
        self.handle_request()

    def do_POST(self):
        self.handle_request()

    def do_PUT(self):
        self.handle_request()

    def do_DELETE(self):
        self.handle_request()

    def handle_request(self):
        path = urllib.parse.urlsplit(self.path).path
        if path.startswith("/api/console"):
            self.proxy_api()
        elif path in ("/", "/console", "/console/"):
            self.send_file(os.path.join(CONSOLE_DIR, "index.html"))
        elif path.startswith("/console/"):
            self.serve_static(path[len("/console/"):])
        else:
            self.send_json(404, {"error": "not found"})

    def serve_static(self, relative):
        relative = os.path.normpath(relative)
        if relative.startswith("..") or os.path.isabs(relative):
            self.send_json(404, {"error": "not found"})
            return
        full = os.path.join(CONSOLE_DIR, relative)
        if not os.path.isfile(full):
            self.send_json(404, {"error": "not found"})
            return
        self.send_file(full)

    def proxy_api(self):
        parsed = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
        if self.token and not any(k == "token" for k, _ in query):
            query.append(("token", self.token))
        target = self.phone + parsed.path + ("?" + urllib.parse.urlencode(query) if query else "")

        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length > 0 else None

        headers = {}
        for name in ("Content-Type", "Cookie", "Accept"):
            value = self.headers.get(name)
            if value:
                headers[name] = value

        request = urllib.request.Request(target, data=body, headers=headers, method=self.command)
        try:
            with urllib.request.urlopen(request, timeout=90) as response:
                data = response.read()
                self.send_response(response.status)
                for key, value in response.headers.items():
                    if key.lower() in HOP_BY_HOP:
                        continue
                    self.send_header(key, value)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                if self.command != "HEAD":
                    self.wfile.write(data)
        except urllib.error.HTTPError as e:
            data = e.read()
            self.send_response(e.code)
            ctype = e.headers.get("Content-Type") or "application/json; charset=utf-8"
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)
        except Exception as e:  # 手机离线、超时、DNS 失败等
            self.send_json(502, {"error": "无法连接手机控制台：%s" % e})


def preflight(phone, token):
    url = phone + "/api/console/status?token=" + urllib.parse.quote(token)
    try:
        with urllib.request.urlopen(url, timeout=3) as response:
            print("手机控制台可用：%s" % response.read().decode("utf-8", "replace"))
    except Exception as e:
        print("警告：暂时无法连接手机控制台（%s）" % e)
        print("      请确认手机地址、代理服务运行状态与 Web 控制台开关；页面打开后可重试。")


def open_browser(url):
    """打开浏览器。优先用 macOS 原生 `open`（不经 AppleEvent，无需自动化权限），失败回退 webbrowser。"""
    def _open():
        try:
            if sys.platform == "darwin" and subprocess.run(["open", url], timeout=10).returncode == 0:
                return
        except Exception:
            pass
        try:
            webbrowser.open(url)
        except Exception:
            traceback.print_exc()
            print("请手动在浏览器打开：%s" % url, flush=True)

    threading.Timer(0.6, _open).start()


def main():
    try:
        transport, phone, token, port, usb_local_port, device_port = load_config()
        if not token:
            print("缺少 token。")
            print("请重新双击「启动控制台.command」，或设置环境变量 PROXYPIN_TOKEN。")
            return 1
        if not phone:
            print("缺少手机地址。")
            print("请重新双击「启动控制台.command」，或设置环境变量 PROXYPIN_PHONE。")
            return 1

        if transport == "usb":
            if not ensure_usb_forward(usb_local_port, device_port):
                print("USB 模式未就绪，控制台仍会启动，页面打开后可重试。")

        ConsoleHandler.phone = phone
        ConsoleHandler.token = token
        preflight(phone, token)

        url = "http://127.0.0.1:%d/console?token=%s" % (port, urllib.parse.quote(token))
        try:
            httpd = ThreadingHTTPServer(("127.0.0.1", port), ConsoleHandler)
        except OSError as e:
            print("无法监听 127.0.0.1:%d：%s（可能已有一个实例在运行）" % (port, e))
            return 1

        print("Web 控制台已启动：%s" % url, flush=True)
        print("手机：%s（%s）" % (phone, "USB 转发" if transport == "usb" else "WiFi 直连"), flush=True)
        print("按 Ctrl+C 停止。")
        if os.environ.get("PROXYPIN_NO_BROWSER") != "1":
            open_browser(url)
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\n已停止。")
        finally:
            httpd.server_close()
        return 0
    except Exception:
        # 双击启动时窗口可能一闪而过，打印堆栈并等待用户确认
        traceback.print_exc()
        try:
            input("\n启动失败，按回车退出…")
        except EOFError:
            pass
        return 1


if __name__ == "__main__":
    sys.exit(main())
