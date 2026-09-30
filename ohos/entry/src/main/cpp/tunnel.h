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
 * 本机 VPN 隧道栈（路线 A）。
 *
 * 对照 Android `android/.../vpn/`（ProxyVpnThread + SocketNIODataService + ConnectionHandler +
 * ConnectionManager + ClientPacketWriter 等约 3351 行）的 C++ 精简重写：
 *
 * - Android 用「VPN 阻塞读线程 + NIO Selector 线程 + 客户端写队列线程」三线程 + ReentrantLock；
 *   本实现合并为**单线程 poll 循环**（tun fd + 全部上行 socket + 控制监听 fd 一并 poll），
 *   会话表与缓冲区无锁，语义等价。
 * - 上行 socket 由本栈自己创建（非阻塞），故可安全地循环读到 EAGAIN；tun fd 由
 *   vpnExtension.create() 提供且为阻塞模式，因此**每次 poll 唤醒只 read 一次**（poll 已保证可读）。
 * - 回包直接由 poll 线程 write 到 tun（无客户端写队列线程）。
 * - ICMP 直接丢弃（Android 用于 ping 连通性测试，MVP 不做）。
 * - proxyPassDomains（CIDR 绕过代理）鸿蒙 VpnConfig 无对应物，不做匹配。
 *
 * 数据流：白名单 App 的 IP 包 → tun(读) → 解析 TCP/UDP → 上行 socket 连
 * 127.0.0.1:<proxyPort>（透明代理：嗅探到 TLS ClientHello/HTTP 方法才走代理，否则直连原始目标）
 * → 代理/目标回包 → 构造响应包 → tun(写) → 白名单 App。
 */

#ifndef PROXYPIN_TUNNEL_H
#define PROXYPIN_TUNNEL_H

#include <atomic>
#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "packet.h"
#include "session.h"

namespace proxypin {

/** 控制通道端口（VPN 扩展进程监听，主进程 Flutter 插件查询用） */
constexpr uint16_t kControlPort = 9109;

/** 本地上行端口对应的原始目标（对照 Android NetworkInfo 的 remoteHost/remotePort） */
struct RemoteTarget {
    uint16_t port = 0;
    std::string host;
};

class Tunnel {
public:
    static Tunnel &instance();

    /**
     * 启动隧道。tun_fd 为 vpnExtension.create() 返回的原生 fd（本类不负责关闭它）。
     * 已在运行时会先停止旧实例。失败返回 false。
     */
    bool start(int tun_fd, const std::string &proxy_host, uint16_t proxy_port);

    /** 停止隧道：唤醒并等待 poll 线程退出，关闭全部上行 socket */
    void stop();

    bool is_running() const { return running_.load(); }

    // ---- 控制通道客户端（跨进程安全：扩展进程跑隧道，主进程查询状态/端口映射）----

    /** 隧道是否在运行（连不上控制通道即视为未运行） */
    static bool query_running();

    /** 查询本地上行端口对应的原始目标；命中返回 true */
    static bool query_remote(uint16_t local_port, RemoteTarget *out);

private:
    Tunnel() = default;

    void run();

    // tun → 上行
    void handle_packet(const uint8_t *data, size_t len);
    void handle_tcp(const uint8_t *data, size_t len, size_t ip_hdr_len, const Ipv4Header &ip);
    void handle_udp(const uint8_t *data, size_t len, size_t ip_hdr_len, const Ipv4Header &ip);

    // TCP 回包（对照 TCPPacketFactory 各方法）
    void reply_syn_ack(const Ipv4Header &ip, const TcpHeader &tcp);
    void resend_ack(Session *s);
    void send_rst(const Ipv4Header &ip, const TcpHeader &tcp, size_t data_len);
    void send_last_ack(const Ipv4Header &ip, const TcpHeader &tcp);
    void ack_fin_ack(const Ipv4Header &ip, const TcpHeader &tcp, Session *s);
    void send_fin_ack(const Ipv4Header &ip, const TcpHeader &tcp, Session *s);
    void send_ack(const Ipv4Header &ip, const TcpHeader &tcp, size_t accepted_len, Session *s);
    void send_ack_for_disorder(const Ipv4Header &ip, const TcpHeader &tcp, size_t data_len);
    void accept_ack(const TcpHeader &tcp, Session *s);
    std::vector<uint8_t> build_response_ack(const Ipv4Header &ip, const TcpHeader &tcp, uint32_t ack_to_client);

    // 上行连接
    void init_proxy_connect(const uint8_t *payload, size_t payload_len, Session *s);
    bool is_proxy_protocol(const uint8_t *payload, size_t len) const;
    void register_port_map(Session *s);

    // 上行 → tun
    void on_upstream_readable(Session *s);
    void on_upstream_writable(Session *s);
    void flush_to_remote(Session *s);
    void read_tcp(Session *s);
    void read_udp(Session *s);
    void push_data_to_client(Session *s);
    void send_fin_to_client(Session *s);

    // 会话表
    Session *find(uint8_t protocol, uint32_t dest_ip, uint16_t dest_port, uint32_t src_ip, uint16_t src_port);
    Session *create_tcp_session(const Ipv4Header &ip, const TcpHeader &tcp);
    Session *create_udp_session(const Ipv4Header &ip, const UdpHeader &udp);
    void close_session(Session *s) { s->is_aborting = true; }
    void drain_closed();
    void reap_idle();

    // 控制通道服务端
    bool start_control_server();
    void handle_control();
    void close_control_server();
    static bool control_query(uint8_t op, uint16_t arg, uint8_t *response);

    /** 写入 tun（阻塞 fd；写失败仅记日志并丢弃该包） */
    void write_tun(const std::vector<uint8_t> &packet);

    std::atomic<bool> running_{false};
    int tun_fd_ = -1;
    int control_fd_ = -1;
    int wake_fds_[2] = {-1, -1};  // 自管道：stop() 唤醒 poll

    uint32_t proxy_ip_ = 0;  // 网络字节序
    uint16_t proxy_port_ = 0;

    std::map<std::string, std::unique_ptr<Session>> sessions_;
    int64_t last_reap_ms_ = 0;
    std::thread thread_;
};

}  // namespace proxypin

#endif  // PROXYPIN_TUNNEL_H
