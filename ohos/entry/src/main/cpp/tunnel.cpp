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

#include "tunnel.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <hilog/log.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cstdlib>
#include <ctime>
#include <vector>

#include "port_map.h"

#define LOG_TAG "ProxyPinTunnel"
#define TUN_LOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, 0x0000, LOG_TAG, __VA_ARGS__)
#define TUN_LOGW(...) OH_LOG_Print(LOG_APP, LOG_WARN, 0x0000, LOG_TAG, __VA_ARGS__)

namespace proxypin {

namespace {

constexpr size_t kTunReadBufferSize = 64 * 1024;
constexpr size_t kUpstreamReadBufferSize = 65535;  // 对照 Constant.MAX_RECEIVE_BUFFER_SIZE
constexpr int kPollTimeoutMs = 1000;
constexpr int64_t kReapIntervalMs = 1000;
constexpr int64_t kUdpIdleTimeoutMs = 60 * 1000;
constexpr int64_t kTcpHalfOpenTimeoutMs = 120 * 1000;

// 控制通道报文：请求 magic(4) + op(1) + arg(2)；响应 status(1) + port(2) + hostLen(1) + host(≤16)
constexpr uint8_t kControlMagic[4] = {'P', 'P', 'T', '1'};
constexpr uint8_t kOpPing = 0x01;
constexpr uint8_t kOpRemotePort = 0x02;
constexpr size_t kControlRequestSize = 7;
constexpr size_t kControlHostCapacity = 15;
constexpr size_t kControlResponseSize = 4 + kControlHostCapacity;
constexpr int kControlServerTimeoutMs = 200;
constexpr int kControlClientTimeoutMs = 300;
constexpr int kControlQueryAttempts = 2;

bool set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) {
        return false;
    }
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0;
}

bool set_blocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) {
        return false;
    }
    return fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0;
}

void set_io_timeout(int fd, int milliseconds) {
    struct timeval tv{};
    tv.tv_sec = milliseconds / 1000;
    tv.tv_usec = (milliseconds % 1000) * 1000;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
}

/** 读满 len 字节：TCP 是流，单次 read 可能只返回一部分（控制通道小报文曾因此偶发解析失败） */
bool read_fully(int fd, uint8_t *buffer, size_t len) {
    size_t offset = 0;
    while (offset < len) {
        ssize_t n = read(fd, buffer + offset, len - offset);
        if (n > 0) {
            offset += static_cast<size_t>(n);
            continue;
        }
        if (n < 0 && errno == EINTR) {
            continue;
        }
        return false;
    }
    return true;
}

/** 写满 len 字节 */
bool write_fully(int fd, const uint8_t *buffer, size_t len) {
    size_t offset = 0;
    while (offset < len) {
        ssize_t n = write(fd, buffer + offset, len - offset);
        if (n > 0) {
            offset += static_cast<size_t>(n);
            continue;
        }
        if (n < 0 && errno == EINTR) {
            continue;
        }
        return false;
    }
    return true;
}

/** 随机初始序列号（对照 TCPPacketFactory.createSynAckPacketData 的 0..100000） */
uint32_t random_initial_sequence() {
    return static_cast<uint32_t>(rand() % 100000);
}

}  // namespace

Tunnel &Tunnel::instance() {
    static Tunnel instance;
    return instance;
}

bool Tunnel::start(int tun_fd, const std::string &proxy_host, uint16_t proxy_port) {
    if (tun_fd <= 0) {
        TUN_LOGW("invalid tun fd %{public}d", tun_fd);
        return false;
    }
    if (running_.load()) {
        TUN_LOGW("tunnel already running, restarting");
        stop();
    }

    struct in_addr addr{};
    if (inet_pton(AF_INET, proxy_host.c_str(), &addr) != 1) {
        TUN_LOGW("invalid proxy host %{public}s", proxy_host.c_str());
        return false;
    }

    tun_fd_ = tun_fd;
    proxy_ip_ = addr.s_addr;
    proxy_port_ = proxy_port;
    srand(static_cast<unsigned>(time(nullptr) ^ static_cast<long>(getpid())));

    if (pipe(wake_fds_) != 0) {
        TUN_LOGW("wake pipe failed errno=%{public}d", errno);
        wake_fds_[0] = wake_fds_[1] = -1;
        return false;
    }
    set_nonblocking(wake_fds_[0]);
    set_nonblocking(wake_fds_[1]);

    start_control_server();  // 失败不致命：只是跨进程查询（isRunning/端口映射）不可用

    PortMap::instance().clear();
    last_reap_ms_ = now_ms();
    running_.store(true);
    thread_ = std::thread([this]() { run(); });

    TUN_LOGI("tunnel started tun=%{public}d proxy=%{public}s:%{public}d ctrl=%{public}d", tun_fd_,
             proxy_host.c_str(), proxy_port, control_fd_);
    return true;
}

