import 'dart:io';
import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:proxypin/utils/file_picker_util.dart';

class Platforms {
  /// 平台直通判断（业务代码统一走本类，禁止直接使用 Platform.isXxx）
  static bool isAndroid() => Platform.isAndroid;

  static bool isIOS() => Platform.isIOS;

  static bool isWindows() => Platform.isWindows;

  static bool isMacOS() => Platform.isMacOS;

  static bool isLinux() => Platform.isLinux;

  /// 判断是否是鸿蒙（HarmonyOS NEXT / ohos）
  static bool isOhos() {
    return Platform.operatingSystem == 'ohos';
  }

  /// 判断是否是桌面端
  static bool isDesktop() {
    return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  }

  /// 判断是否是移动端（含鸿蒙）
  static bool isMobile() {
    return Platform.isAndroid || Platform.isIOS || isOhos();
  }

  /// 是否支持 VPN 抓包（仅 Android/iOS）
  static bool supportVpn() {
    return Platform.isAndroid || Platform.isIOS;
  }

  /// 是否支持系统代理设置（仅桌面端）
  static bool supportSystemProxy() {
    return isDesktop();
  }

  /// 是否支持多窗口（仅 Windows/macOS）
  static bool supportMultiWindow() {
    return Platform.isWindows || Platform.isMacOS;
  }

  /// 是否支持应用级过滤（仅 Android VPN）
  static bool supportAppFilter() {
    return Platform.isAndroid;
  }

  /// 是否支持进程信息查询（Android 及桌面端）
  static bool supportProcessInfo() {
    return Platform.isAndroid || isDesktop();
  }

  /// 是否支持 JS 脚本引擎（鸿蒙 MVP 阶段不支持，flutter_js 无 ohos 原生库）
  static bool supportScript() {
    return !isOhos();
  }

  /// 判断是否是ipad
  static Future<bool> isIpad() async {
    if (Platform.isIOS) {
      final deviceInfo = DeviceInfoPlugin();
      final iosInfo = await deviceInfo.iosInfo;
      return iosInfo.model.toLowerCase().contains('ipad');
    }
    return false;
  }

  /// 桌面端保存文件：只弹对话框选路径并返回，不自动写入。
  /// 调用方拿到路径后自行转换 bytes 并写入，避免用户取消时浪费性能。
  /// 移动端请直接使用 FilePicker.saveFile。
  static Future<String?> saveFileAdaptive({
    required String fileName,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    String? dialogTitle,
  }) async {
    return FilePickerUtil.saveFile(
      fileName: fileName,
      bytes: Uint8List(0),
      type: type,
      allowedExtensions: allowedExtensions,
      dialogTitle: dialogTitle,
    );
  }
}
