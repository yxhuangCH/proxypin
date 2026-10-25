import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/util/random.dart';
import 'package:proxypin/ui/component/toast.dart';
import 'package:proxypin/ui/mobile/setting/access_control.dart';
import 'package:proxypin/utils/ip.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Web 控制台设置：浏览器访问手机抓包数据。
///
/// 控制台默认关闭，开启后生成随机 token，访问地址形如
/// `http://手机IP:9099/console?token=...`。
class WebConsoleSettingPage extends StatefulWidget {
  final ProxyServer proxyServer;

  const WebConsoleSettingPage({super.key, required this.proxyServer});

  @override
  State<WebConsoleSettingPage> createState() => _WebConsoleSettingPageState();
}

class _WebConsoleSettingPageState extends State<WebConsoleSettingPage> {
  Configuration get configuration => widget.proxyServer.configuration;

  bool get _isCN => Localizations.localeOf(context) == const Locale.fromSubtags(languageCode: 'zh');

  String? _localIp;

  @override
  void initState() {
    super.initState();
    _refreshIp();
  }

  Future<void> _refreshIp() async {
    try {
      var ip = await localIp();
      if (mounted) {
        setState(() => _localIp = ip);
      }
    } catch (_) {
      // 无网络接口时保持 null，地址栏显示 127.0.0.1
    }
  }

  String get _host => _localIp ?? '127.0.0.1';

  String get _consoleUrl => 'http://$_host:${widget.proxyServer.port}/console?token=${configuration.webConsoleToken}';

  void _toggle(bool enabled) {
    configuration.webConsoleEnabled = enabled;
    if (enabled) {
      configuration.ensureWebConsoleToken();
      _refreshIp();
    }
    configuration.flushConfig();
    setState(() {});
  }