void Tunnel::stop() {
    if (!running_.exchange(false)) {
        return;
    }
    if (wake_fds_[1] >= 0) {
        ssize_t n = write(wake_fds_[1], "q", 1);  // 唤醒 poll
        (void)n;
    }
    if (thread_.joinable()) {
        thread_.join();
    }

    for (auto &entry : sessions_) {
        Session *s = entry.second.get();
        if (s->upstream_fd >= 0) {
            close(s->upstream_fd);
            s->upstream_fd = -1;
        }
    }
    sessions_.clear();
    PortMap::instance().clear();

    if (wake_fds_[0] >= 0) close(wake_fds_[0]);
    if (wake_fds_[1] >= 0) close(wake_fds_[1]);
    wake_fds_[0] = wake_fds_[1] = -1;
    close_control_server();
    tun_fd_ = -1;
    TUN_LOGI("tunnel stopped");
}

void Tunnel::run() {
    std::vector<uint8_t> tun_buffer(kTunReadBufferSize);
    std::vector<struct pollfd> pfds;
    std::vector<Session *> owners;

    while (running_.load()) {
        pfds.clear();
        owners.clear();

        pfds.push_back({wake_fds_[0], POLLIN, 0});
        owners.push_back(nullptr);
        pfds.push_back({control_fd_, POLLIN, 0});
        owners.push_back(nullptr);
        pfds.push_back({tun_fd_, POLLIN, 0});
        owners.push_back(nullptr);

        for (auto &entry : sessions_) {
            Session *s = entry.second.get();
            if (s->upstream_fd < 0 || s->is_aborting) {
                continue;
            }
            // 尚未 connect 的 TCP 会话（SYN 已建、首个数据报文未触发 init_proxy_connect）
            // 不能进 poll：未连接 socket 会被内核报告 POLLHUP/POLLIN，read 得到 ENOTCONN
            // 导致会话被误杀（真机现象：read errno=107 → 后续报文 unknown session）。
            // 它只等 tun 侧数据，无需监听任何上行事件。
            if (s->protocol == kTcpProtocol && !s->connecting && !s->connected) {
                continue;
            }
            short events = POLLIN;
            bool can_write = !s->to_remote.empty() && s->is_data_for_sending_ready &&
                             (s->protocol == kUdpProtocol || s->connected);
            if (s->connecting || can_write) {
                events = static_cast<short>(events | POLLOUT);
            }
            pfds.push_back({s->upstream_fd, events, 0});
            owners.push_back(s);
        }

        int ret = poll(pfds.data(), pfds.size(), kPollTimeoutMs);
        if (ret < 0) {
            if (errno == EINTR) {
                continue;
            }
            TUN_LOGW("poll failed errno=%{public}d", errno);
            break;
        }

        if (ret > 0) {
            for (size_t i = 0; i < pfds.size(); i++) {
                if (pfds[i].revents == 0) {
                    continue;
                }
                if (i == 0) {
                    uint8_t drain[16];
                    while (read(wake_fds_[0], drain, sizeof(drain)) > 0) {
                    }
                    continue;
                }
                if (i == 1) {
                    if (control_fd_ >= 0) {
                        handle_control();
                    }
                    continue;
                }
                if (i == 2) {
                    // 阻塞模式的 tun fd：poll 已保证可读，只读一次（读到 EAGAIN 会阻塞，
                    // 阻塞后上行 socket 的响应将无人处理 → 故不循环）
                    ssize_t n = read(tun_fd_, tun_buffer.data(), tun_buffer.size());
                    if (n > 0) {
                        handle_packet(tun_buffer.data(), static_cast<size_t>(n));
                    } else if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                        TUN_LOGW("tun read failed errno=%{public}d", errno);
                    }
                    continue;
                }

                Session *s = owners[i];
                if (s == nullptr || s->is_aborting) {
                    continue;
                }
                if ((pfds[i].revents & POLLOUT) != 0) {
                    on_upstream_writable(s);
                }
                if (!s->is_aborting && (pfds[i].revents & (POLLIN | POLLHUP)) != 0) {
                    on_upstream_readable(s);
                }
                if (!s->is_aborting && (pfds[i].revents & POLLIN) == 0 &&
                    (pfds[i].revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
                    TUN_LOGW("upstream error revents=%{public}d", pfds[i].revents);
                    close_session(s);
                }
            }
        }

        reap_idle();
        drain_closed();
    }

    TUN_LOGI("tunnel loop exited");
}

// ---------------------------------------------------------------- tun → 上行

void Tunnel::handle_packet(const uint8_t *data, size_t len) {
    Ipv4Header ip;
    if (!parse_ipv4(data, len, &ip)) {
        // 含 IPv6 报文（PoC 实测除 isIPv6Accepted=false 仍会进 tun）与畸形包，直接丢弃
        return;
    }
    if (ip.more_fragments || ip.fragment_offset != 0) {
        // 分片报文 MVP 不支持重组（Android 会把它误当完整报文解析，这里显式丢弃）。
        // 注意 DF(0x4000) 绝大多数报文都会置位，不能作为丢弃依据。
        return;
    }
    size_t ip_hdr_len = static_cast<size_t>(ip.header_length());
    if (ip_hdr_len + 4 > len) {
        return;
    }

    if (ip.protocol == kTcpProtocol) {
        handle_tcp(data, len, ip_hdr_len, ip);
    } else if (ip.protocol == kUdpProtocol) {
        handle_udp(data, len, ip_hdr_len, ip);
    }
    // ICMP(1) 等：丢弃，不回包（对齐 MVP 裁剪决策）
}

