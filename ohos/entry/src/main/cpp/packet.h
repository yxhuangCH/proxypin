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
 * IPv4/TCP/UDP 报文解析与构造（对照 Android transport/protocol 与 util/PacketUtil.kt）。
 * 第 1 期隧道栈，见 harmony/docs/09 §5。
 */

#ifndef PROXYPIN_PACKET_H
#define PROXYPIN_PACKET_H

#include <cstdint>
#include <cstddef>
#include <string>
#include <vector>

namespace proxypin {

constexpr int kIp4HeaderSize = 20;
constexpr int kTcpHeaderSize = 20;
constexpr int kUdpHeaderSize = 8;
constexpr int kTcpProtocol = 6;
constexpr int kUdpProtocol = 17;
constexpr int kIcmpProtocol = 1;

/** 解析后的 IPv4 头（字段语义对照 IP4Header.kt） */
struct Ipv4Header {
    uint8_t version = 4;
    uint8_t ihl = 5;              // 单位 4 字节
    uint8_t tos = 0;
    uint16_t total_length = 0;
    uint16_t identification = 0;
    // 注意：Android IP4Header 把这两个字段命名为 mayFragment(0x4000)/lastFragment(0x2000)，
    // 实际语义是 DF(不分片) 与 MF(还有分片)，此处按真实语义命名。
    bool dont_fragment = false;    // flags 位 0x4000（DF）
    bool more_fragments = false;   // flags 位 0x2000（MF）
    uint16_t fragment_offset = 0;
    uint8_t ttl = 0;
    uint8_t protocol = 0;
    uint16_t checksum = 0;
    // 地址保存为 read_be32 的**大端解释值**（127.0.0.1 → 0x7F000001，与 ip_to_string 一致）。
    // 赋给 sockaddr_in.sin_addr.s_addr 前必须先 htonl()。
    uint32_t source_ip = 0;
    uint32_t destination_ip = 0;

    int header_length() const { return ihl * 4; }

    /** 序列化为 20 字节头（选项不参与，构造包时 dataOffset 恒为 5） */
    void write_to(uint8_t *out) const;
};

/** 解析后的 TCP 头（对照 TCPHeader.kt） */
struct TcpHeader {
    uint16_t source_port = 0;
    uint16_t destination_port = 0;
    uint32_t sequence_number = 0;
    uint32_t ack_number = 0;
    uint8_t data_offset = 0;      // 单位 4 字节
    bool is_ns = false;
    uint8_t flags = 0;
    uint16_t window_size = 0;
    uint16_t checksum = 0;
    uint16_t urgent_pointer = 0;
    std::vector<uint8_t> options;

    bool is_syn() const { return (flags & 0x02) != 0; }
    bool is_fin() const { return (flags & 0x01) != 0; }
    bool is_rst() const { return (flags & 0x04) != 0; }
    bool is_psh() const { return (flags & 0x08) != 0; }
    bool is_ack() const { return (flags & 0x10) != 0; }
    int header_length() const { return data_offset * 4; }

    void set_flag(uint8_t bit, bool on) {
        flags = on ? static_cast<uint8_t>(flags | bit) : static_cast<uint8_t>(flags & ~bit);
    }
    void set_syn(bool on) { set_flag(0x02, on); }
    void set_fin(bool on) { set_flag(0x01, on); }
    void set_rst(bool on) { set_flag(0x04, on); }
    void set_psh(bool on) { set_flag(0x08, on); }
    void set_ack(bool on) { set_flag(0x10, on); }

    /** 序列化 20 字节头（不含选项） */
    void write_to(uint8_t *out) const;
};

/** 解析后的 UDP 头（对照 UDPHeader.kt） */
struct UdpHeader {
    uint16_t source_port = 0;
    uint16_t destination_port = 0;
    uint16_t length = 0;
    uint16_t checksum = 0;
};

/**
 * 解析 IPv4 头。成功返回 true；非 IPv4 或长度不足返回 false。
 * data/len 为整包；消费的字节数经 header->header_length() 得到。
 */
bool parse_ipv4(const uint8_t *data, size_t len, Ipv4Header *header);

/** 解析 TCP 头；payload_offset 为 TCP 头起始偏移，payload_len 为 TCP 段长度 */
bool parse_tcp(const uint8_t *data, size_t len, size_t payload_offset, TcpHeader *header);

/** 解析 UDP 头 */
bool parse_udp(const uint8_t *data, size_t len, size_t payload_offset, UdpHeader *header);

/** 网络字节序 IP 转字符串 */
std::string ip_to_string(uint32_t ip);

/** 是否为 TLS ClientHello（对照 TLS.kt isTLSClientHello） */
bool is_tls_client_hello(const uint8_t *data, size_t len);

/** 是否以常见 HTTP 方法开头（对照 ConnectionHandler.supperProtocol） */
bool looks_like_http(const uint8_t *data, size_t len);

/**
 * 构造发回客户端的 TCP 包（IP + TCP + 可选 payload），自动计算两个校验和。
 * ip/tcp 为「已翻转」的响应头（源=原目标，目的=客户端）。
 */
std::vector<uint8_t> build_tcp_packet(const Ipv4Header &ip, const TcpHeader &tcp, const uint8_t *payload,
                                      size_t payload_len);

/**
 * 构造发回客户端的 UDP 包（IP + UDP + payload）；UDP 校验和置 0（IPv4 允许）。
 * 与 build_tcp_packet 不同：ip/udp 传**客户端请求**的头，内部自行互换地址与端口
 * （对照 UDPPacketFactory.createResponsePacket）。
 */
std::vector<uint8_t> build_udp_packet(const Ipv4Header &ip, const UdpHeader &udp, const uint8_t *payload,
                                      size_t payload_len);

/** 翻转 IP/TCP 的源与目的（响应方向） */
void flip_ipv4_tcp(Ipv4Header *ip, TcpHeader *tcp);

/** 下一包 ID（对照 PacketUtil.getPacketId） */
uint16_t next_packet_id();

/** 当前秒级时间戳（TCP 时间戳选项用） */
uint32_t current_time_seconds();

}  // namespace proxypin

#endif  // PROXYPIN_PACKET_H
