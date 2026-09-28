import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/utils/platform.dart';

/// 鸿蒙后台保活门面：长时任务（continuousTask）+ 窗口常亮（wakelock 兜底）。
/// 仅 ohos 生效，其余平台静默降级为空操作，调用方无需平台判断。
/// 详见 harmony/docs/06-鸿蒙平台适配要点.md §3。
class KeepAliveService {
  static const MethodChannel _channel = MethodChannel('proxypin/keepalive');

  static bool _running = false;

  /// 长时任务状态变化通知（供 UI 展示保活状态）
  static final ValueNotifier<bool> status = ValueNotifier(false);

  /// 长时任务是否已成功启动（启动失败即降级为"前台使用"定位）
  static bool get isRunning => _running;

  /// 申请长时任务保活（dataTransfer）；返回是否成功，失败不抛异常
  static Future<bool> start() async {
    if (!Platforms.isOhos()) {
      return false;
    }
    try {
      var success = await _channel.invokeMethod<bool>('start');
      _running = success == true;
      status.value = _running;
      if (!_running) {
        logger.w('keep alive start rejected by system');
      }
      return _running;
    } catch (e) {
      logger.w('keep alive start failed: $e');
      _running = false;
      status.value = false;
      return false;
    }
  }

  /// 释放长时任务
  static Future<void> stop() async {
    if (!Platforms.isOhos()) {
      return;
    }
    try {
      await _channel.invokeMethod('stop');
    } catch (e) {
      logger.w('keep alive stop failed: $e');
    }
    _running = false;
    status.value = false;
  }

  /// 窗口常亮（"前台常亮"设置项）
  static Future<void> setKeepScreenOn(bool on) async {
    if (!Platforms.isOhos()) {
      return;
    }
    try {
      await _channel.invokeMethod('setKeepScreenOn', {'on': on});
    } catch (e) {
      logger.w('set keep screen on failed: $e');
    }
  }
}
