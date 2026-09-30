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
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/native/installed_apps.dart';
import 'package:proxypin/native/vpn.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/ui/component/widgets.dart';
import 'package:proxypin/ui/mobile/setting/ohos_app_picker.dart';
import 'package:proxypin/ui/mobile/setting/ohos_preset_apps.dart';
import 'package:proxypin/utils/platform.dart';
import 'package:proxypin/utils/task.dart';

/// 鸿蒙 trustedApplications/blockedApplications 各自的条目上限（系统限制）
const int ohosAppListLimit = 256;

/// 鸿蒙白/黑名单互斥提示。
///
/// 鸿蒙 `VpnConfig` 的 trustedApplications 与 blockedApplications 物理互斥（Android 是
/// 「白名单优先」的叠加语义），配置由 ProxyPinVpnAbility 按「白名单非空则只传白名单」
/// 处理，故此处仅提示用户，不做任何配置改写。
Widget buildMutualExclusionBanner(BuildContext context, VoidCallback onDismiss, String content) {
  bool isCN = Localizations.localeOf(context) == const Locale.fromSubtags(languageCode: 'zh');
  return MaterialBanner(
    leading: const Icon(Icons.info_outline, size: 20),
    content: Text(content, style: const TextStyle(fontSize: 13)),
    actions: [
      TextButton(onPressed: onDismiss, child: Text(isCN ? '知道了' : 'Got it')),
    ],
  );
}

///应用白名单 目前只支持安卓 ios没办法获取安装的列表
///@author wang
class AppWhitelist extends StatefulWidget {
  final ProxyServer proxyServer;

  const AppWhitelist({super.key, required this.proxyServer});

  @override
  State<AppWhitelist> createState() => _AppWhitelistState();
}

class _AppWhitelistState extends State<AppWhitelist> {
  late Configuration configuration;

  bool changed = false;
  bool isLoading = true;
  bool bannerDismissed = false;
  bool _loaded = false;
  List<AppInfo> appInfoList = [];

  AppLocalizations get localizations => AppLocalizations.of(context)!;

  @override
  void initState() {
    super.initState();
    configuration = widget.proxyServer.configuration;
  }

