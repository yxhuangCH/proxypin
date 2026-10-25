#!/usr/bin/env python3
"""ProxyPin 鸿蒙 Web 控制台本地启动器。

- 静态页面从本仓库 web/console/ 读取（改前端不用重新打包 App）。
- /api/console/* 反向代理到手机上的代理服务，token 自动补齐。
- 只监听 127.0.0.1，不对外暴露。

配置优先级：环境变量 > web/.console_config.json
  PROXYPIN_PHONE      手机代理地址，例如 192.168.3.96:9099
  PROXYPIN_TOKEN      Web 控制台 token
  PROXYPIN_LOCAL_PORT 本机端口，默认 8899
"""

import json
import mimetypes
import os
import sys
import threading
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

    phone = os.environ.get("PROXYPIN_PHONE") or config.get("phone") or ""
    token = os.environ.get("PROXYPIN_TOKEN") or config.get("token") or ""
    port = os.environ.get("PROXYPIN_LOCAL_PORT") or config.get("localPort") or 8899

    if phone and "://" not in phone:
        phone = "http://" + phone
    try:
        port = int(port)
    except (TypeError, ValueError):
        port = 8899
    return phone.rstrip("/"), token, port


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


def main():
    phone, token, port = load_config()
    if not phone or not token:
        print("缺少手机地址或 token。")
        print("请重新双击「启动控制台.command」，或设置环境变量 PROXYPIN_PHONE / PROXYPIN_TOKEN。")
        return 1

    ConsoleHandler.phone = phone
    ConsoleHandler.token = token
    preflight(phone, token)

    url = "http://127.0.0.1:%d/console?token=%s" % (port, urllib.parse.quote(token))
    try:
        httpd = ThreadingHTTPServer(("127.0.0.1", port), ConsoleHandler)
    except OSError as e:
        print("无法监听 127.0.0.1:%d：%s（可能已有一个实例在运行）" % (port, e))
        return 1

    print("Web 控制台已启动：%s" % url)
    print("手机：%s" % phone)
    print("按 Ctrl+C 停止。")
    if os.environ.get("PROXYPIN_NO_BROWSER") != "1":
        threading.Timer(0.6, lambda: webbrowser.open(url)).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止。")
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
