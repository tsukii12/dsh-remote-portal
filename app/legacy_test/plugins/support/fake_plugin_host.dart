import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

/// `PluginsApi` is an extension on [DshClient], so fakes sit one level down:
/// a [DshCarrier] answering `pluginManager/*` from [handlers] and a mux link
/// that can push `$events` items.
class FakePluginCarrier extends DshCarrier {
  FakePluginCarrier({this.allowInstall = true});

  /// False imitates the relay allow-list (no install/remove/inspect).
  final bool allowInstall;

  final List<(String endpoint, Map<String, Object?> args)> calls = [];
  final Map<String, FutureOr<Object?> Function(Map<String, Object?> args)> handlers = {};
  FakeMuxLink? link;

  static const _relayBlocked = {
    'pluginManager/installBundle',
    'pluginManager/removeBundle',
    'pluginManager/inspect',
    'pluginManager/cancelInstall',
    'pluginManager/waitForInstall',
  };

  List<Map<String, Object?>> argsOf(String endpoint) => [
    for (final (e, args) in calls)
      if (e == endpoint) args,
  ];

  @override
  String get kind => allowInstall ? 'fake' : 'fake-relay';

  @override
  DshTracer? get tracer => null;

  @override
  bool allowsEndpoint(String endpoint) => allowInstall || !_relayBlocked.contains(endpoint);

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    calls.add((endpoint, args));
    if (!allowsEndpoint(endpoint)) {
      return RpcError(DshRemoteException('METHOD_NOT_ALLOWED', 'not available over the relay'));
    }
    final handler = handlers[endpoint];
    if (handler == null) {
      return RpcError(DshRemoteException('gateway/method-not-found', 'no handler for $endpoint'));
    }
    try {
      return RpcOk(await handler(args));
    } on DshRemoteException catch (error) {
      return RpcError(error);
    }
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) async => link = FakeMuxLink();

  @override
  Future<void> close() async {}

  /// Pushes a `plugin-manager/*` emit (start the mux first).
  void emit(String event, Map<String, Object?> payload) => link!.push({
    'type': 'emit',
    'event': event,
    'args': [payload],
  });
}

class FakeMuxLink implements DshMuxLink {
  DshMuxFrameHandler? _onFrame;
  String? _eventsId;

  @override
  void start({required DshMuxFrameHandler onFrame, required DshMuxLossHandler onLost}) => _onFrame = onFrame;

  @override
  void open(String streamId, String endpoint, Map<String, Object?> payload) {
    if (endpoint != r'$events') return;
    _eventsId = streamId;
    scheduleMicrotask(
      () => push({
        'type': 'ready',
        'clientId': 'client-1',
        'host': {'home': '/home/u'},
      }),
    );
  }

  void push(Map<String, Object?> value) => _onFrame?.call({'type': 'item', 'streamId': _eventsId, 'value': value});

  @override
  void sendItem(String streamId, Object? value) {}

  @override
  void endUplink(String streamId) {}

  @override
  void cancel(String streamId) {}

  @override
  Future<void> close(int code, String reason) async {}
}

HostConnection fakeHost(DshClient client, {HostKind kind = HostKind.portal, String label = '本机'}) => HostConnection(
  client: client,
  label: label,
  isLocal: kind == HostKind.portal,
  kind: kind,
  hostId: '',
);

class _SelectedHost extends ActiveHostController {
  _SelectedHost(this.host);
  final HostConnection? host;
  @override
  HostRef build() => switch (host?.kind) {
    HostKind.portal => HostRef.portal(host!.hostId!),
    _ => HostRef.none,
  };
}

/// [selectHost]: also select [host] as the active host. Pass false when the
/// test overrides `activeHostProvider` itself (a provider is overridden once).
/// [official]: the official market (default: not published yet, empty);
/// [npmIntegrity]: what npm reports (default: no answer).
List<Override> pluginOverrides(
  HostConnection? host, {
  Map<String, Object?>? index,
  OfficialMarketFetcher? official,
  NpmIntegrityReader? npmIntegrity,
  bool safeMode = false,
  bool selectHost = true,
}) => [
  if (selectHost) activeHostProvider.overrideWith(() => _SelectedHost(host)),
  activeConnectionProvider.overrideWithValue(AsyncData(host)),
  // These existing tests exercise live plugin authority, not a platform root
  // or credential identity. Dedicated read_list_* tests cover cache admission.
  readListIdentityProvider.overrideWithValue(null),
  localSafeModeProvider.overrideWithValue(safeMode),
  marketIndexFetcherProvider.overrideWithValue((url) async => parseMarketIndex(index ?? sampleIndex, url)),
  officialMarketFetcherProvider.overrideWithValue(official ?? () async => emptyOfficialMarket),
  npmIntegrityProvider.overrideWithValue(npmIntegrity ?? (_, _) async => null),
];

/// The official market before anything is published (index.json is a 404).
final emptyOfficialMarket = MarketCatalog(
  MarketIndex(url: Uri.parse(officialIndexUrl), title: LocalizedText.plain('go.dshtui.com')),
);

/// The official fixtures (`fixtures/official-index.json` and
/// `fixtures/dsh-go.json`), written to the contract in
/// docs/design/plugin-market.md §3.
Map<String, Object?> officialIndexJson() =>
    jsonDecode(File('test/plugins/fixtures/official-index.json').readAsStringSync()) as Map<String, Object?>;
Map<String, Object?> officialSidecarJson() =>
    jsonDecode(File('test/plugins/fixtures/dsh-go.json').readAsStringSync()) as Map<String, Object?>;