void Tunnel::handle_tcp(const uint8_t *data, size_t len, size_t ip_hdr_len, const Ipv4Header &ip) {
    TcpHeader tcp;
    if (!parse_tcp(data, len, ip_hdr_len, &tcp)) {
        return;
    }
    size_t tcp_hdr_len = static_cast<size_t>(tcp.header_length());
    if (tcp_hdr_len < kTcpHeaderSize || ip_hdr_len + tcp_hdr_len > len) {
        return;
    }
    const uint8_t *payload = data + ip_hdr_len + tcp_hdr_len;
    size_t payload_len = len - ip_hdr_len - tcp_hdr_len;

    uint32_t source_ip = ip.source_ip;
    uint16_t source_port = tcp.source_port;
    uint32_t dest_ip = ip.destination_ip;
    uint16_t dest_port = tcp.destination_port;

    if (tcp.is_syn()) {
        reply_syn_ack(ip, tcp);
        return;
    }

    if (!tcp.is_ack()) {
        // 不带 ACK：客户端 FIN / RST（对照 handleTCPPacket 的 else if 分支）
        Session *s = find(kTcpProtocol, dest_ip, dest_port, source_ip, source_port);
        if (s == nullptr) {
            if (tcp.is_fin()) {
                ack_fin_ack(ip, tcp, nullptr);
            }
        } else if (tcp.is_rst()) {
            close_session(s);
        } else {
            s->last_activity_ms = now_ms();
        }
        return;
    }

    Session *s = find(kTcpProtocol, dest_ip, dest_port, source_ip, source_port);
    if (s == nullptr) {
        TUN_LOGW("packet for unknown session %{public}s", session_key(kTcpProtocol, dest_ip, dest_port, source_ip,
                                                                      source_port).c_str());
        if (tcp.is_fin()) {
            send_last_ack(ip, tcp);
        } else if (!tcp.is_rst()) {
            send_rst(ip, tcp, payload_len);
        }
        return;
    }

    s->last_ip_header = ip;
    s->last_tcp_header = tcp;
    s->has_last_ip_header = true;
    s->has_last_tcp_header = true;
    s->last_activity_ms = now_ms();

    if (payload_len > 0) {
        init_proxy_connect(payload, payload_len, s);
        if (s->is_aborting) {
            return;
        }
        if (s->rec_sequence == 0 || tcp.sequence_number >= s->rec_sequence) {
            s->to_remote.insert(s->to_remote.end(), payload, payload + payload_len);
            send_ack(ip, tcp, payload_len, s);
        } else {
            send_ack_for_disorder(ip, tcp, payload_len);
        }
    } else {
        accept_ack(tcp, s);
        if (s->is_closing) {
            send_fin_ack(ip, tcp, s);
        } else if (s->is_acked_to_fin && !tcp.is_fin()) {
            close_session(s);
        }
    }

    if (s->is_aborting) {
        return;
    }
    if (tcp.is_psh()) {
        s->is_data_for_sending_ready = true;
        flush_to_remote(s);
    } else if (tcp.is_fin()) {
        ack_fin_ack(ip, tcp, s);
    } else if (tcp.is_rst()) {
        close_session(s);
    }
}

void Tunnel::handle_udp(const uint8_t *data, size_t len, size_t ip_hdr_len, const Ipv4Header &ip) {
    UdpHeader udp;
    if (!parse_udp(data, len, ip_hdr_len, &udp)) {
        return;
    }
    size_t payload_offset = ip_hdr_len + kUdpHeaderSize;
    if (payload_offset > len) {
        return;
    }
    const uint8_t *payload = data + payload_offset;
    size_t payload_len = len - payload_offset;

    Session *s = create_udp_session(ip, udp);
    if (s == nullptr) {
        return;
    }
    if (s->is_aborting) {
        return;
    }
    s->last_ip_header = ip;
    s->last_udp_header = udp;
    s->has_last_ip_header = true;
    s->has_last_udp_header = true;
    s->last_activity_ms = now_ms();

    if (payload_len > 0) {
        s->to_remote.insert(s->to_remote.end(), payload, payload + payload_len);
    }
    s->is_data_for_sending_ready = true;
    flush_to_remote(s);
}

// ---------------------------------------------------------------- TCP 回包

