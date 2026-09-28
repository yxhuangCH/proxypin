import 'package:flutter/material.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/ui/component/widgets.dart';

/// 桌面端访问控制设置：客户端 IP 白名单 + 代理鉴权。
/// 与手机端 AccessControlPage 共用 [Configuration] 配置项。
class AccessControlDialog extends StatefulWidget {
  final Configuration configuration;

  const AccessControlDialog({super.key, required this.configuration});

  @override
  State<StatefulWidget> createState() => _AccessControlDialogState();
}

class _AccessControlDialogState extends State<AccessControlDialog> {
  final TextEditingController _ipController = TextEditingController();

  Configuration get configuration => widget.configuration;

  @override
  void dispose() {
    _ipController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    bool isCN = Localizations.localeOf(context) == const Locale.fromSubtags(languageCode: 'zh');

    return AlertDialog(
        scrollable: true,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.0)),
        title: Text(isCN ? '访问控制' : 'Access Control', style: const TextStyle(fontSize: 15)),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(isCN ? '关闭' : 'Close')),
        ],
        content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(isCN ? 'IP 白名单（仅白名单内 IP 可连接）' : 'IP whitelist only')),
                SwitchWidget(
                    value: configuration.accessControlEnabled,
                    scale: 0.85,
                    onChanged: (val) {
                      configuration.accessControlEnabled = val;
                      configuration.flushConfig();
                      setState(() {});
                    }),
              ]),
              if (configuration.accessControlEnabled) ...[
                const SizedBox(height: 6),
                Text(isCN ? '支持 IP 或 CIDR，如 192.168.3.0/24；回环地址始终放行' : 'IP or CIDR, e.g. 192.168.3.0/24',
                    style: const TextStyle(fontSize: 11, color: Colors.grey)),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                      child: TextField(
                          controller: _ipController,
                          style: const TextStyle(fontSize: 13),
                          decoration: const InputDecoration(
                              isDense: true, contentPadding: EdgeInsets.all(8), border: OutlineInputBorder()),
                          onSubmitted: (_) => _addIp())),
                  const SizedBox(width: 8),
                  TextButton(onPressed: _addIp, child: Text(isCN ? '添加' : 'Add')),
                ]),
                const SizedBox(height: 6),
                if (configuration.ipWhitelist.isEmpty)
                  Text(isCN ? '白名单为空：仅本机可连接' : 'Whitelist empty: loopback only',
                      style: TextStyle(fontSize: 12, color: Colors.orange.shade800)),
                ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 150),
                    child: ListView(shrinkWrap: true, children: [
                      for (var ip in configuration.ipWhitelist)
                        Row(children: [
                          Expanded(child: Text(ip, style: const TextStyle(fontSize: 13))),
                          IconButton(
                              icon: const Icon(Icons.delete_outline, size: 18),
                              onPressed: () {
                                configuration.ipWhitelist.remove(ip);
                                configuration.flushConfig();
                                setState(() {});
                              }),
                        ]),
                    ])),
              ],
              const Divider(height: 25),
              Row(children: [
                Expanded(child: Text(isCN ? '代理鉴权（Basic）' : 'Proxy authentication (Basic)')),
                SwitchWidget(
                    value: configuration.proxyAuthEnabled,
                    scale: 0.85,
                    onChanged: (val) {
                      configuration.proxyAuthEnabled = val;
                      configuration.flushConfig();
                      setState(() {});
                    }),
              ]),
              if (configuration.proxyAuthEnabled) ...[
                const SizedBox(height: 8),
                SizedBox(
                    height: 36,
                    child: Row(children: [
                      SizedBox(width: isCN ? 65 : 85, child: Text(isCN ? '用户名：' : 'Username:')),
                      Expanded(
                          child: TextFormField(
                        initialValue: configuration.proxyAuthUsername,
                        onChanged: (val) {
                          configuration.proxyAuthUsername = val;
                          configuration.flushConfig();
                        },
                        decoration: const InputDecoration(
                            contentPadding: EdgeInsets.symmetric(horizontal: 8), border: OutlineInputBorder()),
                      ))
                    ])),
                const SizedBox(height: 10),
                SizedBox(
                    height: 36,
                    child: Row(children: [
                      SizedBox(width: isCN ? 65 : 85, child: Text(isCN ? '密码：' : 'Password:')),
                      Expanded(
                          child: TextFormField(
                        initialValue: configuration.proxyAuthPassword,
                        obscureText: true,
                        onChanged: (val) {
                          configuration.proxyAuthPassword = val;
                          configuration.flushConfig();
                        },
                        decoration: const InputDecoration(
                            contentPadding: EdgeInsets.symmetric(horizontal: 8), border: OutlineInputBorder()),
                      ))
                    ])),
              ],
            ])));
  }

  void _addIp() {
    var ip = _ipController.text.trim();
    if (ip.isEmpty || configuration.ipWhitelist.contains(ip)) return;
    configuration.ipWhitelist.add(ip);
    configuration.flushConfig();
    _ipController.clear();
    setState(() {});
  }
}
