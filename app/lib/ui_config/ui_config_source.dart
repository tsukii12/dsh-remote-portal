// Where ui.json comes from. On the phone's own engine the app reads the file
// straight from the rootfs and follows it with inotify; on a remote host it
// reads through the Host's `workspaceFiles/read` and follows
// `workspaceFiles/changes`, falling back to a 60-second check while the app is
// in front. Both only read.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;

import '../l10n/l10n.dart';
import 'ui_config_model.dart';
import 'ui_config_parser.dart' show UiMessages;
import 'ui_config_schema.dart';

// ── Events ──────────────────────────────────────────────────────────────────

/// One observation of a host's ui.json.
sealed class UiConfigRead {
  const UiConfigRead();
}

/// The file's text, with the source's freshness token.
final class UiConfigText extends UiConfigRead {
  const UiConfigText(this.text, {this.version});

  final String text;
  final String? version;
}

/// There is no ui.json. On a remote host whose DSH home was only guessed,
/// [skillMissing] says the dsh-go-ui skill is not installed there either.
final class UiConfigAbsent extends UiConfigRead {
  const UiConfigAbsent({this.skillMissing = false});

  final bool skillMissing;
}

/// The file exists but cannot be used at all (too large, not text): a fatal
/// issue with [message].
final class UiConfigBroken extends UiConfigRead {
  const UiConfigBroken(this.message, {this.version});

  final String message;
  final String? version;
}

/// The file cannot be looked at right now.
final class UiConfigUnavailable extends UiConfigRead {
  const UiConfigUnavailable(this.reason);

  final UiConfigUnavailableReason reason;
}

enum UiConfigUnavailableReason {
  /// The on-device runtime is not installed yet.
  noRuntime,

  /// A remote host with no conversation: `workspaceFiles/*` needs one.
  noSession,

  /// A remote host where neither the skill nor `$HOME` reveal DSH home.
  noSkill,

  /// The host does not offer `workspaceFiles/read` (some relays).
  unsupported,

  /// The host refused the read (its sandbox or file permissions).
  denied,
}

/// A watched ui.json.
abstract interface class UiConfigSource {
  /// The current state first, then every change. Single subscription.
  Stream<UiConfigRead> watch();
}

/// A source that can keep the app's reading next to the file
/// (`ui.status.json`), for the agent to check its own work.
abstract interface class UiConfigStatusSink {
  Future<void> writeStatus(UiConfigLoad? load);
}

// ── On-device engine ────────────────────────────────────────────────────────

/// `<rootfs>/root/.dsh/dsh-go/ui.json`, followed with a directory watch
/// (inotify) and re-read on every [kicks] event (app resumes, runtime state
/// changes); bursts settle for [debounce] first.
class LocalUiConfigSource implements UiConfigSource, UiConfigStatusSink {
  LocalUiConfigSource({
    required this.rootfs,
    this.kicks = const Stream.empty(),
    this.debounce = const Duration(milliseconds: 300),
    bool Function()? mayWrite,
  }) : mayWrite = mayWrite ?? _always;

  static bool _always() => true;

  /// The rootfs directory (guest `/`), or null before the runtime is
  /// installed. Asked again on every kick.
  final Future<Directory?> Function() rootfs;
  final Stream<void> kicks;
  final Duration debounce;

  /// Whether the app may create `dsh-go/` or write `ui.status.json` now:
  /// not while an install swaps the rootfs and moves /root around
  /// (RuntimeInstaller.activateRootfs), where a new file could make the
  /// move fail.
  final bool Function() mayWrite;

  /// DSH home inside the guest.
  static const guestDshHome = '/root/.dsh';

  StreamController<UiConfigRead>? _out;
  StreamSubscription<void>? _kicks;
  StreamSubscription<FileSystemEvent>? _watch;
  Directory? _dir;
  Timer? _timer;
  String? _lastStatus;
  bool _refreshing = false;
  bool _again = false;

