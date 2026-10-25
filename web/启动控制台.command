#!/bin/bash
# 双击启动 ProxyPin 鸿蒙 Web 控制台（仅在本机 127.0.0.1 上打开浏览器）。
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=".console_config.json"

prompt() {
  osascript -e "text returned of (display dialog \"$1\" default answer \"$2\" with title \"ProxyPin Web 控制台\")"
}

if [ ! -f "$CONFIG" ]; then
  PHONE=$(prompt "请输入手机代理地址（例如 192.168.3.96:9099）" "")
  if [ -z "$PHONE" ]; then
    echo "未填写手机地址，已取消。"
    exit 1
  fi
  TOKEN=$(prompt "请输入 Web 控制台 token（鸿蒙 App 设置页可查看）" "")
  if [ -z "$TOKEN" ]; then
    echo "未填写 token，已取消。"
    exit 1
  fi
  PORT=$(prompt "本机端口" "8899")
  PORT=${PORT:-8899}
  printf '{"phone": "%s", "token": "%s", "localPort": %s}\n' "$PHONE" "$TOKEN" "$PORT" > "$CONFIG"
  echo "已保存配置到 $CONFIG"
fi

exec python3 serve.py
