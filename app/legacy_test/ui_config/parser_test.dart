import 'dart:convert';

import 'package:dsh_app/ui_config/ui_config.dart';
import 'package:dsh_app/ui_config/ui_json_reader.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  group('shared fixtures', () {
    for (final name in fixtureNames()) {
      test(name, () {
        final load = parseUiConfig(fixture(name));
        expect(summarize(load), expected(name), reason: 'Dart and check.mjs must agree on $name');
      });
    }
  });

  group('reader', () {
    test('line and column of a mistake, UTF-16 columns, 1-based', () {
      expect(
        () => readUiJson('{\n  "a": 1,\n}'),
        throwsA(isA<UiJsonSyntaxError>().having((e) => e.message, 'message', '第 2 行第 9 列：多余的逗号')),
      );
      expect(
        () => readUiJson('{"标题": tru}'),
        throwsA(isA<UiJsonSyntaxError>().having((e) => e.message, 'message', '第 1 行第 8 列：无法识别的内容「t」')),
      );
    });

    test('integers stay integers, other numbers are doubles', () {
      final doc = readUiJson('{"a": 1, "b": 1.0, "c": 1e2, "d": 1234567890, "e": -5}');
      final map = doc.value! as Map<String, Object?>;
      expect(map['a'], isA<int>());
      expect(map['b'], isA<double>());
      expect(map['c'], isA<double>());
      expect(map['d'], isA<double>(), reason: 'more than nine digits');
      expect(map['e'], -5);
    });

    test('repeated keys: the later value, in the first place, and its pointer', () {
      final doc = readUiJson('{"a": 1, "b": {"x~/y": 1, "x~/y": 2}, "a": 3}');
      expect(jsonEncode(doc.value), '{"a":3,"b":{"x~/y":2}}');
      expect(doc.duplicateKeys, ['/b/x~0~1y', '/a']);
    });

    test('escapes and surrogate pairs', () {
      final doc = readUiJson(r'{"s": "a\"b\\c\/d\né😀"}');
      expect((doc.value! as Map)['s'], 'a"b\\c/d\né😀');
    });
  });

  group('validator', () {
    test('the spec example applies whole', () {
      final load = parseUiConfig(fixture('valid-full.json'));
      final c = load.config;
      expect(load.issues, isEmpty);
      expect(c.headerActions, [
        const UiHeaderBuiltinItem(UiHeaderBuiltin.schedule),
        const UiHeaderBuiltinItem(UiHeaderBuiltin.detail),
        const UiHeaderBuiltinItem(UiHeaderBuiltin.newChat),
        const UiHeaderCustomItem(id: 'daily', icon: 'bolt', label: '日报', action: UiSendAction('按模板写今天的日报')),
      ]);
      expect(c.quickActions![1].action, const UiCommandAction('compact'));
      expect(c.suggestions!.single.subtitle, '读工作区里的 TODO.md');
      expect(c.drawerGroups, UiDrawerGroup.values);
      expect(c.drawerSort, UiDrawerSort.activity);
      expect(c.drawerFilter, UiDrawerFilter.all);
      expect(c.density, UiDensity.compact);
      expect(c.hide, [UiHideItem.turnFooter, UiHideItem.tokenCount, UiHideItem.reasoningDetails]);
      expect(c.themeMode, UiThemeMode.system);
      expect(c.accent, const UiAccent.preset('daiqing'));
      expect(c.pet, const UiPetSpec(id: 'deepy-whale', position: UiPetPosition.bottomRight, quiet: true));
      expect(c.shortcuts!.single.keys, 'ctrl+k');
      expect(c.shortcuts!.single.action, const UiOpenAction('search'));
      expect(c.seats, {
        'conversation.input.dock': {'dsh-cost-meter': UiSeatMode.hidden},
      });
      expect(load.appliedCount, 15);
      expect(c.entries[UiSettingKey.themeMode]!.pointer, '/theme/mode');
      expect(c.entries[UiSettingKey.hide(UiHideItem.tokenCount)]!.pointer, '/hide/1');
      expect(
        c.entries[UiSettingKey.seat('conversation.input.dock', 'dsh-cost-meter')]!.pointer,
        '/plugins/seats/conversation.input.dock/dsh-cost-meter',
      );
    });

    test('a wrong item is left out, the rest of its list applies', () {
      final load = parseUiConfig(fixture('errors-mixed.json'));
      expect(load.fatal, isFalse);
      expect(load.config.headerActions!.map((h) => h.toJson() is String ? h.toJson() : (h.toJson() as Map)['id']), [
        'newChat',
        'a',
        'b',
        'c',
      ]);
      expect(load.config.quickActions!.map((q) => q.label), ['总结', '命令', '多余']);
      expect(load.config.quickActions![1].action, const UiCommandAction('compact'));
      expect(load.config.drawerGroups, [UiDrawerGroup.today]);
      expect(load.config.drawerFilter, UiDrawerFilter.unread);
      expect(load.config.drawerSort, isNull);
      expect(load.config.hide, [UiHideItem.turnFooter]);
      expect(load.config.themeMode, isNull);
      expect(load.config.pet, isNull);
      expect(load.config.seats, {
        'conversation.input.dock': {'ok-pkg': UiSeatMode.web},
      });
      expect(
        load.issues,
        contains(const UiConfigIssue('/composer/quickActions/1/action/url', '只支持 https 链接', UiIssueKind.invalid)),
      );
      expect(load.notAppliedCount, load.issues.where((i) => i.kind != UiIssueKind.adjusted).length);
    });

    test('labels lose line breaks and control characters, long ones are cut', () {
      final c = parseUiConfig(fixture('labels.json')).config;
      expect((c.headerActions!.single as UiHeaderCustomItem).label, '这是一个很长很长');
      expect(c.quickActions!.map((q) => q.label), ['两 行 标签', '十个字以内的标签啊啊', '超过十个字的标签啊啊']);
      expect((c.quickActions!.first.action as UiSendAction).text, '第一行\n第二行');
      expect(c.suggestions!.map((s) => s.title.runes.length), [20, 20]);
      expect(c.suggestions!.last.title, '😀' * 20);
    });

    test('actions: https only, no userinfo, command slash removed, args trimmed', () {
      final c = parseUiConfig(fixture('actions.json')).config;
      expect(c.quickActions!.map((q) => q.action.toJson()), [
        {'type': 'link', 'url': 'https://example.com/a?b=1#c'},
        {'type': 'link', 'url': 'https://example.com:8443/x'},
        {'type': 'command', 'name': 'plan', 'args': '写一个计划'},
        {'type': 'command', 'name': 'compact'},
      ]);
      expect((c.quickActions![2].action as UiCommandAction).line, '/plan 写一个计划');
      expect(c.accent, const UiAccent.preset('mist'));
    });

    test('shortcuts are canonical: modifiers in order, lower case', () {
      final c = parseUiConfig(fixture('shortcuts.json')).config;
      expect(c.shortcuts!.map((s) => s.keys), ['ctrl+k', 'ctrl+shift+n', 'f5', 'alt+/']);
      expect(c.shortcuts![1].shift, isTrue);
      expect(c.shortcuts![1].key, 'n');
    });

    test('an explicit [] hides every header button and drawer group; all-invalid lists set nothing', () {
      final empty = parseUiConfig(fixture('header-empty.json')).config;
      expect(empty.headerActions, isEmpty);
      expect(empty.drawerGroups, isEmpty);
      expect(empty.quickActions, isNull);
      final invalid = parseUiConfig(fixture('header-all-invalid.json')).config;
      expect(invalid.headerActions, isNull, reason: 'a typo must not hide every button');
      expect(invalid.drawerGroups, isNull);
    });

    test('a custom colour is read as RGB', () {
      final c = parseUiConfig('{"version": 1, "theme": {"accent": "#5f7a55"}}').config;
      expect(c.accent, const UiAccent.color(0x5F7A55));
      expect(c.entries[UiSettingKey.accent]!.value, '#5F7A55');
    });

    test('fatal reads keep the last good configuration', () {
      final good = parseUiConfig('{"version": 1, "density": "compact"}').config;
      for (final text in ['{"version": 1,', '{"version": 2}', '[]', '{"density": "compact"}', '']) {
        final load = parseUiConfig(text, lastGood: good);
        expect(load.fatal, isTrue, reason: text);
        expect(load.fromLastGood, isTrue);
        expect(load.config.density, UiDensity.compact);
        expect(load.appliedCount, 0);
      }
      expect(parseUiConfig('{').config, UiConfig.empty);
    });

    test('more than 64 KiB is not read', () {
      final big = '{"version": 1, "x": "${'a' * (64 * 1024)}"}';
      final load = parseUiConfig(big);
      expect(load.issues.single, const UiConfigIssue('', '文件超过 64 KiB', UiIssueKind.fatal));
    });

    test('entries fingerprint the applied value', () {
      UiConfigEntry entry(String text) => parseUiConfig(text).config.entries[UiSettingKey.themeMode]!;
      expect(
        entry('{"version":1,"theme":{"mode":"dark"}}').hash,
        entry('{"version": 1, "theme": {"mode": "dark"}}').hash,
      );
      expect(
        entry('{"version":1,"theme":{"mode":"dark"}}').hash,
        isNot(entry('{"version":1,"theme":{"mode":"light"}}').hash),
      );
    });

    test('without() drops set-aside settings everywhere', () {
      final c = parseUiConfig(fixture('valid-full.json')).config;
      final rest = c.without({
        UiSettingKey.themeMode,
        UiSettingKey.hide(UiHideItem.tokenCount),
        UiSettingKey.seat('conversation.input.dock', 'dsh-cost-meter'),
      });
      expect(rest.themeMode, isNull);
      expect(rest.hide, [UiHideItem.turnFooter, UiHideItem.reasoningDetails]);
      expect(rest.seats, isEmpty);
      expect(rest.appliedCount, c.appliedCount - 3);
      expect(rest.density, UiDensity.compact);
    });
  });
}
