import 'package:device_info_plus/device_info_plus.dart';
import 'package:proxypin/utils/platform.dart';

class DeviceUtils {
  /// Get the device id
  static Future<String?> deviceId() async {
    var deviceInfoPlugin = DeviceInfoPlugin();
    if (Platforms.isAndroid()) {
      return deviceInfoPlugin.androidInfo.then((it) => it.id);
    } else if (Platforms.isIOS()) {
      return deviceInfoPlugin.iosInfo.then((it) => it.identifierForVendor);
    } else if (Platforms.isOhos()) {
      // 鸿蒙 MVP：暂无稳定设备 ID 来源，后续可用 ohos 适配版 device_info_plus 补充
      return null;
    }

    return await desktopDeviceId();
  }

  /// Get the desktop device id
  static Future<String?> desktopDeviceId() async {
    var deviceInfoPlugin = DeviceInfoPlugin();
    if (Platforms.isWindows()) {
      return deviceInfoPlugin.windowsInfo.then((it) => it.deviceId);
    } else if (Platforms.isMacOS()) {
      return deviceInfoPlugin.macOsInfo.then((it) => it.systemGUID);
    } else if (Platforms.isLinux()) {
      return deviceInfoPlugin.linuxInfo.then((it) => it.machineId);
    }
    return null;
  }
}
