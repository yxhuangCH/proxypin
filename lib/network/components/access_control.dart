import 'dart:convert';
import 'dart:io';

import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/http/http_headers.dart';

/// 局域网访问控制：客户端 IP 白名单 + 代理鉴权（Proxy-Authorization Basic）。
/// 配置见 [Configuration]，默认关闭不改变现有行为。
class AccessControl {
  /// 校验客户端地址是否允许接入。回环地址始终放行。
  static bool isAllowed(InternetAddress remoteAddress, Configuration config) {
    if (!config.accessControlEnabled) return true;

    var host = remoteAddress.host;
    if (remoteAddress.isLoopback || host == 'localhost') return true;

    for (var entry in config.ipWhitelist) {
      if (_match(host.trim(), entry.trim())) return true;
    }
    return false;
  }

  /// 校验请求的 Proxy-Authorization 头。
  static bool checkAuth(HttpRequest request, Configuration config) {
    if (!config.proxyAuthEnabled) return true;

    var header = request.headers.get(HttpHeaders.PROXY_AUTHORIZATION);
    if (header == null || !header.startsWith('Basic ')) return false;

    try {
      var credentials = utf8.decode(base64Decode(header.substring(6).trim()));
      return credentials == '${config.proxyAuthUsername}:${config.proxyAuthPassword}';
    } catch (_) {
      return false;
    }
  }

  /// 精确 IP 或 CIDR（仅 IPv4 支持 CIDR 前缀）匹配
  static bool _match(String host, String entry) {
    if (host == entry) return true;

    var slash = entry.indexOf('/');
    if (slash < 0) return false;

    var network = _ipv4ToInt(entry.substring(0, slash));
    var target = _ipv4ToInt(host);
    var prefix = int.tryParse(entry.substring(slash + 1));
    if (network == null || target == null || prefix == null || prefix < 0 || prefix > 32) return false;

    var mask = prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;
    return (network & mask) == (target & mask);
  }

  static int? _ipv4ToInt(String ip) {
    var parts = ip.split('.');
    if (parts.length != 4) return null;
    var value = 0;
    for (var part in parts) {
      var n = int.tryParse(part);
      if (n == null || n < 0 || n > 255) return null;
      value = (value << 8) | n;
    }
    return value;
  }
}
