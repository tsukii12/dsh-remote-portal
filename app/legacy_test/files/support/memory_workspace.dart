// An in-memory workspace behind [WorkspaceSource]: files by path, versions
// shaped like the Host's (`dev:ino:size:mtimeNs:ctimeNs`), and watches that
// fire when a test writes or deletes something.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_app/state/workspace_state.dart';
import 'package:dsh_client/dsh_client.dart';

class MemoryWorkspace implements WorkspaceSource {
  MemoryWorkspace({
    Map<String, String> files = const {},
    Set<String> folders = const {},
    this.root = '/root/work',
    DateTime? modified,
  }) : _modified = modified ?? DateTime(2026, 10, 24, 9, 30) {
    for (final MapEntry(:key, :value) in files.entries) {
      _files[key] = Uint8List.fromList(utf8.encode(value));
      _times[key] = _modified;
    }
    _folders.addAll(folders);
  }

  /// The workspace's absolute path.
  final String root;
  final DateTime _modified;

  final Map<String, Uint8List> _files = {};
  final Map<String, DateTime> _times = {};
  final Set<String> _folders = {};
  final Map<String, List<StreamController<DshWorkspaceWatchFrame>>> _watches = {};

  /// Every call, as `method path`.
  final List<String> calls = [];

  /// Errors to throw per `method path`.
  final Map<String, Object> failures = {};

  /// Search answers per query (default: names containing it).
  final Map<String, List<FileReferenceCandidate>> searches = {};

  int _ino = 100;
  final Map<String, int> _inodes = {};

  /// Workspace-relative form of [path] ('' = root).
  String rel(String path) {
    if (path == '.' || path == root) return '';
    if (path.startsWith('$root/')) return path.substring(root.length + 1);
    if (path.startsWith('./')) return path.substring(2);
    return path;
  }

  void _check(String call) {
    calls.add(call);
    final failure = failures[call];
    if (failure != null) throw failure;
  }

  Set<String> get _allFolders => {
    ..._folders,
    for (final path in [..._files.keys, ..._folders])
      for (var cut = path.indexOf('/'); cut > 0; cut = path.indexOf('/', cut + 1)) path.substring(0, cut),
  };

  String _version(String path) {
    final bytes = _files[path]!.length;
    final ns = BigInt.from(_times[path]!.millisecondsSinceEpoch) * BigInt.from(1000000);
    final ino = _inodes.putIfAbsent(path, () => _ino++);
    return '36:$ino:$bytes:$ns:$ns';
  }

  @override
  Future<DshWorkspaceListing> list(String path) async {
    final dir = rel(path);
    _check('list $dir');
    final prefix = dir.isEmpty ? '' : '$dir/';
    if (dir.isNotEmpty && !_allFolders.contains(dir)) {
      throw DshRemoteException('workspace-file/not-found', 'no entry at "$dir"', {'path': dir});
    }
    final entries = <String, DshWorkspaceEntry>{};
    for (final folder in _allFolders) {
      if (!folder.startsWith(prefix)) continue;
      final rest = folder.substring(prefix.length);
      if (rest.isEmpty || rest.contains('/')) continue;
      entries[rest] = DshWorkspaceEntry(name: rest, type: DshWorkspaceEntryType.directory);
    }
    for (final MapEntry(:key, :value) in _files.entries) {
      if (!key.startsWith(prefix)) continue;
      final rest = key.substring(prefix.length);
      if (rest.contains('/')) continue;
      entries[rest] = DshWorkspaceEntry(name: rest, type: DshWorkspaceEntryType.file, size: value.length);
    }
    // The backend's own order is by name, case-sensitive.
    final names = entries.keys.toList()..sort();
    return DshWorkspaceListing(path: dir, entries: [for (final n in names) entries[n]!]);
  }

