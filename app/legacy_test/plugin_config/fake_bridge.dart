// A fake `dsh web` with the dsh-go bridge's plugin-config routes
// (PLUGIN-CONFIG-CONTRACT R1 §4–§5) over real HTTP: login, the entry list,
// one entry's complete form with an opaque revision, `{revision, ops}`
// writes, every refusal the contract names, and the RPCs the page also uses
// (`settings/describe` for a Host without the routes, `credentials/*`,
// `pluginManager/listBundles` for which entries are plugins).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';

import '../engine_settings/support.dart' show recordedDescribe;

/// One entry the fake bridge serves.
class BridgeEntry {
  BridgeEntry(this.entryId, this.schema, {Map<String, Object?>? base, this.secrets = const [], this.package})
    : base = base ?? {};

  final String entryId;

  /// The package its module comes from, as the list reports it.
  final String? package;
  final Map<String, Object?> schema;
  final Map<String, Object?> base;
  Map<String, Object?> user = {};
  int revision = 1;

  /// `{path, configured, credentialRef?, writable?}`.
  List<Map<String, Object?>> secrets;

  Map<String, Object?> _merge(Map<String, Object?> under, Map<String, Object?> over) {
    final merged = {...under};
    for (final MapEntry(:key, :value) in over.entries) {
      final below = merged[key];
      merged[key] = below is Map<String, Object?> && value is Map<String, Object?> ? _merge(below, value) : value;
    }
    return merged;
  }

  Map<String, Object?> toJson() => {
    'v': 1,
    'entryId': entryId,
    'revision': 'r$revision',
    'schema': schema,
    'value': _merge(base, user),
    'base': base,
    'user': user,
    'secrets': secrets,
    'writable': true,
  };
}

/// What the next write meets instead of succeeding.
enum BridgeOutcome {
  invalidOperation(400, 'invalid-operation'),
  entryUnavailable(404, 'entry-unavailable'),
  conflict(409, 'conflict'),
  overridden(409, 'overridden'),

  /// Written, reload failed, the previous config restored.
  applyFailed(409, 'apply-failed'),
  invalidConfig(422, 'invalid-config'),
  hostUnavailable(503, 'host-unavailable'),

  /// Written, reload failed, the previous config not restored.
  recoveryFailed(500, 'recovery-failed'),

  /// Written, but the answer comes after the client gave up.
  lostAfterWrite(0, ''),

  /// The answer comes after the client gave up, nothing written.
  lostBeforeWrite(0, '');

  const BridgeOutcome(this.status, this.code);
  final int status;
  final String code;
}

class FakeBridgeHost {
  FakeBridgeHost._(this._server);

  static const token = 'launch-token';
  static const cookie = 'dsh-auth-k1';

