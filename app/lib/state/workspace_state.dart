// One conversation's workspace as the 文件 page browses it, after the
// official file panel (`dsh-client-ui-sidebar-files`): one directory at a
// time, directories first in natural name order, each open directory kept
// current by its own `workspaceFiles/changes` watch, plus name search over
// `fileReferences/list` (the `@` completion's index).

import 'dart:async';
import 'dart:typed_data';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'chat_state.dart';
import 'connection_state.dart';
import 'sessions_state.dart';

/// The Host calls behind the 文件 page and the file previews. [path] is
/// absolute or relative to the workspace root ('' is the root).
abstract interface class WorkspaceSource {
  Future<DshWorkspaceListing> list(String path);

  /// Up to [limit] lines from line [offset] (1-based).
  Future<DshWorkspaceText> read(String path, {int offset = 1, int limit = 500});

  Future<DshFileStat> stat(String path);

  /// One byte window (at most 2 MiB).
  Future<DshWorkspaceBytes> readWindow(String path, {int offset = 0, required int length});

  /// Directory or file changes; see [DshWorkspaceApi.watchWorkspace].
  Stream<DshWorkspaceWatchFrame> watch(String path);

  /// Files and folders whose names match [query], best first.
  Future<List<FileReferenceCandidate>> search(String query);
}

/// [WorkspaceSource] over a connected [DshClient].
class ClientWorkspaceSource implements WorkspaceSource {
  ClientWorkspaceSource(this.client, this.sessionId);

  final DshClient client;
  final String sessionId;

  @override
  Future<DshWorkspaceListing> list(String path) => client.listWorkspace(sessionId, path);

  @override
  Future<DshWorkspaceText> read(String path, {int offset = 1, int limit = 500}) =>
      client.readWorkspaceText(sessionId, path, offset: offset, limit: limit);

  @override
  Future<DshFileStat> stat(String path) => client.statFile(sessionId, path);

  @override
  Future<DshWorkspaceBytes> readWindow(String path, {int offset = 0, required int length}) =>
      client.readWorkspaceWindow(sessionId, path, offset: offset, length: length);

  @override
  Stream<DshWorkspaceWatchFrame> watch(String path) => client.watchWorkspace(sessionId, path);

  @override
  Future<List<FileReferenceCandidate>> search(String query) => client.fileReferences(sessionId, query);
}

/// Workspace access for one conversation; null while not connected.
final workspaceSourceProvider = Provider.autoDispose.family<WorkspaceSource?, String>((ref, sessionId) {
  final client = ref.watch(activeConnectionProvider.select((c) => c.value?.client));
  return client == null ? null : ClientWorkspaceSource(client, sessionId);
});

/// The conversation's working directory — the root the Host lists — when the
/// app knows it. Null: paths stay relative to it, which the Host resolves.
final workspaceRootProvider = Provider.autoDispose.family<String?, String>((ref, sessionId) {
  // Only what the app already has is asked: starting the conversation list
  // or a chat here would open the Host's streams.
  final listed = ref.exists(sessionsProvider)
      ? ref.watch(sessionsProvider.select((s) => s.value?.where((x) => x.sessionId == sessionId).firstOrNull?.cwd))
      : null;
  if (listed != null && listed.isNotEmpty) return _trimSlash(listed);
  final chat = chatProvider(sessionId);
  final header = ref.exists(chat) ? ref.read(chat.notifier).header?.cwd : null;
  return header == null || header.isEmpty ? null : _trimSlash(header);
});

String _trimSlash(String path) => path.length > 1 && path.endsWith('/') ? path.substring(0, path.length - 1) : path;

// ── Paths ───────────────────────────────────────────────────────────────────

/// What the Host is asked for: [rel] under [root], or [rel] itself (relative
/// to the workspace) when the root is unknown.
String workspaceHostPath(String? root, String rel) {
  if (root == null) return rel;
  if (rel.isEmpty) return root;
  return root == '/' ? '/$rel' : '$root/$rel';
}

