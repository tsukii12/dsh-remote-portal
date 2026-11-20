// A fake `dsh web` for the engine settings tests: `settings/describe` and
// `settings/mutate` with the Host's layering (base, the profile's user layer,
// an optional home-patch overlay that locks the namespace), schema checks on
// writes, revisions and stale-revision conflicts, the credential store, the
// model catalog, the plugin inventory and the bundle list. The namespaces
// start from a recorded DSH 0.2.1-rc.2 `settings/describe`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../plugins/support/fake_plugin_host.dart' show FakeMuxLink;
import '../shell/golden_harness.dart' show FakeSettings, goldenApp, loadGoldenFonts;

Object? _fixture(String name) => jsonDecode(File('../packages/dsh_client/test/fixtures/$name').readAsStringSync());

/// `settings/describe` of a throwaway DSH 0.2.1-rc.2 (fresh HOME; the
/// thinking-translation and plugin-market bundles on).
Map<String, Object?> recordedDescribe() => _fixture('settings_describe.json')! as Map<String, Object?>;

/// `pluginInventory/list` of the same Host, trimmed.
Map<String, Object?> recordedInventory() => _fixture('plugin_inventory.json')! as Map<String, Object?>;

/// The two official optional bundles that Host had on (`listBundles`,
/// trimmed): what makes `cot-translation` and `plugin-market` plugins
/// (PluginConfigScope), the rest of [recordedDescribe] being DSH's own.
List<Object?> recordedBundles() => [
  for (final (name, rows) in [
    (
      '@deepseek-ai/dsh-experimental-cot-translation-bundle',
      {
        'translator': '@deepseek-ai/dsh-experimental-translator',
        'cot-translation': '@deepseek-ai/dsh-experimental-client-ui-cot-translation',
      },
    ),
    (
      '@deepseek-ai/dsh-experimental-plugin-market-bundle',
      {
        'plugin-market': '@deepseek-ai/dsh-plugin-market',
        'ui-plugin-market': '@deepseek-ai/dsh-client-ui-plugin-market',
      },
    ),
  ])
    {
      'name': name,
      'official': true,
      'availability': 'installation',
      'enabled': true,
      'installed': false,
      'optional': true,
      'removable': false,
      'rows': [
        for (final MapEntry(:key, :value) in rows.entries) {'rowId': key, 'moduleName': value},
      ],
      'overrides': <Object?>[],
    },
];

Map<String, Object?> _deepMerge(Map<String, Object?> under, Map<String, Object?> over) {
  final merged = {...under};
  for (final MapEntry(:key, :value) in over.entries) {
    final below = merged[key];
    merged[key] = below is Map<String, Object?> && value is Map<String, Object?> ? _deepMerge(below, value) : value;
  }
  return merged;
}

Map<String, Object?> _json(Object? value) => (jsonDecode(jsonEncode(value)) as Map).cast<String, Object?>();

/// One namespace of the fake Host.
class FakeNamespace {
  FakeNamespace({
    required this.ns,
    required this.schemaJson,
    required this.base,
    Map<String, Object?>? user,
    this.overlay,
    this.revision = 0,
    this.autoGenerate = true,
  }) : user = user ?? {},
       schema = SchemaNode.fromJson(schemaJson);

  final String ns;
  final Object? schemaJson;
  final SchemaNode schema;
  Map<String, Object?> base;
  Map<String, Object?> user;

  /// A home patch above the profile: wins, and refuses every write.
  Map<String, Object?>? overlay;
  int revision;
  bool autoGenerate;

  /// Secrets live here (paths joined with '.'), never in [user]'s view.
  final Map<String, Object?> secrets = {};

  Map<String, Object?> get value => _deepMerge(_deepMerge(base, user), overlay ?? const {});

  List<List<String>> get secretPaths => [
    for (final MapEntry(:key, :value) in (schema.fields ?? const <String, SchemaNode>{}).entries)
      if (value.effective.isSecret) [key],
  ];

  Map<String, Object?> _redact(Map<String, Object?> map) {
    final copy = {...map};
    for (final path in secretPaths) {
      copy.remove(path.single);
    }
    return copy;
  }

  Map<String, Object?> view() => {
    'ns': ns,
    'autoGenerate': autoGenerate,
    'schema': schemaJson,
    'value': _json(_redact(value)),
    'base': _json(_redact(base)),
    'user': _json(_redact(user)),
    'applies': 'live',
    'secrets': [
      for (final path in secretPaths) {'path': path, 'set': secrets.containsKey(path.join('.'))},
    ],
    'revision': revision,
  };
}

