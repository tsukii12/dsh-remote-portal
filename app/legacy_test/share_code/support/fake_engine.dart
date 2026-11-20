// A small fake DSH Host for share-code tests: settings, plugins and presets
// answered from in-memory state, every call recorded.

import 'dart:async';
import 'dart:io';

import 'package:dsh_app/share_code/guest_fs.dart';
import 'package:dsh_app/share_code/share_net.dart';
import 'package:dsh_client/dsh_client.dart';

class FakeEngine extends DshCarrier {
  FakeEngine({this.allowInstall = true});

  final bool allowInstall;
  final calls = <(String, Map<String, Object?>)>[];

  /// ns → {value, user, base, revision}.
  final settings = <String, Map<String, Object?>>{};
  final bundles = <Map<String, Object?>>[];
  final presets = <Map<String, Object?>>[];

  /// Spec → failure code for installs that should fail.
  final failInstall = <String, String>{};
  bool restartRequired = false;
  bool describeFails = false;

  List<Map<String, Object?>> argsOf(String endpoint) => [
    for (final (e, a) in calls)
      if (e == endpoint) a,
  ];

  void addSettings(String ns, {Map<String, Object?> base = const {}, Map<String, Object?> user = const {}}) {
    settings[ns] = {
      'base': {...base},
      'user': {...user},
      'revision': 1,
    };
  }

  void addBundle(
    String name, {
    String? version,
    String? source,
    bool official = false,
    bool optional = false,
    bool enabled = true,
    bool installed = true,
    List<Map<String, Object?>> rows = const [],
    String? title,
  }) {
    bundles.add({
      'name': name,
      'version': ?version,
      'source': ?source,
      'official': official,
      'optional': optional,
      'enabled': enabled,
      'installed': installed,
      'removable': installed && !official,
      'availability': installed ? 'profile' : 'installation',
      'rows': rows,
      if (title != null) 'meta': {'title': title},
    });
  }

  @override
  String get kind => 'fake';

  @override
  DshTracer? get tracer => null;

  static const _relayBlocked = {'pluginManager/installBundle', 'pluginManager/removeBundle'};

  @override
  bool allowsEndpoint(String endpoint) => allowInstall || !_relayBlocked.contains(endpoint);

  Map<String, Object?> _view(String ns) {
    final s = settings[ns]!;
    final base = s['base'] as Map<String, Object?>;
    final user = s['user'] as Map<String, Object?>;
    return {
      'ns': ns,
      'schema': s['schema'],
      'secrets': s['secrets'],
      'value': {...base, ...user},
      'base': base,
      'user': user,
      'revision': s['revision'],
    };
  }

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    calls.add((endpoint, args));
    if (!allowsEndpoint(endpoint)) return RpcError(DshRemoteException('METHOD_NOT_ALLOWED', 'blocked'));
    switch (endpoint) {
      case 'settings/describe':
        if (describeFails) return RpcError(DshRemoteException('INTERNAL', 'describe failed'));
        return RpcOk({
          'writable': true,
          'namespaces': [for (final ns in settings.keys) _view(ns)],
        });
      case 'settings/mutate':
        final ns = args['ns'] as String;
        final s = settings[ns];
        if (s == null) return RpcError(DshRemoteException('settings/rejected', 'No configurable plugin entry "$ns"'));
        if (args['expectedRevision'] != null && args['expectedRevision'] != s['revision']) {
          return RpcError(DshRemoteException('settings/conflict', 'stale'));
        }
        final user = Map<String, Object?>.of(s['user'] as Map<String, Object?>);
        for (final op in args['ops'] as List) {
          final m = op as Map;
          final path = (m['path'] as List).cast<String>();
          if (m['op'] == 'set') user[path.first] = m['value'];
        }
        s['user'] = user;
        s['revision'] = (s['revision'] as int) + 1;
        return RpcOk(_view(ns));
      case 'pluginManager/listBundles':
        return RpcOk(bundles);
      case 'agentPresets/list':
        return RpcOk({'presets': presets});
      case 'pluginManager/installBundle':
        final spec = args['spec'] as String;
        final code = failInstall[spec];
        if (code != null) {
          return RpcOk({
            'application': 'failed',
            'target': spec,
            'packageResult': {'exitCode': 1, 'kind': code, 'output': ''},
          });
        }
        final name = spec.startsWith('@') ? '@${spec.substring(1).split('@').first}' : spec.split('@').first;
        bundles.removeWhere((b) => b['name'] == name);
        addBundle(name, version: spec.contains('@', 1) ? spec.split('@').last : null, source: spec);
        return RpcOk({
          'application': restartRequired ? 'restart-required' : 'applied',
          'target': spec,
          'bundle': name,
          'changed': true,
        });
      case 'pluginManager/removeBundle':
        bundles.removeWhere((b) => b['name'] == args['name']);
        return RpcOk({'application': 'applied', 'target': args['name'], 'changed': true});
      case 'pluginManager/setBundleEnabled':
        for (final b in bundles) {
          if (b['name'] == args['name']) b['enabled'] = args['enabled'];
        }
        return RpcOk({'application': 'applied', 'target': args['name'], 'changed': true});
      default:
        return RpcError(DshRemoteException('gateway/method-not-found', endpoint));
    }
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => Completer<DshMuxLink>().future;

  @override
  Future<void> close() async {}
}

class FakeShareNet implements ShareNet {
  final npm = <String, NpmFacts>{};
  final gists = <String, String>{};
  final created = <(String token, String name, String content)>[];

  @override
  Future<NpmFacts?> npmFacts(String name, String version) async => npm['$name@$version'];

  @override
  Future<String> createGist({required String token, required String fileName, required String content}) async {
    if (token != 'good') throw const GistException('GitHub 令牌无效或没有 Gist 权限', unauthorized: true);
    created.add((token, fileName, content));
    const id = 'aa5a315d61ae9438b18d';
    gists[id] = content;
    return id;
  }

  @override
  Future<String> fetchGist(String id) async => gists[id] ?? (throw const GistException('找不到这个 Gist'));
}

/// A throwaway rootfs with DSH home in it.
GuestFs tempGuest() {
  final runtime = Directory.systemTemp.createTempSync('share-guest-');
  final root = Directory('${runtime.path}/rootfs')..createSync();
  Directory('${root.path}/root/.dsh').createSync(recursive: true);
  return GuestFs(root);
}

void writeGuest(GuestFs fs, String path, String text) {
  final f = fs.file(path);
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(text);
}