  /// 不在 initState 里加载：_loadApps 要先读 Localizations，而此时依赖还没建立，
  /// 抛出的异常被 async 函数吞掉，isLoading 永远为 true（真机表现为页面一直转圈）。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _loadApps();
    }
  }

  void _loadApps() async {
    bool isCN = Localizations.localeOf(context) == const Locale.fromSubtags(languageCode: 'zh');
    // 鸿蒙无法查询应用信息：用预置清单反查显示名，查不到回落包名。
    // 关键是不能走下面的 catchError 分支——那会把条目标成 inValid，
    // 用户点「清除失效应用」就会把整个名单误删。
    if (Platforms.isOhos()) {
      setState(() {
        appInfoList =
            configuration.appWhitelist.map((e) => AppInfo(name: ohosPresetAppName(e) ?? e, packageName: e)).toList();
        isLoading = false;
      });
      return;
    }
    var futures = <Future<AppInfo>>[];
    for (var element in configuration.appWhitelist) {
      futures.add(InstalledApps.getAppInfo(element).catchError((e) {
        return AppInfo(name: isCN ? "未知应用" : "Unknown app", packageName: element, inValid: true);
      }));
    }
    var list = await Future.wait(futures);
    if (mounted) {
      setState(() {
        appInfoList = list;
        isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    if (changed) {
      configuration.flushConfig();
      if (Vpn.isVpnStarted) {
        Vpn.restartVpn("127.0.0.1", widget.proxyServer.port, configuration);
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    bool isCN = Localizations.localeOf(context) == const Locale.fromSubtags(languageCode: 'zh');

    return Scaffold(
        appBar: AppBar(
          title: Text(localizations.appWhitelist, style: const TextStyle(fontSize: 16)),
          actions: [
            IconButton(
              icon: const Icon(Icons.add),
              onPressed: () async {
                if (Platforms.isOhos() && configuration.appWhitelist.length >= ohosAppListLimit) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(
                          isCN ? '鸿蒙白名单最多 $ohosAppListLimit 个应用' : 'HarmonyOS allows at most $ohosAppListLimit apps')));
                  return;
                }
                final packageName = await Navigator.of(context).push(MaterialPageRoute(
                  builder: (context) => Platforms.supportInstalledApps()
                      ? InstalledAppsWidget(addedList: appInfoList)
                      : OhosAppPickerWidget(addedList: appInfoList),
                ));
                if (packageName != null && !configuration.appWhitelist.contains(packageName)) {
                  configuration.appWhitelist.add(packageName);
                  changed = true;
                  bool isCN = Localizations.localeOf(context) == const Locale.fromSubtags(languageCode: 'zh');
                  var newApp = Platforms.isOhos()
                      ? AppInfo(name: ohosPresetAppName(packageName) ?? packageName, packageName: packageName)
                      : await InstalledApps.getAppInfo(packageName).catchError((e) {
                          return AppInfo(name: isCN ? "未知应用" : "Unknown app", packageName: packageName, inValid: true);
                        });
                  if (mounted) {
                    setState(() => appInfoList.add(newApp));
                  }
                }
              },
            ),
            IconButton(
              tooltip: isCN ? '清除失效应用' : 'clear invalid apps',
              onPressed: () {
                if (configuration.appWhitelist.isEmpty) return;
                setState(() {
                  appInfoList.removeWhere((appInfo) {
                    if (appInfo.inValid == true) {
                      configuration.appWhitelist.remove(appInfo.packageName);
                      return true;
                    }
                    return false;
                  });
                  changed = true;
                });
              },
              icon: const Icon(Icons.cleaning_services_outlined),
            ),
          ],
        ),
        body: Column(children: [
          if (Platforms.isOhos() && !bannerDismissed && (configuration.appBlacklist?.isNotEmpty ?? false))
            buildMutualExclusionBanner(
                context,
                () => setState(() => bannerDismissed = true),
                isCN
                    ? '鸿蒙系统限制：白名单与黑名单互斥。当前黑名单已有 ${configuration.appBlacklist!.length} 个应用，'
                        '一旦添加白名单，黑名单将不再生效'
                    : 'HarmonyOS limits: whitelist and blacklist are mutually exclusive. '
                        'The blacklist (${configuration.appBlacklist!.length} apps) will be ignored once the whitelist is non-empty'),
          const SizedBox(height: 5),
          SwitchWidget(
              value: configuration.appWhitelistEnabled,
              title: localizations.enable,
              subtitle: localizations.appWhitelistDescribe,
              onChanged: (val) {
                changed = true;
                configuration.appWhitelistEnabled = val;
                configuration.flushConfig();
              }),
          const SizedBox(height: 5),
          Expanded(
              child: isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : appInfoList.isEmpty
                      ? Center(
                          child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 15),
                              child: Text(
                                  isCN
                                      ? "未设置白名单应用时会对所有应用抓包"
                                      : "When no whitelist application is set, all applications will be captured",
                                  style: const TextStyle(color: Colors.grey))),
                        )
                      : ListView.builder(
                          itemCount: appInfoList.length,
                          itemBuilder: (BuildContext context, int index) {
                            AppInfo appInfo = appInfoList[index];
                            return ListTile(
                              leading:
                                  appInfo.icon == null ? const Icon(Icons.question_mark) : Image.memory(appInfo.icon!),
                              title: Text(appInfo.name ?? ""),
                              subtitle: Text(appInfo.packageName ?? ""),
                              trailing: IconButton(
                                icon: const Icon(Icons.delete),
                                onPressed: () {
                                  setState(() {
                                    configuration.appWhitelist.remove(appInfo.packageName);
                                    appInfoList.remove(appInfo);
                                    changed = true;
                                  });
                                },
                              ),
                            );
                          })),
        ]));
  }
}

class AppBlacklist extends StatefulWidget {
  final ProxyServer proxyServer;

  const AppBlacklist({super.key, required this.proxyServer});

  @override
  State<AppBlacklist> createState() => _AppBlacklistState();
}

class _AppBlacklistState extends State<AppBlacklist> {
  late Configuration configuration;

  bool changed = false;
  bool isLoading = true;
  bool bannerDismissed = false;
  bool _loaded = false;
  List<AppInfo> appInfoList = [];

  AppLocalizations get localizations => AppLocalizations.of(context)!;

  @override
  void initState() {
    super.initState();
    configuration = widget.proxyServer.configuration;
  }