DshRemoteException _rejected(String ns, String message) => DshRemoteException('settings/rejected', message, {'ns': ns});

/// Mirrors the engine's schemastery messages for the checks the forms rely on.
String? _invalid(SchemaNode node, Object? value, String path) {
  final n = node.effective;
  final meta = n.meta;
  String at(String text) => 'invalid config:\n  - \$.$path $text (at $path)';
  switch (n.type) {
    case 'number':
      if (value is! num) return at('expected number but got $value');
      if (meta.max != null && value > meta.max!) return at('expected number <= ${meta.max} but got $value');
      if (meta.min != null && value < meta.min!) return at('expected number >= ${meta.min} but got $value');
      if (meta.step != null && meta.step! > 0) {
        final k = (value - (meta.min ?? 0)) / meta.step!;
        if ((k - k.round()).abs() > 1e-9) return at('expected number multiple of ${meta.step} but got $value');
      }
    case 'string':
      if (value is! String) return at('expected string but got $value');
      if (meta.pattern != null && !RegExp(meta.pattern!).hasMatch(value)) {
        return at('expect string to match regexp /${meta.pattern}/');
      }
    case 'boolean':
      if (value is! bool) return at('expected boolean but got $value');
    case 'union':
      final values = n.enumValues;
      if (values != null && !values.contains(value)) return at('expected one of $values but got $value');
    case 'array':
      if (value is! List) return at('expected array but got $value');
      for (final (i, item) in value.indexed) {
        final error = _invalid(n.inner!, item, '$path[$i]');
        if (error != null) return error;
      }
    case 'object':
      if (value is! Map) return at('expected object but got $value');
      for (final MapEntry(key: name, value: child) in n.fields!.entries) {
        if (!value.containsKey(name)) continue;
        final error = _invalid(child, value[name], '$path.$name');
        if (error != null) return error;
      }
  }
  return null;
}

/// The fake Host behind a [DshClient].
class FakeSettingsHost extends DshCarrier {
  FakeSettingsHost({Map<String, Object?>? describe, this.writable = true}) {
    final recorded = describe ?? recordedDescribe();
    for (final raw in (recorded['namespaces']! as List).cast<Map<String, Object?>>()) {
      final ns = raw['ns']! as String;
      namespaces[ns] = FakeNamespace(
        ns: ns,
        schemaJson: raw['schema'],
        base: _json(raw['base'] ?? raw['value']),
        user: _json(raw['user'] ?? const {}),
        revision: raw['revision'] as int? ?? 0,
        autoGenerate: raw['autoGenerate'] != false,
      );
    }
  }

  bool writable;
  final Map<String, FakeNamespace> namespaces = {};

  /// The credential store: reference → value.
  final Map<String, String> credentials = {};

  /// References the launch environment supplies (writes refused).
  final Set<String> envCredentials = {};

  Map<String, Object?> modelCatalog = sampleCatalog;
  Map<String, Object?>? inventory;
  List<Object?> bundles = const [];

  /// `pluginManager/listBundles` fails (the plugin list can't be read).
  bool failListBundles = false;

  /// Calls in order (endpoint, args).
  final List<(String, Map<String, Object?>)> calls = [];

  /// Runs before a `settings/mutate` is answered (to move the revision under
  /// the client, say).
  FutureOr<void> Function(String ns)? beforeMutate;

  /// Holds `settings/mutate` answers until completed.
  Completer<void>? gate;

  FakeMuxLink? link;

  List<Map<String, Object?>> mutates() => [
    for (final (e, args) in calls)
      if (e == 'settings/mutate') args,
  ];

  /// Changes a namespace behind the client's back (another device).
  void externalSet(String ns, List<String> path, Object? value, {bool notify = true}) {
    final n = namespaces[ns]!;
    n.user = withPath(n.user, path, value);
    n.revision++;
    if (notify) emit('settings/document-updated', [ns, n.revision]);
  }

  void emit(String event, List<Object?> args) => link?.push({'type': 'emit', 'event': event, 'args': args});

  @override
  String get kind => 'fake-settings';

