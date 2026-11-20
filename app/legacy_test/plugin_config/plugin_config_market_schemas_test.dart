// Real plugin Configs on the generated form (fixtures/schemas/: the
// `Schema.toJSON()` wire format of published packages, each file naming its
// package, version and source file): every field a schema declares is on
// the page — as a control, or as a row that says to set it on the web — and
// the titles, hints and option labels read in Chinese wherever the schema
// has Chinese, else English, else the key.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/state/plugin_config/plugin_config_memory.dart';
import 'package:dsh_app/ui/engine_settings/schema_fields.dart';
import 'package:dsh_app/ui/engine_settings/schema_form.dart';
import 'package:dsh_app/ui/plugins/config/plugin_config_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

final _dir = Directory('test/plugin_config/fixtures/schemas');

Map<String, Object?> _fixture(String name) =>
    jsonDecode(File('${_dir.path}/$name.json').readAsStringSync()) as Map<String, Object?>;

SettingsNamespaceView _view(String name) =>
    SettingsNamespaceView(ns: 'x', schema: SchemaNode.fromJson(_fixture(name)['schema']), value: const {}, revision: 0);

List<SchemaFieldSpec> _fields(SettingsNamespaceView view) => schemaSections(view).expand((s) => s.fields).toList();

/// The spec drawn at [path].
SchemaFieldSpec _at(SettingsNamespaceView view, String path) =>
    _fields(view).singleWhere((f) => f.path.join('.') == path);

SchemaNode _node(SettingsNamespaceView view, String path) => schemaAt(view.schema, path.split('.'))!;

String _label(SettingsNamespaceView view, String path) =>
    labelFor(path.split('.').last, _node(view, path), const FieldCopy());

String? _hint(SettingsNamespaceView view, String path) => hintFor(_node(view, path), const FieldCopy());

