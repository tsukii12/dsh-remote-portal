// One icon table for a plugin's manifest and its views
// (docs/design/plugin-ui-v3.md §4.3): every name draws, the SDK lists the
// same names, and nothing reads as the app asking for trust.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/plugins/native/native_icons.dart';
import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_plugin.dart';
import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_model.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every name draws a glyph, each name once, in the protocol pattern', () {
    expect(nativeIconNames.toSet(), hasLength(nativeIconNames.length));
    expect(nativeIconNames.length, greaterThanOrEqualTo(140));
    for (final name in nativeIconNames) {
      expect(nativeIcon(name), isNotNull, reason: name);
      expect(RegExp(r'^[a-z][a-z0-9-]{0,31}$').hasMatch(name), isTrue, reason: name);
    }
  });

  test('no lock, key, shield, fingerprint, approval or permission glyph is offered', () {
    const trust = [
      AppIcons.lock,
      AppIcons.lockActive,
      AppIcons.unlock,
      AppIcons.fingerprint,
      AppIcons.apiKey,
      AppIcons.verified,
      AppIcons.approval,
      AppIcons.permissions,
      AppIcons.securityWarning,
      AppIcons.safeMode,
      AppIcons.privacy,
      AppIcons.autoApprove,
    ];
    for (final name in nativeIconNames) {
      expect(trust, isNot(contains(nativeIcon(name))), reason: name);
    }
    for (final name in ['lock', 'unlock', 'key', 'shield', 'fingerprint', 'approve', 'permission', 'verified']) {
      expect(nativeIcon(name), isNull, reason: name);
    }
  });

  test("the SDK's view schema lists the same names, in the same order", () {
    final schema = jsonDecode(File('test/fixtures/plugin_view.schema.json').readAsStringSync()) as Map;
    final icon = ((schema[r'$defs'] as Map)['icon'] as Map)['anyOf'] as List;
    expect((icon.first as Map)['enum'], nativeIconNames);
  });

  test('a view takes any of them; an unknown one is a note, not an error', () {
    final parsed = parsePluginView({
      'type': 'list',
      'items': [
        {'title': '贴纸', 'icon': 'gallery'},
        {'title': '群', 'icon': 'group'},
        {'title': '锁', 'icon': 'lock'},
      ],
    });
    final view = (parsed as DshUiParsed).view;
    final list = view.root as DshUiList;
    expect([for (final i in list.items) i.icon], ['gallery', 'group', '']);
    expect(view.issues.map((i) => i.path), contains('view.items[2].icon'));
  });
}
