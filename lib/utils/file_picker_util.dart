import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:proxypin/ui/component/app_dialog.dart';
import 'package:proxypin/utils/navigator.dart';
import 'package:proxypin/utils/platform.dart';

/// file_picker 无 ohos 实现，鸿蒙上统一降级为提示并返回 null，避免 MissingPluginException。
/// 其他平台直接透传到 FilePicker。
class FilePickerUtil {
  static Future<FilePickerResult?> pickFiles({
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    bool allowMultiple = false,
    String? initialDirectory,
  }) async {
    if (Platforms.isOhos()) {
      _showUnsupported();
      return null;
    }
    return FilePicker.pickFiles(
      type: type,
      allowedExtensions: allowedExtensions,
      allowMultiple: allowMultiple,
      initialDirectory: initialDirectory,
    );
  }

  static Future<String?> saveFile({
    String? fileName,
    Uint8List? bytes,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    String? dialogTitle,
    String? initialDirectory,
  }) async {
    if (Platforms.isOhos()) {
      _showUnsupported();
      return null;
    }
    return FilePicker.saveFile(
      fileName: fileName,
      bytes: bytes,
      type: type,
      allowedExtensions: allowedExtensions,
      dialogTitle: dialogTitle,
      initialDirectory: initialDirectory,
    );
  }

  static void _showUnsupported() {
    final ctx = NavigatorHelper().navigatorKey.currentContext;
    if (ctx != null) {
      CustomToast('当前平台暂不支持文件选择').show(ctx);
    }
  }
}