  @override
  Stream<UiConfigRead> watch() {
    late final StreamController<UiConfigRead> out;
    out = StreamController<UiConfigRead>(
      onListen: () {
        _out = out;
        _kicks = kicks.listen((_) => unawaited(_refresh()));
        unawaited(_refresh());
      },
      onCancel: () async {
        _out = null;
        _timer?.cancel();
        await _kicks?.cancel();
        await _watch?.cancel();
        _watch = null;
      },
    );
    return out.stream;
  }

  void _emit(UiConfigRead read) {
    final out = _out;
    if (out != null && !out.isClosed) out.add(read);
  }

  Future<void> _refresh() async {
    if (_refreshing) {
      _again = true;
      return;
    }
    _refreshing = true;
    try {
      do {
        _again = false;
        await _arm();
        _read();
      } while (_again && _out != null);
    } finally {
      _refreshing = false;
    }
  }

  /// Finds the directory and (re)starts the watch; creates `dsh-go/` once
  /// DSH home exists.
  Future<void> _arm() async {
    Directory? root;
    try {
      root = await rootfs();
    } catch (_) {
      root = null;
    }
    if (_out == null) return;
    if (root == null) {
      await _disarm();
      _dir = null;
      return;
    }
    final home = Directory('${root.path}$guestDshHome');
    final dir = Directory('${home.path}/dsh-go');
    if (_watch != null && _dir?.path == dir.path) return;
    await _disarm();
    _dir = dir;
    if (!dir.existsSync()) {
      if (!home.existsSync() || !mayWrite()) return;
      try {
        dir.createSync(recursive: true);
      } catch (_) {
        return;
      }
    }
    try {
      _watch = dir.watch().listen(
        (event) {
          if (_touchesConfig(event)) _schedule();
        },
        onError: (Object _) => unawaited(_lost()),
        onDone: () => unawaited(_lost()),
      );
    } catch (_) {
      // No inotify here: kicks still re-read.
    }
  }

  Future<void> _lost() async {
    _watch = null;
    _schedule();
  }

  Future<void> _disarm() async {
    final watch = _watch;
    _watch = null;
    await watch?.cancel();
  }

  static bool _isConfig(String path) => path == 'ui.json' || path.endsWith('/ui.json');

  static bool _touchesConfig(FileSystemEvent event) =>
      _isConfig(event.path) || (event is FileSystemMoveEvent && _isConfig(event.destination ?? ''));

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(debounce, () {
      if (_watch == null) {
        unawaited(_refresh());
      } else {
        _read();
      }
    });
  }

  void _read() {
    if (_out == null) return;
    final dir = _dir;
    if (dir == null) {
      _emit(const UiConfigUnavailable(UiConfigUnavailableReason.noRuntime));
      return;
    }
    final file = File('${dir.path}/ui.json');
    try {
      final stat = file.statSync();
      if (stat.type != FileSystemEntityType.file) {
        _emit(const UiConfigAbsent());
        return;
      }
      final version = '${stat.modified.millisecondsSinceEpoch}:${stat.size}';
      if (stat.size > UiSchema.maxBytes) {
        _emit(UiConfigBroken(UiMessages.fileTooLarge, version: version));
        return;
      }
      final bytes = file.readAsBytesSync();
      if (bytes.length > UiSchema.maxBytes) {
        _emit(UiConfigBroken(UiMessages.fileTooLarge, version: version));
        return;
      }
      _emit(UiConfigText(utf8.decode(bytes, allowMalformed: true), version: version));
    } on FileSystemException {
      _emit(const UiConfigAbsent());
    }
  }

  /// `dsh-go/ui.status.json`: what the app applied, for the agent. Written
  /// only when it changes; removed when there is no ui.json.
  @override
  Future<void> writeStatus(UiConfigLoad? load) async {
    final dir = _dir;
    if (dir == null || !dir.existsSync() || !mayWrite()) return;
    final file = File('${dir.path}/ui.status.json');
    try {
      if (load == null) {
        _lastStatus = null;
        if (file.existsSync()) file.deleteSync();
        return;
      }
      final body = {
        'version': UiSchema.version,
        'applied': load.appliedCount,
        'fatal': load.fatal,
        'usingPrevious': load.fromLastGood,
        'issues': [for (final i in load.issues) i.toJson()],
      };
      final key = jsonEncode(body);
      if (key == _lastStatus && file.existsSync()) return;
      final text = const JsonEncoder.withIndent('  ')
          .convert({'readAt': load.readAt.toUtc().toIso8601String(), ...body});
      final tmp = File('${file.path}.tmp');
      tmp.writeAsStringSync('$text\n', flush: true);
      tmp.renameSync(file.path);
      _lastStatus = key;
    } catch (_) {
      // Best effort: the app works without it.
    }
  }
}

