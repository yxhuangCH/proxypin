/*
 * Copyright 2024 Hongen Wang All rights reserved.
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
import 'package:flutter/services.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/native/keep_alive.dart';
import 'package:proxypin/ui/component/toast.dart';
import 'package:proxypin/ui/mobile/setting/access_control.dart';
import 'package:proxypin/utils/ip.dart';

/// 鸿蒙首页引导卡（仅 ohos，调用方用 Platforms.isOhos() 门禁）：
/// 1. 大字展示本机局域网代理地址（IP:端口），一键复制；
/// 2. 被调试设备代理配置教程、CA 证书安装引导入口；
/// 3. 未开启任何访问控制（白名单/鉴权）时显示安全提示横幅，可跳转开启。
class OhosGuideCard extends StatefulWidget {
  final ProxyServer proxyServer;

  const OhosGuideCard({super.key, required this.proxyServer});

  @override
  State<OhosGuideCard> createState() => _OhosGuideCardState();
}

class _OhosGuideCardState extends State<OhosGuideCard> {
  String? _ip;
  bool _expanded = true;
  bool _securityDismissed = false;

  bool get isCN => Localizations.localeOf(context) == const Locale.fromSubtags(languageCode: 'zh');

  String get address => '${_ip ?? '...'}:${widget.proxyServer.port}';

  @override
  void initState() {
    super.initState();
    localIp().then((value) {
      if (mounted) setState(() => _ip = value);
    });
  }

  @override
  Widget build(BuildContext context) {
    var config = widget.proxyServer.configuration;
    bool unprotected = !config.accessControlEnabled && !config.proxyAuthEnabled;
    var primary = Theme.of(context).colorScheme.primary;

    return Card(
        margin: const EdgeInsets.fromLTRB(8, 4, 8, 2),
        elevation: 0,
        shape: RoundedRectangleBorder(
            side: BorderSide(color: Theme.of(context).dividerColor.withValues(alpha: 0.13)),
            borderRadius: BorderRadius.circular(10)),
        child: Column(children: [
          InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(children: [
                    Icon(Icons.wifi, color: primary),
                    const SizedBox(width: 10),
                    Expanded(
                        child:
                            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(isCN ? '本机代理地址（被调试设备填写此地址）' : 'Proxy address (fill in on the debugged device)',
                              style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                          Text(address, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600)),
                        ])),
                    IconButton(
                        tooltip: isCN ? '复制' : 'Copy',
                        icon: const Icon(Icons.copy, size: 20),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: address));
                          Toast.show(isCN ? '已复制 $address' : 'Copied $address', context);
                        }),
                    Icon(_expanded ? Icons.expand_less : Icons.expand_more, color: Colors.grey),
                  ]))),
          if (_expanded) ...[
            Divider(height: 0, thickness: 0.3, color: Theme.of(context).dividerColor.withValues(alpha: 0.22)),
            Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _step(isCN ? '① 被调试设备与本机连接同一 WiFi' : '1. Connect the debugged device to the same WiFi'),
                  _step(isCN ? '② 在其 WiFi 代理设置中填写上方地址' : '2. Fill the address above in its WiFi proxy settings'),
                  _step(isCN
                      ? '③ 配好代理后浏览器访问 http://proxy.pin/ssl 下载并安装 CA 证书（HTTPS 抓包需要）'
                      : '3. With proxy set, visit http://proxy.pin/ssl in browser to download and install the CA certificate (required for HTTPS)'),
                ])),
            Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                child: Row(children: [
                  TextButton.icon(
                      icon: const Icon(Icons.settings_ethernet, size: 18),
                      label: Text(isCN ? '代理配置教程' : 'Proxy setup guide'),
                      onPressed: _showProxyTutorial),
                  TextButton.icon(
                      icon: const Icon(Icons.https, size: 18),
                      label: Text(isCN ? '证书安装引导' : 'CA install guide'),
                      onPressed: _showCertTutorial),
                ])),
            // 后台保活状态（详见 harmony/docs/06 §3.4：UI 明示服务可中断）
            ValueListenableBuilder(
                valueListenable: KeepAliveService.status,
                builder: (context, running, _) => Padding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
                    child: Row(children: [
                      Icon(running ? Icons.check_circle_outline : Icons.info_outline,
                          size: 15, color: running ? Colors.green.shade700 : Colors.grey.shade600),
                      const SizedBox(width: 5),
                      Expanded(
                          child: Text(
                              running
                                  ? (isCN ? '后台保活：长时任务已开启，退后台仍可能被系统限制' : 'Keep-alive: continuous task on, may still be limited in background')
                                  : (isCN ? '后台保活：未开启，退后台/熄屏后代理可能中断' : 'Keep-alive: off, proxy may stop in background'),
                              style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700))),
                    ]))),
          ],
          if (unprotected && !_securityDismissed) ...[
            Divider(height: 0, thickness: 0.3, color: Theme.of(context).dividerColor.withValues(alpha: 0.22)),
            Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
                child: Row(children: [
                  Icon(Icons.warning_amber_rounded, size: 20, color: Colors.orange.shade800),
                  const SizedBox(width: 6),
                  Expanded(
                      child: Text(
                          isCN ? '代理对局域网所有设备开放，建议开启访问控制' : 'Proxy is open to the whole LAN, enable access control',
                          style: TextStyle(fontSize: 12, color: Colors.orange.shade800))),
                  TextButton(
                      child: Text(isCN ? '去开启' : 'Enable'),
                      onPressed: () {
                        Navigator.of(context)
                            .push(MaterialPageRoute(
                                builder: (_) => AccessControlPage(configuration: widget.proxyServer.configuration)))
                            .then((_) {
                          if (mounted) setState(() {});
                        });
                      }),
                  IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => setState(() => _securityDismissed = true)),
                ])),
          ],
        ]));
  }

  Widget _step(String text) {
    return Padding(
        padding: const EdgeInsets.only(bottom: 3),
        child: Text(text, style: const TextStyle(fontSize: 12.5, height: 1.35)));
  }

  void _showProxyTutorial() {
    _showTutorial(
        isCN ? '被调试设备代理配置' : 'Proxy setup on the debugged device',
        isCN
            ? '1. 被调试设备连接与本机相同的 WiFi 网络；\n\n'
                '2. 打开该设备的 WiFi 详情 → 代理 → 手动：\n'
                '   服务器/主机名：${_ip ?? ''}\n'
                '   端口：${widget.proxyServer.port}\n\n'
                '3. 保存后，该设备的 HTTP(S) 流量即会经过本机，可在抓包列表查看。\n\n'
                '提示：HarmonyOS 设备在 设置 → WLAN → 点击已连接网络 → 代理 中设置。'
            : '1. Connect the debugged device to the same WiFi network as this device;\n\n'
                '2. Open its WiFi details → Proxy → Manual:\n'
                '   Host: ${_ip ?? ''}\n'
                '   Port: ${widget.proxyServer.port}\n\n'
                '3. After saving, HTTP(S) traffic of that device will go through this device.');
  }

  void _showCertTutorial() {
    _showTutorial(
        isCN ? 'CA 证书安装（HTTPS 抓包）' : 'CA certificate (for HTTPS)',
        isCN
            ? 'HTTPS 抓包需要在被调试设备上安装 ProxyPin CA 证书：\n\n'
                '1. 先在被调试设备上配好代理（见代理配置教程）；\n'
                '2. 在被调试设备浏览器访问：http://proxy.pin/ssl\n'
                '3. 下载 CA 证书并安装：\n'
                '   HarmonyOS：设置 → 安全 → 更多安全设置 → 加密和凭据 → 从存储设备安装；\n'
                '   Android：设置 → 安全 → 加密与凭据 → 安装证书 → CA 证书。\n\n'
                '注意：部分应用校验证书（SSL Pinning），需配合脚本或 Frida 绕过。'
            : 'HTTPS capture requires installing the ProxyPin CA on the debugged device:\n\n'
                '1. Set up the proxy first (see proxy setup guide);\n'
                '2. Visit http://proxy.pin/ssl in the device browser;\n'
                '3. Download and install the CA certificate in system settings.');
  }

  void _showTutorial(String title, String content) {
    showDialog(
        context: context,
        builder: (context) => AlertDialog(
                scrollable: true,
                title: Text(title, style: const TextStyle(fontSize: 16)),
                content: SelectableText(content),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.of(context).pop(), child: Text(isCN ? '关闭' : 'Close')),
                ]));
  }
}
