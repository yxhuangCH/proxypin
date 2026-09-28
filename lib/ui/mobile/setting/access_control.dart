import 'package:flutter/material.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/ui/component/widgets.dart';

/// 访问控制设置页：客户端 IP 白名单 + 代理鉴权。
/// 手机/鸿蒙端使用；配置存于 [Configuration] 并即时持久化。
class AccessControlPage extends StatefulWidget {
  final Configuration configuration;

  const AccessControlPage({super.key, required this.configuration});

  @override
  State<AccessControlPage> createState() => _AccessControlPageState();
}

class _AccessControlPageState extends State<AccessControlPage> {
  final TextEditingController _ipController = TextEditingController();
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;

  Configuration get configuration => widget.configuration;

  @override
  void initState() {
    super.initState();
    _usernameController = TextEditingController(text: configuration.proxyAuthUsername);
    _passwordController = TextEditingController(text: configuration.proxyAuthPassword);
  }

  @override
  void dispose() {
    _ipController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    bool isCN = Localizations.localeOf(context) == const Locale.fromSubtags(languageCode: 'zh');

    return Scaffold(
        appBar: AppBar(title: Text(isCN ? '访问控制' : 'Access Control', style: const TextStyle(fontSize: 16)), centerTitle: true),
        body: ListView(padding: const EdgeInsets.all(12), children: [
          _section(children: [
            SwitchListTile(
                title: Text(isCN ? 'IP 白名单' : 'IP Whitelist'),
                subtitle: Text(
                    isCN ? '开启后仅白名单内 IP 可连接代理，回环地址始终放行' : 'Only whitelisted IPs can connect when enabled',
                    style: const TextStyle(fontSize: 12)),
                value: configuration.accessControlEnabled,
                onChanged: (value) {
                  configuration.accessControlEnabled = value;
                  configuration.flushConfig();
                  setState(() {});
                }),
            if (configuration.accessControlEnabled) ...[
              Divider(height: 0, thickness: 0.3, color: Theme.of(context).dividerColor),
              Padding(
                  padding: const EdgeInsets.fromLTRB(15, 10, 15, 0),
                  child: Row(children: [
                    Expanded(
                        child: TextField(
                            controller: _ipController,
                            style: const TextStyle(fontSize: 14),
                            decoration: InputDecoration(
                                isDense: true,
                                hintText: isCN ? 'IP 或 CIDR，如 192.168.3.0/24' : 'IP or CIDR, e.g. 192.168.3.0/24',
                                border: const OutlineInputBorder()),
                            onSubmitted: (_) => _addIp())),
                    const SizedBox(width: 8),
                    FilledButton(onPressed: _addIp, child: Text(isCN ? '添加' : 'Add')),
                  ])),
              const SizedBox(height: 8),
              if (configuration.ipWhitelist.isEmpty)
                Padding(
                    padding: const EdgeInsets.all(15),
                    child: Text(isCN ? '白名单为空：仅本机可连接' : 'Whitelist is empty: only loopback allowed',
                        style: TextStyle(fontSize: 12, color: Colors.orange.shade800))),
              for (var ip in configuration.ipWhitelist)
                ListTile(
                    dense: true,
                    title: Text(ip, style: const TextStyle(fontSize: 14)),
                    trailing: IconButton(
                        icon: const Icon(Icons.delete_outline, size: 20),
                        onPressed: () {
                          configuration.ipWhitelist.remove(ip);
                          configuration.flushConfig();
                          setState(() {});
                        })),
              const SizedBox(height: 6),
            ],
          ]),
          const SizedBox(height: 12),
          _section(children: [
            SwitchListTile(
                title: Text(isCN ? '代理鉴权' : 'Proxy Authentication'),
                subtitle: Text(
                    isCN ? '开启后客户端需提供 Basic 账号密码（Proxy-Authorization）' : 'Clients must provide Basic credentials',
                    style: const TextStyle(fontSize: 12)),
                value: configuration.proxyAuthEnabled,
                onChanged: (value) {
                  configuration.proxyAuthEnabled = value;
                  configuration.flushConfig();
                  setState(() {});
                }),
            if (configuration.proxyAuthEnabled) ...[
              Divider(height: 0, thickness: 0.3, color: Theme.of(context).dividerColor),
              Padding(
                  padding: const EdgeInsets.fromLTRB(15, 10, 15, 0),
                  child: TextField(
                      controller: _usernameController,
                      style: const TextStyle(fontSize: 14),
                      decoration: InputDecoration(
                          isDense: true, labelText: isCN ? '用户名' : 'Username', border: const OutlineInputBorder()),
                      onChanged: (value) {
                        configuration.proxyAuthUsername = value;
                        configuration.flushConfig();
                      })),
              Padding(
                  padding: const EdgeInsets.fromLTRB(15, 10, 15, 12),
                  child: TextField(
                      controller: _passwordController,
                      obscureText: true,
                      style: const TextStyle(fontSize: 14),
                      decoration: InputDecoration(
                          isDense: true, labelText: isCN ? '密码' : 'Password', border: const OutlineInputBorder()),
                      onChanged: (value) {
                        configuration.proxyAuthPassword = value;
                        configuration.flushConfig();
                      })),
            ],
          ]),
        ]));
  }

  void _addIp() {
    var ip = _ipController.text.trim();
    if (ip.isEmpty || configuration.ipWhitelist.contains(ip)) return;
    configuration.ipWhitelist.add(ip);
    configuration.flushConfig();
    _ipController.clear();
    setState(() {});
  }

  Widget _section({required List<Widget> children}) => Card(
        color: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
            side: BorderSide(color: Theme.of(context).dividerColor.withValues(alpha: 0.13)),
            borderRadius: BorderRadius.circular(10)),
        child: Column(children: children),
      );
}