// ── Remote hosts ────────────────────────────────────────────────────────────

/// What [RemoteUiConfigSource] needs from a connected host; [DshUiRemoteHost]
/// is the real one, tests fake it.
abstract interface class UiRemoteHost {
  bool supports(String endpoint);

  /// A conversation to scope `workspaceFiles/*` to (the most recent one).
  Future<String?> recentSessionId();

  /// `skills/list`'s path of the `dsh-go-ui` skill (its SKILL.md).
  Future<String?> skillFile(String sessionId);

  /// The host user's `$HOME` (from the connection handshake).
  String? get userHome;

  Future<DshWorkspaceText> read(String sessionId, String path, {int offset = 1, int limit = workspaceMaxPageLines});

  Stream<DshWorkspaceWatchFrame> watch(String sessionId, String path);

  /// Moments a conversation or the skill may have appeared (a conversation
  /// was added, the connection came back).
  Stream<void> get changes;
}

/// DSH home from the skill's SKILL.md path: `<home>/skills/dsh-go-ui/SKILL.md`
/// (or the folder itself). Null when the path does not have that shape.
String? dshHomeFromSkillPath(String path) {
  final parts = path.split('/');
  while (parts.isNotEmpty && parts.last.isEmpty) {
    parts.removeLast();
  }
  if (parts.isNotEmpty && parts.last == 'SKILL.md') parts.removeLast();
  if (parts.length < 3 || parts.last != 'dsh-go-ui' || parts[parts.length - 2] != 'skills') return null;
  final home = parts.sublist(0, parts.length - 2).join('/');
  return home.isEmpty ? null : home;
}

/// A remote host's `$DSH_HOME/dsh-go/ui.json` over `workspaceFiles/*`.
class RemoteUiConfigSource implements UiConfigSource {
  RemoteUiConfigSource({
    required this.host,
    this.kicks = const Stream.empty(),
    this.debounce = const Duration(milliseconds: 300),
    this.pollEvery = const Duration(seconds: 60),
    bool Function()? isForeground,
  }) : isForeground = isForeground ?? _appInFront;

  final UiRemoteHost host;
  final Stream<void> kicks;
  final Duration debounce;
  final Duration pollEvery;
  final bool Function() isForeground;

  static bool _appInFront() {
    try {
      final state = WidgetsBinding.instance.lifecycleState;
      return state == null || state == AppLifecycleState.resumed;
    } catch (_) {
      return true;
    }
  }

  StreamController<UiConfigRead>? _out;
  final _subs = <StreamSubscription<Object?>>[];
  StreamSubscription<DshWorkspaceWatchFrame>? _watch;
  Timer? _timer;
  Timer? _poll;
  String? _session;
  String? _path;
  String? _version;
  bool _skillMissing = false;
  bool _watchFailed = false;
  bool _starting = false;
  bool _reading = false;
  bool _readAgain = false;

  /// The path being read, once DSH home is known (for tests and the UI).
  String? get path => _path;