  /// 同 AppWhitelist：见其 didChangeDependencies 注释。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _loadApps();
    }
  }

  void _loadApps() async {
    bool isCN = Localizations.localeOf(context) == const Locale.fromSubtags(languageCode: 'zh');
    // 同 AppWhitelist：鸿蒙不走 getAppInfo，避免条目被误标 inValid
    if (Platforms.isOhos()) {
      setState(() {
        appInfoList = (configuration.appBlacklist ?? [])
            .map((e) => AppInfo(name: ohosPresetAppName(e) ?? e, packageName: e))
            .toList();
        isLoading = false;
      });
      return;
    }
    var futures = <Future<AppInfo>>[];
    for (var element in configuration.appBlacklist ?? []) {
      futures.add(InstalledApps.getAppInfo(element).catchError((e) {
        return AppInfo(name: isCN ? "未知应用" : "Unknown app", packageName: element, inValid: true);
      }));
    }
    var list = await Future.wait(futures);
    if (mounted) {
      setState(() {
        appInfoList = list;
        isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    if (changed) {
      configuration.flushConfig();
      if (Vpn.isVpnStarted) {
        Vpn.restartVpn("127.0.0.1", widget.proxyServer.port, configuration);
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    bool isCN = Localizations.localeOf(context) == const Locale.fromSubtags(languageCode: 'zh');

    return Scaffold(
      appBar: AppBar(
        title: Text(localizations.appBlacklist, style: const TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () async {
              if (Platforms.isOhos() && (configuration.appBlacklist?.length ?? 0) >= ohosAppListLimit) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(
                        isCN ? '鸿蒙黑名单最多 $ohosAppListLimit 个应用' : 'HarmonyOS allows at most $ohosAppListLimit apps')));
                return;
              }
              final packageName = await Navigator.of(context).push(MaterialPageRoute(
                builder: (context) => Platforms.supportInstalledApps()
                    ? InstalledAppsWidget(addedList: appInfoList)
                    : OhosAppPickerWidget(addedList: appInfoList),
              ));
              if (packageName != null && configuration.appBlacklist?.contains(packageName) != true) {
                configuration.appBlacklist ??= [];
                configuration.appBlacklist?.add(packageName);
                changed = true;
                bool isCN = Localizations.localeOf(context) == const Locale.fromSubtags(languageCode: 'zh');
                var newApp = Platforms.isOhos()
                    ? AppInfo(name: ohosPresetAppName(packageName) ?? packageName, packageName: packageName)
                    : await InstalledApps.getAppInfo(packageName).catchError((e) {
                        return AppInfo(name: isCN ? "未知应用" : "Unknown app", packageName: packageName, inValid: true);
                      });
                if (mounted) {
                  setState(() => appInfoList.add(newApp));
                }
              }
            },
          ),
          IconButton(
            tooltip: isCN ? '清除失效应用' : 'clear invalid apps',
            onPressed: () {
              if (configuration.appBlacklist?.isEmpty == true) return;
              setState(() {
                appInfoList.removeWhere((appInfo) {
                  if (appInfo.inValid == true) {
                    configuration.appBlacklist?.remove(appInfo.packageName);
                    return true;
                  }
                  return false;
                });
                changed = true;
              });
            },
            icon: const Icon(Icons.cleaning_services_outlined),
          ),
        ],
      ),
      body: Column(children: [
        if (Platforms.isOhos() && !bannerDismissed && configuration.appWhitelist.isNotEmpty)
          buildMutualExclusionBanner(
              context,
              () => setState(() => bannerDismissed = true),
              isCN
                  ? '鸿蒙系统限制：白名单与黑名单互斥。当前白名单已有 ${configuration.appWhitelist.length} 个应用，'
                      '黑名单不会生效（需先清空白名单）'
                  : 'HarmonyOS limits: whitelist and blacklist are mutually exclusive. '
                      'The blacklist has no effect while the whitelist (${configuration.appWhitelist.length} apps) is non-empty'),
        Expanded(
            child: isLoading
                ? const Center(child: CircularProgressIndicator())
                : appInfoList.isEmpty
                    ? Center(
                        child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 15),
                            child: Text(localizations.emptyData, style: const TextStyle(color: Colors.grey))),
                      )
                    : ListView.builder(
                        itemCount: appInfoList.length,
                        itemBuilder: (BuildContext context, int index) {
                          AppInfo appInfo = appInfoList[index];
                          return ListTile(
                            leading:
                                appInfo.icon == null ? const Icon(Icons.question_mark) : Image.memory(appInfo.icon!),
                            title: Text(appInfo.name ?? ""),
                            subtitle: Text(appInfo.packageName ?? ""),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete),
                              onPressed: () {
                                setState(() {
                                  configuration.appBlacklist?.remove(appInfo.packageName);
                                  appInfoList.remove(appInfo);
                                  changed = true;
                                });
                              },
                            ),
                          );
                        })),
      ]),
    );
  }
}