/// [rel] + `/` + [name].
String workspaceChild(String rel, String name) => rel.isEmpty ? name : '$rel/$name';

/// [name] inside the folder the Host knows as [dir] (absolute or relative).
String _childOf(String dir, String name) {
  if (dir.isEmpty) return name;
  if (dir == '/') return '/$name';
  return '$dir/$name';
}

/// The folder above [rel] ('' at the top).
String workspaceParent(String rel) {
  final cut = rel.lastIndexOf('/');
  return cut < 0 ? '' : rel.substring(0, cut);
}

/// Directories first, then names in natural order (`2` before `10`),
/// ignoring case — the official tree's order.
int compareWorkspaceEntries(DshWorkspaceEntry a, DshWorkspaceEntry b) {
  if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
  return naturalCompare(a.name, b.name);
}

/// Case-insensitive comparison where digit runs compare by value.
int naturalCompare(String a, String b) {
  final x = a.toLowerCase();
  final y = b.toLowerCase();
  var i = 0;
  var j = 0;
  while (i < x.length && j < y.length) {
    final cx = x.codeUnitAt(i);
    final cy = y.codeUnitAt(j);
    if (_digit(cx) && _digit(cy)) {
      var ei = i;
      while (ei < x.length && _digit(x.codeUnitAt(ei))) {
        ei++;
      }
      var ej = j;
      while (ej < y.length && _digit(y.codeUnitAt(ej))) {
        ej++;
      }
      final nx = x.substring(i, ei).replaceFirst(RegExp('^0+(?=.)'), '');
      final ny = y.substring(j, ej).replaceFirst(RegExp('^0+(?=.)'), '');
      if (nx.length != ny.length) return nx.length - ny.length;
      final c = nx.compareTo(ny);
      if (c != 0) return c;
      i = ei;
      j = ej;
      continue;
    }
    if (cx != cy) return cx - cy;
    i++;
    j++;
  }
  final rest = (x.length - i) - (y.length - j);
  return rest != 0 ? rest : a.compareTo(b);
}

bool _digit(int unit) => unit >= 0x30 && unit <= 0x39;

/// When a file last changed, read from the Host's version token.
///
/// The token is opaque by contract; the Host's local filesystem writes it as
/// `dev:ino:size:mtimeNs:ctimeNs`, and nothing else reports a time. Anything
/// that does not look exactly like that (another backend, a future format)
/// gives null and the page shows the size alone.
DateTime? modifiedFromVersion(String version, {DateTime? now}) {
  final parts = version.split(':');
  if (parts.length != 5 || parts.any((p) => p.isEmpty || !RegExp(r'^\d+$').hasMatch(p))) return null;
  final ns = BigInt.tryParse(parts[3]);
  if (ns == null) return null;
  final ms = (ns ~/ BigInt.from(1000000)).toInt();
  final at = DateTime.fromMillisecondsSinceEpoch(ms);
  final latest = (now ?? DateTime.now()).add(const Duration(days: 1));
  if (at.year < 1990 || at.isAfter(latest)) return null;
  return at;
}

// ── One directory, live ─────────────────────────────────────────────────────

/// A directory as the page shows it.
class WorkspaceDir {
  const WorkspaceDir({
    this.entries = const [],
    this.truncated = false,
    this.loaded = false,
    this.error,
    this.refreshing = false,
    this.live = false,
    this.times = const {},
  });

  /// Sorted with [compareWorkspaceEntries].
  final List<DshWorkspaceEntry> entries;
  final bool truncated;

  /// A listing arrived at least once.
  final bool loaded;

  /// Why the last listing failed (shown only while nothing is [loaded]).
  final Object? error;
  final bool refreshing;

  /// The Host watches it: changes show up by themselves.
  final bool live;

  /// Files' modified times by name, as they arrive.
  final Map<String, DateTime> times;

