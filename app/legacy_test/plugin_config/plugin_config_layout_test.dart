// How a plugin's page orders its fields: what must be filled in, keys,
// switches, choices and live fields first; plumbing folded under 「高级」 on a
// long form; a search over titles, descriptions (both languages), keys and
// choices that shows folded fields too.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/plugin_config/plugin_config_api.dart';
import 'package:dsh_app/ui/plugins/config/plugin_config_layout.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

List<String> _keys(Iterable<dynamic> sections) => [
  for (final s in sections)
    for (final f in s.fields) (f.path as List<String>).join('.'),
];

PluginConfigForm _form(Map<String, Object?> schema, {Map<String, Object?> base = const {}}) => PluginConfigForm(
  SettingsNamespaceView(ns: 'p', schema: SchemaNode.fromJson(schema), value: base, base: base, revision: 0),
);

void main() {
  test('tiers', () {
    SchemaNode node(Map<String, Object?> json) => SchemaNode.fromJson(json);
    expect(configTierOf('apiKey', node(str(role: 'secret'))), ConfigTier.primary);
    expect(configTierOf('city', node(str(required: true))), ConfigTier.primary, reason: 'must be filled in');
    expect(configTierOf('precision', node(choice(['a', 'b']))), ConfigTier.primary);
    expect(configTierOf('punctuation', node(boolean(def: true))), ConfigTier.primary);
    expect(configTierOf('threads', node(natural(def: 2))), ConfigTier.regular);
    expect(configTierOf('modelOrigins', node(strings())), ConfigTier.advanced);
    expect(configTierOf('timeoutMs', node(natural(def: 1))), ConfigTier.advanced);
    expect(configTierOf('maxPending', node(natural(def: 1))), ConfigTier.advanced);
    expect(configTierOf('dataRoot', node(str())), ConfigTier.advanced);
    expect(configTierOf('bingEndpoint', node(str(def: 'https://x'))), ConfigTier.advanced);
    expect(configTierOf('segmentSeconds', node(number(def: 30))), ConfigTier.advanced);
    expect(configTierOf('threshold', node(number(def: 0.5, min: 0, max: 1, role: 'slider'))), ConfigTier.regular);
    // A plugin that tunes it live means people change it.
    expect(configTierOf('timeoutMs', node(natural(def: 1)), live: true), ConfigTier.primary);
  });

  test('a long form: choices first, plumbing under 高级, groups kept in order', () {
    final form = PluginConfigForm(voiceEntry().view());
    final layout = pluginConfigLayout(form);
    expect(layout.fieldCount, 20);
    expect(_keys(layout.sections), ['language', 'precision', 'punctuation', 'threads', 'vad.threshold']);
    expect([for (final s in layout.sections) s.title], [null, '语音检测']);
    expect(_keys(layout.advanced), [
      'modelOrigins',
      'dataRoot',
      'modelDirectory',
      'prepareTimeoutMs',
      'inferenceTimeoutMs',
      'idleTimeoutMs',
      'graceMs',
      'vad.minSpeechSeconds',
      'vad.minSilenceSeconds',
      'vad.onsetPaddingSeconds',
      'segments.segmentSeconds',
      'segments.maxPending',
      'limits.maxAudioBytes',
      'limits.maxResponseBytes',
      'limits.maxLogBytes',
    ]);
    expect([for (final s in layout.advanced) s.title], [null, '语音检测', '分段', '限制']);
    expect(layout.advancedCount, 15);
  });

  test('a short form folds nothing', () {
    final form = PluginConfigForm(translatorEntry().view());
    final layout = pluginConfigLayout(form);
    expect(layout.advanced, isEmpty);
    expect(_keys(layout.sections), ['provider', 'apiKey', 'targetLanguage', 'timeoutMs', 'bingEndpoint', 'maxTextChars']);
  });

  test('everything plumbing: nothing to fold it away from', () {
    final form = _form(
      fields({
        for (final key in ['aMs', 'bMs', 'cMs', 'dMs', 'eMs', 'fMs', 'gMs']) key: natural(def: 1),
      }),
    );
    final layout = pluginConfigLayout(form);
    expect(layout.advanced, isEmpty);
    expect(layout.fieldCount, 7);
  });

  test('a schema that folds its own groups keeps its layout (dsh-ears 0.4.3)', () {
    final schema = jsonDecode(File('test/engine_settings/fixtures/dsh-ears-0.4.3.json').readAsStringSync());
    final form = _form(schema as Map<String, Object?>);
    final layout = pluginConfigLayout(form);
    expect(layout.authored, isTrue);
    expect(layout.fieldCount, greaterThan(40));
    expect(layout.advanced, isEmpty, reason: 'nothing pulled out of the author\'s groups');
    // Common items still lead within a group: each provider's key first.
    final groq = layout.sections.firstWhere((s) => s.fields.any((f) => f.path.join('.') == 'cloudAsr.groq.model'));
    expect(groq.fields.first.key, 'apiKey');
    expect(declaresCollapse(PluginConfigForm(voiceEntry().view()).view.schema), isFalse);
  });

  test('search: titles in both languages, keys, choices; folded fields too', () {
    final form = PluginConfigForm(voiceEntry().view());
    expect(_keys(pluginConfigLayout(form, query: '超时').sections), [
      'prepareTimeoutMs',
      'inferenceTimeoutMs',
    ]);
    expect(_keys(pluginConfigLayout(form, query: 'timeout').sections), [
      'prepareTimeoutMs',
      'inferenceTimeoutMs',
      'idleTimeoutMs',
    ]);
    expect(_keys(pluginConfigLayout(form, query: 'Sensitivity').sections), ['vad.threshold']);
    expect(_keys(pluginConfigLayout(form, query: 'fp32').sections), ['precision'], reason: 'a choice');
    expect(_keys(pluginConfigLayout(form, query: 'limits audio').sections), ['limits.maxAudioBytes']);
    final none = pluginConfigLayout(form, query: 'nothing like this');
    expect(none.sections, isEmpty);
    expect(none.advanced, isEmpty);
    expect(none.fieldCount, 20);
  });
}
