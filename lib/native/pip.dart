
import 'package:flutter/services.dart';
import 'package:proxypin/native/vpn.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/ui/launch/launch.dart';
import 'package:proxypin/ui/mobile/mobile.dart';
import 'package:proxypin/utils/lang.dart';
import 'package:proxypin/utils/platform.dart';

///画中画
class PictureInPicture {
  static bool inPip = false;

  static final MethodChannel _channel = const MethodChannel('com.proxy/pictureInPicture')
    ..setMethodCallHandler((call) async {
      logger.d("pictureInPicture MethodCallHandler ${call.method}");
      if (call.method == 'cleanSession') {
        MobileApp.requestStateKey.currentState?.clean();
      } else if (call.method == 'exitPictureInPictureMode') {
        inPip = false;
        if (Platforms.supportVpn()) {
          Vpn.isRunning().then((value) {
            Vpn.isVpnStarted = value;
            SocketLaunch.startStatus.value = ValueWrap.of(value);
          });
        }
      }

      return Future.value();
    });

  ///进入画中画模式
  static Future<bool> enterPictureInPictureMode(String host, int port,
      {List<String>? appList, List<String>? disallowApps}) async {
    final bool enterPictureInPictureMode = await _channel.invokeMethod('enterPictureInPictureMode',
        {"proxyHost": host, "proxyPort": port, "allowApps": appList, "disallowApps": disallowApps});
    inPip = true;

    return enterPictureInPictureMode;
  }

  ///退出画中画模式
  static Future<bool> exitPictureInPictureMode() async {
    final bool exitPictureInPictureMode = await _channel.invokeMethod('exitPictureInPictureMode');
    return exitPictureInPictureMode;
  }

  /// 设置画中画开关（仅 ohos：同步 arm/disarm 原生 PiP 控制器）
  static Future<void> setEnabled(bool enabled) async {
    if (!Platforms.isOhos()) return;
    try {
      await _channel.invokeMethod('setEnabled', {'enabled': enabled});
    } catch (e) {
      logger.w('pip setEnabled failed: $e');
    }
  }

  ///发送数据
  static Future<bool> addData(String text) async {
    if ((Platforms.isIOS() || Platforms.isOhos()) && inPip) {
      _channel.invokeMethod('addData', text.fixAutoLines());
    }
    return false;
  }

  /// 清空小窗最近请求（会话清理时同步，仅 ohos 有原生缓冲）
  static Future<void> clearData() async {
    if (!Platforms.isOhos()) return;
    try {
      await _channel.invokeMethod('clearData');
    } catch (e) {
      logger.w('pip clearData failed: $e');
    }
  }
}
