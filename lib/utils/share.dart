import 'package:flutter/services.dart';
import 'package:proxypin/ui/component/app_dialog.dart';
import 'package:proxypin/utils/navigator.dart';
import 'package:proxypin/utils/platform.dart';
import 'package:share_plus/share_plus.dart';

/// 统一分享入口。
/// 鸿蒙：share_plus 无 ohos 官方实现，走自研插件（ohos/entry ProxyPinSharePlugin，Share Kit 系统分享面板）。
class ShareUtil {
  static const MethodChannel _ohosChannel = MethodChannel('proxypin/share');

  static Future<ShareResult?> share(ShareParams params) async {
    if (Platforms.isOhos()) {
      return _shareOhos(params);
    }
    return SharePlus.instance.share(params);
  }

  /// 鸿蒙系统分享面板。无法获取分享结果，统一返回 null。
  static Future<ShareResult?> _shareOhos(ShareParams params) async {
    try {
      final files = params.files;
      if (files != null && files.isNotEmpty) {
        await _ohosChannel.invokeMethod('shareFiles', {
          'paths': files.map((f) => f.path).toList(),
          'names': params.fileNameOverrides,
          'text': params.text,
        });
      } else if (params.text != null && params.text!.isNotEmpty) {
        await _ohosChannel.invokeMethod('shareText', {
          'text': params.text,
          'title': params.title,
          'subject': params.subject,
        });
      } else if (params.uri != null) {
        await _ohosChannel.invokeMethod('shareUri', {
          'uri': params.uri.toString(),
          'title': params.title,
        });
      }
    } catch (e) {
      final ctx = NavigatorHelper().navigatorKey.currentContext;
      if (ctx != null && ctx.mounted) {
        CustomToast('分享失败: $e').show(ctx);
      }
    }
    return null;
  }
}
