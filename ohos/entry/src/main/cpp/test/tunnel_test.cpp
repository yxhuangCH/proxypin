// 隧道栈宿主机端到端回归（不需真机/DevEco，构建与运行见同目录 run.sh）：
// 用 AF_UNIX SOCK_DGRAM socketpair 冒充 tun fd（保留报文边界，语义与 tun 一致），
// 用本机 TCP/UDP 服务冒充「代理」与「目标」，跑通 SYN→SYN-ACK→数据→响应→FIN，
// 并验证 port_map 控制通道、UDP 转发、未知会话 RST。
//
// 本文件只被 run.sh 编译，不在 hvigor 构建图上（cpp/CMakeLists.txt 显式列举源文件），
// 所以改完 packet/tunnel/port_map 后必须手动跑一次本回归。
#include <arpa/inet.h>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <netinet/in.h>
#include <poll.h>
#include <string>
#include <sys/socket.h>
#include <unistd.h>
#include <vector>

#include "packet.h"
#include "tunnel.h"

using namespace proxypin;

static const uint32_t kClientIp = 0x0A000002;   // 10.0.0.2（tun 侧）
static const uint16_t kClientPort = 51234;
static const uint32_t kServerIp = 0x5DB8D822;   // 93.184.216.34（原始目标）
static const uint16_t kServerPort = 443;
static const uint8_t kClientHello[] = {0x16, 0x03, 0x01, 0x02, 0x00, 0x01, 0x00, 0x01, 0xfc, 0x03,
                                       0x03, 0xaa, 0xbb, 0xcc, 0xdd, 0x00, 0x00, 0x00, 0x00, 0x00,
                                       0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                                       0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                                       0x00, 0x00, 0x00};

