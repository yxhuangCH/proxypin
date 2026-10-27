#!/bin/bash
# 双击启动 ProxyPin Android Web 控制台（仅在本机 127.0.0.1 上打开浏览器）。
set -euo pipefail
cd "$(dirname "$0")"

# 出错时停住窗口，避免 Terminal 一闪而过看不到错误
trap 'echo; read -n 1 -s -r -p "出错了，按任意键退出…" || true; echo' ERR

CONFIG=".console_config.android.json"

prompt() {
  osascript -e "text returned of (display dialog \"$1\" default answer \"$2\" with title \"ProxyPin Web 控制台（Android）\")"
}

choose() {
  osascript -e "button returned of (display dialog \"$1\" with title \"ProxyPin Web 控制台（Android）\" buttons {\"WiFi\", \"USB\"} default button \"$2\")"
}

if [ ! -f "$CONFIG" ]; then
  MODE=$(choose "Android 手机与电脑的连接方式？\n\nWiFi：同一局域网直连\nUSB：数据线 + adb 端口转发（公司网络隔离 WiFi 时用）" "USB")
  TOKEN=$(prompt "请输入 Web 控制台 token（Android App 设置页可查看）" "")
  if [ -z "$TOKEN" ]; then
    echo "未填写 token，已取消。"
    exit 1
  fi
  PORT=$(prompt "本机端口" "8899")
  PORT=${PORT:-8899}

  if [ "$MODE" = "USB" ]; then
    printf '{"transport": "adb", "token": "%s", "localPort": %s, "devicePort": 9099}\n' "$TOKEN" "$PORT" > "$CONFIG"
    echo "已保存配置到 $CONFIG（USB 模式，启动时会自动执行 adb forward）"
  else
    PHONE=$(prompt "请输入手机代理地址（例如 192.168.3.96:9099）" "")
    if [ -z "$PHONE" ]; then
      echo "未填写手机地址，已取消。"
      exit 1
    fi
    printf '{"transport": "wifi", "phone": "%s", "token": "%s", "localPort": %s}\n' "$PHONE" "$TOKEN" "$PORT" > "$CONFIG"
    echo "已保存配置到 $CONFIG"
  fi
fi

exec env PROXYPIN_CONFIG="$CONFIG" python3 serve.py