  WorkspaceDir copyWith({
    List<DshWorkspaceEntry>? entries,
    bool? truncated,
    bool? loaded,
    Object? error,
    bool clearError = false,
    bool? refreshing,
    bool? live,
    Map<String, DateTime>? times,
  }) => WorkspaceDir(
    entries: entries ?? this.entries,
    truncated: truncated ?? this.truncated,
    loaded: loaded ?? this.loaded,
    error: clearError ? null : error ?? this.error,
    refreshing: refreshing ?? this.refreshing,
    live: live ?? this.live,
    times: times ?? this.times,
  );
}

/// (conversation, folder relative to the workspace root).
typedef WorkspaceDirKey = (String sessionId, String rel);

/// Files whose times are looked up per listing (the rest show size only).
const workspaceTimedFiles = 120;

/// Lists one directory, then relists whenever the Host says its children
/// changed (and after every reconnect). Kept for a while after the page
/// leaves it, so going back up is instant.
class WorkspaceDirController extends Notifier<WorkspaceDir> {
  WorkspaceDirController(this.key);

  final WorkspaceDirKey key;

  WorkspaceSource? _source;
  String _path = '';
  int _generation = 0;
  Timer? _debounce;
  bool _loading = false;
  bool _again = false;
  Completer<void>? _next;

  /// Size and latest timestamp request for each file name.
  final Map<String, ({int? size, Object request})> _timed = {};

  static const _relistDelay = Duration(milliseconds: 250);
  static const _readyWait = Duration(milliseconds: 600);
  static const _keepFor = Duration(seconds: 30);

  @override
  WorkspaceDir build() {
    final (sessionId, rel) = key;
    final source = ref.watch(workspaceSourceProvider(sessionId));
    // Same Host: keep showing the folder while it is read again (the root
    // may only now be known); another Host starts empty.
    final kept = identical(source, _source) ? _kept : null;
    _source = source;
    _path = workspaceHostPath(ref.watch(workspaceRootProvider(sessionId)), rel);
    _timed.clear();
    final generation = ++_generation;

    final link = ref.keepAlive();
    Timer? release;
    ref.onCancel(() => release = Timer(_keepFor, link.close));
    ref.onResume(() => release?.cancel());
    ref.onDispose(() {
      release?.cancel();
      _debounce?.cancel();
    });

    if (source == null) return _keep(const WorkspaceDir());

    // As the official tree does, the first listing waits for the watch to be
    // on (so nothing slips between the two), but not for long: a Host that
    // cannot watch, or a link still coming up, only costs [_readyWait].
    var waiting = true;
    void first() {
      if (!waiting || generation != _generation) return;
      waiting = false;
      unawaited(_load());
    }

    final fallback = Timer(_readyWait, first);
    final watch = source
        .watch(_path)
        .listen(
          (frame) {
            if (generation != _generation) return;
            if (frame is DshWorkspaceWatchReady) {
              if (!state.live) _set(state.copyWith(live: true));
              if (waiting) {
                fallback.cancel();
                first();
                return;
              }
            }
            _schedule();
          },
          onError: (Object _) {
            if (generation != _generation) return;
            if (state.live) _set(state.copyWith(live: false));
            fallback.cancel();
            first();
          },
          onDone: () {
            fallback.cancel();
            first();
          },
        );
    ref.onDispose(() {
      fallback.cancel();
      unawaited(watch.cancel());
    });
    return _keep(kept ?? const WorkspaceDir());
  }

  WorkspaceDir? _kept;

  WorkspaceDir _keep(WorkspaceDir value) => _kept = value;

  void _set(WorkspaceDir value) => state = _keep(value);