  void _resetToken() {
    showDialog(
        context: context,
        builder: (context) => AlertDialog(
              title: Text(_isCN ? '重置 token' : 'Reset token', style: const TextStyle(fontSize: 16)),
              content: Text(_isCN ? '重置后，之前打开的页面和保存的地址将立即失效。' : 'Previously opened pages and saved URLs will stop working.'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: Text(_isCN ? '取消' : 'Cancel')),
                FilledButton(
                    onPressed: () {
                      configuration.webConsoleToken = RandomUtil.randomString(32);
                      configuration.flushConfig();
                      Navigator.pop(context);
                      setState(() {});
                    },
                    child: Text(_isCN ? '重置' : 'Reset')),
              ],
            ));
  }

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    Toast.show(AppLocalizations.of(context)!.copied, context);
  }

  void _showQrCode() {
    showDialog(
        context: context,
        builder: (context) => AlertDialog(
              title: Text(_isCN ? '扫码打开控制台' : 'Open console', style: const TextStyle(fontSize: 16)),
              content: SizedBox(
                  width: 260,
                  height: 280,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    QrImageView(backgroundColor: Colors.white, data: _consoleUrl, version: QrVersions.auto, size: 200),
                    const SizedBox(height: 10),
                    SelectableText(_host, style: const TextStyle(fontSize: 12)),
                    const SizedBox(height: 6),
                    Text(_isCN ? '手机与电脑需在同一可互通的局域网' : 'Phone and computer must be on the same reachable LAN',
                        style: const TextStyle(fontSize: 12), textAlign: TextAlign.center),
                  ])),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: Text(_isCN ? '关闭' : 'Close')),
              ],
            ));
  }

  @override
  Widget build(BuildContext context) {
    final dividerColor = Theme.of(context).dividerColor.withValues(alpha: 0.22);
    final warningColor = Colors.orange.shade800;

    Widget section(List<Widget> tiles) => Card(
          color: Colors.transparent,
          elevation: 0,
          shape: RoundedRectangleBorder(
              side: BorderSide(color: Theme.of(context).dividerColor.withValues(alpha: 0.13)),
              borderRadius: BorderRadius.circular(10)),
          child: Column(children: tiles),
        );

    return Scaffold(
        appBar: AppBar(
            title: Text(_isCN ? 'Web 控制台' : 'Web Console', style: const TextStyle(fontSize: 16)), centerTitle: true),
        body: ListView(padding: const EdgeInsets.all(12), children: [
          section([
            SwitchListTile(
                title: Text(_isCN ? '启用 Web 控制台' : 'Enable Web Console'),
                subtitle: Text(
                    _isCN ? '浏览器访问手机抓包数据，默认关闭' : 'Browse captured traffic from a browser (off by default)',
                    style: const TextStyle(fontSize: 12)),
                value: configuration.webConsoleEnabled,
                onChanged: _toggle),
            if (configuration.webConsoleEnabled) ...[
              Divider(height: 0, thickness: 0.3, color: dividerColor),
              Padding(
                  padding: const EdgeInsets.fromLTRB(15, 12, 15, 0),
                  child: Text(
                      _isCN
                          ? '仅在公司内网使用：抓包内容、重发与响应改写能力都不能暴露给同网段无关人员。'
                          : 'Company intranet only: captures, replay and rewrite must not be exposed to others on the LAN.',
                      style: TextStyle(fontSize: 12, color: warningColor))),
              ListTile(
                  title: Text(_isCN ? '访问地址' : 'Console URL', style: const TextStyle(fontSize: 14)),
                  subtitle: SelectableText(_consoleUrl, style: const TextStyle(fontSize: 12)),
                  trailing: IconButton(
                      icon: const Icon(Icons.copy, size: 20),
                      tooltip: _isCN ? '复制链接' : 'Copy link',
                      onPressed: () => _copy(_consoleUrl))),
              ListTile(
                  title: Text(_isCN ? 'Token' : 'Token', style: const TextStyle(fontSize: 14)),
                  subtitle: SelectableText(configuration.webConsoleToken, style: const TextStyle(fontSize: 12)),
                  trailing: IconButton(
                      icon: const Icon(Icons.copy, size: 20),
                      tooltip: _isCN ? '复制 token' : 'Copy token',
                      onPressed: () => _copy(configuration.webConsoleToken))),
              Padding(
                  padding: const EdgeInsets.fromLTRB(15, 0, 15, 10),
                  child: Wrap(spacing: 8, runSpacing: 8, children: [
                    OutlinedButton.icon(
                        onPressed: _showQrCode,
                        icon: const Icon(Icons.qr_code, size: 18),
                        label: Text(_isCN ? '二维码' : 'QR code')),
                    OutlinedButton.icon(
                        onPressed: _resetToken,
                        icon: const Icon(Icons.refresh, size: 18),
                        label: Text(_isCN ? '重置 token' : 'Reset token')),
                  ])),
              if (!widget.proxyServer.isRunning)
                Padding(
                    padding: const EdgeInsets.fromLTRB(15, 0, 15, 12),
                    child: Text(_isCN ? '代理服务未运行，控制台当前不可用。' : 'Proxy server is not running; console unavailable.',
                        style: TextStyle(fontSize: 12, color: warningColor))),
              Divider(height: 0, thickness: 0.3, color: dividerColor),
              ListTile(
                  title: Text(_isCN ? '访问控制' : 'Access Control', style: const TextStyle(fontSize: 14)),
                  subtitle: Text(_isCN ? 'IP 白名单与代理鉴权' : 'IP whitelist and proxy authentication',
                      style: const TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                  onTap: () => Navigator.push(
                      context, MaterialPageRoute(builder: (_) => AccessControlPage(configuration: configuration)))),
            ],
          ]),
          const SizedBox(height: 12),
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                  _isCN
                      ? '提示：公司电脑只需浏览器。把 HTTP/HTTPS 代理指向手机IP:9099，再打开上面的控制台地址；'
                          'HTTPS 解密需要目标端信任 ProxyPin CA。手机灭屏或代理停止后，控制台同时不可用。'
                      : 'Tip: the company computer only needs a browser. Point its HTTP/HTTPS proxy to phoneIP:9099, '
                          'then open the console URL. HTTPS decryption requires trusting the ProxyPin CA.',
                  style: const TextStyle(fontSize: 12, color: Colors.grey))),
        ]));
  }
}