std::vector<uint8_t> Tunnel::build_response_ack(const Ipv4Header &ip, const TcpHeader &tcp,
                                                uint32_t ack_to_client) {
    Ipv4Header out_ip = ip;
    TcpHeader out_tcp = tcp;
    flip_ipv4_tcp(&out_ip, &out_tcp);
    uint32_t sequence = out_tcp.ack_number;  // 翻转不涉及 seq/ack
    out_tcp.ack_number = ack_to_client;
    out_tcp.sequence_number = sequence;
    out_ip.identification = next_packet_id();
    out_tcp.set_ack(true);
    out_tcp.set_syn(false);
    out_tcp.set_psh(false);
    out_tcp.set_fin(false);
    out_tcp.data_offset = 5;
    out_tcp.options.clear();
    return build_tcp_packet(out_ip, out_tcp, nullptr, 0);
}

void Tunnel::reply_syn_ack(const Ipv4Header &ip, const TcpHeader &tcp) {
    Session *s = create_tcp_session(ip, tcp);
    if (s == nullptr) {
        return;
    }
    if (s->has_last_ip_header) {
        // 已有会话又收到 SYN（重传或竞态）：重发上次 ACK 拒绝该 SYN
        resend_ack(s);
        return;
    }

    Ipv4Header out_ip = ip;
    TcpHeader out_tcp = tcp;
    out_ip.identification = 0;
    flip_ipv4_tcp(&out_ip, &out_tcp);
    out_tcp.ack_number = tcp.sequence_number + 1;
    out_tcp.sequence_number = random_initial_sequence();
    out_tcp.set_ack(true);
    out_tcp.set_syn(true);
    out_tcp.data_offset = 5;
    out_tcp.options.clear();

    s->max_segment_size = 0;
    s->send_un_ack = out_tcp.sequence_number;
    s->send_next = out_tcp.sequence_number + 1;
    s->rec_sequence = out_tcp.ack_number;  // 客户端初始序列 +1
    s->last_ip_header = ip;
    s->last_tcp_header = tcp;
    s->has_last_ip_header = true;
    s->has_last_tcp_header = true;

    write_tun(build_tcp_packet(out_ip, out_tcp, nullptr, 0));
}

void Tunnel::resend_ack(Session *s) {
    if (!s->has_last_ip_header || !s->has_last_tcp_header) {
        return;
    }
    write_tun(build_response_ack(s->last_ip_header, s->last_tcp_header, s->rec_sequence));
}

void Tunnel::send_rst(const Ipv4Header &ip, const TcpHeader &tcp, size_t data_len) {
    Ipv4Header out_ip = ip;
    TcpHeader out_tcp = tcp;

    uint32_t ack_number = 0;
    uint32_t sequence = 0;
    if (out_tcp.ack_number > 0) {
        sequence = out_tcp.ack_number;
    } else {
        ack_number = out_tcp.sequence_number + static_cast<uint32_t>(data_len);
    }
    out_tcp.ack_number = ack_number;
    out_tcp.sequence_number = sequence;

    flip_ipv4_tcp(&out_ip, &out_tcp);
    out_ip.identification = 0;
    out_tcp.flags = 0;
    out_tcp.is_ns = false;
    out_tcp.set_rst(true);
    out_tcp.data_offset = 5;
    out_tcp.options.clear();
    out_tcp.window_size = 0;

    write_tun(build_tcp_packet(out_ip, out_tcp, nullptr, 0));
}

void Tunnel::send_last_ack(const Ipv4Header &ip, const TcpHeader &tcp) {
    write_tun(build_response_ack(ip, tcp, tcp.sequence_number + 1));
}

void Tunnel::ack_fin_ack(const Ipv4Header &ip, const TcpHeader &tcp, Session *s) {
    Ipv4Header out_ip = ip;
    TcpHeader out_tcp = tcp;
    flip_ipv4_tcp(&out_ip, &out_tcp);
    out_tcp.ack_number = tcp.sequence_number + 1;
    out_tcp.sequence_number = tcp.ack_number;
    out_ip.identification = next_packet_id();
    out_tcp.set_ack(true);
    out_tcp.set_syn(false);
    out_tcp.set_psh(false);
    out_tcp.set_fin(true);
    out_tcp.data_offset = 5;
    out_tcp.options.clear();

    write_tun(build_tcp_packet(out_ip, out_tcp, nullptr, 0));
    if (s != nullptr) {
        close_session(s);
    }
}

void Tunnel::send_fin_ack(const Ipv4Header &ip, const TcpHeader &tcp, Session *s) {
    Ipv4Header out_ip = ip;
    TcpHeader out_tcp = tcp;
    flip_ipv4_tcp(&out_ip, &out_tcp);
    uint32_t sequence = tcp.ack_number;
    out_tcp.ack_number = tcp.sequence_number;
    out_tcp.sequence_number = sequence;
    out_ip.identification = next_packet_id();
    out_tcp.set_ack(false);
    out_tcp.set_syn(false);
    out_tcp.set_psh(false);
    out_tcp.set_fin(true);
    out_tcp.data_offset = 5;
    out_tcp.options.clear();

    write_tun(build_tcp_packet(out_ip, out_tcp, nullptr, 0));
    s->send_next = sequence + 1;
    s->is_closing = false;
}