  @override
  Future<DshWorkspaceText> read(String path, {int offset = 1, int limit = 500}) async {
    final file = rel(path);
    _check('read $file');
    final bytes = _files[file];
    if (bytes == null) {
      throw DshRemoteException('workspace-file/not-found', 'no entry', {'path': file});
    }
    final String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      throw DshRemoteException('workspace-file/not-text', 'not text', {'path': file});
    }
    if (text.contains('\u0000')) {
      throw DshRemoteException('workspace-file/not-text', 'not text', {'path': file});
    }
    var lines = text.split('\n');
    if (text.endsWith('\n')) lines = lines.sublist(0, lines.length - 1);
    if (text.isEmpty) lines = const [];
    final start = (offset - 1).clamp(0, lines.length);
    final end = (start + limit).clamp(0, lines.length);
    final page = lines.sublist(start, end);
    return DshWorkspaceText(
      text: page.join('\n'),
      lines: page.length,
      eof: end >= lines.length,
      offset: offset,
      absolutePath: '$root/$file',
      version: _version(file),
      bytes: bytes.length,
    );
  }

  @override
  Future<DshFileStat> stat(String path) async {
    final file = rel(path);
    _check('stat $file');
    if (!_files.containsKey(file)) {
      throw DshRemoteException('workspace-file/not-found', 'no entry', {'path': file});
    }
    return DshFileStat(absolutePath: '$root/$file', version: _version(file), bytes: _files[file]!.length);
  }

  @override
  Future<DshWorkspaceBytes> readWindow(String path, {int offset = 0, required int length}) async {
    final file = rel(path);
    _check('readBytes $file');
    final bytes = _files[file];
    if (bytes == null) {
      throw DshRemoteException('workspace-file/not-found', 'no entry', {'path': file});
    }
    final end = (offset + length).clamp(0, bytes.length);
    return DshWorkspaceBytes(
      data: Uint8List.sublistView(bytes, offset.clamp(0, bytes.length), end),
      eof: end >= bytes.length,
      offset: offset,
      absolutePath: '$root/$file',
      version: _version(file),
      bytes: bytes.length,
    );
  }

  @override
  Stream<DshWorkspaceWatchFrame> watch(String path) {
    final target = rel(path);
    calls.add('watch $target');
    late final StreamController<DshWorkspaceWatchFrame> controller;
    controller = StreamController<DshWorkspaceWatchFrame>(
      onListen: () => scheduleMicrotask(() {
        if (!controller.isClosed) controller.add(const DshWorkspaceWatchReady());
      }),
      onCancel: () => _watches[target]?.remove(controller),
    );
    (_watches[target] ??= []).add(controller);
    return controller.stream;
  }

  /// How many watches are open on [path].
  int watching(String path) => _watches[rel(path)]?.length ?? 0;

  @override
  Future<List<FileReferenceCandidate>> search(String query) async {
    _check('search $query');
    if (searches[query] case final hits?) return hits;
    final q = query.toLowerCase();
    return [
      for (final folder in _allFolders.toList()..sort())
        if (folder.split('/').last.toLowerCase().contains(q)) FileReferenceCandidate(path: folder, isDirectory: true),
      for (final file in _files.keys.toList()..sort())
        if (file.split('/').last.toLowerCase().contains(q)) FileReferenceCandidate(path: file, isDirectory: false),
    ];
  }

  // ── Test controls ─────────────────────────────────────────────────────────

  /// Writes [path] (text or bytes) and tells the watches, as the Host would.
  void write(String path, Object content, {DateTime? at}) {
    final created = !_files.containsKey(path);
    _files[path] = content is Uint8List ? content : Uint8List.fromList(utf8.encode('$content'));
    _times[path] = at ?? _modified.add(const Duration(minutes: 5));
    _notify(path, absent: false);
    if (created) _notify(_parent(path), absent: false);
  }

  void delete(String path) {
    _files.remove(path);
    _notify(path, absent: true);
    _notify(_parent(path), absent: false);
  }

  /// A reconnect: every watch says `ready` again.
  void reconnect() {
    for (final list in _watches.values) {
      for (final c in [...list]) {
        c.add(const DshWorkspaceWatchReady());
      }
    }
  }

  String _parent(String path) {
    final cut = path.lastIndexOf('/');
    return cut < 0 ? '' : path.substring(0, cut);
  }

  void _notify(String target, {required bool absent}) {
    for (final c in [...?_watches[target]]) {
      c.add(
        DshWorkspaceWatchChange(
          absolutePath: target.isEmpty ? root : '$root/$target',
          version: absent || !_files.containsKey(target) ? null : _version(target),
          absent: absent,
        ),
      );
    }
  }
}
