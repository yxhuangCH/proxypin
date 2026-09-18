import 'package:flutter/material.dart';
import 'package:flutter_toastr/flutter_toastr.dart';
import 'package:proxypin/utils/platform.dart';
import 'package:toastification/toastification.dart';

/// Toast 门面：flutter_toastr 无 ohos 实现，鸿蒙上改走纯 Dart 的 toastification；
/// 其他平台保持 FlutterToastr 原生 toast。签名与 Toast.show 保持一致。
class Toast {
  static final int lengthShort = 1;
  static final int lengthLong = 2;
  static final int bottom = 0;
  static final int center = 1;
  static final int top = 2;

  static void show(String msg, BuildContext context,
      {int? duration = 1,
      int? position = 0,
      Color backgroundColor = const Color(0xAA000000),
      textStyle = const TextStyle(fontSize: 15, color: Colors.white),
      double backgroundRadius = 20,
      bool? rootNavigator,
      Border? border}) {
    if (Platforms.isOhos()) {
      toastification.show(
        context: context,
        title: Text(msg, style: const TextStyle(fontSize: 15)),
        type: ToastificationType.info,
        style: ToastificationStyle.flat,
        alignment: Alignment.bottomCenter,
        autoCloseDuration: Duration(seconds: duration ?? 1),
        showProgressBar: false,
        dragToClose: true,
      );
      return;
    }

    FlutterToastr.show(msg, context,
        duration: duration,
        position: position,
        backgroundColor: backgroundColor,
        textStyle: textStyle,
        backgroundRadius: backgroundRadius,
        rootNavigator: rootNavigator,
        border: border);
  }
}
