import 'package:proxypin/ui/component/app_dialog.dart';
import 'package:proxypin/utils/navigator.dart';
import 'package:proxypin/utils/platform.dart';
import 'package:share_plus/share_plus.dart';

/// 统一分享入口。
/// 鸿蒙 MVP：share_plus 暂无 ohos 实现，点击分享降级为提示，二期接入原生分享。
class ShareUtil {
  static Future<ShareResult?> share(ShareParams params) async {
    if (Platforms.isOhos()) {
      final ctx = NavigatorHelper().navigatorKey.currentContext;
      if (ctx != null) {
        CustomToast('当前平台暂不支持分享').show(ctx);
      }
      return null;
    }
    return SharePlus.instance.share(params);
  }
}