void Tunnel::send_ack(const Ipv4Header &ip, const TcpHeader &tcp, size_t accepted_len, Session *s) {
    uint32_t ack_number = s->rec_sequence + static_cast<uint32_t>(accepted_len);
    s->rec_sequence = ack_number;
    write_tun(build_response_ack(ip, tcp, ack_number));
}

void Tunnel::send_ack_for_disorder(const Ipv4Header &ip, const TcpHeader &tcp, size_t data_len) {
    uint32_t ack_number = tcp.sequence_number + static_cast<uint32_t>(data_len);
    write_tun(build_response_ack(ip, tcp, ack_number));
}

void Tunnel::accept_ack(const TcpHeader &tcp, Session *s) {
    if (tcp.ack_number > s->send_un_ack || tcp.ack_number == s->send_next) {
        s->send_un_ack = tcp.ack_number;
        s->rec_sequence = tcp.sequence_number;
    }
}

// ---------------------------------------------------------------- 上行连接

bool Tunnel::is_proxy_protocol(const uint8_t *payload, size_t len) const {
    return is_tls_client_hello(payload, len) || looks_like_http(payload, len);
}

void Tunnel::init_proxy_connect(const uint8_t *payload, size_t payload_len, Session *s) {
    if (s->is_init_connect) {
        return;
    }
    s->is_init_connect = true;
    if (s->upstream_fd < 0 || s->connecting || s->connected) {
        return;
    }

    bool to_proxy = is_proxy_protocol(payload, payload_len);
    struct sockaddr_in addr{};
    addr.sin_family = AF_INET;
    if (to_proxy) {
        addr.sin_addr.s_addr = proxy_ip_;
        addr.sin_port = htons(proxy_port_);
        s->is_proxied = true;
    } else {
        // destination_ip 是 read_be32 的大端解释值（127.0.0.1 → 0x7F000001），
        // 而 sin_addr.s_addr 需要「网络序值」，故在此 htonl 转换
        addr.sin_addr.s_addr = htonl(s->destination_ip);
        addr.sin_port = htons(s->destination_port);
    }

    TUN_LOGI("connect %{public}s to %{public}s:%{public}d", s->key().c_str(), to_proxy ? "proxy" : "target",
             ntohs(addr.sin_port));

    int ret = connect(s->upstream_fd, reinterpret_cast<struct sockaddr *>(&addr), sizeof(addr));
    if (ret == 0) {
        s->connected = true;
        register_port_map(s);
    } else if (errno == EINPROGRESS) {
        s->connecting = true;
    } else {
        TUN_LOGW("connect %{public}s failed errno=%{public}d", s->key().c_str(), errno);
        if (s->has_last_ip_header && s->has_last_tcp_header) {
            send_rst(s->last_ip_header, s->last_tcp_header, 0);
        }
        close_session(s);
    }
}

void Tunnel::register_port_map(Session *s) {
    if (!s->is_proxied || s->upstream_fd < 0) {
        return;
    }
    struct sockaddr_in local{};
    socklen_t local_len = sizeof(local);
    if (getsockname(s->upstream_fd, reinterpret_cast<struct sockaddr *>(&local), &local_len) != 0) {
        return;
    }
    s->local_port = ntohs(local.sin_port);
    PortMap::instance().set(s->local_port, s->destination_ip, s->destination_port);
    TUN_LOGI("proxied %{public}s local_port=%{public}d", s->key().c_str(), s->local_port);
}

// ---------------------------------------------------------------- 上行 → tun

void Tunnel::on_upstream_readable(Session *s) {
    if (s->protocol == kUdpProtocol) {
        read_udp(s);
    } else {
        read_tcp(s);
    }
}

void Tunnel::on_upstream_writable(Session *s) {
    if (s->connecting) {
        int error = 0;
        socklen_t error_len = sizeof(error);
        if (getsockopt(s->upstream_fd, SOL_SOCKET, SO_ERROR, &error, &error_len) != 0 || error != 0) {
            TUN_LOGW("connect %{public}s failed errno=%{public}d", s->key().c_str(), error);
            if (s->has_last_ip_header && s->has_last_tcp_header) {
                send_rst(s->last_ip_header, s->last_tcp_header, 0);
            }
            close_session(s);
            return;
        }
        s->connecting = false;
        s->connected = true;
        register_port_map(s);
    }
    flush_to_remote(s);
}

