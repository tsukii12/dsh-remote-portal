import 'dart:convert';

import 'package:dsh_app/ui/engine_settings/engine_settings_page.dart';
import 'package:dsh_app/ui/engine_settings/web_search_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const _text = ValueKey('text-input');
const _secret = ValueKey('secret-input');

FakeSettingsHost _host(bool api, {Map<String, Object?>? describe}) {
  final host = FakeSettingsHost(describe: describe);
  if (api) {
    host.namespaces['web']!.user = {
      'searchProvider': 'deepseek-search-api',
      'fetchProvider': 'deepseek-fetch-api',
    };
  }
  final ns = api ? WebSearchSettingsPage.apiNs : WebSearchSettingsPage.messagesNs;
  host.namespaces[ns]!.base = {...host.namespaces[ns]!.base, 'apiKeyEnv': 'G53_SEARCH_KEY'};
  return host;
}

Future<void> _open(WidgetTester tester, FakeSettingsHost host, {Widget? page}) async {
  await pumpPage(
    tester,
    page ?? const WebSearchSettingsPage(),
    overrides: engineOverrides(DshClient.withCarrier(host)),
    height: 1100,
    fonts: true,
  );
}

Future<Map<String, dynamic>> _capture(WidgetTester tester, Key key, String tag) async {
  expect(defaultTargetPlatform, TargetPlatform.android);
  final field = find.byKey(key);
  expect(field, findsOneWidget);
  await tester.tap(field);
  await tester.pump();
  final widget = tester.widget<TextField>(field);
  final editable = find.descendant(of: field, matching: find.byType(EditableText));
  final config = tester.state<EditableTextState>(editable).textInputConfiguration.toJson();
  final wire = Map<String, dynamic>.from(tester.testTextInput.setClientArgs!);
  for (final property in ['inputType', 'obscureText', 'autocorrect', 'enableSuggestions', 'enableIMEPersonalizedLearning']) {
    expect(wire[property], config[property], reason: 'Observe the actual platform channel, $property');
  }
  // Preserve machine-readable platform observations in the raw test stream.
  // ignore: avoid_print
  print('G53_SEARCH ${jsonEncode({
    'case': tag,
    'widget': {
      'keyboardType': widget.keyboardType.toJson(),
      'obscureText': widget.obscureText,
      'autocorrect': widget.autocorrect,
      'enableSuggestions': widget.enableSuggestions,
      'enableIMEPersonalizedLearning': widget.enableIMEPersonalizedLearning,
      'maxLines': widget.maxLines,
    },
    'platformConfig': wire,
    'editableConfig': config,
  })}');
  return wire;
}

void _ordinaryUrl(Map<String, dynamic> wire) {
  expect(wire['inputType']['name'], 'TextInputType.url');
  expect(wire['obscureText'], isFalse);
  expect(wire['enableSuggestions'], isTrue);
  expect(wire['autocorrect'], isFalse);
}

void _keyPolicy(Map<String, dynamic> wire, {required bool obscure}) {
  expect(wire['inputType']['name'], 'TextInputType.visiblePassword');
  expect(wire['obscureText'], obscure);
  expect(wire['enableSuggestions'], isFalse);
  expect(wire['autocorrect'], isFalse);
  expect(wire['enableIMEPersonalizedLearning'], isFalse);
}

