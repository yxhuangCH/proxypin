/*
 * Copyright 2023 Hongen Wang
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:proxypin/ui/component/toast.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/native/vpn.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/native/keep_alive.dart';
import 'package:proxypin/ui/desktop/ssl/pc_cert.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:proxypin/utils/lang.dart';
import 'package:proxypin/utils/desktop_tray.dart';
import 'package:proxypin/utils/platform.dart';
import 'package:window_manager/window_manager.dart';

import '../mobile/setting/ssl.dart';

///启动按钮
///@author wanghongen
///2023/10/8
class SocketLaunch extends StatefulWidget {
  static ValueNotifier<ValueWrap<bool>> startStatus = ValueNotifier(ValueWrap());

  final ProxyServer proxyServer;
  final int size;
  final bool startup; //默认是否启动
  final Function? onStart;
  final Function? onStop;

  final bool serverLaunch; //是否启动代理服务器

  const SocketLaunch(
      {super.key,
      required this.proxyServer,
      this.size = 25,
      this.onStart,
      this.onStop,
      this.startup = true,
      this.serverLaunch = true});

  @override
  State<StatefulWidget> createState() => _SocketLaunchState();
}

class _SocketLaunchState extends State<SocketLaunch> with WindowListener, WidgetsBindingObserver {
  AppLocalizations get localizations => AppLocalizations.of(context)!;
  bool started = false;

  @override
  void initState() {
    super.initState();
    if (Platforms.isDesktop()) {
      windowManager.addListener(this);
      windowManager.setPreventClose(true);
      DesktopTrayManager.instance.setQuitHandler(appExit);
    }

    WidgetsBinding.instance.addObserver(this);
    //启动代理服务器
    if (widget.startup) {
      start();
    }

    SocketLaunch.startStatus.addListener(() {
      if (SocketLaunch.startStatus.value.get() == started) {
        return;
      }
      setState(() {
        started = SocketLaunch.startStatus.value.get() ?? started;
      });
    });
  }

  @override
  void dispose() {
    if (Platforms.isDesktop()) {
      windowManager.removeListener(this);
      DesktopTrayManager.instance.setQuitHandler(null);
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void onWindowClose() async {
    logger.d("onWindowClose");
    await _handleWindowClose();
  }

  Future<void> _handleWindowClose() async {
    final appConfiguration = AppConfiguration.current;
    if (Platforms.isDesktop() && appConfiguration?.minimizeToTray == null || appConfiguration?.minimizeToTray == true) {
      if (appConfiguration?.minimizeToTray == null) {
        final minimize = await _showTrayClosePrompt();
        if (!mounted) {
          return;
        }

        appConfiguration?.minimizeToTray = minimize;
        await appConfiguration?.flushConfig();

        if (!minimize) {
          await appExit();
          return;
        }
      }

      try {
        await DesktopTrayManager.instance.showToTray();
        return;
      } catch (e) {
        logger.e('show to tray failed, fallback to exit', error: e);
      }
    }

    await appExit();
  }

  Future<bool> _showTrayClosePrompt() async {
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) {
            return AlertDialog(
              title: Text(localizations.minimizeToTrayTitle),
              content: SizedBox(width: 320, child: Text(maxLines: 3, localizations.trayClosePromptContent)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text(localizations.trayCloseExitAnyway),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: Text(localizations.trayCloseMinimizeToTray),
                ),
              ],
            );
          },
        ) ??
        false;
  }

  Future<void> appExit() async {
    logger.d("appExit");
    _stopOhosKeepAlive();
    await widget.proxyServer.stop();
    started = false;
    if (Platforms.isDesktop()) {
      await DesktopTrayManager.instance.exitApp();
      windowManager.setPreventClose(false);
      await windowManager.destroy();
    }

    if (!Platforms.isWindows() && !Platforms.isLinux()) {
      try {
        await SystemNavigator.pop(animated: true).timeout(const Duration(milliseconds: 150));
      } catch (_) {
        //
      }
    }

    exit(0);
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    if (Platforms.isDesktop()) {
      bool isPreventClose = await windowManager.isPreventClose();
      if (!isPreventClose || Platforms.isMacOS()) {
        await appExit();
      }
    }
    return super.didRequestAppExit();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (widget.proxyServer.isRunning && started) {
        widget.proxyServer.retryBind().catchError((e) {
          logger.e('retryBind failed on resumed', error: e);
        });
        // 回到前台后重新拉起保活（长时任务可能在后台被系统回收）
        _applyOhosKeepAlive();
      }

      if (Platforms.supportVpn() && started == false) {
        Vpn.isRunning().then((value) {
          Vpn.isVpnStarted = value;
          SocketLaunch.startStatus.value = ValueWrap.of(value);
        });
      }
    }

    if (state == AppLifecycleState.detached) {
      logger.d('AppLifecycleState.detached');
      _stopOhosKeepAlive();
      widget.onStop?.call();
      widget.proxyServer.stop();
      started = false;
    }
  }

  /// 鸿蒙：代理运行期间申请长时任务保活，并应用"前台常亮"设置；
  /// 长时任务被系统拒绝时静默降级（详见 harmony/docs/06 §3.4 产品定位话术）
  Future<void> _applyOhosKeepAlive() async {
    if (!Platforms.isOhos() || !widget.proxyServer.isRunning) {
      return;
    }
    var keepAlive = await KeepAliveService.start();
    if (!keepAlive) {
      logger.w('continuous task unavailable, fallback to foreground-only mode');
    }
    await KeepAliveService.setKeepScreenOn(AppConfiguration.current?.keepScreenOn ?? false);
  }

  /// 鸿蒙：停止代理时释放长时任务与常亮
  void _stopOhosKeepAlive() {
    if (!Platforms.isOhos()) {
      return;
    }
    KeepAliveService.stop();
    KeepAliveService.setKeepScreenOn(false);
  }

  @override
  Widget build(BuildContext context) {
    Color primaryColor = Theme.of(context).colorScheme.primary;
    return IconButton(
        tooltip: started ? localizations.stop : localizations.start,
        icon: Icon(started ? Icons.stop : Icons.play_arrow_sharp,
            color: started ? Colors.red : primaryColor, size: widget.size.toDouble()),
        onPressed: () async {
          if (started) {
            if (!widget.serverLaunch) {
              setState(() {
                widget.onStop?.call();
                started = !started;
              });
              return;
            }

            widget.proxyServer.stop().then((value) {
              _stopOhosKeepAlive();
              widget.onStop?.call();
              if (mounted) {
                setState(() {
                  started = !started;
                });
              }
            }).catchError((e) {
              logger.e("stop proxy server failed", error: e);
              if (mounted) {
                Toast.show(localizations.fail, context, duration: 3);
                setState(() {
                  started = false;
                });
              }
            });
          } else {
            start();
          }
        });
  }

  ///启动代理服务器
  Future<void> start() async {
    try {
      if (!widget.serverLaunch) {
        await widget.onStart?.call();
        setState(() {
          started = true;
        });
        // VPN 模式（鸿蒙）：代理服务常驻（startup 自启），此分支同样申请长时任务保活，
        // 否则息屏约 1 分钟后系统会销毁 VPN（PoC 结论 P2）
        _applyOhosKeepAlive();
        return;
      }

      widget.proxyServer.start().then((value) {
        if (mounted) {
          setState(() {
            started = true;
          });
        }
        _applyOhosKeepAlive();
        widget.onStart?.call();
      }).catchError((e) {
        logger.e("启动代理服务器失败", error: e);
        String message = localizations.proxyPortRepeat(widget.proxyServer.port);
        Toast.show(message, context, duration: 3);
      });
    } finally {
      Future.delayed(const Duration(seconds: 5)).then((value) {
        if (!mounted) {
          return;
        }
        if (Platforms.isDesktop()) {
          PCCertChecker.check(context);
        } else if (Platforms.isIOS()) {
          IOSCertChecker.check(context);
        }
      });
    }
  }
}
