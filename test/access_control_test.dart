import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/components/access_control.dart';
import 'package:proxypin/network/http/http.dart';

void main() {
  Configuration config({bool enabled = true, List<String> whitelist = const []}) {
    var c = Configuration.fromJson({});
    c.accessControlEnabled = enabled;
    c.ipWhitelist = whitelist;
    return c;
  }

  test('访问控制关闭时全部放行', () {
    var c = config(enabled: false, whitelist: ['1.2.3.4']);
    expect(AccessControl.isAllowed(InternetAddress('9.9.9.9'), c), isTrue);
  });

  test('回环地址始终放行', () {
    var c = config(whitelist: ['192.168.1.0/24']);
    expect(AccessControl.isAllowed(InternetAddress('127.0.0.1'), c), isTrue);
    expect(AccessControl.isAllowed(InternetAddress('::1'), c), isTrue);
  });

  test('精确 IP 匹配', () {
    var c = config(whitelist: ['192.168.3.100']);
    expect(AccessControl.isAllowed(InternetAddress('192.168.3.100'), c), isTrue);
    expect(AccessControl.isAllowed(InternetAddress('192.168.3.101'), c), isFalse);
  });

  test('CIDR 匹配', () {
    var c = config(whitelist: ['192.168.3.0/24']);
    expect(AccessControl.isAllowed(InternetAddress('192.168.3.1'), c), isTrue);
    expect(AccessControl.isAllowed(InternetAddress('192.168.3.254'), c), isTrue);
    expect(AccessControl.isAllowed(InternetAddress('192.168.4.1'), c), isFalse);
  });

  test('CIDR /32 与 /0 边界', () {
    var c = config(whitelist: ['10.0.0.1/32']);
    expect(AccessControl.isAllowed(InternetAddress('10.0.0.1'), c), isTrue);
    expect(AccessControl.isAllowed(InternetAddress('10.0.0.2'), c), isFalse);
    var all = config(whitelist: ['0.0.0.0/0']);
    expect(AccessControl.isAllowed(InternetAddress('8.8.8.8'), all), isTrue);
  });

  test('非法条目不误放行', () {
    var c = config(whitelist: ['not-an-ip/24', '192.168.1.0/99', '192.168.1.0/']);
    expect(AccessControl.isAllowed(InternetAddress('192.168.1.5'), c), isFalse);
  });

  test('代理鉴权 Basic 校验', () {
    var c = Configuration.fromJson({});
    c.proxyAuthEnabled = true;
    c.proxyAuthUsername = 'user';
    c.proxyAuthPassword = 'pass';

    var ok = HttpRequest(HttpMethod.get, 'http://example.com/');
    ok.headers.set('Proxy-Authorization', 'Basic ${base64Encode(utf8.encode('user:pass'))}');
    expect(AccessControl.checkAuth(ok, c), isTrue);

    var wrong = HttpRequest(HttpMethod.get, 'http://example.com/');
    wrong.headers.set('Proxy-Authorization', 'Basic ${base64Encode(utf8.encode('user:bad'))}');
    expect(AccessControl.checkAuth(wrong, c), isFalse);

    var missing = HttpRequest(HttpMethod.get, 'http://example.com/');
    expect(AccessControl.checkAuth(missing, c), isFalse);

    var garbage = HttpRequest(HttpMethod.get, 'http://example.com/');
    garbage.headers.set('Proxy-Authorization', 'Basic !!!not-base64!!!');
    expect(AccessControl.checkAuth(garbage, c), isFalse);

    c.proxyAuthEnabled = false;
    expect(AccessControl.checkAuth(missing, c), isTrue);
  });
}
