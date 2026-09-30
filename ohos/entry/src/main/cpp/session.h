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
 * 隧道会话状态（对照 Android vpn/Connection.kt）。
 *
 * 与 Android 的差异：Android 用「VPN 读线程 + NIO 线程」两个线程访问会话，故 Connection
 * 处处 @Synchronized；本实现把两者合并为**单线程 poll 循环**，会话只由该线程读写，字段无需锁。
 * 对外可见的信息（port_map）另用互斥量保护。
 */

#ifndef PROXYPIN_SESSION_H
#define PROXYPIN_SESSION_H

#include <chrono>
#include <cstdint>
#include <string>
#include <vector>

#include "packet.h"

namespace proxypin {

struct Session {
    uint8_t protocol = kTcpProtocol;
    uint32_t source_ip = 0;       // 客户端（tun 侧）地址
    uint16_t source_port = 0;
    uint32_t destination_ip = 0;  // 原始目标地址
    uint16_t destination_port = 0;

    // 上行 socket：TCP 为 connect 后的 socket，UDP 为 connected datagram socket
    int upstream_fd = -1;
    bool connecting = false;       // 非阻塞 connect 进行中（等 POLLOUT）
    bool connected = false;
    bool is_init_connect = false;  // 是否已发起上行连接（延迟到首个带数据的包才连，见 init_proxy_connect）
    bool is_aborting = false;      // 待由循环关闭并移除
    bool is_closing = false;       // 已向客户端发过 FIN-ACK，在等客户端最后一个 ACK
    bool is_acked_to_fin = false;  // 客户端的 FIN 已被 ACK
    bool is_proxied = false;       // 上行连到本机代理（需登记 port_map）

    // 从远程读到、待发往客户端的数据（对照 Connection.receivingStream）
    std::vector<uint8_t> to_client;
    // 客户端发来、待写入远程的数据（对照 Connection.sendingStream）
    std::vector<uint8_t> to_remote;

    bool is_data_for_sending_ready = false;  // 客户端已发 PSH，可以把 to_remote 写出去
    bool has_received_last_segment = false;  // 远程本次读取不足一个缓冲区，响应包带 PSH

    // 从客户端收到的序列（对照 Connection.recSequence）
    uint32_t rec_sequence = 0;
    // 已发给客户端、等其 ACK 的序列（对照 Connection.sendUnAck）
    uint32_t send_un_ack = 0;
    // 下一个要发给客户端的序列（对照 Connection.sendNext）
    uint32_t send_next = 0;
    // TCP 选项里的 MSS。Android 的 TCPHeader.handleTcpOptions 从未被调用，实际恒为 0，
    // 使下行分片恒走 1024 兜底（见 push_data_to_client），此处保持同样行为。
    int max_segment_size = 0;

    // 最近一次客户端包的头，用于构造回包（对照 lastIpHeader/lastTcpHeader/lastUdpHeader）
    Ipv4Header last_ip_header;
    TcpHeader last_tcp_header;
    UdpHeader last_udp_header;
    bool has_last_ip_header = false;
    bool has_last_tcp_header = false;
    bool has_last_udp_header = false;

    // 上行 socket 的本地端口（代理连接用，供 port_map 登记/注销）
    uint16_t local_port = 0;

    // 最近一次活动时间（steady_clock 毫秒），用于回收泄漏会话
    int64_t last_activity_ms = 0;

    std::string key() const;
};

inline const char *protocol_name(uint8_t protocol) {
    return protocol == kUdpProtocol ? "UDP" : "TCP";
}

/** 会话键，对照 Connection.getConnectionKey："proto|srcIp:srcPort->destIp:destPort" */
inline std::string session_key(uint8_t protocol, uint32_t dest_ip, uint16_t dest_port, uint32_t source_ip,
                               uint16_t source_port) {
    return std::string(protocol_name(protocol)) + "|" + ip_to_string(source_ip) + ":" +
           std::to_string(source_port) + "->" + ip_to_string(dest_ip) + ":" + std::to_string(dest_port);
}

inline std::string Session::key() const {
    return session_key(protocol, destination_ip, destination_port, source_ip, source_port);
}

/** 单调时钟毫秒数 */
inline int64_t now_ms() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

}  // namespace proxypin

#endif  // PROXYPIN_SESSION_H
