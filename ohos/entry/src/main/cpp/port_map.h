/*
 * Copyright (c) 2026 ProxyPin
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/**
 * 本地上行端口 → 原始目标地址的映射（对照 Android vpn/util/ProcessInfoManager.kt 的
 * localPortCache，但不需要 /proc 解析：隧道栈在建立会话时天然知道原始目标）。
 *
 * 用途：本机 App 的请求经 tun 转发到 127.0.0.1:9099 的代理后，代理侧只看到「来自某个
 * 本地端口的连接」，需要反查它原本要访问的 host:port（Dart 侧 channel_dispatcher 的
 * _fixAndroidVpnPort）。
 *
 * 只在**代理连接**上登记（直连目标的连接不加，与 Android 一致）。
 * 隧道线程写、ArkTS/Flutter 线程读，故用互斥量保护。
 */

#ifndef PROXYPIN_PORT_MAP_H
#define PROXYPIN_PORT_MAP_H

#include <cstdint>
#include <map>
#include <mutex>
#include <string>

namespace proxypin {

struct RemoteAddress {
    uint32_t host_ip = 0;  // 网络字节序
    uint16_t port = 0;
};

class PortMap {
public:
    static PortMap &instance();

    void set(uint16_t local_port, uint32_t host_ip, uint16_t port);
    void erase(uint16_t local_port);
    void clear();

    /** 命中返回 true 并填充 out；否则返回 false */
    bool get(uint16_t local_port, RemoteAddress *out) const;

private:
    PortMap() = default;

    mutable std::mutex mutex_;
    std::map<uint16_t, RemoteAddress> map_;
};

}  // namespace proxypin

#endif  // PROXYPIN_PORT_MAP_H