void Tunnel::flush_to_remote(Session *s) {
    if (s->upstream_fd < 0) {
        return;
    }
    if (s->to_remote.empty()) {
        return;
    }
    if (s->connecting || (!s->connected && s->protocol == kTcpProtocol)) {
        return;  // 等 connect 完成后再写（对照 SocketNIODataService.processPendingWrite 的 connected 前提）
    }

    size_t written = 0;
    size_t total = s->to_remote.size();
    while (written < total) {
        ssize_t n = write(s->upstream_fd, s->to_remote.data() + written, total - written);
        if (n > 0) {
            written += static_cast<size_t>(n);
            continue;
        }
        if (n < 0 && errno == EINTR) {
            continue;
        }
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            break;  // socket 缓冲区满，剩余部分等 POLLOUT 续传
        }
        // 写失败：TCP 给客户端发 RST 后断开（对照 SocketChannelWriter.writeTCP）
        TUN_LOGW("write %{public}s failed errno=%{public}d", s->key().c_str(), errno);
        if (s->protocol == kTcpProtocol && s->has_last_ip_header && s->has_last_tcp_header) {
            send_rst(s->last_ip_header, s->last_tcp_header, 0);
        }
        close_session(s);
        return;
    }

    if (written > 0) {
        s->to_remote.erase(s->to_remote.begin(), s->to_remote.begin() + static_cast<long>(written));
    }
    if (s->to_remote.empty()) {
        s->is_data_for_sending_ready = false;
    }
}

void Tunnel::read_tcp(Session *s) {
    std::vector<uint8_t> buffer(kUpstreamReadBufferSize);
    while (true) {
        ssize_t n = read(s->upstream_fd, buffer.data(), buffer.size());
        if (n > 0) {
            s->has_received_last_segment = static_cast<size_t>(n) < buffer.size();
            s->to_client.insert(s->to_client.end(), buffer.begin(), buffer.begin() + n);
            while (!s->to_client.empty()) {
                push_data_to_client(s);
            }
            continue;
        }
        if (n == 0) {
            TUN_LOGI("remote closed, send FIN to %{public}s", s->key().c_str());
            send_fin_to_client(s);
            close_session(s);
            return;
        }
        if (errno == EINTR) {
            continue;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            return;
        }
        TUN_LOGW("read %{public}s failed errno=%{public}d", s->key().c_str(), errno);
        close_session(s);
        return;
    }
}

void Tunnel::read_udp(Session *s) {
    std::vector<uint8_t> buffer(kUpstreamReadBufferSize);
    while (true) {
        ssize_t n = read(s->upstream_fd, buffer.data(), buffer.size());
        if (n > 0) {
            if (!s->has_last_ip_header || !s->has_last_udp_header) {
                continue;
            }
            Ipv4Header out_ip = s->last_ip_header;
            UdpHeader out_udp = s->last_udp_header;
            write_tun(build_udp_packet(out_ip, out_udp, buffer.data(), static_cast<size_t>(n)));
            continue;
        }
        if (errno == EINTR) {
            continue;
        }
        if (n == 0 || errno == EAGAIN || errno == EWOULDBLOCK) {
            return;
        }
        TUN_LOGW("read udp %{public}s failed errno=%{public}d", s->key().c_str(), errno);
        close_session(s);
        return;
    }
}

void Tunnel::push_data_to_client(Session *s) {
    if (s->to_client.empty()) {
        return;
    }
    if (!s->has_last_ip_header || !s->has_last_tcp_header) {
        s->to_client.clear();
        return;
    }

    int max = s->max_segment_size - 60;
    if (max < 1) {
        max = 1024;
    }
    size_t take = s->to_client.size();
    if (take > static_cast<size_t>(max)) {
        take = static_cast<size_t>(max);
    }
    if (take == 0) {
        return;
    }

    Ipv4Header out_ip = s->last_ip_header;
    TcpHeader out_tcp = s->last_tcp_header;
    flip_ipv4_tcp(&out_ip, &out_tcp);
    uint32_t sequence = s->send_next;
    s->send_next = static_cast<uint32_t>(s->send_next + take);
    out_tcp.ack_number = s->rec_sequence;
    out_tcp.sequence_number = sequence;
    out_ip.identification = next_packet_id();
    out_tcp.set_ack(true);
    out_tcp.set_syn(false);
    out_tcp.set_psh(s->has_received_last_segment);
    out_tcp.set_fin(false);
    out_tcp.data_offset = 5;
    out_tcp.options.clear();

    write_tun(build_tcp_packet(out_ip, out_tcp, s->to_client.data(), take));
    s->to_client.erase(s->to_client.begin(), s->to_client.begin() + static_cast<long>(take));
}

void Tunnel::send_fin_to_client(Session *s) {
    if (!s->has_last_ip_header || !s->has_last_tcp_header) {
        return;
    }
    Ipv4Header out_ip = s->last_ip_header;
    TcpHeader out_tcp = s->last_tcp_header;
    flip_ipv4_tcp(&out_ip, &out_tcp);
    out_tcp.ack_number = s->rec_sequence;
    out_tcp.sequence_number = s->send_next;
    out_ip.identification = next_packet_id();
    out_tcp.flags = 0;
    out_tcp.is_ns = false;
    out_tcp.set_ack(true);
    out_tcp.set_fin(true);
    out_tcp.data_offset = 5;
    out_tcp.options.clear();
    out_tcp.window_size = 0;

    write_tun(build_tcp_packet(out_ip, out_tcp, nullptr, 0));
}

// ---------------------------------------------------------------- 会话表

