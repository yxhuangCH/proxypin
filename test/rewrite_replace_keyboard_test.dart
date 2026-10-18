import 'dart:convert';

import 'package:code_forge/code_forge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/components/manager/rewrite_rule.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/ui/mobile/setting/rewrite/rewrite_replace.dart';

void main() {
  testWidgets('response body editor shows the soft keyboard when tapped', (tester) async {
    final calls = <MethodCall>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.textInput, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.textInput, null));

    final response = HttpResponse(HttpStatus.ok)..body = utf8.encode('{"ok":true}');
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: MobileRewriteReplace(
          ruleType: RuleType.responseReplace,
          items: RewriteItem.fromResponse(response),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    calls.clear();

    await tester.tap(find.byType(CodeForge));
    await tester.pump();

    expect(
      calls.map((call) => call.method),
      contains('TextInput.show'),
      reason: 'Tapping the response editor should explicitly show the soft keyboard',
    );

    await tester.pump(const Duration(milliseconds: 300));
  });
}
