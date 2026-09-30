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

#include "packet.h"

#include <atomic>
#include <cstdio>
#include <cstring>
#include <ctime>

namespace proxypin {

namespace {

std::atomic<uint16_t> g_packet_id{0};

inline uint16_t read_be16(const uint8_t *p) {
    return static_cast<uint16_t>((static_cast<uint16_t>(p[0]) << 8) | p[1]);
}

inline uint32_t read_be32(const uint8_t *p) {
    return (static_cast<uint32_t>(p[0]) << 24) | (static_cast<uint32_t>(p[1]) << 16) |
           (static_cast<uint32_t>(p[2]) << 8) | static_cast<uint32_t>(p[3]);
}

inline void write_be16(uint8_t *p, uint16_t v) {
    p[0] = static_cast<uint8_t>(v >> 8);
    p[1] = static_cast<uint8_t>(v & 0xFF);
}

inline void append_be16(std::vector<uint8_t> &out, uint16_t v) {
    out.push_back(static_cast<uint8_t>(v >> 8));
    out.push_back(static_cast<uint8_t>(v & 0xFF));
}

inline void append_be32(std::vector<uint8_t> &out, uint32_t v) {
    out.push_back(static_cast<uint8_t>(v >> 24));
    out.push_back(static_cast<uint8_t>(v >> 16));
    out.push_back(static_cast<uint8_t>(v >> 8));
    out.push_back(static_cast<uint8_t>(v));
}

/**
 * 反码求和校验（对照 PacketUtil.calculateChecksum）：
 * 按 16bit 大端累加，奇数尾部字节作为高字节，回卷进位后取反。
 */
uint16_t checksum_bytes(const uint8_t *data, size_t len) {
    uint32_t sum = 0;
    size_t i = 0;
    while (i < len) {
        uint32_t word = static_cast<uint32_t>(data[i]) << 8;
        if (i + 1 < len) {
            word |= data[i + 1];
        }
        sum += word;
        i += 2;
    }
    while (sum >> 16) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return static_cast<uint16_t>(~sum & 0xFFFF);
}

/** 带伪首部的传输层校验和（TCP/UDP 伪首部：src, dst, 0, proto, length） */
uint16_t checksum_with_pseudo(uint32_t src_ip, uint32_t dst_ip, uint8_t protocol, const uint8_t *segment,
                              size_t segment_len) {
    std::vector<uint8_t> buf;
    buf.reserve(12 + segment_len + 1);
    append_be32(buf, src_ip);
    append_be32(buf, dst_ip);
    buf.push_back(0);
    buf.push_back(protocol);
    append_be16(buf, static_cast<uint16_t>(segment_len));
    buf.insert(buf.end(), segment, segment + segment_len);
    if (buf.size() % 2 != 0) {
        buf.push_back(0);
    }
    return checksum_bytes(buf.data(), buf.size());
}

const char *const kHttpMethods[] = {"GET",  "POST",     "PUT",   "PATCH", "DELETE", "HEAD",
                                    "OPTIONS", "TRACE", "CONNECT", "PROPFIND", "REPORT"};

}  // namespace

void Ipv4Header::write_to(uint8_t *out) const {
    out[0] = static_cast<uint8_t>((version << 4) | (ihl & 0x0F));
    out[1] = tos;
    write_be16(out + 2, total_length);
    write_be16(out + 4, identification);
    uint8_t flag = 0;
    if (dont_fragment) {
        flag = static_cast<uint8_t>(flag | 0x40);
    }
    if (more_fragments) {
        flag = static_cast<uint8_t>(flag | 0x20);
    }
    out[6] = static_cast<uint8_t>(((fragment_offset >> 8) & 0x1F) | flag);
    out[7] = static_cast<uint8_t>(fragment_offset & 0xFF);
    out[8] = ttl;
    out[9] = protocol;
    write_be16(out + 10, checksum);
    out[12] = static_cast<uint8_t>(source_ip >> 24);
    out[13] = static_cast<uint8_t>(source_ip >> 16);
    out[14] = static_cast<uint8_t>(source_ip >> 8);
    out[15] = static_cast<uint8_t>(source_ip);
    out[16] = static_cast<uint8_t>(destination_ip >> 24);
    out[17] = static_cast<uint8_t>(destination_ip >> 16);
    out[18] = static_cast<uint8_t>(destination_ip >> 8);
    out[19] = static_cast<uint8_t>(destination_ip);
}

void TcpHeader::write_to(uint8_t *out) const {
    write_be16(out, source_port);
    write_be16(out + 2, destination_port);
    write_be16(out + 4, static_cast<uint16_t>(sequence_number >> 16));
    write_be16(out + 6, static_cast<uint16_t>(sequence_number & 0xFFFF));
    write_be16(out + 8, static_cast<uint16_t>(ack_number >> 16));
    write_be16(out + 10, static_cast<uint16_t>(ack_number & 0xFFFF));
    out[12] = static_cast<uint8_t>(((data_offset << 4) & 0xF0) | (is_ns ? 0x01 : 0x00));
    out[13] = flags;
    write_be16(out + 14, window_size);
    write_be16(out + 16, checksum);
    write_be16(out + 18, urgent_pointer);
}

bool parse_ipv4(const uint8_t *data, size_t len, Ipv4Header *header) {
    if (len < static_cast<size_t>(kIp4HeaderSize)) {
        return false;
    }
    uint8_t version_ihl = data[0];
    uint8_t version = version_ihl >> 4;
    if (version != 4) {
        return false;
    }
    uint8_t ihl = version_ihl & 0x0F;
    if (ihl < 5 || len < static_cast<size_t>(ihl) * 4) {
        return false;
    }
    header->version = version;
    header->ihl = ihl;
    header->tos = data[1];
    header->total_length = read_be16(data + 2);
    header->identification = read_be16(data + 4);
    uint16_t flags_and_fragment = read_be16(data + 6);
    header->dont_fragment = (flags_and_fragment & 0x4000) != 0;
    header->more_fragments = (flags_and_fragment & 0x2000) != 0;
    header->fragment_offset = static_cast<uint16_t>(flags_and_fragment & 0x1FFF);
    header->ttl = data[8];
    header->protocol = data[9];
    header->checksum = read_be16(data + 10);
    header->source_ip = read_be32(data + 12);
    header->destination_ip = read_be32(data + 16);
    return true;
}

bool parse_tcp(const uint8_t *data, size_t len, size_t payload_offset, TcpHeader *header) {
    if (len < payload_offset + static_cast<size_t>(kTcpHeaderSize)) {
        return false;
    }
    const uint8_t *p = data + payload_offset;
    header->source_port = read_be16(p);
    header->destination_port = read_be16(p + 2);
    header->sequence_number = read_be32(p + 4);
    header->ack_number = read_be32(p + 8);
    uint8_t data_offset_and_reserved = p[12];
    header->data_offset = static_cast<uint8_t>(data_offset_and_reserved >> 4);
    header->is_ns = (data_offset_and_reserved & 0x01) != 0;
    header->flags = p[13];
    header->window_size = read_be16(p + 14);
    header->checksum = read_be16(p + 16);
    header->urgent_pointer = read_be16(p + 18);

    int options_size = header->data_offset - 5;
    if (options_size > 0) {
        size_t options_bytes = static_cast<size_t>(options_size) * 4;
        if (len < payload_offset + static_cast<size_t>(kTcpHeaderSize) + options_bytes) {
            return false;
        }
        header->options.assign(p + kTcpHeaderSize, p + kTcpHeaderSize + options_bytes);
    } else {
        header->options.clear();
    }
    return true;
}

bool parse_udp(const uint8_t *data, size_t len, size_t payload_offset, UdpHeader *header) {
    if (len < payload_offset + static_cast<size_t>(kUdpHeaderSize)) {
        return false;
    }
    const uint8_t *p = data + payload_offset;
    header->source_port = read_be16(p);
    header->destination_port = read_be16(p + 2);
    header->length = read_be16(p + 4);
    header->checksum = read_be16(p + 6);
    return true;
}

std::string ip_to_string(uint32_t ip) {
    char buf[16];
    snprintf(buf, sizeof(buf), "%u.%u.%u.%u", (ip >> 24) & 0xFF, (ip >> 16) & 0xFF, (ip >> 8) & 0xFF, ip & 0xFF);
    return std::string(buf);
}

bool is_tls_client_hello(const uint8_t *data, size_t len) {
    // 对照 TLS.kt isTLSClientHello（保持与 Android 侧一致的判定条件）
    if (len < 43) {
        return false;
    }
    if (data[0] != 0x16) {  // handshake
        return false;
    }
    if (data[1] != 0x03) {
        return false;
    }
    if (data[5] != 0x01) {  // client hello
        return false;
    }
    return data[9] == 0x03 && data[10] >= 0x00 && data[1] <= 0x03;
}

bool looks_like_http(const uint8_t *data, size_t len) {
    for (const char *method : kHttpMethods) {
        size_t method_len = strlen(method);
        if (len < method_len) {
            continue;
        }
        bool match = true;
        for (size_t i = 0; i < method_len; i++) {
            char c = static_cast<char>(data[i]);
            char upper = (c >= 'a' && c <= 'z') ? static_cast<char>(c - 32) : c;
            if (upper != method[i]) {
                match = false;
                break;
            }
        }
        if (match) {
            return true;
        }
    }
    return false;
}

std::vector<uint8_t> build_tcp_packet(const Ipv4Header &ip, const TcpHeader &tcp, const uint8_t *payload,
                                      size_t payload_len) {
    uint8_t ip_bytes[kIp4HeaderSize];
    uint8_t tcp_bytes[kTcpHeaderSize];

    Ipv4Header ip_header = ip;
    ip_header.ihl = 5;  // 响应包不带 IP 选项
    ip_header.total_length =
        static_cast<uint16_t>(ip_header.header_length() + kTcpHeaderSize + payload_len);
    ip_header.checksum = 0;
    ip_header.write_to(ip_bytes);
    uint16_t ip_checksum = checksum_bytes(ip_bytes, kIp4HeaderSize);
    write_be16(ip_bytes + 10, ip_checksum);

    TcpHeader tcp_header = tcp;
    tcp_header.data_offset = 5;
    tcp_header.checksum = 0;
    tcp_header.write_to(tcp_bytes);

    std::vector<uint8_t> segment;
    segment.reserve(kTcpHeaderSize + payload_len);
    segment.insert(segment.end(), tcp_bytes, tcp_bytes + kTcpHeaderSize);
    if (payload != nullptr && payload_len > 0) {
        segment.insert(segment.end(), payload, payload + payload_len);
    }

    uint16_t tcp_checksum =
        checksum_with_pseudo(ip_header.source_ip, ip_header.destination_ip, kTcpProtocol, segment.data(), segment.size());
    write_be16(segment.data() + 16, tcp_checksum);

    std::vector<uint8_t> out;
    out.reserve(kIp4HeaderSize + segment.size());
    out.insert(out.end(), ip_bytes, ip_bytes + kIp4HeaderSize);
    out.insert(out.end(), segment.begin(), segment.end());
    return out;
}

std::vector<uint8_t> build_udp_packet(const Ipv4Header &ip, const UdpHeader &udp, const uint8_t *payload,
                                      size_t payload_len) {
    uint16_t udp_len = static_cast<uint16_t>(kUdpHeaderSize + payload_len);

    uint8_t ip_bytes[kIp4HeaderSize];
    Ipv4Header ip_header = ip;
    ip_header.ihl = 5;  // 响应包不带 IP 选项
    ip_header.dont_fragment = false;  // 对照 UDPPacketFactory：setMayFragment(false)
    ip_header.identification = next_packet_id();
    ip_header.source_ip = ip.destination_ip;  // 响应方向：地址互换
    ip_header.destination_ip = ip.source_ip;
    ip_header.total_length = static_cast<uint16_t>(ip_header.header_length() + udp_len);
    ip_header.checksum = 0;
    ip_header.write_to(ip_bytes);
    write_be16(ip_bytes + 10, checksum_bytes(ip_bytes, kIp4HeaderSize));

    uint8_t udp_bytes[kUdpHeaderSize];
    write_be16(udp_bytes, udp.destination_port);  // 响应方向：端口互换
    write_be16(udp_bytes + 2, udp.source_port);
    write_be16(udp_bytes + 4, udp_len);
    write_be16(udp_bytes + 6, 0);  // IPv4 下 UDP 校验和可选，与 Android 一致置 0

    std::vector<uint8_t> out;
    out.reserve(kIp4HeaderSize + udp_len);
    out.insert(out.end(), ip_bytes, ip_bytes + kIp4HeaderSize);
    out.insert(out.end(), udp_bytes, udp_bytes + kUdpHeaderSize);
    if (payload != nullptr && payload_len > 0) {
        out.insert(out.end(), payload, payload + payload_len);
    }
    return out;
}

void flip_ipv4_tcp(Ipv4Header *ip, TcpHeader *tcp) {
    uint32_t source_ip = ip->source_ip;
    ip->source_ip = ip->destination_ip;
    ip->destination_ip = source_ip;

    uint16_t source_port = tcp->source_port;
    tcp->source_port = tcp->destination_port;
    tcp->destination_port = source_port;
}

uint16_t next_packet_id() {
    return g_packet_id.fetch_add(1);
}

uint32_t current_time_seconds() {
    return static_cast<uint32_t>(time(nullptr));
}

}  // namespace proxypin
