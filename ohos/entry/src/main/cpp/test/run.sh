#!/usr/bin/env bash
# 隧道栈宿主机回归：不需要真机、不需要 DevEco，直接在本机跑 cpp/ 下的隧道代码。
#
#   ./run.sh          # 编译并运行全部场景
#
# 原理：用 AF_UNIX SOCK_DGRAM socketpair 冒充 tun fd（保留报文边界，语义与 tun 一致），
# 用本机 TCP/UDP 服务冒充「代理」与「目标」；hilog 由 test/hilog_stub.cpp 打桩。
# 详见 harmony/docs/09-应用白名单与VPN路线实施.md §5。
set -euo pipefail

cd "$(dirname "$0")"
src=$(cd .. && pwd)                       # ohos/entry/src/main/cpp
out=${TMPDIR:-/tmp}/tunnel_test

${CXX:-clang++} -std=c++17 -g -O0 -Wall \
    -I"$src" -I"$PWD" \
    tunnel_test.cpp hilog_stub.cpp \
    "$src/tunnel.cpp" "$src/packet.cpp" "$src/port_map.cpp" \
    -o "$out"

exec "$out"