  static Future<FakeBridgeHost> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final host = FakeBridgeHost._(server);
    server.listen((request) => unawaited(host._handle(request)));
    return host;
  }

  final HttpServer _server;
  Uri get baseUri => Uri.parse('http://127.0.0.1:${_server.port}');

  /// False: the Host has no plugin-config routes (404).
  bool routes = true;
  final Map<String, BridgeEntry> entries = {};

  /// Listed but not editable: entryId → (state, reason).
  final Map<String, (String, String)> unavailable = {};

  /// Served verbatim as the list's entries instead of [entries] and
  /// [unavailable] (a recorded Host's list).
  List<Object?>? listed;

  /// Served verbatim for a GET of that entry (a recorded Host's answer).
  final Map<String, Object?> recorded = {};

  /// `pluginManager/listBundles`: the bundles that make [entries] plugins.
  List<Object?> bundles = bridgeBundles();

  /// `pluginManager/listBundles` answers `ok: false` (the RPC failed).
  bool failListBundles = false;

  /// RPCs whose answer waits for the completer: a call in flight.
  final Map<String, Completer<void>> holds = {};

  BridgeOutcome? next;

  /// What the real Host (R3) can do on recovery-failed: the plugin does not
  /// come back, so the entry is listed failed and not configurable, and its
  /// detail answers 404 entry-unavailable. False: it stays readable and
  /// writable (the plugin came back on its own).
  bool recoveryLosesEntry = false;

  /// The field a 422 names.
  List<String>? invalidPath;

  /// How long a lost answer takes.
  Duration lostFor = const Duration(milliseconds: 600);

  final Map<String, String> credentials = {};

  /// (method, path, body) of every bridge and RPC request.
  final requests = <(String, String, Object?)>[];

  List<Object?> writes() => [
    for (final (method, path, body) in requests)
      if (method == 'POST' && path.startsWith(dshGoPluginConfigPath)) body,
  ];

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    final path = request.uri.path;
    if (path == '/' && request.uri.queryParameters['token'] == token) {
      response
        ..statusCode = 303
        ..headers.set('location', './')
        ..headers.add('set-cookie', '$cookie=v1.sig; Path=/; HttpOnly');
      await response.close();
      return;
    }
    if (!(request.headers.value(HttpHeaders.cookieHeader)?.contains('$cookie=v1.sig') ?? false)) {
      response.statusCode = 401;
      await response.close();
      return;
    }
    final body = request.method == 'POST' ? jsonDecode(await utf8.decodeStream(request)) : null;
    requests.add((request.method, request.uri.path, body));
    void json(int status, Object? payload) {
      response.statusCode = status;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(payload));
    }

    void refuse(int status, String code, {List<String>? field}) => json(status, {
      'error': {'code': code, 'message': 'refused (may carry input: sk-should-not-show)', 'path': ?field},
    });

    if (path.startsWith('/api/')) {
      if (holds[path.substring(5)] case final hold?) await hold.future;
      json(200, {'type': 'server-response', 'rpcId': (body as Map)['rpcId'], 'result': _rpc(path.substring(5), body)});
    } else if (!routes && path.startsWith(dshGoPluginConfigPath)) {
      response.statusCode = 404;
    } else if (path == dshGoPluginConfigPath) {
      json(200, {
        'v': 1,
        'entries':
            listed ??
            [
              for (final e in entries.values)
                {'entryId': e.entryId, 'package': e.package, 'state': 'active', 'configurable': true},
              for (final MapEntry(:key, value: (state, reason)) in unavailable.entries)
                {'entryId': key, 'state': state, 'configurable': false, 'reason': reason},
            ],
      });
    } else if (path.startsWith('$dshGoPluginConfigPath/')) {
      final id = Uri.decodeComponent(path.substring(dshGoPluginConfigPath.length + 1));
      final entry = entries[id];
      if (recorded[id] case final answer? when request.method == 'GET') {
        json(200, answer);
      } else if (entry == null) {
        refuse(404, 'entry-unavailable');
      } else if (request.method == 'GET') {
        json(200, entry.toJson());
      } else {
        await _write(entry, body as Map<String, Object?>, json, refuse);
      }
    } else {
      response.statusCode = 404;
    }
    await response.close();
  }

  Future<void> _write(
    BridgeEntry entry,
    Map<String, Object?> body,
    void Function(int, Object?) json,
    void Function(int, String, {List<String>? field}) refuse,
  ) async {
    final outcome = next;
    next = null;
    if (body['revision'] != 'r${entry.revision}') return refuse(409, 'conflict');
    Map<String, Object?> applied() {
      var user = entry.user;
      for (final op in (body['ops']! as List).cast<Map<String, Object?>>()) {
        final path = (op['path']! as List).cast<String>();
        user = op['op'] == 'set' ? withPath(user, path, op['value']) : withoutPath(user, path);
      }
      return user;
    }

    switch (outcome) {
      case null:
        entry
          ..user = applied()
          ..revision += 1;
        return json(200, entry.toJson());
      case BridgeOutcome.applyFailed:
        // Restored: the file and the running config are as before.
        entry.revision += 2;
        return refuse(409, 'apply-failed');
      case BridgeOutcome.recoveryFailed:
        entry
          ..user = applied()
          ..revision += 1;
        if (recoveryLosesEntry) {
          entries.remove(entry.entryId);
          unavailable[entry.entryId] = ('failed', 'not-active');
        }
        return refuse(500, 'recovery-failed');
      case BridgeOutcome.invalidConfig:
        return refuse(422, 'invalid-config', field: invalidPath);
      case BridgeOutcome.lostAfterWrite:
        entry
          ..user = applied()
          ..revision += 1;
        await Future<void>.delayed(lostFor);
        return json(200, entry.toJson());
      case BridgeOutcome.lostBeforeWrite:
        await Future<void>.delayed(lostFor);
        return refuse(503, 'host-unavailable');
      case final other:
        return refuse(other.status, other.code);
    }
  }

  Map<String, Object?> _rpc(String method, Map<Object?, Object?> envelope) {
    final args = ((envelope['payload'] as Map?)?['args'] as Map?)?.cast<String, Object?>() ?? const {};
    Map<String, Object?> ok([Object? value]) => {'ok': true, 'value': ?value};
    switch (method) {
      case 'settings/describe':
        return ok(recordedDescribe());
      case 'pluginManager/listBundles':
        if (failListBundles) {
          return {
            'ok': false,
            'error': {'code': 'gateway/internal', 'message': 'listBundles unavailable'},
          };
        }
        return ok(bundles);
      case 'pluginManager/setBundleEnabled':
        final name = args['name'];
        final enabled = args['enabled'] == true;
        bundles = [
          for (final b in bundles.cast<Map<String, Object?>>()) b['name'] == name ? {...b, 'enabled': enabled} : b,
        ];
        return ok({
          'stage': 'enable',
          'target': name,
          'enabled': enabled,
          'changed': true,
          'application': 'applied',
          'warnings': <Object?>[],
        });
      case 'credentials/describe':
        return ok({
          for (final ref in (args['refs']! as List).cast<String>())
            ref: {'configured': credentials.containsKey(ref), 'writable': true},
        });
      case 'credentials/set':
        credentials[args['ref']! as String] = args['value']! as String;
        return ok();
      case 'credentials/unset':
        credentials.remove(args['ref']);
        return ok();
    }
    return {
      'ok': false,
      'error': {'code': 'gateway/method-not-found', 'message': method},
    };
  }
}