static int listen_tcp(uint16_t *out_port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    struct sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    assert(bind(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0);
    assert(listen(fd, 8) == 0);
    socklen_t len = sizeof(addr);
    assert(getsockname(fd, (struct sockaddr *)&addr, &len) == 0);
    *out_port = ntohs(addr.sin_port);
    return fd;
}

static int listen_udp(uint16_t *out_port) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    assert(bind(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0);
    socklen_t len = sizeof(addr);
    assert(getsockname(fd, (struct sockaddr *)&addr, &len) == 0);
    *out_port = ntohs(addr.sin_port);
    return fd;
}

static std::vector<uint8_t> client_packet(uint32_t src_ip, uint16_t src_port, uint32_t dst_ip,
                                          uint16_t dst_port, uint32_t seq, uint32_t ack, uint8_t flags,
                                          const uint8_t *payload, size_t payload_len) {
    Ipv4Header ip;
    ip.identification = 1;
    ip.ttl = 64;
    ip.protocol = kTcpProtocol;
    ip.source_ip = src_ip;
    ip.destination_ip = dst_ip;
    TcpHeader tcp;
    tcp.source_port = src_port;
    tcp.destination_port = dst_port;
    tcp.sequence_number = seq;
    tcp.ack_number = ack;
    tcp.flags = flags;
    tcp.window_size = 65535;
    return build_tcp_packet(ip, tcp, payload, payload_len);
}

/** 手工构造请求方向（客户端 → 目标）的 UDP 包；UDP 校验和置 0（IPv4 允许） */
static std::vector<uint8_t> client_udp_packet(uint32_t src_ip, uint16_t src_port, uint32_t dst_ip,
                                              uint16_t dst_port, const uint8_t *payload, size_t payload_len) {
    size_t total = 20 + 8 + payload_len;
    std::vector<uint8_t> raw(total, 0);
    raw[0] = 0x45;
    raw[2] = static_cast<uint8_t>(total >> 8);
    raw[3] = static_cast<uint8_t>(total & 0xFF);
    raw[8] = 64;
    raw[9] = kUdpProtocol;
    for (int i = 0; i < 4; i++) {  // 网络字节序（大端）
        raw[12 + i] = static_cast<uint8_t>(src_ip >> (24 - 8 * i));
        raw[16 + i] = static_cast<uint8_t>(dst_ip >> (24 - 8 * i));
    }

    uint32_t sum = 0;
    for (size_t i = 0; i < 20; i += 2) {
        sum += (raw[i] << 8) | raw[i + 1];
    }
    while (sum >> 16) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    uint16_t checksum = static_cast<uint16_t>(~sum & 0xFFFF);
    raw[10] = static_cast<uint8_t>(checksum >> 8);
    raw[11] = static_cast<uint8_t>(checksum & 0xFF);

    raw[20] = static_cast<uint8_t>(src_port >> 8);
    raw[21] = static_cast<uint8_t>(src_port & 0xFF);
    raw[22] = static_cast<uint8_t>(dst_port >> 8);
    raw[23] = static_cast<uint8_t>(dst_port & 0xFF);
    uint16_t udp_len = static_cast<uint16_t>(8 + payload_len);
    raw[24] = static_cast<uint8_t>(udp_len >> 8);
    raw[25] = static_cast<uint8_t>(udp_len & 0xFF);
    memcpy(raw.data() + 28, payload, payload_len);
    return raw;
}

static void send_tun(int fd, const std::vector<uint8_t> &packet) {
    assert(write(fd, packet.data(), packet.size()) == (ssize_t)packet.size());
}

/** 从「tun」读一个报文，超时返回空 */
static std::vector<uint8_t> recv_tun(int fd, int timeout_ms = 2000) {
    struct pollfd pfd = {fd, POLLIN, 0};
    int ret = poll(&pfd, 1, timeout_ms);
    if (ret <= 0) {
        return {};
    }
    std::vector<uint8_t> buffer(65535);
    ssize_t n = read(fd, buffer.data(), buffer.size());
    if (n <= 0) {
        return {};
    }
    buffer.resize(static_cast<size_t>(n));
    return buffer;
}

struct TcpView {
    Ipv4Header ip;
    TcpHeader tcp;
    std::vector<uint8_t> payload;
};

static bool parse_view(const std::vector<uint8_t> &raw, TcpView *view) {
    if (!parse_ipv4(raw.data(), raw.size(), &view->ip)) {
        return false;
    }
    size_t ip_len = static_cast<size_t>(view->ip.header_length());
    if (!parse_tcp(raw.data(), raw.size(), ip_len, &view->tcp)) {
        return false;
    }
    size_t offset = ip_len + static_cast<size_t>(view->tcp.header_length());
    view->payload.assign(raw.begin() + offset, raw.end());
    return true;
}

int main() {
    assert(!Tunnel::query_running());  // 未启动时控制通道不可达

    uint16_t proxy_port = 0;
    int proxy_listen = listen_tcp(&proxy_port);
    uint16_t udp_port = 0;
    int udp_server = listen_udp(&udp_port);

    int tun[2] = {-1, -1};
    assert(socketpair(AF_UNIX, SOCK_DGRAM, 0, tun) == 0);

    assert(Tunnel::instance().start(tun[0], "127.0.0.1", proxy_port));
    assert(Tunnel::query_running());

    // ---------- 1. SYN → SYN-ACK ----------
    send_tun(tun[1], client_packet(kClientIp, kClientPort, kServerIp, kServerPort, 100, 0, 0x02, nullptr, 0));
    std::vector<uint8_t> syn_ack = recv_tun(tun[1]);
    assert(!syn_ack.empty());
    TcpView view{};
    assert(parse_view(syn_ack, &view));
    assert(view.ip.source_ip == kServerIp && view.ip.destination_ip == kClientIp);
    assert(view.ip.total_length == 40);
    assert(view.tcp.source_port == kServerPort && view.tcp.destination_port == kClientPort);
    assert(view.tcp.is_syn() && view.tcp.is_ack());
    assert(view.tcp.ack_number == 101);
    uint32_t server_seq = view.tcp.sequence_number;
    assert(server_seq < 100000);
    printf("1. SYN -> SYN-ACK seq=%u ack=%u\n", server_seq, view.tcp.ack_number);

    // ---------- 1.5 回归：SYN 后、首个数据前 poll 被唤醒（控制通道查询），
    // 未连接会话不得被误杀（旧 bug：未 connect 的 socket 进 poll 拿 POLLHUP →
    // read ENOTCONN → 会话关闭 → 后续报文 unknown session，真机 errno=107） ----------
    for (int i = 0; i < 3; i++) {
        assert(Tunnel::query_running());  // 每次查询都 accept 一次控制连接 → 唤醒 poll
        usleep(50000);
    }
    send_tun(tun[1], client_packet(kClientIp, kClientPort, kServerIp, kServerPort, 101,
                                   server_seq + 1, 0x10, nullptr, 0));  // 纯 ACK
    usleep(50000);
    assert(Tunnel::query_running());
    usleep(50000);
    printf("1.5 poll wakeup before first data: session alive\n");

    // ---------- 2. ACK + ClientHello(PSH) → 代理收到数据 ----------
    std::vector<uint8_t> data_packet = client_packet(kClientIp, kClientPort, kServerIp, kServerPort, 101,
                                                     server_seq + 1, 0x18, kClientHello, sizeof(kClientHello));
    send_tun(tun[1], data_packet);
    std::vector<uint8_t> ack = recv_tun(tun[1]);
    assert(!ack.empty());
    assert(parse_view(ack, &view));
    assert(view.tcp.is_ack() && !view.tcp.is_syn() && !view.tcp.is_psh());
    assert(view.tcp.ack_number == 101 + sizeof(kClientHello));  // 客户端序列 + 数据长度
    printf("2. data -> ACK ack=%u\n", view.tcp.ack_number);

    struct pollfd proxy_wait = {proxy_listen, POLLIN, 0};
    assert(poll(&proxy_wait, 1, 2000) == 1);
    struct sockaddr_in peer{};
    socklen_t peer_len = sizeof(peer);
    int upstream = accept(proxy_listen, (struct sockaddr *)&peer, &peer_len);
    assert(upstream > 0);
    uint16_t upstream_local_port = ntohs(peer.sin_port);
    printf("   proxy accepted, upstream local port=%u\n", upstream_local_port);

    std::vector<uint8_t> received(sizeof(kClientHello));
    assert(read(upstream, received.data(), received.size()) == (ssize_t)sizeof(kClientHello));
    assert(memcmp(received.data(), kClientHello, sizeof(kClientHello)) == 0);

    // ---------- 3. port_map：本地上行端口 → 原始目标端口 ----------
    RemoteTarget resolved{};
    assert(Tunnel::query_remote(upstream_local_port, &resolved));
    assert(resolved.port == kServerPort);
    assert(resolved.host == "93.184.216.34");
    printf("3. port_map %u -> %s:%u\n", upstream_local_port, resolved.host.c_str(), resolved.port);

    // ---------- 4. 代理回数据 → 隧道发 PSH 包给客户端 ----------
    const char response[] = "HTTP/1.1 200 OK\r\n\r\nhello";
    assert(write(upstream, response, sizeof(response) - 1) == (ssize_t)(sizeof(response) - 1));
    std::vector<uint8_t> down = recv_tun(tun[1]);
    assert(!down.empty());
    assert(parse_view(down, &view));
    assert(view.ip.source_ip == kServerIp && view.tcp.source_port == kServerPort);
    assert(view.tcp.sequence_number == server_seq + 1);
    assert(view.tcp.ack_number == 101 + sizeof(kClientHello));
    assert(view.tcp.is_psh() && view.tcp.is_ack());
    assert(std::string(view.payload.begin(), view.payload.end()) == std::string(response));
    printf("4. server data -> PSH seq=%u len=%zu\n", view.tcp.sequence_number, view.payload.size());

    // ---------- 5. 客户端 ACK 被接受（无回包）----------
    send_tun(tun[1], client_packet(kClientIp, kClientPort, kServerIp, kServerPort, 101 + sizeof(kClientHello),
                                   server_seq + 1 + view.payload.size(), 0x10, nullptr, 0));
    assert(recv_tun(tun[1], 300).empty());

    // ---------- 6. 客户端 FIN → FIN-ACK，上行 socket 关闭 ----------
    send_tun(tun[1], client_packet(kClientIp, kClientPort, kServerIp, kServerPort,
                                   101 + sizeof(kClientHello), server_seq + 1 + view.payload.size(), 0x11,
                                   nullptr, 0));
    std::vector<uint8_t> fin_ack = recv_tun(tun[1]);
    assert(!fin_ack.empty());
    assert(parse_view(fin_ack, &view));
    assert(view.tcp.is_fin() && view.tcp.is_ack());
    struct pollfd closed_wait = {upstream, POLLIN, 0};
    assert(poll(&closed_wait, 1, 2000) == 1);
    char eof_buf[16];
    assert(read(upstream, eof_buf, sizeof(eof_buf)) == 0);  // 远端关闭
    printf("6. client FIN -> FIN-ACK, upstream closed\n");
    close(upstream);

    // ---------- 7. 未知会话的包 → RST ----------
    send_tun(tun[1], client_packet(kClientIp, 40777, kServerIp, kServerPort, 5000, 0, 0x10, nullptr, 0));
    std::vector<uint8_t> rst = recv_tun(tun[1]);
    assert(!rst.empty());
    assert(parse_view(rst, &view));
    assert(view.tcp.is_rst());
    assert(view.tcp.source_port == kServerPort);
    printf("7. unknown session -> RST\n");

    // ---------- 8. UDP 转发（DNS 类）----------
    {
        const char query[] = "dns-query";
        // 客户端把 UDP 包发给本机 udp_server（隧道直连它，非代理）
        std::vector<uint8_t> udp_req = client_udp_packet(kClientIp, 5353, 0x7F000001, udp_port,
                                                        reinterpret_cast<const uint8_t *>(query), sizeof(query) - 1);
        for (size_t i = 0; i < udp_req.size(); i++) fprintf(stderr, "%02x ", udp_req[i]);
        fprintf(stderr, " <- udp_req len=%zu udp_port=%u\n", udp_req.size(), udp_port);
        send_tun(tun[1], udp_req);

        struct pollfd udp_wait = {udp_server, POLLIN, 0};
        assert(poll(&udp_wait, 1, 2000) == 1);
        struct sockaddr_in from{};
        socklen_t from_len = sizeof(from);
        char payload[64] = {0};
        ssize_t n = recvfrom(udp_server, payload, sizeof(payload), 0, (struct sockaddr *)&from, &from_len);
        assert(n == (ssize_t)(sizeof(query) - 1));
        assert(memcmp(payload, query, sizeof(query) - 1) == 0);
        // 回一个响应
        const char reply[] = "dns-reply";
        assert(sendto(udp_server, reply, sizeof(reply) - 1, 0, (struct sockaddr *)&from, from_len) ==
               (ssize_t)(sizeof(reply) - 1));

        std::vector<uint8_t> udp_down = recv_tun(tun[1]);
        assert(!udp_down.empty());
        Ipv4Header down_ip;
        for (size_t i = 0; i < udp_down.size(); i++) fprintf(stderr, "%02x ", udp_down[i]);
        fprintf(stderr, " <- udp_down len=%zu\n", udp_down.size());
        assert(parse_ipv4(udp_down.data(), udp_down.size(), &down_ip));
        assert(down_ip.protocol == kUdpProtocol);
        assert(down_ip.source_ip == 0x7F000001 && down_ip.destination_ip == kClientIp);
        UdpHeader down_udp;
        assert(parse_udp(udp_down.data(), udp_down.size(), down_ip.header_length(), &down_udp));
        assert(down_udp.source_port == udp_port && down_udp.destination_port == 5353);
        assert(down_udp.checksum == 0);
        assert(std::string(udp_down.begin() + 28, udp_down.end()) == std::string(reply));
        printf("8. UDP forwarded and echoed back\n");
    }

    // ---------- 9. IPv6 / 畸形包 / 分片包被丢弃 ----------
    {
        std::vector<uint8_t> v6(40, 0);
        v6[0] = 0x60;
        send_tun(tun[1], v6);
        std::vector<uint8_t> short_pkt(10, 0);
        send_tun(tun[1], short_pkt);
        std::vector<uint8_t> fragmented =
            client_packet(kClientIp, kClientPort, kServerIp, kServerPort, 1, 0, 0x02, nullptr, 0);
        fragmented[6] = static_cast<uint8_t>(0x20 | 0x40);  // MF 置位（同时带 DF，验证 DF 不导致丢弃）
        send_tun(tun[1], fragmented);
        assert(recv_tun(tun[1], 300).empty());

        // DF 置位（真实 TCP 报文的常态）不得被丢弃：应正常回 SYN-ACK
        std::vector<uint8_t> df_syn =
            client_packet(kClientIp, kClientPort, kServerIp, kServerPort, 900, 0, 0x02, nullptr, 0);
        df_syn[6] = 0x40;  // DF only
        send_tun(tun[1], df_syn);
        std::vector<uint8_t> df_ack = recv_tun(tun[1]);
        assert(!df_ack.empty());
        assert(parse_view(df_ack, &view));
        assert(view.tcp.is_syn() && view.tcp.is_ack());
        send_tun(tun[1], client_packet(kClientIp, kClientPort, kServerIp, kServerPort, 901,
                                       view.tcp.sequence_number + 1, 0x11, nullptr, 0));
        assert(!recv_tun(tun[1]).empty());  // FIN-ACK
        printf("9. IPv6/malformed/fragment dropped; DF-set packet handled\n");
    }

    // ---------- 10. 直连（非嗅探协议）：隧道连原始目标，不经代理 ----------
    {
        uint16_t direct_port = 0;
        int direct_listen = listen_tcp(&direct_port);
        uint32_t direct_ip = 0x7F000001;  // 127.0.0.1
        const uint16_t client_port2 = 41000;

        send_tun(tun[1], client_packet(kClientIp, client_port2, direct_ip, direct_port, 7000, 0, 0x02, nullptr, 0));
        std::vector<uint8_t> d_syn_ack = recv_tun(tun[1]);
        assert(!d_syn_ack.empty() && parse_view(d_syn_ack, &view));
        assert(view.tcp.is_syn() && view.tcp.is_ack());
        uint32_t dseq = view.tcp.sequence_number;

        const char raw_data[] = "\x00\x01rawprotocol\x02";  // 既非 TLS 也非 HTTP 方法
        send_tun(tun[1], client_packet(kClientIp, client_port2, direct_ip, direct_port, 7001, dseq + 1, 0x18,
                                       reinterpret_cast<const uint8_t *>(raw_data), sizeof(raw_data) - 1));
        std::vector<uint8_t> d_ack = recv_tun(tun[1]);
        assert(!d_ack.empty() && parse_view(d_ack, &view));
        assert(view.tcp.ack_number == 7001 + sizeof(raw_data) - 1);

        struct pollfd direct_wait = {direct_listen, POLLIN, 0};
        assert(poll(&direct_wait, 1, 2000) == 1);
        struct sockaddr_in d_peer{};
        socklen_t d_peer_len = sizeof(d_peer);
        int direct_conn = accept(direct_listen, (struct sockaddr *)&d_peer, &d_peer_len);
        assert(direct_conn > 0);
        // 直连不进 port_map（对照 Android 只对代理连接登记）
        RemoteTarget ignored_target{};
        assert(!Tunnel::query_remote(ntohs(d_peer.sin_port), &ignored_target));
        std::vector<uint8_t> d_received(sizeof(raw_data) - 1);
        assert(read(direct_conn, d_received.data(), d_received.size()) == (ssize_t)d_received.size());
        assert(memcmp(d_received.data(), raw_data, sizeof(raw_data) - 1) == 0);

        const char d_reply[] = "raw-reply";
        assert(write(direct_conn, d_reply, sizeof(d_reply) - 1) == (ssize_t)(sizeof(d_reply) - 1));
        std::vector<uint8_t> d_down = recv_tun(tun[1]);
        assert(!d_down.empty() && parse_view(d_down, &view));
        assert(view.ip.source_ip == direct_ip);
        assert(std::string(view.payload.begin(), view.payload.end()) == std::string(d_reply));
        printf("10. direct (non-sniffed) TCP forwarded without proxy\n");
        close(direct_conn);
        close(direct_listen);
    }

    // ---------- 11. 非标准端口明文 HTTP：走代理且 port_map 记录原始端口 ----------
    {
        const uint16_t odd_port = 8088;
        const uint16_t client_port3 = 42000;
        send_tun(tun[1], client_packet(kClientIp, client_port3, kServerIp, odd_port, 8000, 0, 0x02, nullptr, 0));
        std::vector<uint8_t> h_syn_ack = recv_tun(tun[1]);
        assert(!h_syn_ack.empty() && parse_view(h_syn_ack, &view));
        uint32_t hseq = view.tcp.sequence_number;

        const char get_req[] = "GET /index.html HTTP/1.1\r\nHost: example.com\r\n\r\n";
        send_tun(tun[1], client_packet(kClientIp, client_port3, kServerIp, odd_port, 8001, hseq + 1, 0x18,
                                       reinterpret_cast<const uint8_t *>(get_req), sizeof(get_req) - 1));
        assert(!recv_tun(tun[1]).empty());  // ACK

        struct pollfd h_wait = {proxy_listen, POLLIN, 0};
        assert(poll(&h_wait, 1, 2000) == 1);
        struct sockaddr_in h_peer{};
        socklen_t h_peer_len = sizeof(h_peer);
        int h_conn = accept(proxy_listen, (struct sockaddr *)&h_peer, &h_peer_len);
        assert(h_conn > 0);
        std::vector<uint8_t> h_received(sizeof(get_req) - 1);
        assert(read(h_conn, h_received.data(), h_received.size()) == (ssize_t)h_received.size());
        assert(memcmp(h_received.data(), get_req, sizeof(get_req) - 1) == 0);
        RemoteTarget h_resolved{};
        assert(Tunnel::query_remote(ntohs(h_peer.sin_port), &h_resolved));
        assert(h_resolved.port == odd_port);  // 明文 HTTP 靠 port_map 还原非标准端口
        printf("11. plain HTTP on port %u routed to proxy, port_map=%s:%u\n", odd_port,
               h_resolved.host.c_str(), h_resolved.port);
        close(h_conn);
    }

    Tunnel::instance().stop();
    assert(!Tunnel::query_running());
    close(proxy_listen);
    close(udp_server);
    close(tun[0]);
    close(tun[1]);
    printf("tunnel OK\n");
    return 0;
}