/// The official market read from the fixtures, as the app reads the live one.
MarketCatalog officialFixtureMarket({Map<String, Object?>? index, Map<String, Object?>? sidecar}) => MarketCatalog(
  parseMarketIndex(index ?? officialIndexJson(), Uri.parse(officialIndexUrl)),
  listings: parseMarketSidecar(sidecar ?? officialSidecarJson()).plugins,
);

Map<String, Object?> ok(Object? value) => {'ok': true, 'value': value};

// ── Sample data (shapes from DSH 0.2.1-rc.2 and dshfind) ────────────────────

Map<String, Object?> bundleJson(
  String name, {
  String? version = '1.0.0',
  bool enabled = true,
  bool installed = true,
  bool official = false,
  bool optional = false,
  bool removable = true,
  String availability = 'profile',
  Object? title,
  Object? description,
  Map<String, Object?>? error,
  String? readOnlyReason,
  Map<String, Object?>? installTarget,
}) => {
  'name': name,
  'official': official,
  'availability': availability,
  'version': ?version,
  'meta': {'title': ?title, 'description': ?description},
  'enabled': enabled,
  'installed': installed,
  'optional': optional,
  'removable': removable,
  'readOnlyReason': ?readOnlyReason,
  'error': ?error,
  'installTarget': ?installTarget,
  'rows': [
    {'rowId': name, 'moduleName': name, 'entryId': 'include:$name'},
  ],
  'overrides': <Object?>[],
};

final sampleBundles = <Object?>[
  bundleJson(
    '@deepseek-ai/dsh-base',
    version: '0.2.1-rc.2',
    installed: false,
    removable: false,
    availability: 'installation',
    readOnlyReason: 'management-required',
  ),
  bundleJson('dsh-approval-gate', version: '0.3.0', description: '危险命令二次确认'),
  bundleJson('broken-thing', version: null, error: {'code': 'not-bundle'}, removable: true),
  bundleJson(
    '@deepseek-ai/dsh-experimental-session-search',
    version: '0.2.1-rc.2',
    official: true,
    optional: true,
    installed: false,
    enabled: false,
    removable: false,
    availability: 'installation',
    title: {'en': 'Session search', 'zh': '会话搜索'},
    description: {'en': 'Search earlier sessions', 'zh': '为智能体提供搜索历史会话的工具。'},
  ),
];

Map<String, Object?> _version(String version, {int ts = 1789469760}) => {
  'version': version,
  'publishTimestamp': ts,
  'source': {'type': 'npm'},
};

final sampleIndex = <String, Object?>{
  'format': 1,
  'title': {'en': 'dshfind · DSH Plugin Directory', 'zh': 'dshfind · DSH 插件目录'},
  'metadata': {
    'categories': {
      'agent': {
        'title': {'en': 'Agent Boosters', 'zh': 'Agent 增强'},
      },
      'tools': {
        'title': {'en': 'Tools & Integrations', 'zh': '工具集成'},
      },
      'skin': {
        'title': {'en': 'Skins & Themes', 'zh': '皮肤主题'},
      },
    },
    'labels': {
      'featured': {
        'title': {'en': "Editor's pick", 'zh': '编辑推荐'},
      },
    },
    'sortKeys': {
      'stars': {
        'title': {'en': 'GitHub stars'},
        'order': 'desc',
      },
    },
  },
  'plugins': [
    {
      'name': 'novel-writer',
      'title': 'novel-writer',
      'description': '小说创作模式：一个统筹队长统领全局，5 个专职子代理协同写作。',
      'author': 'sailoumili',
      'homepage': 'https://dshfind.com/en/plugins/sailoumili/novel-writer',
      'repository': {'url': 'https://github.com/sailoumili/novel-writer'},
      'metadata': {
        'category': 'agent',
        'labels': ['featured'],
        'sortKeys': {'stars': 31},
      },
      'versions': [_version('1.0.2')],
    },
    {
      'name': 'dsh-approval-gate',
      'title': 'Approval Gate',
      'description': 'Ask before dangerous commands',
      'author': 'gatekeeper',
      'metadata': {
        'category': 'tools',
        'keywords': ['审批', 'safety'],
      },
      'versions': [_version('0.4.0'), _version('0.3.0')],
    },
    {
      'name': 'dsh-pink-skin',
      'title': 'Pink Skin',
      'description': '粉色主题皮肤',
      'author': 'artist',
      'metadata': {'category': 'skin'},
      'versions': [_version('2.0.0')],
    },
    {
      'name': 'dsh-memory-lite',
      'title': 'Memory Lite',
      'description': '轻量记忆插件',
      'author': 'mem',
      'versions': [_version('0.1.0')],
    },
  ],
};

Map<String, Object?> installResult({
  String application = 'applied',
  String target = 'novel-writer',
  String? kind,
  Map<String, Object?>? error,
  List<String>? pendingBuilds,
  String? restartReason,
  String? failedAt,
  List<Object?>? registries,
}) => {
  'stage': application == 'applied' || application == 'restart-required' ? 'enable' : 'install',
  'target': target,
  'changed': application == 'applied' || application == 'restart-required',
  'application': application,
  'restartReason': ?restartReason,
  'bundle': application == 'applied' || application == 'restart-required' ? target : null,
  'error': ?error,
  'pendingBuilds': ?pendingBuilds,
  'failedAt': ?failedAt,
  'registries': ?registries,
  if (kind != null)
    'packageResult': {
      'exitCode': 1,
      'output': 'pnpm output for $kind',
      'truncated': false,
      'logPath': '/h/pnpm.log',
      'kind': kind,
    },
};