void main() {
  for (final api in [false, true]) {
    final mode = api ? 'api' : 'messages';
    final ns = api ? WebSearchSettingsPage.apiNs : WebSearchSettingsPage.messagesNs;

    testWidgets('search $mode endpoint sends ordinary URI input to the real channel', (tester) async {
      final host = _host(api);
      await _open(tester, host);
      await tester.tap(find.text('服务地址'));
      await settle(tester);
      final wire = await _capture(tester, _text, '$mode-url');
      _ordinaryUrl(wire);
      expect(host.mutates(), isEmpty);
      expect(host.credentials, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('search $mode API key hide reveal hide keeps sensitive input policy', (tester) async {
      final host = _host(api);
      host.credentials['G53_SEARCH_KEY'] = 'dummy-retained-search-key';
      await _open(tester, host);
      await tester.tap(find.text('API Key'));
      await settle(tester);
      _keyPolicy(await _capture(tester, _secret, '$mode-key-hidden'), obscure: true);
      expect(tester.widget<TextField>(find.byKey(_secret)).controller!.text, isEmpty);
      await tester.tap(find.byTooltip('显示'));
      await tester.pump();
      _keyPolicy(await _capture(tester, _secret, '$mode-key-shown'), obscure: false);
      expect(tester.widget<TextField>(find.byKey(_secret)).controller!.text, isEmpty);
      await tester.tap(find.byTooltip('隐藏'));
      await tester.pump();
      _keyPolicy(await _capture(tester, _secret, '$mode-key-hidden-again'), obscure: true);
      expect(host.credentials, {'G53_SEARCH_KEY': 'dummy-retained-search-key'});
      expect(host.mutates(), isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('search $mode URL paste save and empty reset leave stored key intact', (tester) async {
      const pasted = 'https://search.example.invalid:8443/v1/tools?q=fixture';
      var clipboardReads = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') {
          clipboardReads++;
          return {'text': pasted};
        }
        if (call.method == 'Clipboard.hasStrings') return {'value': true};
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final host = _host(api);
      host.credentials['G53_SEARCH_KEY'] = 'dummy-retained-search-key';
      await _open(tester, host);
      await tester.tap(find.text('服务地址'));
      await settle(tester);
      await _capture(tester, _text, '$mode-paste-url');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      expect(tester.widget<TextField>(find.byKey(_text)).controller!.text, pasted);
      expect(clipboardReads, greaterThan(0));
      expect(host.mutates(), isEmpty);
      await tester.tap(find.text('完成'));
      await settle(tester);
      expect(host.mutates(), hasLength(1));
      expect(host.mutates().single['ns'], ns);
      expect(host.mutates().single['ops'], [
        {'op': 'set', 'path': ['baseURL'], 'value': pasted},
      ]);
      expect(host.namespaces[ns]!.user['baseURL'], pasted);
      expect(host.credentials, {'G53_SEARCH_KEY': 'dummy-retained-search-key'});
      await tester.tap(find.text('服务地址'));
      await settle(tester);
      expect(tester.widget<TextField>(find.byKey(_text)).controller!.text, pasted);
      await tester.enterText(find.byKey(_text), '');
      await tester.tap(find.text('完成'));
      await settle(tester);
      expect(host.mutates().last['ops'], [
        {'op': 'unset', 'path': ['baseURL']},
      ]);
      expect(host.credentials, {'G53_SEARCH_KEY': 'dummy-retained-search-key'});
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('unannotated schema text retains its prior input policy', (tester) async {
    final host = FakeSettingsHost();
    await _open(tester, host, page: const EngineSettingsPage(ns: 'cot-translation'));
    await tester.tap(find.text('目标语言'));
    await settle(tester);
    final wire = await _capture(tester, _text, 'generic-text-control');
    expect(wire['inputType']['name'], 'TextInputType.text');
    expect(wire['enableSuggestions'], isFalse);
    expect(wire['autocorrect'], isFalse);
    expect(host.mutates(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a served textarea keeps multiline behavior even for the curated URL field', (tester) async {
    final describe = recordedDescribe();
    final namespace = (describe['namespaces']! as List).cast<Map<String, Object?>>().singleWhere(
      (n) => n['ns'] == WebSearchSettingsPage.messagesNs,
    );
    final schema = namespace['schema']! as Map<String, Object?>;
    final refs = schema['refs']! as Map<String, Object?>;
    final root = refs['${schema['uid']}']! as Map<String, Object?>;
    final fieldId = (root['dict']! as Map<String, Object?>)['baseURL'];
    final field = refs['$fieldId']! as Map<String, Object?>;
    field['meta'] = {'role': 'textarea'};
    final host = _host(false, describe: describe);
    await _open(tester, host);
    await tester.tap(find.text('服务地址'));
    await settle(tester);
    final wire = await _capture(tester, _text, 'textarea-control');
    expect(wire['inputType']['name'], 'TextInputType.multiline');
    expect(wire['enableSuggestions'], isFalse);
    expect(wire['autocorrect'], isFalse);
    expect(tester.widget<TextField>(find.byKey(_text)).maxLines, 8);
    expect(host.mutates(), isEmpty);
    expect(tester.takeException(), isNull);
  });
}
