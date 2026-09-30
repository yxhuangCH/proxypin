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
import 'package:proxypin/native/installed_apps.dart';
import 'package:proxypin/ui/mobile/setting/ohos_preset_apps.dart';

/// 鸿蒙应用选择页（白名单/黑名单共用的降级方案）
///
/// 鸿蒙三方应用无法枚举已安装应用，改为「手动输入 bundleName + 预置清单」。
/// 返回值协议与 [InstalledAppsWidget] 一致：`Navigator.pop(packageName)`，
/// 调用方（AppWhitelist/AppBlacklist）逻辑无需区分平台。
class OhosAppPickerWidget extends StatefulWidget {
  const OhosAppPickerWidget({super.key, required this.addedList});

  final List<AppInfo> addedList;

  @override
  State<OhosAppPickerWidget> createState() => _OhosAppPickerWidgetState();
}

class _OhosAppPickerWidgetState extends State<OhosAppPickerWidget> {
  /// bundleName 格式校验：字母开头，允许字母/数字/下划线/点，至少两段
  /// （单段包名在鸿蒙上不合法，如 "com" 或 "browser"）
  static final RegExp _bundlePattern = RegExp(r'^[a-zA-Z][\w]*(\.[a-zA-Z][\w]*)+$');

  final TextEditingController _controller = TextEditingController();
  String? _error;
  String? _keyword;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submitManual() {
    final input = _controller.text.trim();
    if (input.isEmpty) {
      return;
    }
    if (!_bundlePattern.hasMatch(input)) {
      setState(() {
        _error = _isCN ? '包名格式不正确，示例：com.example.app' : 'Invalid bundle name, e.g. com.example.app';
      });
      return;
    }
    if (_added.contains(input)) {
      setState(() {
        _error = _isCN ? '该应用已在列表中' : 'Already in the list';
      });
      return;
    }
    Navigator.of(context).pop(input);
  }

  Set<String> get _added => widget.addedList.map((e) => e.packageName).whereType<String>().toSet();

  bool get _isCN => Localizations.localeOf(context) == const Locale.fromSubtags(languageCode: 'zh');

  List<OhosPresetApp> get _visibleApps {
    final added = _added;
    var list = ohosPresetApps.where((app) => !added.contains(app.bundleName)).toList();
    final kw = _keyword?.trim().toLowerCase();
    if (kw != null && kw.isNotEmpty) {
      list = list
          .where((app) => app.name.toLowerCase().contains(kw) || app.bundleName.toLowerCase().contains(kw))
          .toList();
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visibleApps;
    final dividerColor = Theme.of(context).dividerColor.withValues(alpha: 0.3);

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text(_isCN ? '选择应用' : 'Select app', style: const TextStyle(fontSize: 16)),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: TextField(
            controller: _controller,
            autocorrect: false,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              isDense: true,
              labelText: _isCN ? '手动输入包名（bundleName）' : 'Bundle name',
              hintText: 'com.example.app',
              errorText: _error,
              suffixIcon: IconButton(
                icon: const Icon(Icons.check),
                tooltip: _isCN ? '添加' : 'Add',
                onPressed: _submitManual,
              ),
            ),
            onChanged: (_) {
              if (_error != null) {
                setState(() => _error = null);
              }
            },
            onSubmitted: (_) => _submitManual(),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
          child: TextField(
            decoration: InputDecoration(
              border: InputBorder.none,
              isDense: true,
              hintText: _isCN ? '搜索常见应用' : 'Search common apps',
              prefixIcon: const Icon(Icons.search, size: 20),
            ),
            onChanged: (value) => setState(() => _keyword = value),
          ),
        ),
        Divider(height: 0, thickness: 0.3, color: dividerColor),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _isCN ? '常见应用（包名随版本可能变化，无效时请手动输入）' : 'Common apps (bundle names may change; enter manually if invalid)',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ),
        ),
        Expanded(
          child: visible.isEmpty
              ? Center(
                  child: Text(_isCN ? '无可选项' : 'No result', style: const TextStyle(color: Colors.grey)),
                )
              : ListView.builder(
                  itemCount: visible.length,
                  itemBuilder: (BuildContext context, int index) {
                    final app = visible[index];
                    return ListTile(
                      leading: const Icon(Icons.android),
                      title: Text(app.name),
                      subtitle: Text(app.bundleName),
                      onTap: () => Navigator.of(context).pop(app.bundleName),
                    );
                  }),
        ),
      ]),
    );
  }
}