  @override
  DshTracer? get tracer => null;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    calls.add((endpoint, args));
    try {
      return RpcOk(await _answer(endpoint, args));
    } on DshRemoteException catch (error) {
      return RpcError(error);
    }
  }

  Future<Object?> _answer(String endpoint, Map<String, Object?> args) async {
    switch (endpoint) {
      case 'settings/describe':
        return {
          'writable': writable,
          'hasDocument': true,
          'namespaces': [for (final n in namespaces.values) n.view()],
        };
      case 'settings/mutate':
        final ns = args['ns']! as String;
        await beforeMutate?.call(ns);
        await gate?.future;
        final n = namespaces[ns];
        if (n == null) throw _rejected(ns, 'No configurable plugin entry "$ns"');
        if (!writable) throw _rejected(ns, 'settings are read-only');
        final expected = args['expectedRevision'] as int?;
        if (expected != null && expected != n.revision) {
          throw DshRemoteException(
            'settings/conflict',
            'settings namespace "$ns" changed since it was read (expected revision $expected, now ${n.revision})',
            {'ns': ns, 'expected': expected, 'actual': n.revision},
          );
        }
        if (n.overlay != null) {
          throw _rejected(ns, 'Configuration for "$ns" is overridden by a home patch or command-line overlay');
        }
        var user = n.user;
        for (final op in (args['ops']! as List).cast<Map<String, Object?>>()) {
          final path = (op['path']! as List).cast<String>();
          if (n.secretPaths.any((p) => p.join('.') == path.join('.'))) {
            if (op['op'] == 'set') {
              n.secrets[path.join('.')] = op['value'];
            } else {
              n.secrets.remove(path.join('.'));
            }
            continue;
          }
          user = op['op'] == 'set' ? withPath(user, path, op['value']) : withoutPath(user, path);
        }
        final merged = _deepMerge(n.base, user);
        for (final MapEntry(:key, :value) in (n.schema.fields ?? const <String, SchemaNode>{}).entries) {
          if (!merged.containsKey(key)) continue;
          final error = _invalid(value, merged[key], key);
          if (error != null) throw _rejected(ns, error);
        }
        if (jsonEquals(merged, n.base)) user = {};
        if (!jsonEquals(user, n.user)) {
          n.user = user;
          n.revision++;
        }
        scheduleMicrotask(() => emit('settings/document-updated', [ns, n.revision]));
        return n.view();
      case 'credentials/describe':
        return {
          for (final ref in (args['refs']! as List).cast<String>())
            ref: {
              'configured': credentials.containsKey(ref) || envCredentials.contains(ref),
              'writable': !envCredentials.contains(ref),
              if (credentials.containsKey(ref) || envCredentials.contains(ref))
                'source': envCredentials.contains(ref) ? 'env' : 'file',
            },
        };
      case 'credentials/set':
        final ref = args['ref']! as String;
        if (envCredentials.contains(ref)) {
          throw DshRemoteException('credential/rejected', 'supplied by the launch environment', {'ref': ref});
        }
        credentials[ref] = args['value']! as String;
        scheduleMicrotask(() => emit('credentials/reference-updated', [ref]));
        return null;
      case 'credentials/unset':
        final ref = args['ref']! as String;
        credentials.remove(ref);
        scheduleMicrotask(() => emit('credentials/reference-updated', [ref]));
        return null;
      case 'session/modelCatalog':
        return modelCatalog;
      case 'pluginInventory/list':
        if (inventory == null) throw const DshRemoteException('gateway/method-not-found', 'no pluginInventory');
        return inventory;
      case 'pluginManager/listBundles':
        if (failListBundles) throw const DshRemoteException('gateway/internal', 'listBundles unavailable');
        return bundles;
      case 'pluginManager/listPlugins':
        return const <Object?>[];
    }
    throw DshRemoteException('gateway/method-not-found', 'no handler for $endpoint');
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) async => link = FakeMuxLink();

  @override
  Future<void> close() async {}
}

/// `session/modelCatalog`: DeepSeek and one custom route.
const sampleCatalog = <String, Object?>{
  'defaultSelection': {'provider': 'deepseek-official', 'model': 'deepseek-flash'},
  'routableProviders': ['deepseek-official', 'custom-mygw'],
  'groups': [
    {
      'id': 'deepseek-official',
      'name': 'DeepSeek',
      'models': [
        {'id': 'deepseek-flash', 'name': 'DeepSeek-V4.1-Flash'},
        {'id': 'deepseek-v4-pro', 'name': 'DeepSeek-V4-Pro'},
      ],
    },
    {
      'id': 'custom-mygw',
      'name': 'My Gateway',
      'models': [
        {'id': 'qwen3-coder', 'name': 'Qwen3 Coder'},
      ],
    },
  ],
  'failures': <Object?>[],
};

