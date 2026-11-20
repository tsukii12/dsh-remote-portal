// The plugin settings on a bridge R7 Host (runtime r14), from what a real one
// answered (backend stack R7 on DSH 0.2.1-rc.4, with the voice-input kit and
// session search switched on, a local bundle with covered and uncovered rows,
// the App's phone control and an observer as overlays):
//
//   fixtures/bridge_catalog_r14.json          GET /dsh-go/v1/plugin-config
//   fixtures/plugin_bundles_r14.json          pluginManager/listBundles, same
//                                             moment (icons cut to "<icon>",
//                                             the run's paths to /root/plugins)
//   fixtures/bridge_entry_r14_sensevoice.json GET …/speech-to-text-sensevoice,
//                                             covered by a command-line overlay
//
// What R7 adds and the App now reads: per entry `owner`, `bundle`, `kind`,
// `source`, `writable`, and a `label` that is the bundle's title. Covered
// entries say so in the list (「由配置文件固定」); `owner` core or overlay never
// makes an entry configurable here, whatever the bundle list says, and the
// bundle list still has to say so too; entries of one bundle get names
// apart; a list without the new fields (r13) works as before. The screens:
// plugin_config_r7_widgets_test.dart.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/plugin_config/plugin_config_state.dart';
import 'package:dsh_app/ui/plugins/config/plugin_config_entries.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bridge.dart';

Object? _fixture(String name) => jsonDecode(File('test/plugin_config/fixtures/$name').readAsStringSync());

/// The recorded list's raw items.
List<Map<String, Object?>> _raw([String name = 'bridge_catalog_r14.json']) =>
    ((_fixture(name)! as Map)['entries'] as List).cast<Map<String, Object?>>();

List<PluginConfigEntrySummary> _listed(List<Map<String, Object?>> raw) => [
  for (final e in raw) ?PluginConfigEntrySummary.fromJson(e),
];

List<Map<String, Object?>> _rawBundles([String name = 'plugin_bundles_r14.json']) =>
    (_fixture(name)! as List).cast<Map<String, Object?>>();

List<PluginBundle> _bundles([List<Map<String, Object?>>? raw]) => [
  for (final b in raw ?? _rawBundles()) PluginBundle.fromJson(b),
];

/// The page's state on that Host: the bridge's list (forms read one at a
/// time), scoped by [bundles].
PluginConfigState _state(
  List<PluginBundle>? bundles, {
  List<Map<String, Object?>>? raw,
  Map<String, PluginConfigForm> forms = const {},
}) => PluginConfigState(
  forms: forms,
  lazy: true,
  complete: true,
  entries: {for (final e in _listed(raw ?? _raw())) e.entryId: PluginConfigEntry.listed(e)},
  scope: PluginConfigScope.of(bundles),
);

/// [raw] with [change] applied to the item of [entryId].
List<Map<String, Object?>> _with(List<Map<String, Object?>> raw, String entryId, Map<String, Object?> change) => [
  for (final e in raw) e['entryId'] == entryId ? {...e, ...change} : e,
];

/// The entries the App offers on the recorded r14 Host, in the Host's order.
const _r14Plugins = [
  'speech-to-text',
  'speech-to-text-sensevoice',
  'api-speech-to-text',
  'normal',
  'home-covered',
  'home-same',
  'cli-covered',
  'flag-only',
  'ambiguous',
  'race',
  // dsh-media: in the bundle, but 设置 › 图像与视频 is its page.
  'error-entry',
  'optional-tool-session-query',
];

/// Of those, the ones an overlay covers.
const _covered = ['speech-to-text-sensevoice', 'home-covered', 'home-same', 'cli-covered'];

const _voice = ['speech-to-text', 'speech-to-text-sensevoice', 'api-speech-to-text'];

final _zh = lookupL10n(AppLocale.zhCN);
final _en = lookupL10n(AppLocale.en);

