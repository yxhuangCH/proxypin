import 'dart:io';

import 'package:flutter/services.dart';
import 'package:proxypin/network/channel/host_port.dart';
import 'package:proxypin/network/util/process_info.dart';
import 'package:proxypin/utils/platform.dart';

class ProcessInfoPlugin {
  static const MethodChannel _methodChannel = MethodChannel('com.proxy/processInfo');

  static Future<ProcessInfo?> getProcessByPort(String host, int port) {
    return _methodChannel.invokeMethod<Map>('getProcessByPort', {"host": host, "port": port}).then((process) {
      if (process == null) return null;

      return ProcessInfo(process['packageName'], process['name'], process['packageName'],
          os: Platform.operatingSystem,
          icon: process['icon'],
          remoteHost: process['remoteHost'],
          remotePost: process['remotePort']);
    });
  }

  static Future<HostAndPort?> getRemoteAddressByPort(int port) async {
    // 鸿蒙与 Android 的 VPN 隧道都需要经端口映射反查原始目标（明文 HTTP 非标准端口修正）
    if (!Platforms.isAndroid() && !Platforms.isOhos()) return null;

    return _methodChannel.invokeMethod<Map>('getRemoteAddressByPort', {"port": port}).then((process) {
      if (process == null) return null;
      return HostAndPort.host(process['remoteHost'], process['remotePort']);
    });
  }
}
