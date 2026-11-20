// An in-memory DSH host for the workspace tests: the workspace registry
// (`workspace/*` + the `workspace/follow` stream), a folder tree for
// `directoryPicker/*`, and `session/list` / `session/create`. It behaves
// like DSH 0.2.1-rc.2 did against a throwaway `dsh web`: new workspaces go
// to the front, only `workspaceId` attaches a conversation, removal keeps
// folders and conversations.

import 'dart:async';

import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../shell/golden_harness.dart' show FakeCurrentSession, FakeRuntime, FakeSettings, runningStatus, sampleNow;

class FakeWorkspaceHost extends DshCarrier {
  FakeWorkspaceHost({
    this.home = '/root',
    Iterable<String> folders = const [],
    this.canCreate = true,
    this.browse = true,
  }) {
    for (final f in folders) {
      _addFolder(f);
    }
    _addFolder(home);
  }

  final String home;

  /// False imitates the DSH Remote allow-list (listing only).
  final bool canCreate;

  /// False imitates a Host that composes the native picker.
  final bool browse;

  final Set<String> folders = {'/'};
  final List<Map<String, Object?>> workspaces = [];
  List<String> pinned = [];
  List<String> archived = [];
  final List<Map<String, Object?>> sessions = [];
  final List<(String, Map<String, Object?>)> calls = [];
  _Link? _link;
  int _seq = 0;
  DateTime _clock = DateTime.utc(2026, 10, 24, 6);

  List<Map<String, Object?>> argsOf(String endpoint) => [
    for (final (e, a) in calls)
      if (e == endpoint) a,
  ];

  void _addFolder(String path) {
    var p = path;
    while (p.isNotEmpty && p != '/') {
      folders.add(p);
      final cut = p.lastIndexOf('/');
      p = cut <= 0 ? '/' : p.substring(0, cut);
    }
  }

  String _now() => (_clock = _clock.add(const Duration(seconds: 1))).toIso8601String();

  /// Registers a workspace directly (fixtures), newest first.
  Map<String, Object?> seedWorkspace(String path, {String? title, List<String> sessionIds = const []}) {
    _addFolder(path);
    final w = <String, Object?>{
      'workspaceId': 'ws-${++_seq}',
      'path': path,
      'title': title ?? path.split('/').last,
      'sessionIds': List.of(sessionIds),
      'createdAt': _now(),
      'updatedAt': _now(),
    };
    workspaces.insert(0, w);
    return w;
  }

  /// Adds a conversation row as `session/list` reports it.
  void seedSession(String id, String title, DateTime updatedAt, {bool running = false}) {
    sessions.add({
      'sessionId': id,
      'updatedAt': updatedAt.millisecondsSinceEpoch,
      'running': running,
      'blank': false,
      'agentAvailable': running,
      'cwd': '/root/workspace',
      'projections': {
        'kind': 'hints',
        'asOfSeq': 1,
        'values': {'title': title},
      },
    });
  }

  Map<String, Object?> get _baseline => {
    'items': workspaces,
    'archivedSessionIds': archived,
    'pinnedSessionIds': pinned,
  };

  /// Pushes one `workspace/follow` frame.
  void push(Map<String, Object?> frame) => _link?.follow(frame);

  Map<String, Object?>? _ws(Object? id) => workspaces.where((w) => w['workspaceId'] == id).firstOrNull;

  @override
  String get kind => 'fake-workspaces';

  @override
  DshTracer? get tracer => null;

  @override
  bool allowsEndpoint(String endpoint) => canCreate || endpoint != 'directoryPicker/createDirectory';