/// A connected client over [host] (mux started so host events arrive).
Future<DshClient> fakeClient(FakeSettingsHost host) async {
  final client = DshClient.withCarrier(host);
  return client;
}

HostConnection fakeConnection(DshClient client, {bool local = true}) => HostConnection(hostId: '', 
  client: client,
  label: local ? '本机' : '电脑 · SSH',
  isLocal: local,
  kind: local ? HostKind.portal : HostKind.portal,
);

/// What the engine settings pages need, with [host] as the active engine.
List<Override> engineOverrides(DshClient? client, {bool local = true, AppSettings? settings}) => [
  activeConnectionProvider.overrideWithValue(AsyncData(client == null ? null : fakeConnection(client, local: local))),
  localSafeModeProvider.overrideWithValue(false),
  settingsProvider.overrideWith(() => FakeSettings(settings ?? const AppSettings(loaded: true))),
  // Live engine settings, not the read-list display cache: its identity
  // would read the local runtime, which these pages do not fake.
  readListIdentityProvider.overrideWithValue(null),
];

/// A few frames: state changes land, their transitions finish.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }
}

/// Lets async fakes (microtasks, timers under runAsync) finish.
Future<void> flush(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
  await settle(tester);
}

/// The page in a phone-sized app (390 × [height]).
Future<void> pumpPage(
  WidgetTester tester,
  Widget page, {
  required List<Override> overrides,
  Brightness brightness = Brightness.light,
  double height = 844,
  bool fonts = false,
}) async {
  if (fonts) await tester.runAsync(loadGoldenFonts);
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = Size(390 * 2, height * 2);
  tester.view.padding = const FakeViewPadding(top: 32 * 2, bottom: 24 * 2);
  tester.view.viewPadding = const FakeViewPadding(top: 32 * 2, bottom: 24 * 2);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(goldenApp(home: page, brightness: brightness, overrides: overrides));
  await flush(tester);
}

/// The sample bundle list: the base bundle and the optional thinking
/// translation (on), with the rows the settings pages route by.
List<Object?> sampleBundles() => [
  {
    'name': '@deepseek-ai/dsh-base',
    'official': false,
    'availability': 'installation',
    'version': '0.2.1-rc.2',
    'meta': {'title': '@deepseek-ai/dsh-base'},
    'enabled': true,
    'installed': false,
    'optional': false,
    'removable': false,
    'readOnlyReason': 'management-required',
    'rows': [
      for (final id in [
        'plugin-manager',
        'tool-plugin-manager',
        'session-log-deepseek',
        'remote-access',
        'bash-sandbox',
        'subagent',
        'web',
        'web-search-deepseek',
        'web-deepseek-api',
        'agent-loop',
        'pwsh-sandbox',
        'tool-bash',
        'tool-pwsh',
      ])
        {'rowId': id, 'moduleName': '@deepseek-ai/dsh-$id', 'entryId': 'include:$id'},
    ],
    'overrides': <Object?>[],
  },
  {
    'name': '@deepseek-ai/dsh-web-app',
    'official': false,
    'availability': 'installation',
    'version': '0.2.1-rc.2',
    'meta': {
      'title': {'en': 'web-app', 'zh': 'Web 应用运行支持'},
    },
    'enabled': true,
    'installed': false,
    'optional': false,
    'removable': false,
    'rows': [
      for (final id in ['subagent-model-selection-settings', 'ui-theme'])
        {'rowId': id, 'moduleName': '@deepseek-ai/dsh-$id', 'entryId': 'include:$id'},
    ],
    'overrides': <Object?>[],
  },
  {
    'name': '@deepseek-ai/dsh-experimental-cot-translation-bundle',
    'official': true,
    'availability': 'installation',
    'version': '0.2.1-rc.2',
    'meta': {
      'title': {'en': 'Machine translation of reasoning', 'zh': '思考过程机器翻译'},
      'description': {'zh': '把展开的思考过程翻译成界面语言。'},
    },
    'enabled': true,
    'installed': false,
    'optional': true,
    'removable': false,
    'rows': [
      {
        'rowId': 'translator',
        'moduleName': '@deepseek-ai/dsh-experimental-translator',
        'entryId': 'include:translator',
      },
      {
        'rowId': 'cot-translation',
        'moduleName': '@deepseek-ai/dsh-experimental-cot-translation',
        'entryId': 'include:cot-translation',
      },
    ],
    'overrides': <Object?>[],
  },
];
