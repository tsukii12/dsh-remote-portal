import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/ui/engine_settings/namespace_copy.dart';
import 'package:dsh_app/ui/engine_settings/plugin_namespace_copy_zh.dart';
import 'package:dsh_app/ui/engine_settings/schema_fields.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => AppLocale.use(AppLocale.zhCN));
  tearDown(() => AppLocale.use(AppLocale.zhCN));

  const fixtures = <String, String>{
    'dsh-context': 'schemas/dsh-context-0.78.2.json',
    'imagegen': 'schemas/dickpy-dsh-imagegen-1.10.0.json',
    'auto-review': 'schemas/dsh-auto-review-0.15.0.json',
    'furongjun1999-dsh-memory': 'schemas/furongjun1999-dsh-memory-0.9.17.json',
    'agent-teams': 'schemas/nanmicoder-dsh-agent-teams-0.1.27.json',
    'mobile-access': 'schemas/dsh-mobile-0.7.0.json',
    'anime-find': 'schemas/cocofhu-anime-find-0.1.12.json',
    'dsh-media': 'schemas/ccch1mneyyy-dsh-media-0.2.1.json',
    'speech-to-text-sensevoice': 'bridge_entry_r14_sensevoice.json',
  };

  test('Chinese copy is reached by published bundle row IDs', () {
    expect(pluginNamespaceCopyZh, hasLength(10));
    expect(copyOf('imagegen', ['promptModel']).label, '对话模型');
    expect(copyOf('mobile-access', ['listenPort']).label, '监听端口');
    expect(copyOf('univer', ['gatewayPort']).label, '协作网关端口');
    expect(
      copyOf('furongjun1999-dsh-memory', [
        'memory',
        'contextWindow',
        'turns',
      ]).label,
      '窗口保留记录数',
    );
    expect(namespaceTitles['dsh-context'], '上下文管理');
    expect(namespaceCopy['@dickpy/dsh-imagegen'], isNull);
  });

  for (final entry in fixtures.entries) {
    test('${entry.key}: copied paths exist and enum values are unchanged', () {
      final raw = jsonDecode(
        File('test/plugin_config/fixtures/${entry.value}').readAsStringSync(),
      ) as Map;
      final schema = SchemaNode.fromJson(raw['schema']);
      for (final field in pluginNamespaceCopyZh[entry.key]!.entries) {
        final node = schemaAt(schema, field.key.split('.'));
        expect(node, isNotNull, reason: '${entry.key}.${field.key}');
        expect(
          labelFor(field.key.split('.').last, node!, field.value),
          field.value.label,
        );
        if (field.value.choices.isNotEmpty) {
          expect(
            field.value.choices.keys,
            unorderedEquals(node.effective.enumValues!),
            reason: field.key,
          );
          for (final choice in field.value.choices.entries) {
            expect(
              valueLabel(choice.key, field.value, node: node),
              choice.value,
            );
          }
        }
      }
    });
  }

  test('a title never names 毫秒 for a field typed in seconds', () {
    // `*Ms` numbers are stored in ms but shown as durations and typed in 秒
    // (unitFor). 「（毫秒）」 in the title would turn a typed 120000 into 33 hours.
    final number = SchemaNode.fromJson({'type': 'number'});
    for (final MapEntry(key: ns, value: fields) in pluginNamespaceCopyZh.entries) {
      for (final MapEntry(key: path, value: copy) in fields.entries) {
        final unit = unitFor(path.split('.').last, number);
        if (unit != FieldUnit.milliseconds) continue;
        expect(editUnitLabel(unit), '秒');
        expect(copy.label, isNot(contains('毫秒')), reason: '$ns.$path');
      }
    }
  });

  test(
    'English retains the pre-existing fallback and all settings behavior',
    () {
      AppLocale.use(AppLocale.en);
      for (final ns in pluginNamespaceCopyZh.keys) {
        expect(namespaceCopy[ns], isNull, reason: ns);
        expect(namespaceTitles[ns], isNull, reason: ns);
      }
      expect(copyOf('imagegen', ['promptModel']).label, isNull);
      expect(namespaceCopy['ui-chat'], isNotNull);
      for (final fields in pluginNamespaceCopyZh.values) {
        for (final copy in fields.values) {
          expect(copy.fallback, isNull);
          expect(copy.aliases, isEmpty);
          expect(copy.unit, isNull);
          expect(copy.countUnit, isNull);
          expect(copy.hint?.length ?? 0, lessThanOrEqualTo(16));
        }
      }
    },
  );
}