Session *Tunnel::find(uint8_t protocol, uint32_t dest_ip, uint16_t dest_port, uint32_t src_ip,
                      uint16_t src_port) {
    auto it = sessions_.find(session_key(protocol, dest_ip, dest_port, src_ip, src_port));
    if (it == sessions_.end()) {
        return nullptr;
    }
    return it->second.get();
}

Session *Tunnel::create_tcp_session(const Ipv4Header &ip, const TcpHeader &tcp) {
    std::string key = session_key(kTcpProtocol, ip.destination_ip, tcp.destination_port, ip.source_ip,
                                 tcp.source_port);
    auto it = sessions_.find(key);
    if (it != sessions_.end()) {
        return it->second.get();
    }

    auto session = std::make_unique<Session>();
    session->protocol = kTcpProtocol;
    session->source_ip = ip.source_ip;
    session->source_port = tcp.source_port;
    session->destination_ip = ip.destination_ip;
    session->destination_port = tcp.destination_port;
    session->last_activity_ms = now_ms();

    session->upstream_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (session->upstream_fd < 0) {
        TUN_LOGW("socket failed errno=%{public}d", errno);
        return nullptr;
    }
    int on = 1;
    setsockopt(session->upstream_fd, SOL_SOCKET, SO_KEEPALIVE, &on, sizeof(on));
    setsockopt(session->upstream_fd, IPPROTO_TCP, TCP_NODELAY, &on, sizeof(on));
    int recv_buffer = kUpstreamReadBufferSize;
    setsockopt(session->upstream_fd, SOL_SOCKET, SO_RCVBUF, &recv_buffer, sizeof(recv_buffer));
    set_nonblocking(session->upstream_fd);

    Session *raw = session.get();
    sessions_[key] = std::move(session);
    return raw;
}

Session *Tunnel::create_udp_session(const Ipv4Header &ip, const UdpHeader &udp) {
    std::string key =
        session_key(kUdpProtocol, ip.destination_ip, udp.destination_port, ip.source_ip, udp.source_port);
    auto it = sessions_.find(key);
    if (it != sessions_.end()) {
        return it->second.get();
    }

    auto session = std::make_unique<Session>();
    session->protocol = kUdpProtocol;
    session->source_ip = ip.source_ip;
    session->source_port = udp.source_port;
    session->destination_ip = ip.destination_ip;
    session->destination_port = udp.destination_port;
    session->last_activity_ms = now_ms();

    session->upstream_fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (session->upstream_fd < 0) {
        TUN_LOGW("udp socket failed errno=%{public}d", errno);
        return nullptr;
    }
    set_nonblocking(session->upstream_fd);

    struct sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(ip.destination_ip);  // 大端解释值 → 网络序值
    addr.sin_port = htons(udp.destination_port);
    if (connect(session->upstream_fd, reinterpret_cast<struct sockaddr *>(&addr), sizeof(addr)) != 0) {
        TUN_LOGW("udp connect %{public}s failed errno=%{public}d", key.c_str(), errno);
        close(session->upstream_fd);
        return nullptr;
    }
    session->connected = true;
    session->is_init_connect = true;

    Session *raw = session.get();
    sessions_[key] = std::move(session);
    return raw;
}

void Tunnel::drain_closed() {
    auto it = sessions_.begin();
    while (it != sessions_.end()) {
        Session *s = it->second.get();
        if (!s->is_aborting) {
            ++it;
            continue;
        }
        if (s->upstream_fd >= 0) {
            close(s->upstream_fd);
            s->upstream_fd = -1;
        }
        if (s->local_port != 0) {
            PortMap::instance().erase(s->local_port);
        }
        it = sessions_.erase(it);
    }
}

void Tunnel::reap_idle() {
    int64_t current = now_ms();
    if (current - last_reap_ms_ < kReapIntervalMs) {
        return;
    }
    last_reap_ms_ = current;

    for (auto &entry : sessions_) {
        Session *s = entry.second.get();
        if (s->is_aborting) {
            continue;
        }
        int64_t idle = current - s->last_activity_ms;
        if (s->protocol == kUdpProtocol && idle > kUdpIdleTimeoutMs) {
            // UDP 会话用完即弃（Android 不回收，长时间运行会泄漏 fd）
            close_session(s);
        } else if (s->protocol == kTcpProtocol && !s->is_init_connect && idle > kTcpHalfOpenTimeoutMs) {
            // 只回过 SYN-ACK、客户端始终没发数据的半开会话
            close_session(s);
        }
    }
}

// ---------------------------------------------------------------- tun 写

void Tunnel::write_tun(const std::vector<uint8_t> &packet) {
    if (tun_fd_ < 0 || packet.empty()) {
        return;
    }
    size_t written = 0;
    while (written < packet.size()) {
        ssize_t n = write(tun_fd_, packet.data() + written, packet.size() - written);
        if (n > 0) {
            written += static_cast<size_t>(n);
            continue;
        }
        if (n < 0 && errno == EINTR) {
            continue;
        }
        // 阻塞 fd 上只在出错时走到这里（如 VPN 已销毁）：丢弃该包
        TUN_LOGW("tun write failed errno=%{public}d len=%{public}d", errno,
                 static_cast<int>(packet.size()));
        return;
    }
}