void main() {
  tearDown(() => AppLocale.use(AppLocale.zhCN));

  final names = [
    for (final file in _dir.listSync().whereType<File>())
      if (file.path.endsWith('.json')) file.uri.pathSegments.last.replaceFirst(RegExp(r'\.json$'), ''),
  ]..sort();

  group('nothing a schema declares goes missing', () {
    test('the sample is the one documented', () {
      expect(names, hasLength(9));
      for (final name in names) {
        final raw = _fixture(name);
        expect(raw['package'], isA<String>(), reason: name);
        expect(raw['version'], isA<String>(), reason: name);
        expect(raw['file'], isA<String>(), reason: name);
      }
    });

    for (final name in names) {
      test(name, () {
        final view = _view(name);
        final fields = _fields(view);
        final drawn = {for (final f in fields) f.path.join('.')};
        for (final f in fields) {
          if (f.fallbackNode == null) expect(schemaAt(view.schema, f.path), isNotNull, reason: f.path.join('.'));
        }
        // A declared key shows itself, under its group, or inside the row of
        // an ancestor; only what schemastery marks hidden, credential-ref
        // plumbing and constant markers stay off the page.
        void walk(SchemaNode node, List<String> prefix, int depth) {
          final declared = schemaObjectFields(node);
          if (declared == null || depth > 8) return;
          for (final MapEntry(:key, :value) in declared.entries) {
            final path = [...prefix, key];
            final dotted = path.join('.');
            final kind = kindOf(value);
            final covered = [for (var i = 1; i <= path.length; i++) path.take(i).join('.')].any(drawn.contains);
            final under = drawn.any((d) => d.startsWith('$dotted.'));
            if (kind == FieldKind.hidden) {
              expect(covered || under, isFalse, reason: '$name: $dotted is hidden');
            } else {
              expect(covered || under, isTrue, reason: '$name: $dotted ($kind) is not on the page');
            }
            if (!covered) walk(value, path, depth + 1);
          }
        }

        walk(view.schema, const [], 0);
      });
    }
  });

  group('fields that are now controls', () {
    test('@nanmicoder/dsh-agent-teams 0.1.27: an optional object is a group of its fields', () {
      final view = _view('nanmicoder-dsh-agent-teams-0.1.27');
      // fallback: union([object({provider, model}), const(undefined)])
      expect(kindOf(_node(view, 'fallback')), FieldKind.group);
      expect(kindOf(_node(view, 'fallback.provider')), FieldKind.text);
      expect(kindOf(_node(view, 'fallback.model')), FieldKind.text);
      final section = schemaSections(view).singleWhere((s) => s.fields.any((f) => f.path.first == 'fallback'));
      expect(section.title, 'Fallback');
      expect(section.fields.map((f) => f.path.join('.')), ['fallback.provider', 'fallback.model']);
      expect(schemaPathDisabled(view.schema, ['fallback', 'provider']), isFalse);
      // A dict of objects stays a row to set on the web.
      expect(_at(view, 'profiles').fallbackNode, isNull);
      expect(kindOf(_node(view, 'profiles')), FieldKind.readOnly);
    });

    test('dsh-mobile 0.7.0: an optional list is a list', () {
      final view = _view('dsh-mobile-0.7.0');
      // hostExecution.extensions: union([const(undefined), array(String)])
      final extensions = _node(view, 'hostExecution.extensions');
      expect(kindOf(extensions), FieldKind.list);
      expect(valueNodeOf(extensions).inner?.effective.type, 'string');
      // hidden() fields stay hidden.
      expect(drawnPaths(view), isNot(contains('setupFile')));
    });

    test('@dickpy/dsh-imagegen 1.10.0: a map of secrets is never a plain-text editor', () {
      final view = _view('dickpy-dsh-imagegen-1.10.0');
      expect(kindOf(_node(view, 'channelSecrets')), FieldKind.readOnly);
      expect(kindOf(_node(view, 'skillConfigSecrets')), FieldKind.readOnly);
      expect(kindOf(_node(view, 'skillConfig')), FieldKind.dict);
      expect(kindOf(_node(view, 'promptApiKey')), FieldKind.secret);
      expect(kindOf(_node(view, 'channels')), FieldKind.objectList);
    });

    test('@cocofhu/anime-find 0.1.12: items that declare no fields are not an empty form', () {
      final view = _view('cocofhu-anime-find-0.1.12');
      // streamRules: array(object({}))
      expect(kindOf(_node(view, 'streamRules')), FieldKind.readOnly);
      expect(kindOf(_node(view, 'sources')), FieldKind.list);
    });

    test('dsh-context 0.78.2: every field is a native control', () {
      final view = _view('dsh-context-0.78.2');
      final fields = _fields(view);
      expect(fields, hasLength(21));
      expect(
        fields.where(
          (f) => !{FieldKind.number, FieldKind.choice, FieldKind.text}.contains(kindOf(_node(view, f.path.join('.')))),
        ),
        isEmpty,
      );
    });
  });

  group('Chinese first, then English, then the key', () {
    test('@ccch1mneyyy/dsh-media 0.2.1: a long Chinese description names the field', () {
      final view = _view('ccch1mneyyy-dsh-media-0.2.1');
      expect(_label(view, 'defaults.serviceId'), '默认服务 ID');
      expect(_hint(view, 'defaults.serviceId'), '留空使用首个已配置服务');
      expect(_label(view, 'budget.unknownPriceHoldCny'), '无可靠价格时每次预留金额');
      expect(_hint(view, 'budget.unknownPriceHoldCny'), '逐次确认，非供应商收费上限');
      expect(_label(view, 'budget.dailyCny'), '每日本地预算（人民币，上海日期）', reason: 'short enough as it is');
      expect(_hint(view, 'budget.dailyCny'), isNull);
      // Group titles too: 「凭据槽 1：DSH_MEDIA_SLOT_1_API_KEY」.
      final titles = schemaSections(view).map((s) => s.title).toList();
      expect(titles, contains('密钥（固定目标，只写） · 凭据槽 1'));
      expect(titles.where((t) => t != null && t.contains('Slot')), isEmpty);
      // The service form's fields and options.
      final service = schemaValueOf(_node(view, 'services')).inner!.fields!;
      expect(labelFor('responseFormat', service['responseFormat']!, const FieldCopy()), '兼容接口返回格式');
      expect(hintFor(service['responseFormat']!, const FieldCopy()), '按模型目录；GPT Image 留空');
      expect(labelFor('models', service['models']!, const FieldCopy()), '允许的模型 ID');
      expect(labelFor('keyRef', service['keyRef']!, const FieldCopy()), '凭据引用');
      expect(choicesFor(service['responseFormat']!, const FieldCopy()).map((c) => c.$2), [
        '未设置',
        'url',
        'b64_json',
      ], reason: 'the empty string is an option, not a blank one');
    });

    test('@cocofhu/anime-find 0.1.12: titles stay Chinese', () {
      final view = _view('cocofhu-anime-find-0.1.12');
      expect(_label(view, 'streamEnabled'), '启用流媒体在线播放');
      expect(_hint(view, 'streamEnabled'), '内置试点规则，可关闭或替换');
      expect(_label(view, 'streamRules'), '流媒体规则');
      expect(_label(view, 'sources'), '启用的搜索源，默认仅 Mikan');
    });

    test('an English clause or a comma does not make a title', () {
      expect(leadingPhrase('If remaining <= this (absolute or <1 fraction), treat as exhausted.'), isNull);
      expect(leadingPhrase('这是一段相当长的说明文字，超过了标题能放下的长度。'), isNull);
      expect(leadingPhrase('上游地址 https://example.com/api/v1/endpoint 用于转发请求'), isNull);
      expect(leadingPhrase('上游请求超时(毫秒)，超过后放弃重试并报告错误'), (title: '上游请求超时', rest: '毫秒，超过后放弃重试并报告错误'));
    });

    test('schemastery i18n(): the UI language, plain text in it, then English', () {
      final view = _view('schemastery-3.18.5-i18n');
      // {'': '最大重试次数', en: 'Maximum retries'} (mergeDesc keeps the plain text)
      expect(_label(view, 'retries'), '最大重试次数');
      // {'': 'Upstream endpoint', 'zh-CN': '上游地址', en: …}
      expect(_label(view, 'endpoint'), '上游地址');
      // {zh_CN: '区域', en_US: 'Region'}
      expect(_label(view, 'region'), '区域');
      // Only English: English before the key.
      expect(_label(view, 'proxy.url'), 'Proxy URL');
      expect(schemaSections(view).map((s) => s.title), contains('代理'));
      // Options name themselves: const('fast').description({zh-CN, en-US}).
      expect(choicesFor(_node(view, 'mode'), const FieldCopy()).map((c) => c.$2), ['快速', '稳妥', 'custom']);
      expect(valueLabel('fast', const FieldCopy(), node: _node(view, 'mode')), '快速');

      AppLocale.use(AppLocale.en);
      expect(_label(view, 'retries'), 'Maximum retries');
      expect(_label(view, 'endpoint'), 'Upstream endpoint');
      expect(_label(view, 'region'), 'Region');
      expect(choicesFor(_node(view, 'mode'), const FieldCopy()).map((c) => c.$2), ['Fast', '稳妥', 'custom']);
    });

    test('dsh-context 0.78.2 declares no text at all: the key in words', () {
      final view = _view('dsh-context-0.78.2');
      expect(_label(view, 'defaultPlacement'), 'Default placement');
      expect(choicesFor(_node(view, 'defaultPlacement'), const FieldCopy()).map((c) => c.$2), [
        'all',
        'tab',
        'sidebar',
        'hide',
      ]);
    });
  });

  group('on the page', () {
    MemoryPluginConfigApi api(String name) =>
        MemoryPluginConfigApi([MemoryPluginEntry(ns: 'weather', schema: _fixture(name)['schema'])]);

    testWidgets('an optional object shows its fields; an optional list opens its editor', (tester) async {
      await pumpConfigPage(
        tester,
        const PluginConfigPage(ns: 'weather'),
        api('nanmicoder-dsh-agent-teams-0.1.27'),
        height: 2400,
      );
      expect(find.text('Fallback'), findsOneWidget);
      expect(find.text('服务'), findsOneWidget);
      expect(find.text('模型'), findsOneWidget);
      expect(find.text('Profiles'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('dsh-mobile 0.7.0: the optional extensions list opens', (tester) async {
      await pumpConfigPage(tester, const PluginConfigPage(ns: 'weather'), api('dsh-mobile-0.7.0'), height: 2400);
      // Long form: its titled groups fold; open 「Host execution」.
      await tester.tap(find.text('Host execution'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Extensions'));
      await tester.tap(find.text('Extensions'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('list-input')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

Set<String> drawnPaths(SettingsNamespaceView view) => {for (final f in _fields(view)) f.path.join('.')};