  @override
  Stream<UiConfigRead> watch() {
    late final StreamController<UiConfigRead> out;
    out = StreamController<UiConfigRead>(
      onListen: () {
        _out = out;
        _subs
          ..add(kicks.listen((_) => _kick()))
          ..add(host.changes.listen((_) => _kick()));
        unawaited(_start());
      },
      onCancel: () async {
        _out = null;
        _timer?.cancel();
        _poll?.cancel();
        for (final s in _subs) {
          await s.cancel();
        }
        _subs.clear();
        await _watch?.cancel();
        _watch = null;
      },
    );
    return out.stream;
  }

  void _emit(UiConfigRead read) {
    final out = _out;
    if (out != null && !out.isClosed) out.add(read);
  }

  void _kick() {
    if (_out == null) return;
    if (_path == null) {
      unawaited(_start());
    } else {
      _schedule();
    }
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(debounce, () => unawaited(_read()));
  }

  Future<void> _start() async {
    if (_starting || _out == null) return;
    _starting = true;
    try {
      if (!host.supports('workspaceFiles/read')) {
        _emit(const UiConfigUnavailable(UiConfigUnavailableReason.unsupported));
        return;
      }
      final session = await host.recentSessionId().catchError((Object _) => null);
      if (_out == null) return;
      if (session == null) {
        _emit(const UiConfigUnavailable(UiConfigUnavailableReason.noSession));
        return;
      }
      final skill = await host.skillFile(session).catchError((Object _) => null);
      if (_out == null) return;
      var home = skill == null ? null : dshHomeFromSkillPath(skill);
      final guessed = home == null;
      if (home == null) {
        final userHome = host.userHome;
        if (userHome != null && userHome.isNotEmpty) home = '${userHome.replaceFirst(RegExp(r'/+$'), '')}/.dsh';
      }
      if (home == null) {
        _emit(const UiConfigUnavailable(UiConfigUnavailableReason.noSkill));
        return;
      }
      _session = session;
      _path = '$home/dsh-go/ui.json';
      _skillMissing = guessed;
      await _read();
    } finally {
      _starting = false;
    }
  }

  void _forget() {
    _session = null;
    _path = null;
    _version = null;
    _watchFailed = false;
    unawaited(_watch?.cancel());
    _watch = null;
    _poll?.cancel();
    _poll = null;
  }

  Future<void> _read() async {
    final session = _session;
    final path = _path;
    if (session == null || path == null || _out == null) return;
    if (_reading) {
      _readAgain = true;
      return;
    }
    _reading = true;
    try {
      final first = await host.read(session, path);
      if (_out == null || path != _path) return;
      if ((first.bytes ?? 0) > UiSchema.maxBytes) {
        _version = first.version;
        _emit(UiConfigBroken(UiMessages.fileTooLarge, version: first.version));
      } else {
        final text = StringBuffer(first.text);
        var page = first;
        var pages = 1;
        var tooLarge = false;
        while (!page.eof && page.lines > 0 && pages < 16) {
          page = await host.read(session, path, offset: page.offset + page.lines);
          text
            ..write('\n')
            ..write(page.text);
          pages++;
          if (text.length > UiSchema.maxBytes) {
            tooLarge = true;
            break;
          }
        }
        if (_out == null || path != _path) return;
        _version = first.version;
        final body = text.toString();
        _emit(
          tooLarge || utf8.encode(body).length > UiSchema.maxBytes
              ? UiConfigBroken(UiMessages.fileTooLarge, version: first.version)
              : UiConfigText(body, version: first.version),
        );
      }
      _follow();
    } on DshRemoteException catch (e) {
      if (_out == null) return;
      switch (e.code) {
        case 'workspace-file/not-found' || 'workspace-file/not-regular-file':
          _version = null;
          _emit(UiConfigAbsent(skillMissing: _skillMissing));
          _follow();
        case 'workspace-file/too-large':
          _emit(UiConfigBroken(UiMessages.fileTooLarge));
          _follow();
        case 'workspace-file/not-text':
          _emit(UiConfigBroken(appL10n.shellConfigNotTextFile));
          _follow();
        case 'workspace-file/unknown-workspace' || 'session/not-found':
          // The conversation went away: pick another one.
          _forget();
          unawaited(Future<void>.microtask(_start));
        default:
          _emit(const UiConfigUnavailable(UiConfigUnavailableReason.denied));
      }
    } catch (_) {
      // Lost link or timeout: the next kick or reconnect reads again.
    } finally {
      _reading = false;
      if (_readAgain) {
        _readAgain = false;
        _schedule();
      }
    }
  }