// ---------------------------------------------------------------- 控制通道

bool Tunnel::start_control_server() {
    control_fd_ = socket(AF_INET, SOCK_STREAM, 0);
    if (control_fd_ < 0) {
        TUN_LOGW("control socket failed errno=%{public}d", errno);
        return false;
    }
    int on = 1;
    setsockopt(control_fd_, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));

    struct sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(kControlPort);
    if (bind(control_fd_, reinterpret_cast<struct sockaddr *>(&addr), sizeof(addr)) != 0 ||
        listen(control_fd_, 4) != 0) {
        TUN_LOGW("control listen :%{public}d failed errno=%{public}d", kControlPort, errno);
        close(control_fd_);
        control_fd_ = -1;
        return false;
    }
    set_nonblocking(control_fd_);
    return true;
}

void Tunnel::close_control_server() {
    if (control_fd_ >= 0) {
        close(control_fd_);
        control_fd_ = -1;
    }
}

void Tunnel::handle_control() {
    struct sockaddr_in peer{};
    socklen_t peer_len = sizeof(peer);
    int fd = accept(control_fd_, reinterpret_cast<struct sockaddr *>(&peer), &peer_len);
    if (fd < 0) {
        return;
    }
    // macOS/BSD 上 accept 会继承监听 socket 的 O_NONBLOCK（Linux 不会），
    // 这里显式恢复阻塞，再配合 SO_RCVTIMEO 做「等一小会儿拿不到请求就放弃」
    set_blocking(fd);
    set_io_timeout(fd, kControlServerTimeoutMs);

    uint8_t request[kControlRequestSize] = {0};
    if (read_fully(fd, request, sizeof(request)) && memcmp(request, kControlMagic, 4) == 0) {
        uint8_t op = request[4];
        uint16_t arg = static_cast<uint16_t>((request[5] << 8) | request[6]);
        uint8_t response[kControlResponseSize] = {0};
        response[0] = 1;  // 默认：未找到
        if (op == kOpPing) {
            response[0] = 0;
        } else if (op == kOpRemotePort) {
            RemoteAddress remote{};
            if (PortMap::instance().get(arg, &remote)) {
                response[0] = 0;
                response[1] = static_cast<uint8_t>(remote.port >> 8);
                response[2] = static_cast<uint8_t>(remote.port & 0xFF);
                std::string host = ip_to_string(remote.host_ip);
                if (host.size() > kControlHostCapacity) {
                    host.resize(kControlHostCapacity);
                }
                response[3] = static_cast<uint8_t>(host.size());
                memcpy(response + 4, host.data(), host.size());
            }
        }
        write_fully(fd, response, sizeof(response));
    }
    close(fd);
}

bool Tunnel::control_query(uint8_t op, uint16_t arg, uint8_t *response) {
    // 尽力而为的旁路通道（端口修正 / isRunning）：偶发失败重试一次即可，
    // 不阻塞隧道主循环，也不让调用方感知瞬时抖动
    for (int attempt = 0; attempt < kControlQueryAttempts; attempt++) {
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) {
            return false;
        }
        set_io_timeout(fd, kControlClientTimeoutMs);

        struct sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        addr.sin_port = htons(kControlPort);
        if (connect(fd, reinterpret_cast<struct sockaddr *>(&addr), sizeof(addr)) != 0) {
            close(fd);
            return false;  // 隧道未运行
        }

        uint8_t request[kControlRequestSize] = {kControlMagic[0], kControlMagic[1], kControlMagic[2],
                                               kControlMagic[3], op, static_cast<uint8_t>(arg >> 8),
                                               static_cast<uint8_t>(arg & 0xFF)};
        bool ok = false;
        if (write_fully(fd, request, sizeof(request))) {
            uint8_t buffer[kControlResponseSize] = {0};
            if (read_fully(fd, buffer, sizeof(buffer)) && buffer[0] == 0) {
                ok = true;
                if (response != nullptr) {
                    memcpy(response, buffer, sizeof(buffer));
                }
            }
        }
        close(fd);
        if (ok) {
            return true;
        }
    }
    return false;
}

bool Tunnel::query_running() {
    return control_query(kOpPing, 0, nullptr);
}

bool Tunnel::query_remote(uint16_t local_port, RemoteTarget *out) {
    if (out == nullptr) {
        return false;
    }
    uint8_t response[kControlResponseSize] = {0};
    if (!control_query(kOpRemotePort, local_port, response)) {
        return false;
    }
    out->port = static_cast<uint16_t>((response[1] << 8) | response[2]);
    size_t host_len = response[3];
    if (host_len > kControlHostCapacity) {
        host_len = kControlHostCapacity;
    }
    out->host.assign(reinterpret_cast<const char *>(response + 4), host_len);
    return true;
}

}  // namespace proxypin