///已安装的app列表
class InstalledAppsWidget extends StatefulWidget {
  const InstalledAppsWidget({
    super.key,
    required this.addedList,
  });

  final List<AppInfo> addedList;

  @override
  State<InstalledAppsWidget> createState() => _InstalledAppsWidgetState();
}

class _InstalledAppsWidgetState extends State<InstalledAppsWidget> {
  static List<AppInfo>? apps;
  static bool includeSystemApps = false;
  static final Map<String, Future<AppInfo>> _iconFutureCache = {};

  RxBool loading = false.obs;

  String? keyword;

  @override
  void initState() {
    super.initState();
    DelayedTask().cancel("InstalledAppsWidget_release");
    if (apps != null) {
      return;
    }
    refreshApps();
  }

  @override
  void dispose() {
    DelayedTask().debounce("InstalledAppsWidget_release", const Duration(seconds: 60), () {
      apps = null;
      includeSystemApps = false;
      _iconFutureCache.clear();
    });
    super.dispose();
  }

  void refreshApps() async {
    try {
      loading.value = true;
      apps = await InstalledApps.getInstalledApps(false, includeSystemApps: includeSystemApps);
    } finally {
      loading.value = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    bool isCN = Localizations.localeOf(context) == const Locale.fromSubtags(languageCode: 'zh');

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          decoration: InputDecoration(
            hintText: isCN ? "请输入应用名或包名" : "Please enter the application or package name",
            border: InputBorder.none,
            hintStyle: TextStyle(color: Colors.grey.shade500),
            suffixIcon: IconButton(
              color: includeSystemApps ? Theme.of(context).colorScheme.primary : null,
              icon: const Icon(Icons.visibility_outlined),
              tooltip: isCN ? "显示系统应用" : "Show system apps",
              onPressed: () {
                setState(() {
                  includeSystemApps = !includeSystemApps;
                });
                refreshApps();
              },
            ),
          ),
          onChanged: (String value) {
            keyword = value.toLowerCase();
            setState(() {});
          },
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          refreshApps();
        },
        child: Obx(() => loading.value
            ? const Center(
                child: CircularProgressIndicator(),
              )
            : buildAppListView()),
      ),
    );
  }

  ListView buildAppListView() {
    if (apps == null) {
      return ListView();
    }
    List<AppInfo> appInfoList = apps!;
    appInfoList = appInfoList.toSet().difference(widget.addedList.toSet()).toList();
    if (keyword != null && keyword!.trim().isNotEmpty) {
      appInfoList = appInfoList
          .where((element) =>
              element.name!.toLowerCase().contains(keyword!) || element.packageName!.toLowerCase().contains(keyword!))
          .toList();
    }

    return ListView.builder(
        itemCount: appInfoList.length,
        itemBuilder: (BuildContext context, int index) {
          AppInfo appInfo = appInfoList[index];
          return ListTile(
            leading: _buildAppIcon(appInfo),
            title: Text(appInfo.name ?? ""),
            subtitle: Text(appInfo.packageName ?? ""),
            onTap: () async {
              Navigator.of(context).pop(appInfo.packageName);
            },
          );
        });
  }

  Widget _buildAppIcon(AppInfo appInfo) {
    final icon = appInfo.icon;
    if (icon != null && icon.isNotEmpty) {
      return Image.memory(icon);
    }

    final packageName = appInfo.packageName;
    if (packageName == null || packageName.isEmpty) {
      return const Icon(Icons.question_mark);
    }

    final future = _iconFutureCache.putIfAbsent(
      packageName,
      () => InstalledApps.getAppInfo(packageName),
    );

    return FutureBuilder<AppInfo>(
      future: future,
      builder: (BuildContext context, AsyncSnapshot<AppInfo> snapshot) {
        final loadedIcon = snapshot.data?.icon;
        if (loadedIcon != null && loadedIcon.isNotEmpty) {
          return Image.memory(loadedIcon);
        }

        if (snapshot.hasError) {
          return const Icon(Icons.question_mark);
        }

        return const SizedBox(
          width: 24,
          height: 24,
          child: Center(
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      },
    );
  }
}