  /// Pull to refresh: relist and read every time again.
  Future<void> refresh() async {
    _timed.clear();
    _set(state.copyWith(refreshing: true));
    await _load();
  }

  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(_relistDelay, () => unawaited(_load()));
  }

  Future<void> _load() async {
    if (_loading) {
      // One more listing after the one in flight; callers wait for it.
      _again = true;
      await (_next ??= Completer<void>()).future;
      return;
    }
    _loading = true;
    try {
      await _list();
    } finally {
      _loading = false;
      if (_again) {
        _again = false;
        final next = _next;
        _next = null;
        unawaited(_load().whenComplete(() => next?.complete()));
      }
    }
  }

  Future<void> _list() async {
    final source = _source;
    if (source == null) return;
    final generation = _generation;
    try {
      final listing = await source.list(_path);
      if (!ref.mounted || generation != _generation) return;
      final entries = [...listing.entries]..sort(compareWorkspaceEntries);
      final names = {for (final e in entries) e.name};
      _timed.removeWhere((name, _) => !names.contains(name));
      _set(
        state.copyWith(
          entries: _same(entries, state.entries) ? state.entries : entries,
          truncated: listing.truncated,
          loaded: true,
          clearError: true,
          refreshing: false,
          times: {
            for (final MapEntry(:key, :value) in state.times.entries)
              if (names.contains(key)) key: value,
          },
        ),
      );
      unawaited(_readTimes(source, entries, generation));
    } catch (error) {
      if (!ref.mounted || generation != _generation) return;
      _set(state.copyWith(error: error, refreshing: false));
    }
  }

  /// Times of new or resized files, a few at a time.
  Future<void> _readTimes(WorkspaceSource source, List<DshWorkspaceEntry> entries, int generation) async {
    final wanted = [
      for (final e in entries.where((e) => e.isFile).take(workspaceTimedFiles))
        if (!_timed.containsKey(e.name) || _timed[e.name]?.size != e.size) e,
    ];
    final request = Object();
    for (final e in wanted) {
      _timed[e.name] = (size: e.size, request: request);
    }
    const batch = 6;
    for (var i = 0; i < wanted.length; i += batch) {
      final chunk = wanted.skip(i).take(batch).toList();
      final found = await Future.wait([
        for (final e in chunk)
          source.stat(_childOf(_path, e.name)).then((s) => modifiedFromVersion(s.version), onError: (Object _) => null),
      ]);
      if (!ref.mounted || generation != _generation) return;
      final times = {...state.times};
      var changed = false;
      for (final (j, e) in chunk.indexed) {
        if (!identical(_timed[e.name]?.request, request)) continue;
        final at = found[j];
        if (at != null && times[e.name] != at) {
          times[e.name] = at;
          changed = true;
        }
      }
      if (changed) _set(state.copyWith(times: times));
    }
  }

  static bool _same(List<DshWorkspaceEntry> a, List<DshWorkspaceEntry> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].name != b[i].name || a[i].type != b[i].type || a[i].size != b[i].size) return false;
    }
    return true;
  }
}

final workspaceDirProvider = NotifierProvider.autoDispose.family<WorkspaceDirController, WorkspaceDir, WorkspaceDirKey>(
  WorkspaceDirController.new,
);

/// `fileReferences/list` for (conversation, query).
final workspaceSearchProvider = FutureProvider.autoDispose.family<List<FileReferenceCandidate>, (String, String)>((
  ref,
  key,
) async {
  final (sessionId, query) = key;
  final source = ref.watch(workspaceSourceProvider(sessionId));
  if (source == null || query.trim().isEmpty) return const [];
  return source.search(query.trim());
});

/// The bytes of one small file in memory, through byte windows.
Future<Uint8List> readWorkspaceBytes(WorkspaceSource source, String path, {required int maxBytes}) async {
  const window = 1024 * 1024;
  final out = BytesBuilder(copy: false);
  var offset = 0;
  while (true) {
    final part = await source.readWindow(path, offset: offset, length: window);
    if ((part.bytes ?? 0) > maxBytes) {
      throw DshRemoteException('workspace-file/too-large', 'over $maxBytes bytes', {'path': path, 'limit': maxBytes});
    }
    out.add(part.data);
    offset += part.data.length;
    if (offset > maxBytes) {
      throw DshRemoteException('workspace-file/too-large', 'over $maxBytes bytes', {'path': path, 'limit': maxBytes});
    }
    if (part.eof || part.data.isEmpty) return out.takeBytes();
  }
}