  static RpcResult _fail(String code, [Map<String, Object?> details = const {}]) =>
      RpcError(DshRemoteException(code, code, details));

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    calls.add((endpoint, args));
    if (!allowsEndpoint(endpoint)) return _fail('METHOD_NOT_ALLOWED');
    final request = (args['request'] as Map?)?.cast<String, Object?>() ?? const {};
    switch (endpoint) {
      case 'session/list':
        return RpcOk({'items': sessions});
      case 'session/create':
        final id = 'session-new-${++_seq}';
        final workspaceId = request['workspaceId'];
        if (workspaceId != null) {
          final w = _ws(workspaceId);
          if (w == null) return _fail(WorkspaceErrors.notFound, {'workspaceId': workspaceId});
          w['sessionIds'] = [...(w['sessionIds'] as List), id];
          w['updatedAt'] = _now();
          push({'type': 'upsert', 'workspace': w});
        }
        return RpcOk({'sessionId': id});
      case 'workspace/create':
        final path = request['path'] as String;
        final existing = workspaces.where((w) => w['path'] == path).firstOrNull;
        if (existing != null) return RpcOk({'workspace': existing, 'created': false});
        if (!folders.contains(path)) return _fail(WorkspaceErrors.invalidPath, {'path': path});
        final w = seedWorkspace(path);
        push({'type': 'upsert', 'workspace': w});
        push({
          'type': 'order',
          'workspaceIds': [for (final w in workspaces) w['workspaceId']],
        });
        return RpcOk({'workspace': w, 'created': true});
      case 'workspace/rename':
        final w = _ws(request['workspaceId']);
        if (w == null) return _fail(WorkspaceErrors.notFound);
        final title = request['title'] as String;
        if (workspaces.any((o) => o != w && o['title'] == title)) {
          return _fail(WorkspaceErrors.nameConflict, {'name': title});
        }
        w['title'] = title;
        w['updatedAt'] = _now();
        push({'type': 'upsert', 'workspace': w});
        return RpcOk({'workspace': w});
      case 'workspace/delete':
        final w = _ws(request['workspaceId']);
        if (w == null) return _fail(WorkspaceErrors.notFound);
        workspaces.remove(w);
        push({
          'type': 'order',
          'workspaceIds': [for (final w in workspaces) w['workspaceId']],
        });
        push({'type': 'remove', 'workspaceId': w['workspaceId']});
        return const RpcOk({'deleted': true});
      case 'workspace/pinSession' || 'workspace/unpinSession':
        final id = request['sessionId'] as String;
        pinned = [if (endpoint == 'workspace/pinSession') id, ...pinned.where((p) => p != id)];
        push({'type': 'pinned', 'pinnedSessionIds': pinned});
        return RpcOk({'pinnedSessionIds': pinned});
      case 'directoryPicker/list':
        if (!browse) return _fail(WorkspaceErrors.pickerUnavailable, {'capability': 'browse'});
        final path = (args['path'] as String?) ?? home;
        if (!folders.contains(path)) return _fail(WorkspaceErrors.unreadable, {'path': path});
        return RpcOk(_level(path));
      case 'directoryPicker/createDirectory':
        final parent = args['path'] as String;
        final child = parent == '/' ? '/${args['name']}' : '$parent/${args['name']}';
        if (folders.contains(child)) return _fail(WorkspaceErrors.exists, {'path': child});
        _addFolder(child);
        return RpcOk(child);
    }
    return _fail('gateway/method-not-found');
  }

  Map<String, Object?> _level(String path) {
    final crumbs = <Map<String, Object?>>[
      {'name': '/', 'path': '/', 'hidden': false},
    ];
    var at = '';
    for (final part in path.split('/').where((p) => p.isNotEmpty)) {
      at = '$at/$part';
      crumbs.add({'name': part, 'path': at, 'hidden': false});
    }
    final prefix = path == '/' ? '/' : '$path/';
    final children = [
      for (final f in folders)
        if (f != path && f.startsWith(prefix) && !f.substring(prefix.length).contains('/')) f,
    ]..sort();
    return {
      'path': path,
      'home': home,
      'crumbs': crumbs,
      'entries': [
        for (final c in children)
          {'name': c.substring(prefix.length), 'path': c, 'hidden': c.substring(prefix.length).startsWith('.')},
      ],
      'truncated': false,
    };
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) async => _link = _Link(this);

  @override
  Future<void> close() async {}
}

class _Link implements DshMuxLink {
  _Link(this.host);

  final FakeWorkspaceHost host;
  DshMuxFrameHandler? _onFrame;
  String? _events;

  /// Open `workspace/follow` streams (the drawer's list and the session list
  /// each follow it).
  final Set<String> _follows = {};

  @override
  void start({required DshMuxFrameHandler onFrame, required DshMuxLossHandler onLost}) => _onFrame = onFrame;

  @override
  void open(String streamId, String endpoint, Map<String, Object?> payload) {
    if (endpoint == r'$events') {
      _events = streamId;
      scheduleMicrotask(
        () => _onFrame?.call({
          'type': 'item',
          'streamId': _events,
          'value': {
            'type': 'ready',
            'clientId': 'client-1',
            'host': {'home': host.home},
          },
        }),
      );
    } else if (endpoint == 'workspace/follow') {
      _follows.add(streamId);
      scheduleMicrotask(
        () => _onFrame?.call({
          'type': 'item',
          'streamId': streamId,
          'value': _copy({'type': 'baseline', 'value': host._baseline}),
        }),
      );
    }
  }

