import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/ui/engine_settings/schema_fields.dart';
import 'package:dsh_client/dsh_client.dart' show SettingsDescription;
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  final namespaces = SettingsDescription.fromJson(recordedDescribe()).namespaces;
  SchemaNode field(String ns, String key) => namespaces[ns]!.schema.fields![key]!;

  test('every recorded field gets a control', () {
    expect(kindOf(field('subagent', 'maxDepth')), FieldKind.number);
    expect(kindOf(field('ui-settings', 'enabled')), FieldKind.toggle);
    expect(kindOf(field('ui-chat', 'linkOpening')), FieldKind.choice);
    expect(kindOf(field('ui-chat', 'transcriptView')), FieldKind.choice);
    expect(kindOf(field('web-search-deepseek', 'apiKey')), FieldKind.secret);
    expect(kindOf(field('web-search-deepseek', 'apiKeyEnv')), FieldKind.hidden);
    expect(kindOf(field('web-search-deepseek', 'baseURL')), FieldKind.text);
    expect(kindOf(field('plugin-market', 'indexes')), FieldKind.list);
    expect(kindOf(field('llm-deepseek', 'models')), FieldKind.objectList);
    expect(kindOf(field('llm-deepseek', 'retryPolicy')), FieldKind.readOnly);
    expect(kindOf(field('llm-deepseek', 'thinking')), FieldKind.choice);
    expect(kindOf(field('ui-settings-account', 'version')), FieldKind.hidden, reason: 'a lone constant');
    expect(kindOf(field('ui-settings-account', 'purpose')), FieldKind.choice, reason: 'nullable enum');
    expect(kindOf(field('cot-translation', 'targetLanguage')), FieldKind.text);
    final models = field('llm-deepseek', 'models').inner!;
    expect(kindOf(models.fields!['imagePixelBudget']!), FieldKind.readOnly, reason: 'number or a constant');
    expect(kindOf(models.fields!['inputModalities']!), FieldKind.list);
  });

  test('units from keys and roles, values in words', () {
    final timeout = field('bash-sandbox', 'timeoutMs');
    expect(unitFor('timeoutMs', timeout), FieldUnit.milliseconds);
    expect(unitFor('maxOutputBytes', field('bash-sandbox', 'maxOutputBytes')), FieldUnit.bytes);
    expect(unitFor('fileExpiresAfterSeconds', field('llm-deepseek', 'fileExpiresAfterSeconds')), FieldUnit.seconds);
    expect(unitFor('count', field('web-deepseek-api', 'count')), FieldUnit.plain);
    expect(formatNumber(60000, FieldUnit.milliseconds), '1 分钟');
    expect(formatNumber(45000, FieldUnit.milliseconds), '45 秒');
    expect(formatNumber(1500, FieldUnit.milliseconds), '1.5 秒');
    expect(formatNumber(800, FieldUnit.milliseconds), '800 毫秒');
    expect(formatNumber(604800, FieldUnit.seconds), '168 小时');
    expect(formatNumber(64000, FieldUnit.bytes), '64 KB');
    expect(formatNumber(67108864, FieldUnit.bytes), '64 MB');
    expect(formatNumber(900, FieldUnit.bytes), '900 字节');
    expect(formatNumber(256000, FieldUnit.tokens), '256K');
    expect(formatNumber(0.25, FieldUnit.ratio), '25%');
    expect(formatNumber(10, FieldUnit.plain), '10');
    expect(toEditValue(60000, FieldUnit.milliseconds), 60);
    expect(fromEditValue(1.5, FieldUnit.milliseconds), 1500);
    expect(editUnitLabel(FieldUnit.milliseconds), '秒');
  });

  test('bounds: "no limit" and "above zero" read as such', () {
    final depth = field('subagent', 'maxDepth').meta;
    expect(meaningfulMax(depth), isNull);
    expect(rangeText(depth, FieldUnit.plain), '不小于 0');
    final count = field('web-deepseek-api', 'count').meta;
    expect(rangeText(count, FieldUnit.plain), '1–50');
    final idle = field('llm-deepseek', 'streamIdleTimeoutMs').meta;
    expect(rangeText(idle, FieldUnit.milliseconds), startsWith('大于 0'));
  });

  test('numbers are checked the way the engine checks them', () {
    final depth = field('subagent', 'maxDepth').meta;
    expect(validateNumber('2', depth, FieldUnit.plain), isNull);
    expect(validateNumber('', depth, FieldUnit.plain), isNull);
    expect(validateNumber('-1', depth, FieldUnit.plain), '不能小于 0');
    expect(validateNumber('1.5', depth, FieldUnit.plain), '请填整数');
    expect(validateNumber('abc', depth, FieldUnit.plain), '请填数字');
    final count = field('web-deepseek-api', 'count').meta;
    expect(validateNumber('51', count, FieldUnit.plain), '请填 1–50 之间的数');
    final timeout = field('bash-sandbox', 'timeoutMs').meta;
    expect(validateNumber('1.5', timeout, FieldUnit.milliseconds), isNull, reason: 'typed in seconds');
  });

  test('stored-unit validation matches schemastery 3.18.5 generated cases', () {
    final fixture = jsonDecode(
      File('test/engine_settings/fixtures/schemastery-validation.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    for (final entry in fixture.entries) {
      final node = SchemaNode.fromJson(entry.value['schema']);
      final unit = switch (entry.key) {
        'percent' || 'tinyPercent' => FieldUnit.ratio,
        'milliseconds' => FieldUnit.milliseconds,
        _ => FieldUnit.plain,
      };
      for (final sample in entry.value['cases'] as List) {
        final value = sample['value'];
        final error = value is num
            ? validateNumber('${toEditValue(value, unit)}', node.meta, unit)
            : validateText(value as String, node.meta);
        expect(error == null, sample['valid'], reason: '${entry.key}: $value');
      }
    }
  });

  test('strings follow the JavaScript pattern', () {
    final language = field('cot-translation', 'targetLanguage').meta;
    expect(validateText('zh', language), isNull);
    expect(validateText('auto', language), isNull);
    expect(validateText('中文', language, patternMessage: '填语言代码'), '填语言代码');
    final url = field('plugin-market', 'indexes').inner!.meta;
    expect(validateText('https://example.com/i.json', url), isNull);
    expect(validateText('ftp://x', url), '格式不对');
    expect(validateText('', url), isNull, reason: 'empty restores the default');
    expect(jsRegExp('(', null), isNull);
  });

  test('labels: page copy, short descriptions, known keys, then the key in words', () {
    final depth = field('subagent', 'maxDepth');
    expect(labelFor('maxDepth', depth, const FieldCopy(label: '最大递归深度')), '最大递归深度');
    expect(labelFor('baseURL', field('web-search-deepseek', 'baseURL'), const FieldCopy()), '服务地址');
    expect(labelFor('maxOutputBytes', field('bash-sandbox', 'maxOutputBytes'), const FieldCopy()), 'Max output bytes');
    expect(humanizeKey('sendOriginalQuestion'), 'Send original question');
    expect(humanizeKey('api_key'), 'Api key');
    expect(humanizeKey('baseURL'), 'Base URL');
    final described = SchemaNode.fromJson({
      'type': 'string',
      'meta': {
        'description': {'en': 'Proxy', 'zh': '代理地址。'},
      },
    });
    expect(labelFor('x', described, const FieldCopy()), '代理地址');
    final long = SchemaNode.fromJson({
      'type': 'string',
      'meta': {'description': '这是一段相当长的说明文字，超过了标题能放下的长度。第二句不会出现。'},
    });
    expect(labelFor('proxyUrl', long, const FieldCopy()), 'Proxy url');
    expect(hintFor(long, const FieldCopy()), '这是一段相当长的说明文字，超过了标题能放下的长度。');
  });

  test('choices: page copy decides what is offered; aliases read as their choice', () {
    const copy = FieldCopy(
      choices: {'compact': '简洁', 'standard': '标准', 'detailed': '详细', 'verbose': '完全展开'},
      aliases: {'normal': 'detailed', 'expanded': 'detailed'},
    );
    final transcript = field('ui-chat', 'transcriptView');
    expect(choicesFor(transcript, copy).map((c) => c.$2), ['简洁', '标准', '详细', '完全展开']);
    expect(choiceValue('normal', copy), 'detailed');
    expect(valueLabel('expanded', copy), '详细');
    expect(choicesFor(field('ui-chat', 'linkOpening'), const FieldCopy()).map((c) => c.$1), ['sidebar', 'new-tab']);
    expect(valueLabel('system', const FieldCopy()), '跟随系统');
    expect(valueLabel(null, const FieldCopy()), '未设置');
  });
}