void main() {
  group('the recorded r14 list', () {
    test('every entry says who carries it and whether a write would be taken', () {
      final raw = _raw();
      expect(raw, hasLength(218));
      expect(
        {for (final e in raw) ...e.keys},
        {
          'entryId',
          'package',
          'owner',
          'bundle',
          'kind',
          'source',
          'label',
          'state',
          'configurable',
          'writable',
          'reason',
        },
      );
      final listed = _listed(raw);
      final owners = <String?, int>{};
      for (final e in listed) {
        owners.update(e.owner, (n) => n + 1, ifAbsent: () => 1);
      }
      expect(owners, {'core': 191, 'installed': 11, 'overlay': 10, 'optional': 6});
      // The Host itself never offers core or an overlay.
      for (final e in listed.where((e) => e.owner == 'core' || e.owner == 'overlay')) {
        expect((e.configurable, e.writable), (false, false), reason: e.entryId);
      }
      final byId = {for (final e in listed) e.entryId: e};
      final phone = byId['dsh-app-phone']!;
      expect((phone.owner, phone.bundle, phone.kind, phone.reason), ('overlay', null, 'overlay', 'entry-unavailable'));
      final sensevoice = byId['speech-to-text-sensevoice']!;
      expect(
        (sensevoice.owner, sensevoice.bundle, sensevoice.source, sensevoice.writable, sensevoice.reason),
        (
          'optional',
          '@deepseek-ai/dsh-experimental-voice-input-bundle',
          'official-optional-bundle',
          false,
          'overridden',
        ),
      );
      // The label is the bundle's title: the kit's three entries share one.
      expect({for (final id in _voice) byId[id]!.label!.resolve('zh')}, {'语音输入'});
    });

    test('设置 › 引擎参数 › 插件 offers the chosen bundles\' entries, nothing else', () {
      final state = _state(_bundles());
      expect(pluginConfigEntries(state), _r14Plugins);
      for (final e in _listed(_raw()).where((e) => e.owner == 'core' || e.owner == 'overlay')) {
        expect(state.isPlugin(e.entryId), isFalse, reason: e.entryId);
      }
    });
  });

  group('owner: the Host\'s word narrows the bundle list, never widens it', () {
    for (final (owner, kind) in [('core', 'core'), ('overlay', 'overlay'), ('host', 'plugin'), ('installed', 'core')]) {
      test('owner $owner, kind $kind: not offered, not read, not written', () async {
        final raw = _with(_raw(), 'normal', {'owner': owner, 'kind': kind});
        final state = _state(_bundles(), raw: raw);
        expect(state.isPlugin('normal'), isFalse);
        expect(pluginConfigEntries(state), _r14Plugins.where((id) => id != 'normal').toList());

        final host = await FakeBridgeHost.start();
        addTearDown(host.close);
        host.listed = raw;
        final client = await DshClient.connect(baseUri: host.baseUri, token: FakeBridgeHost.token, startMux: false);
        addTearDown(client.close);
        final scope = PluginConfigScope.of(_bundles());
        final api = BridgePluginConfigApi(client, _NoFallback(), scope: () => scope);
        await api.describe();
        await expectLater(api.read('normal'), throwsA(isA<PluginConfigFailure>()));
        await expectLater(
          api.apply('normal', const [
            SettingsOp.set(['count'], 2),
          ], revision: 'r1').drain<void>(),
          throwsA(isA<PluginConfigFailure>().having((f) => f.kind, 'kind', PluginConfigFailureKind.rejected)),
        );
        expect(host.requests.where((r) => r.$2.startsWith('$dshGoPluginConfigPath/')), isEmpty);
        // The same entry as listed goes out (404 here: the fake has no form).
        await expectLater(api.read('flag-only'), completion(isNull));
        expect(host.requests.where((r) => r.$2 == dshGoPluginConfigEntryPath('flag-only')), hasLength(1));
      });
    }

    test('another bundle than the one carrying the row: refused', () {
      final state = _state(_bundles(), raw: _with(_raw(), 'normal', {'bundle': 'wave10-r7-error'}));
      expect(state.isPlugin('normal'), isFalse);
      expect(state.isPlugin('flag-only'), isTrue);
    });

    test('core and overlay entries a chosen bundle claims, even listed configurable: refused', () {
      final raw = [
        for (final e in _raw())
          if (e['owner'] == 'core' || e['owner'] == 'overlay') {...e, 'configurable': true, 'reason': null} else e,
      ];
      final claimed = [
        for (final e in raw)
          if (e['owner'] == 'core' || e['owner'] == 'overlay') e,
      ];
      // A local bundle whose rows claim every one of them, by id and package.
      final claim = {
        'name': 'claims-everything',
        'source': 'file:/root/plugins/claims-everything',
        'enabled': true,
        'installed': true,
        'rows': [
          for (final e in claimed) {'rowId': e['entryId'], 'moduleName': e['package'] ?? './index.js'},
        ],
      };
      final bundles = _bundles([..._rawBundles(), claim]);
      final state = _state(bundles, raw: raw);
      expect(claimed, hasLength(201));
      for (final e in claimed) {
        expect(state.isPlugin(e['entryId']! as String), isFalse, reason: '${e['entryId']} (${e['owner']})');
      }
      expect(pluginConfigEntries(state), _r14Plugins);
      // Control: the same list without what R7 adds. Core ids are refused
      // by the bundle list too (the core layers declare them as well); an
      // overlay row no other bundle declares gets through, so for those the
      // owner is what refuses them.
      final older = _state(
        bundles,
        raw: [
          for (final e in raw)
            {...e}..removeWhere((k, _) => const {'owner', 'bundle', 'kind', 'source', 'writable'}.contains(k)),
        ],
      );
      expect(older.isPlugin('webserver'), isFalse);
      for (final id in ['dsh-app-phone', 'bare-overlay', 'home-insert', 'cli-insert']) {
        expect(older.isPlugin(id), isTrue, reason: id);
        expect(state.isPlugin(id), isFalse, reason: id);
      }
    });

    test('owner installed for an entry no chosen bundle carries: refused by the bundle list', () {
      final raw = _with(_raw(), 'disabled-owner', {'configurable': true, 'writable': true, 'reason': null});
      final state = _state(_bundles(), raw: raw);
      expect(state.entries['disabled-owner']!.owner, 'installed');
      expect(state.isPlugin('disabled-owner'), isFalse, reason: 'its bundle is switched off');
      expect(pluginConfigEntries(_state(null, raw: raw)), isEmpty, reason: 'no bundle list yet: nothing');
    });
  });

  group('both must agree: the confirmed plugin list (CR-a17797b) and R7', () {
    test('a plugin list not confirmed grants nothing, whatever R7 says', () {
      for (final scope in [PluginConfigScope.none, PluginConfigScope.failed, PluginConfigScope.offline]) {
        final state = PluginConfigState(
          forms: const {},
          lazy: true,
          complete: true,
          entries: {for (final e in _listed(_raw())) e.entryId: PluginConfigEntry.listed(e)},
          scope: scope,
        );
        expect(pluginConfigEntries(state), isEmpty, reason: '${scope.status}');
        for (final id in _r14Plugins) {
          expect(state.isPlugin(id), isFalse, reason: '$id (${scope.status})');
          expect(pluginConfigReadOnlyNote(state, id), isNull, reason: '$id (${scope.status})');
        }
      }
    });

    test('the bridge: reads, writes and credentials go out only while both say plugin', () async {
      final host = await FakeBridgeHost.start();
      addTearDown(host.close);
      host.entries['speech-to-text-sensevoice'] = sensevoiceEntry();
      final item = {
        'entryId': 'speech-to-text-sensevoice',
        'package': '@deepseek-ai/dsh-experimental-speech-to-text-sensevoice',
        'owner': 'optional',
        'bundle': '@deepseek-ai/dsh-experimental-voice-input-bundle',
        'kind': 'plugin',
        'source': 'official-optional-bundle',
        'label': {'en': 'Voice input', 'zh': '语音输入'},
        'state': 'active',
        'configurable': true,
        'writable': true,
      };
      host.listed = [item];
      final client = await DshClient.connect(baseUri: host.baseUri, token: FakeBridgeHost.token, startMux: false);
      addTearDown(client.close);
      final confirmed = PluginConfigScope.of(_bundles(host.bundles.cast<Map<String, Object?>>()));
      var scope = confirmed;
      final api = BridgePluginConfigApi(client, _NoFallback(), scope: () => scope);
      await api.describe();
      expect((await api.read('speech-to-text-sensevoice'))!.credentialRefs, contains('SENSEVOICE_KEY'));
      expect(await api.describeCredentials({'SENSEVOICE_KEY'}), contains('SENSEVOICE_KEY'));

      Future<void> refused(String message) async {
        await expectLater(
          api.read('speech-to-text-sensevoice'),
          throwsA(isA<PluginConfigFailure>().having((f) => f.message, 'message', message)),
        );
        await expectLater(
          api.apply('speech-to-text-sensevoice', const [
            SettingsOp.set(['threads'], 4),
          ], revision: 'r1').drain<void>(),
          throwsA(isA<PluginConfigFailure>()),
        );
        await expectLater(api.setCredential('SENSEVOICE_KEY', 'sk-x'), throwsA(isA<PluginConfigFailure>()));
        expect(await api.describeCredentials({'SENSEVOICE_KEY'}), isEmpty);
      }

      // R7 says plugin, the plugin list failed: refused.
      scope = PluginConfigScope.failed;
      await refused('插件清单读取失败，稍后重试');
      // The list confirmed again, R7 now says an overlay owns it: refused.
      scope = confirmed;
      host.listed = [
        {...item, 'owner': 'overlay', 'kind': 'overlay', 'bundle': null},
      ];
      await api.describe();
      await refused('暂不支持在这里设置');
      // Only the one read while both agreed reached the Host.
      expect(host.requests.where((r) => r.$2.startsWith('$dshGoPluginConfigPath/')), hasLength(1));
      expect(host.writes(), isEmpty);
      expect(host.requests.where((r) => r.$2 == '/api/credentials/set'), isEmpty);
      expect(host.credentials, isEmpty);
    });
  });

  group('read-only in the list', () {
    test('covered entries say 「由配置文件固定」 before they are opened', () {
      final state = _state(_bundles());
      for (final id in _r14Plugins) {
        final note = pluginConfigReadOnlyNote(state, id, l10n: _zh);
        expect(note, _covered.contains(id) ? '由配置文件固定' : isNull, reason: id);
        expect(state.entries[id]!.readOnly, _covered.contains(id), reason: id);
      }
      expect(pluginConfigReadOnlyNote(state, 'home-covered', l10n: _en), 'Set by configuration file');
      // Not a plugin's: nothing to say about it here.
      expect(pluginConfigReadOnlyNote(state, 'dsh-app-phone'), isNull);
    });

    test('an engine that cannot take the write: 「只读」', () {
      final raw = _with(_raw(), 'normal', {'writable': false, 'reason': 'host-unavailable'});
      final state = _state(_bundles(), raw: raw);
      expect(pluginConfigReadOnlyNote(state, 'normal', l10n: _zh), '只读');
      expect(pluginConfigReadOnlyNote(state, 'normal', l10n: _en), 'Read-only');
      expect(state.entries['normal']!.fixedByFile, isFalse);
    });

    test('the covered entry as read: the form is not writable either', () async {
      final host = await FakeBridgeHost.start();
      addTearDown(host.close);
      host.listed = _raw();
      host.recorded['speech-to-text-sensevoice'] = _fixture('bridge_entry_r14_sensevoice.json');
      final client = await DshClient.connect(baseUri: host.baseUri, token: FakeBridgeHost.token, startMux: false);
      addTearDown(client.close);
      final scope = PluginConfigScope.of(_bundles());
      final api = BridgePluginConfigApi(client, _NoFallback(), scope: () => scope);
      final catalog = (await api.describe())!;
      expect(catalog.entries['speech-to-text-sensevoice']!.readOnly, isTrue);
      final form = (await api.read('speech-to-text-sensevoice'))!;
      expect(form.view.writable, isFalse);
      expect(form.view.schema.fields, hasLength(23));
    });
  });

  group('names: one entry, the bundle; several, bundle · entry', () {
    test('the recorded Host, in Chinese and English', () {
      final bundles = _bundles();
      final state = _state(bundles);
      String zh(String id) => pluginConfigTitle(id, bundles, state: state, l10n: _zh);
      String en(String id) => pluginConfigTitle(id, bundles, state: state, l10n: _en);
      expect([for (final id in _voice) zh(id)], ['语音输入 · 语音识别', '语音输入 · SenseVoice 本地识别', '语音输入 · 语音转写接口']);
      expect(
        [for (final id in _voice) en(id)],
        [
          'Voice input · Speech recognition',
          'Voice input · Local SenseVoice recognition',
          'Voice input · Speech transcription API',
        ],
      );
      // Session search: one entry to set (the other is core's module).
      expect(zh('optional-tool-session-query'), '会话搜索');
      expect(en('optional-tool-session-query'), 'Session search');
      expect(zh('error-entry'), 'wave10-r7-error');
      // The local bundle's rows all carry one module title: the ids tell
      // them apart.
      expect(zh('normal'), 'R7 自装套件 · Normal');
      expect(zh('home-covered'), 'R7 自装套件 · Home covered');
      expect(en('flag-only'), 'R7 installed bundle · Flag only');
      final all = [for (final id in _r14Plugins) zh(id)];
      expect(all.toSet(), hasLength(all.length), reason: 'no two the same: $all');
    });

    test('rows without titles: the official table, else the id in words', () {
      final raw = [
        for (final b in _rawBundles())
          if (b['name'] == '@deepseek-ai/dsh-experimental-voice-input-bundle')
            {
              ...b,
              'rows': [
                for (final r in (b['rows']! as List).cast<Map<String, Object?>>()) {...r}..remove('meta'),
              ],
            }
          else
            b,
      ];
      final bundles = _bundles(raw);
      final state = _state(bundles);
      expect(
        [for (final id in _voice) pluginConfigTitle(id, bundles, state: state, l10n: _zh)],
        ['语音输入 · 语音识别', '语音输入 · SenseVoice 识别', '语音输入 · 转写接口'],
      );
      expect(
        [for (final id in _voice) pluginConfigTitle(id, bundles, state: state, l10n: _en)],
        ['Voice input · Speech recognition', 'Voice input · SenseVoice recognition', 'Voice input · Transcription API'],
      );
      expect(pluginConfigIdName('optional-terminal-bash', l10n: _zh), 'Bash 终端');
      expect(pluginConfigIdName('optional-my-cache'), 'My cache');
    });

    test('a schema that names itself, once its form is read', () {
      final raw = [
        for (final b in _rawBundles())
          if (b['name'] == '@deepseek-ai/dsh-experimental-voice-input-bundle')
            {
              ...b,
              'rows': [
                for (final r in (b['rows']! as List).cast<Map<String, Object?>>()) {...r}..remove('meta'),
              ],
            }
          else
            b,
      ];
      final bundles = _bundles(raw);
      final form = PluginConfigForm(
        SettingsNamespaceView(
          ns: 'api-speech-to-text',
          schema: SchemaNode.fromJson({
            'type': 'object',
            'meta': {
              'title': {'zh': '浏览器录音接口', 'en': 'Browser recording API'},
            },
            'dict': {
              'maxAudioBytes': {'type': 'number', 'meta': {}},
            },
          }),
          value: const {'maxAudioBytes': 1},
          revision: 0,
        ),
      );
      final state = _state(bundles, forms: {'api-speech-to-text': form});
      expect(pluginConfigTitle('api-speech-to-text', bundles, state: state, l10n: _zh), '语音输入 · 浏览器录音接口');
      expect(
        pluginConfigTitle('api-speech-to-text', bundles, state: state, l10n: _en),
        'Voice input · Browser recording API',
      );
    });

    test('a bundle without a title of its own adds nothing: the entries\' names', () {
      final raw = [
        for (final b in _rawBundles())
          if (b['name'] == '@deepseek-ai/dsh-experimental-voice-input-bundle') ({...b}..remove('meta')) else b,
      ];
      final bundles = _bundles(raw);
      final state = _state(bundles);
      expect(
        [for (final id in _voice) pluginConfigTitle(id, bundles, state: state, l10n: _zh)],
        ['语音识别', 'SenseVoice 本地识别', '语音转写接口'],
      );
    });

    test('no bundle list at hand: R7\'s own bundle and label still keep them apart', () {
      final state = _state(_bundles());
      expect(
        [for (final id in _voice) pluginConfigTitle(id, null, state: state, l10n: _zh)],
        ['语音输入 · 语音识别', '语音输入 · SenseVoice 识别', '语音输入 · 转写接口'],
      );
    });

    test('the bundle\'s sheet lists each by its own name', () {
      final bundles = _bundles();
      final state = _state(bundles);
      expect(
        [for (final id in _voice) pluginConfigEntryName(id, bundles, state: state, l10n: _zh)],
        ['语音识别', 'SenseVoice 本地识别', '语音转写接口'],
      );
      // A row titled with its package name says nothing: the table's name.
      expect(
        bundles
            .expand((b) => b.rows)
            .firstWhere((r) => r.rowId == 'optional-tool-session-query')
            .meta!
            .title!
            .resolve(),
        '@deepseek-ai/dsh-tool-session-query',
      );
      expect(pluginConfigEntryName('optional-tool-session-query', bundles, state: state, l10n: _zh), '会话搜索工具');
      expect(
        pluginConfigEntryName('optional-tool-session-query', bundles, state: state, l10n: _en),
        'Session search tool',
      );
    });
  });

  group('an older bridge (r13: no owner, no writable)', () {
    List<Map<String, Object?>> r13() => _raw('bridge_catalog_r13.json');
    List<PluginBundle> r13Bundles() => _bundles(_rawBundles('plugin_bundles_r13.json'));

    test('the same entries as before, none marked read-only', () {
      final state = _state(r13Bundles(), raw: r13());
      expect(pluginConfigEntries(state), [
        'speech-to-text',
        'speech-to-text-sensevoice',
        'api-speech-to-text',
        'local-notes',
      ]);
      for (final e in state.entries.values) {
        expect((e.owner, e.bundle, e.kind, e.source, e.writable), (null, null, null, null, null), reason: e.entryId);
        expect(pluginConfigReadOnlyNote(state, e.entryId), isNull, reason: e.entryId);
      }
    });

    test('names as before R7: each row by its own title, in the app\'s language whatever is asked', () {
      final bundles = r13Bundles();
      final state = _state(bundles, raw: r13());
      expect(pluginConfigNamedByBundle(state, 'speech-to-text'), isFalse);
      for (final l in [_zh, _en, null]) {
        expect(
          [
            for (final id in [..._voice, 'local-notes']) pluginConfigTitle(id, bundles, state: state, l10n: l),
          ],
          ['语音识别', 'SenseVoice 本地识别', '语音转写接口', 'dsh-go-fixture-local-notes'],
        );
      }
      // The R7 Host's own list: named by bundle.
      expect(pluginConfigNamedByBundle(_state(_bundles()), 'speech-to-text'), isTrue);
    });
  });
}

/// The bridge answers here; the fallback is never asked.
class _NoFallback implements PluginConfigApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('fallback asked: ${invocation.memberName}');
}