/// The official optional bundles the fake Host has switched on, as an r13
/// Host lists them (fixtures/plugin_bundles_r13.json, trimmed): voice input
/// (its SenseVoice provider is [sensevoiceEntry]) and thinking translation
/// (`cot-translation` in the recorded `settings/describe`).
List<Object?> bridgeBundles() => [
  {
    'name': '@deepseek-ai/dsh-experimental-voice-input-bundle',
    'official': true,
    'availability': 'installation',
    'enabled': true,
    'installed': false,
    'optional': true,
    'removable': false,
    'rows': [
      {'rowId': 'speech-to-text', 'moduleName': '@deepseek-ai/dsh-experimental-speech-to-text'},
      {'rowId': 'speech-to-text-sensevoice', 'moduleName': '@deepseek-ai/dsh-experimental-speech-to-text-sensevoice'},
    ],
    'overrides': <Object?>[],
  },
  {
    'name': '@deepseek-ai/dsh-experimental-cot-translation-bundle',
    'official': true,
    'availability': 'installation',
    'enabled': true,
    'installed': false,
    'optional': true,
    'removable': false,
    'rows': [
      {'rowId': 'translator', 'moduleName': '@deepseek-ai/dsh-experimental-translator'},
      {'rowId': 'cot-translation', 'moduleName': '@deepseek-ai/dsh-experimental-client-ui-cot-translation'},
    ],
    'overrides': <Object?>[],
  },
];

/// DSH's own web server (a `dsh-base` row): listed by the Host, configurable
/// there, and never a plugin.
BridgeEntry webserverEntry() => BridgeEntry(
  'webserver',
  {
    'uid': 1,
    'refs': {
      '1': {
        'type': 'object',
        'dict': {'host': 2, 'port': 3},
        'meta': {},
      },
      '2': {
        'type': 'string',
        'meta': {'default': '127.0.0.1'},
      },
      '3': {
        'type': 'number',
        'meta': {'default': 0},
      },
    },
  },
  base: {'host': '127.0.0.1', 'port': 0},
  package: '@deepseek-ai/dsh-host-webserver',
);

/// SenseVoice-like: a live language, two ordinary fields, a bound key and a
/// bare token. `uid`/`refs`, as the bridge serves it.
BridgeEntry sensevoiceEntry() => BridgeEntry(
  'speech-to-text-sensevoice',
  {
    'uid': 1,
    'refs': {
      '1': {
        'type': 'object',
        'dict': {'language': 2, 'threads': 3, 'precision': 4, 'apiKey': 7, 'token': 8},
        'meta': {},
      },
      '2': {
        'type': 'string',
        'meta': {
          'volatile': true,
          'default': 'auto',
          'description': {'zh': '识别语言', 'en': 'Recognition language'},
        },
      },
      '3': {
        'type': 'number',
        'meta': {
          'default': 2,
          'min': 1,
          'step': 1,
          'description': {'zh': '推理线程', 'en': 'Inference threads'},
        },
      },
      '4': {
        'type': 'union',
        'list': [5, 6],
        'meta': {
          'default': 'int8',
          'description': {'zh': '模型精度', 'en': 'Model precision'},
        },
      },
      '5': {'type': 'const', 'value': 'int8', 'meta': {}},
      '6': {'type': 'const', 'value': 'fp32', 'meta': {}},
      '7': {
        'type': 'string',
        'meta': {
          'role': 'secret',
          'description': {'zh': 'API Key', 'en': 'API Key'},
        },
      },
      '8': {
        'type': 'string',
        'meta': {
          'role': 'secret',
          'description': {'zh': '访问令牌', 'en': 'Access token'},
        },
      },
    },
  },
  base: {'language': 'auto', 'threads': 2, 'precision': 'int8'},
  package: '@deepseek-ai/dsh-experimental-speech-to-text-sensevoice',
  secrets: [
    {'path': ['apiKey'], 'configured': false, 'credentialRef': 'SENSEVOICE_KEY', 'writable': true},
    {'path': ['token'], 'configured': true},
  ],
);