  void follow(Map<String, Object?> frame) {
    for (final id in _follows) {
      // Deep-copy so later fixture edits don't mutate delivered frames.
      _onFrame?.call({'type': 'item', 'streamId': id, 'value': _copy(frame)});
    }
  }

  static Object? _copy(Object? v) => switch (v) {
    Map() => {for (final MapEntry(:key, :value) in v.entries) key.toString(): _copy(value)},
    List() => [for (final e in v) _copy(e)],
    _ => v,
  };

  @override
  void sendItem(String streamId, Object? value) {}

  @override
  void endUplink(String streamId) {}

  @override
  void cancel(String streamId) => _follows.remove(streamId);

  @override
  Future<void> close(int code, String reason) async {}
}

/// A connected host backed by [carrier].
HostConnection workspaceHost(FakeWorkspaceHost carrier, {bool local = true, String? workingDirectory}) =>
    HostConnection(
      client: DshClient.withCarrier(carrier),
      label: local ? '本机' : '电脑',
      isLocal: local,
      kind: local ? HostKind.portal : HostKind.portal,
      hostId: local ? '' : 'pc',
      workingDirectory: workingDirectory,
    );

// ── Sample host ──────────────────────────────────────────────────────────────

/// A phone engine with three workspaces and eight conversations, anchored to
/// the midnight of [sampleNow] (the drawer's pinned clock in goldens) so the
/// day groups do not move with the real date: dsh-app holds s1, s2, s4, s6;
/// 博客 (in the phone's storage) holds s3; notes is empty.
FakeWorkspaceHost sampleWorkspaceHost({DateTime? now}) {
  final host = FakeWorkspaceHost(
    folders: [
      '/root/workspace',
      '/root/code/dsh-app',
      '/root/code/dsh-app/lib',
      '/root/code/site',
      '/root/code/.cache',
      '/root/code/tools',
      '/root/notes',
      '/sdcard/Documents/blog',
      '/sdcard/Download',
    ],
  );
  final today = now ?? sampleNow;
  final midnight = DateTime(today.year, today.month, today.day);
  const titles = {
    's1': '修复登录按钮重复提交',
    's2': '给设置页加深色模式',
    's3': '写一篇 proot 入门',
    's4': '重构 sessions_state 的刷新逻辑',
    's5': '写一个解析 tar.xz 的 Kotlin 工具',
    's6': 'DeepSeek API 计费怎么算',
  };
  final ages = {
    's1': const Duration(seconds: -3),
    's2': const Duration(seconds: -2),
    's3': const Duration(seconds: -1),
    's4': const Duration(hours: 3),
    's5': const Duration(hours: 9),
    's6': const Duration(days: 3),
  };
  for (final MapEntry(:key, :value) in titles.entries) {
    host.seedSession(key, value, midnight.subtract(ages[key]!), running: key == 's1');
  }
  host.seedWorkspace('/root/notes');
  host.seedWorkspace('/sdcard/Documents/blog', title: '博客', sessionIds: ['s3']);
  host.seedWorkspace('/root/code/dsh-app', sessionIds: ['s1', 's2', 's4', 's6']);
  return host;
}

// ── Overrides ─────────────────────────────────────────────────────────────────

class FixedWorkspacePrefs extends WorkspacePrefsController {
  FixedWorkspacePrefs(this.initial);

  final WorkspacePrefs initial;

  @override
  WorkspacePrefs build() => initial;
}

const samplePrefs = WorkspacePrefs(
  loaded: true,
  selected: 'ws-3',
  pinned: ['ws-3'],
  groups: {'ws-2': '个人'},
  recent: ['/root/code', '/sdcard/Documents'],
);

List<Override> workspaceOverrides(
  FakeWorkspaceHost host, {
  WorkspacePrefs prefs = samplePrefs,
  bool phoneStorage = true,
  String? current = 's2',
  bool livePrefs = false,
  HostConnection? connection,
}) => [
  activeConnectionProvider.overrideWithValue(AsyncData(connection ?? workspaceHost(host))),
  localRuntimeProvider.overrideWith(() => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus))),
  settingsProvider.overrideWith(() => FakeSettings(AppSettings(loaded: true, phoneStorage: phoneStorage))),
  // Live: the real controller over (mocked) shared preferences.
  if (!livePrefs) workspacePrefsProvider.overrideWith(() => FixedWorkspacePrefs(prefs)),
  currentSessionProvider.overrideWith(() => FakeCurrentSession(current)),
];