  /// Follows the file: `workspaceFiles/changes` when the host has it (DSH
  /// 0.2.1 watches a file outside the workspace, and a missing one: it
  /// reports the creation), else a check every [pollEvery] while the app is
  /// in front. A refused watch falls back to polling, and is tried again once
  /// the file shows up.
  void _follow() {
    if (_watch != null || _session == null || _path == null) return;
    if (!_watchFailed && host.supports('workspaceFiles/changes')) {
      _poll?.cancel();
      _poll = null;
      final session = _session!;
      final path = _path!;
      _watch = host
          .watch(session, path)
          .listen(
            (_) => _schedule(),
            onError: (Object _) {
              _watch = null;
              _watchFailed = true;
              _startPolling();
            },
            onDone: () {
              _watch = null;
              _startPolling();
            },
            cancelOnError: true,
          );
      return;
    }
    _startPolling();
  }

  void _startPolling() {
    if (_poll != null || _out == null) return;
    _poll = Timer.periodic(pollEvery, (_) => unawaited(_check()));
  }

  /// One cheap look (a one-line page) and a full read when the version moved.
  Future<void> _check() async {
    final session = _session;
    final path = _path;
    if (session == null || path == null || _out == null || _reading || !isForeground()) return;
    try {
      final probe = await host.read(session, path, limit: 1);
      if (probe.version != _version || _version == null) {
        final appeared = _version == null;
        await _read();
        if (appeared && _version != null && _watch == null && host.supports('workspaceFiles/changes')) {
          _watchFailed = false;
          _follow();
        }
      }
    } on DshRemoteException catch (e) {
      if ((e.code == 'workspace-file/not-found' || e.code == 'workspace-file/not-regular-file') && _version != null) {
        _version = null;
        _emit(UiConfigAbsent(skillMissing: _skillMissing));
      }
    } catch (_) {}
  }
}

/// [UiRemoteHost] over a connected [DshClient].
class DshUiRemoteHost implements UiRemoteHost {
  DshUiRemoteHost(this.client);

  final DshClient client;

  @override
  bool supports(String endpoint) => client.supportsEndpoint(endpoint);

  @override
  Future<String?> recentSessionId() async {
    final sessions = await client.listSessions();
    if (sessions.isEmpty) return null;
    final ranked = [...sessions]
      ..sort((a, b) {
        int rank(SessionSummary s) => (s.isSubagent ? 2 : 0) + (s.blank ? 1 : 0);
        final byRank = rank(a).compareTo(rank(b));
        return byRank != 0 ? byRank : b.updatedAt.compareTo(a.updatedAt);
      });
    final id = ranked.first.sessionId;
    return id.isEmpty ? null : id;
  }

  @override
  Future<String?> skillFile(String sessionId) async {
    for (final skill in await client.listSkills(sessionId)) {
      if (skill.name == 'dsh-go-ui') return skill.path;
    }
    return null;
  }

  @override
  String? get userHome => client.mux.generation?.home;

  @override
  Future<DshWorkspaceText> read(String sessionId, String path, {int offset = 1, int limit = workspaceMaxPageLines}) =>
      client.readWorkspaceText(sessionId, path, offset: offset, limit: limit);

  @override
  Stream<DshWorkspaceWatchFrame> watch(String sessionId, String path) => client.watchWorkspace(sessionId, path);

  @override
  Stream<void> get changes => client.hostEvents.where((e) => e is SessionAddedEvent || e is HostReadyEvent).map((_) {});
}
