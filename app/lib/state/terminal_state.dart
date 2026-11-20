// 对话终端的状态层。一个对话一组终端页签;每个页签是 Host 上的一个 PTY,
// 外加本地的 xterm 屏幕模型。
//
// 行为与官方 TerminalView 一致:
// * 打开时先列出 Host 保留的终端并逐个恢复;一个都没有就新建一个;
// * 新建前先定好 id(重复 create 幂等,关闭过的 id 不能再用);
// * 先 retain 再 attach;每次 attach 都从完整屏幕快照开始,换一块新屏幕;
// * 断线只丢输入权,进程还在:连接恢复(新的 mux 代)或回到前台时重新 attach;
// * 进程退出不自动重开,页签停在「已结束」,由用户在原位置新建。
// 页面离开只断开连接,不结束进程;关闭页签才结束进程。

import 'dart:async';
import 'dart:async' as dart_async show AsyncError; // Riverpod exports its own AsyncError.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart' show Terminal;

import '../l10n/l10n.dart';
import 'connection_state.dart';

// ── Backend seam ─────────────────────────────────────────────────────────────

/// What the terminal page needs from one conversation on one Host. Tests
/// swap in a fake through [terminalBackendProvider].
abstract class TerminalBackend {
  /// False on connections that cannot carry terminal input (the relay).
  bool get supported;

  /// A Remote Host that announced no terminal: its owner turned it off.
  bool get offOnHost;

  /// Fires each time the link to the Host comes back.
  Stream<void> get reconnected;

  Future<TerminalEnvironment> environment();
  Future<List<TerminalShell>> shells();
  Future<List<TerminalInfo>> list();
  Future<TerminalInfo> create(String id, {required int cols, required int rows, String? shellPath});
  Future<void> rename(String id, String title);
  Future<void> close(String id);
  Stream<void> retain(String id);
  TerminalAttachment attach(String id, TerminalEnvironment environment);
}

class ClientTerminalBackend implements TerminalBackend {
  ClientTerminalBackend(this.client, this.sessionId);

  final DshClient client;
  final String sessionId;

  @override
  bool get supported => client.supportsTerminals;

  @override
  bool get offOnHost => client.terminalsOffOnHost;

  @override
  Stream<void> get reconnected => client.mux.generations.map((_) {});

  @override
  Future<TerminalEnvironment> environment() => client.terminalEnvironment(sessionId);

  @override
  Future<List<TerminalShell>> shells() => client.terminalShells(sessionId);

  @override
  Future<List<TerminalInfo>> list() => client.listTerminals(sessionId);

  @override
  Future<TerminalInfo> create(String id, {required int cols, required int rows, String? shellPath}) =>
      client.createTerminal(sessionId, id: id, cols: cols, rows: rows, shellPath: shellPath);

  @override
  Future<void> rename(String id, String title) => client.renameTerminal(sessionId, id, title);

  @override
  Future<void> close(String id) => client.closeTerminal(sessionId, id);

  @override
  Stream<void> retain(String id) => client.retainTerminal(sessionId, id);

  @override
  TerminalAttachment attach(String id, TerminalEnvironment environment) =>
      client.attachTerminal(sessionId, id, environment: environment);
}

/// Null while there is no connection to the active host.
final terminalBackendProvider = Provider.autoDispose.family<TerminalBackend?, String>((ref, sessionId) {
  final client = ref.watch(activeConnectionProvider.select((c) => c.value?.client));
  return client == null ? null : ClientTerminalBackend(client, sessionId);
});

// ── State ────────────────────────────────────────────────────────────────────

enum TerminalPhase {
  /// `terminal/create` in flight.
  starting,

  /// Waiting for the hold and the first screen.
  connecting,

  /// Attached: output flows; input too when [TerminalTab.writable].
  live,

  /// The link dropped; the process is still there.
  disconnected,

  /// The shell exited (or the terminal was closed elsewhere).
  ended,

  /// The Host no longer has this terminal (engine restarted).
  missing,

  /// Could not start (limit reached, shell failed).
  failed,
}

/// One terminal page tab.
@immutable
class TerminalTab {
  const TerminalTab({
    required this.id,
    required this.terminal,
    this.title = '',
    this.phase = TerminalPhase.starting,
    this.writable = false,
    this.info,
    this.message,
  });

  final String id;

  /// The screen model. A fresh one replaces it with every attachment's
  /// snapshot; output lands in it directly (no state change per chunk).
  final Terminal terminal;
  final String title;
  final TerminalPhase phase;

  /// This phone holds input (only meaningful while [TerminalPhase.live]).
  final bool writable;
  final TerminalInfo? info;

  /// Short copy for [TerminalPhase.failed].
  final String? message;

  /// Another page or device took input over.
  bool get readOnly => phase == TerminalPhase.live && !writable;
  int? get exitCode => info?.exitCode;

  TerminalTab copyWith({
    Terminal? terminal,
    String? title,
    TerminalPhase? phase,
    bool? writable,
    TerminalInfo? info,
    String? message,
    bool clearMessage = false,
  }) => TerminalTab(
    id: id,
    terminal: terminal ?? this.terminal,
    title: title ?? this.title,
    phase: phase ?? this.phase,
    writable: writable ?? this.writable,
    info: info ?? this.info,
    message: clearMessage ? null : message ?? this.message,
  );
}

@immutable
class TerminalWorkspaceState {
  const TerminalWorkspaceState({
    this.loading = true,
    this.supported = true,
    this.offline = false,
    this.error,
    this.tabs = const [],
    this.selectedId,
    this.environment,
  });

  /// Listing the conversation's terminals.
  final bool loading;

  /// False when this connection cannot run terminals (relay).
  final bool supported;

  /// No connection to the active host.
  final bool offline;

  /// The list could not be read; [TerminalWorkspace.reload] retries.
  final String? error;
  final List<TerminalTab> tabs;
  final String? selectedId;
  final TerminalEnvironment? environment;

  TerminalTab? get selected {
    for (final tab in tabs) {
      if (tab.id == selectedId) return tab;
    }
    return tabs.isEmpty ? null : tabs.first;
  }

  TerminalWorkspaceState copyWith({
    bool? loading,
    String? error,
    bool clearError = false,
    List<TerminalTab>? tabs,
    String? selectedId,
    TerminalEnvironment? environment,
  }) => TerminalWorkspaceState(
    loading: loading ?? this.loading,
    supported: supported,
    offline: offline,
    error: clearError ? null : error ?? this.error,
    tabs: tabs ?? this.tabs,
    selectedId: selectedId ?? this.selectedId,
    environment: environment ?? this.environment,
  );
}

/// Copy for errors the page shows.
abstract final class TerminalCopy {
  static String get offline => appL10n.commonEngineUnreachable;
  static String get limit => appL10n.stateTerminalLimit;
  static String get startFailed => appL10n.stateTerminalStartFailed;
  static String get disabledOnHost => appL10n.stateTerminalDisabledOnHost;

  /// A Remote Host whose owner switched the terminal off in its local Remote
  /// settings (ds-harness-remote `TERMINAL_DISABLED`); only they can turn it on.
  /// Also inside the [ParallelWaitError] of the first load's `(a, b).wait`.
  static bool isDisabledOnHost(Object error) => switch (error) {
    DshRemoteException(code: 'TERMINAL_DISABLED') => true,
    ParallelWaitError(:final errors) => switch (errors) {
      (final dart_async.AsyncError? a, final dart_async.AsyncError? b) => [
        a?.error,
        b?.error,
      ].nonNulls.any(isDisabledOnHost),
      _ => false,
    },
    _ => false,
  };
}

// ── Controller ───────────────────────────────────────────────────────────────

class _Link {
  _Link(this.id);

  final String id;
  String? shellPath;
  TerminalAttachment? attachment;
  StreamSubscription<TerminalFrame>? frames;
  StreamSubscription<void>? retain;
  bool retained = false;

  /// The tab was shown: it attaches (and so takes input control). Tabs never
  /// looked at are only held.
  bool wanted = false;

  /// The attach waiting for the hold to be acknowledged.
  void Function()? onRetained;

  /// Bumped by every (re)connect; late events of an older one are dropped.
  int generation = 0;

  void detach() {
    unawaited(frames?.cancel());
    frames = null;
    final old = attachment;
    attachment = null;
    if (old != null) unawaited(old.close());
  }

  void dispose() {
    generation++;
    detach();
    unawaited(retain?.cancel());
    retain = null;
    retained = false;
    onRetained = null;
  }
}

class TerminalWorkspace extends Notifier<TerminalWorkspaceState> {
  TerminalWorkspace(this.sessionId);

  final String sessionId;

  static const _shellKey = 'terminal.shell';

  TerminalBackend? _backend;
  final Map<String, _Link> _links = {};
  StreamSubscription<void>? _reconnects;
  List<TerminalShell>? _shells;
  (int, int)? _viewSize;
  Completer<void>? _sized;

  /// How long a new terminal waits for the screen to be measured, so the
  /// shell starts at the phone's size instead of 80 × 24.
  @visibleForTesting
  static Duration viewSizeWait = const Duration(milliseconds: 400);

  /// The PTY follows the screen size once it settles (the keyboard sliding
  /// in resizes the screen every frame; the shell should redraw once).
  @visibleForTesting
  static Duration resizeSettle = const Duration(milliseconds: 150);
  final Map<String, Timer> _resizes = {};

  /// Bumped on every build and dispose: async work of an older one stops.
  int _epoch = 0;

  @override
  TerminalWorkspaceState build() {
    final backend = ref.watch(terminalBackendProvider(sessionId));
    final epoch = ++_epoch;
    _backend = backend;
    ref.onDispose(() => _teardown(epoch));
    if (backend == null) return const TerminalWorkspaceState(loading: false, offline: true);
    if (!backend.supported) return const TerminalWorkspaceState(loading: false, supported: false);
    _reconnects = backend.reconnected.listen((_) => reconnectAll());
    // Retrying still tries: the Host applies its switch without reconnecting.
    if (backend.offOnHost) return TerminalWorkspaceState(loading: false, error: TerminalCopy.disabledOnHost);
    scheduleMicrotask(() => _load(epoch));
    return const TerminalWorkspaceState();
  }

  void _teardown(int epoch) {
    if (epoch == _epoch) _epoch++;
    unawaited(_reconnects?.cancel());
    _reconnects = null;
    for (final link in _links.values) {
      link.dispose();
    }
    _links.clear();
    for (final timer in _resizes.values) {
      timer.cancel();
    }
    _resizes.clear();
    _shells = null;
    final sized = _sized;
    _sized = null;
    if (sized != null && !sized.isCompleted) sized.complete();
  }

  bool _stale(int epoch) => epoch != _epoch || !ref.mounted;

  // ── Loading ──

  Future<void> _load(int epoch) async {
    final backend = _backend;
    if (backend == null || _stale(epoch)) return;
    try {
      final (environment, list) = await (backend.environment(), backend.list()).wait;
      if (_stale(epoch)) return;
      final tabs = [
        for (final info in list)
          TerminalTab(
            id: info.id,
            terminal: _placeholder(info.id),
            title: info.title,
            phase: info.running ? TerminalPhase.connecting : TerminalPhase.ended,
            info: info,
          ),
      ];
      final running = tabs.where((t) => t.info?.running ?? false);
      state = state.copyWith(
        loading: false,
        clearError: true,
        environment: environment,
        tabs: tabs,
        selectedId: (running.isEmpty ? tabs.firstOrNull : running.first)?.id,
      );
      for (final tab in tabs) {
        final link = _links.putIfAbsent(tab.id, () => _Link(tab.id));
        if (tab.id == state.selectedId) {
          _connect(tab.id);
        } else {
          _hold(link);
        }
      }
      if (tabs.isEmpty) await newTerminal();
    } on Object catch (error) {
      if (_stale(epoch)) return;
      final message = TerminalCopy.isDisabledOnHost(error) ? TerminalCopy.disabledOnHost : TerminalCopy.offline;
      state = state.copyWith(loading: false, error: message);
    }
  }

  /// Retries a failed listing.
  Future<void> reload() async {
    if (_backend == null || state.loading) return;
    state = state.copyWith(loading: true, clearError: true);
    await _load(_epoch);
  }

  // ── Tabs ──

  /// Shows [id]; a tab shown for the first time attaches now.
  void select(String id) {
    if (state.selectedId == id || _tab(id) == null) return;
    state = state.copyWith(selectedId: id);
    _show(id);
  }

  void _show(String id) {
    final tab = _tab(id);
    if (tab == null) return;
    final link = _links[id];
    final startable = switch (tab.phase) {
      TerminalPhase.starting || TerminalPhase.failed || TerminalPhase.missing => false,
      _ => true,
    };
    if (startable && (link == null || !link.wanted)) _connect(id);
  }

  /// Opens a new terminal ([shellPath] from [shells]; null uses the last
  /// choice when it is still installed, else the default). With [replacing],
  /// it takes that tab's place and the old terminal is closed.
  Future<void> newTerminal({String? shellPath, String? replacing}) async {
    final backend = _backend;
    if (backend == null) return;
    final id = newTerminalId();
    final tab = TerminalTab(id: id, terminal: _placeholder(id));
    final tabs = [...state.tabs];
    final at = replacing == null ? -1 : tabs.indexWhere((t) => t.id == replacing);
    if (at >= 0) {
      tabs[at] = tab;
      _closeQuietly(replacing!);
    } else {
      tabs.add(tab);
    }
    state = state.copyWith(tabs: tabs, selectedId: id);
    _links[id] = _Link(id)..shellPath = shellPath;
    if (shellPath != null) unawaited(_rememberShell(shellPath));
    await _create(id);
  }

  /// Retries a tab whose start failed (same id: create is idempotent).
  Future<void> retry(String id) async {
    final tab = _tab(id);
    if (tab == null) return;
    if (tab.phase == TerminalPhase.failed) {
      await _create(id);
    } else {
      reconnect(id);
    }
  }

  /// Ends the terminal on the Host and drops the tab.
  void closeTab(String id) {
    final index = state.tabs.indexWhere((t) => t.id == id);
    if (index < 0) return;
    final tabs = [...state.tabs]..removeAt(index);
    var selected = state.selectedId;
    if (selected == id) {
      selected = tabs.isEmpty ? null : tabs[index.clamp(0, tabs.length - 1)].id;
    }
    state = TerminalWorkspaceState(
      loading: false,
      tabs: tabs,
      selectedId: selected,
      environment: state.environment,
      error: state.error,
    );
    _closeQuietly(id);
    if (selected != null) _show(selected);
  }

  /// Renames on the Host; false (and the old title back) when it failed.
  Future<bool> rename(String id, String title) async {
    final backend = _backend;
    final tab = _tab(id);
    final next = title.trim();
    if (backend == null || tab == null || next.isEmpty || next == tab.title) return false;
    final epoch = _epoch;
    final previous = tab.title;
    _update(id, (t) => t.copyWith(title: next));
    try {
      var end = next.length > 120 ? 120 : next.length;
      if (end < next.length) {
        final before = next.codeUnitAt(end - 1);
        final after = next.codeUnitAt(end);
        if (before >= 0xD800 && before <= 0xDBFF && after >= 0xDC00 && after <= 0xDFFF) end--;
      }
      await backend.rename(id, next.substring(0, end));
      return true;
    } on Object {
      if (_stale(epoch)) return false;
      _update(id, (t) => t.copyWith(title: previous));
      return false;
    }
  }

  /// Installed shells for the picker (cached for this page).
  Future<List<TerminalShell>> shells() async {
    final cached = _shells;
    if (cached != null) return cached;
    final backend = _backend;
    if (backend == null) return const [];
    final epoch = _epoch;
    final shells = await backend.shells();
    if (_stale(epoch)) return const [];
    return _shells = shells;
  }

  // ── Connection ──

  /// Re-attaches [id]: after a drop, or to take input back.
  void reconnect(String id) {
    final tab = _tab(id);
    if (tab == null || tab.phase == TerminalPhase.starting || tab.phase == TerminalPhase.failed) return;
    _connect(id);
  }

  /// Re-attaches every dropped tab (the link came back, the app resumed).
  void reconnectAll() {
    // Nothing listed yet (the Host had the terminal off, or the link was
    // down): the link coming back is the moment to list again.
    if (state.tabs.isEmpty && state.error != null) {
      unawaited(reload());
      return;
    }
    for (final tab in state.tabs) {
      final link = _links[tab.id];
      if (tab.phase == TerminalPhase.disconnected) {
        _connect(tab.id);
      } else if (link != null && !link.wanted && link.retain == null && tab.phase != TerminalPhase.missing) {
        _hold(link);
      }
    }
  }

  /// Input from the screen (keys, paste, emulator replies).
  void send(String id, String data) => _links[id]?.attachment?.write(data);

  /// The visible screen measured [cols] × [rows]; the PTY follows when this
  /// phone holds input.
  void resize(String id, int cols, int rows) {
    _viewSize = (cols, rows);
    final sized = _sized;
    if (sized != null && !sized.isCompleted) sized.complete();
    _resizes.remove(id)?.cancel();
    if (resizeSettle == Duration.zero) {
      _links[id]?.attachment?.resize(cols, rows);
      return;
    }
    _resizes[id] = Timer(resizeSettle, () {
      _resizes.remove(id);
      _links[id]?.attachment?.resize(cols, rows);
    });
  }

  // ── Internals ──

  TerminalTab? _tab(String id) {
    for (final tab in state.tabs) {
      if (tab.id == id) return tab;
    }
    return null;
  }

  void _update(String id, TerminalTab Function(TerminalTab tab) change) {
    final tabs = state.tabs;
    final index = tabs.indexWhere((t) => t.id == id);
    if (index < 0) return;
    state = state.copyWith(tabs: [...tabs]..[index] = change(tabs[index]));
  }

  Terminal _placeholder(String id) => _emulator(id, null, null);

  /// A screen wired to [id]'s attachment; [info] and [screen] restore a
  /// snapshot at the Host's size.
  Terminal _emulator(String id, TerminalInfo? info, String? screen) {
    final scrollback = state.environment?.scrollback ?? TerminalEnvironment.defaults.scrollback;
    final terminal = Terminal(maxLines: (scrollback < 200 ? 200 : scrollback) + 200);
    if (info != null) terminal.resize(info.cols, info.rows);
    if (screen != null && screen.isNotEmpty) terminal.write(screen);
    terminal.onOutput = (data) => send(id, data);
    terminal.onResize = (cols, rows, _, _) => resize(id, cols, rows);
    return terminal;
  }

  Future<void> _create(String id) async {
    final backend = _backend;
    final link = _links[id];
    if (backend == null || link == null) return;
    final epoch = _epoch;
    _update(id, (t) => t.copyWith(phase: TerminalPhase.starting, clearMessage: true));
    final environment = state.environment ?? TerminalEnvironment.defaults;
    try {
      final shellPath = link.shellPath ?? await _preferredShell(backend);
      link.shellPath = shellPath;
      await _measured();
      if (_stale(epoch) || !_links.containsKey(id)) return;
      final (cols, rows) = _viewSize ?? (80, 24);
      final info = await backend.create(
        id,
        cols: cols.clamp(2, environment.maxCols),
        rows: rows.clamp(1, environment.maxRows),
        shellPath: shellPath,
      );
      if (_stale(epoch) || !_links.containsKey(id)) return;
      _update(id, (t) => t.copyWith(info: info, title: info.title));
      _connect(id);
    } on DshRemoteException catch (error) {
      if (_stale(epoch)) return;
      final message = switch (error.code) {
        'terminal/limit-reached' => TerminalCopy.limit,
        'TERMINAL_DISABLED' => TerminalCopy.disabledOnHost,
        _ => TerminalCopy.startFailed,
      };
      _update(id, (t) => t.copyWith(phase: TerminalPhase.failed, message: message));
    } on Object {
      if (_stale(epoch)) return;
      _update(id, (t) => t.copyWith(phase: TerminalPhase.failed, message: TerminalCopy.offline));
    }
  }

  /// Waits (briefly) for the first measurement of the screen.
  Future<void> _measured() async {
    if (_viewSize != null || viewSizeWait == Duration.zero) return;
    final sized = _sized ??= Completer<void>();
    final timer = Timer(viewSizeWait, () {
      if (!sized.isCompleted) sized.complete();
    });
    await sized.future;
    timer.cancel();
  }

  /// Holds [link]'s terminal (no output, no input control) so the Host
  /// never reclaims it while the page is open; a pending attach follows the
  /// acknowledgement.
  void _hold(_Link link) {
    final backend = _backend;
    if (backend == null || link.retain != null) return;
    link.retained = false;
    link.retain = backend
        .retain(link.id)
        .listen(
          (_) {
            if (link.retained) return;
            link.retained = true;
            final pending = link.onRetained;
            link.onRetained = null;
            pending?.call();
          },
          onError: (Object error) {
            link
              ..retained = false
              ..retain = null
              ..onRetained = null;
            if (link.wanted) {
              _onError(link, link.generation, error);
            } else if (error is DshRemoteException && error.code == 'terminal/unavailable') {
              _update(link.id, (t) => t.copyWith(phase: TerminalPhase.missing, writable: false));
            }
          },
          onDone: () {
            link
              ..retained = false
              ..retain = null;
          },
        );
  }

  /// Attaches [id] (after its hold): a fresh screen and input control.
  void _connect(String id) {
    final backend = _backend;
    final link = _links.putIfAbsent(id, () => _Link(id));
    if (backend == null) return;
    link
      ..detach()
      ..wanted = true;
    final token = ++link.generation;
    _update(id, (t) => t.copyWith(phase: TerminalPhase.connecting, writable: false));

    void attach() {
      if (token != link.generation) return;
      final attachment = backend.attach(id, state.environment ?? TerminalEnvironment.defaults);
      link.attachment = attachment;
      link.frames = attachment.frames.listen(
        (frame) => _onFrame(link, token, frame),
        onError: (Object error) => _onError(link, token, error),
        onDone: () => _onDone(link, token),
      );
    }

    if (link.retained && link.retain != null) {
      attach();
      return;
    }
    link.onRetained = attach;
    _hold(link);
  }

  void _onFrame(_Link link, int token, TerminalFrame frame) {
    if (token != link.generation) return;
    final id = link.id;
    final writable = link.attachment?.writable ?? false;
    switch (frame) {
      case TerminalSnapshot(:final info, :final screen):
        _update(
          id,
          (t) => t.copyWith(
            terminal: _emulator(id, info, screen),
            info: info,
            title: info.title,
            phase: info.running ? TerminalPhase.live : TerminalPhase.ended,
            writable: writable,
          ),
        );
      case TerminalOutput(:final data):
        _tab(id)?.terminal.write(data);
      case TerminalStatus(:final info):
        _update(
          id,
          (t) => t.copyWith(
            info: info,
            title: info.title,
            phase: info.running ? TerminalPhase.live : TerminalPhase.ended,
            writable: writable,
          ),
        );
      case TerminalAck(:final refusal):
        if (refusal != null) _update(id, (t) => t.copyWith(writable: false));
    }
  }

  void _onError(_Link link, int token, Object error) {
    if (token != link.generation) return;
    link.detach();
    final missing = error is DshRemoteException && error.code == 'terminal/unavailable';
    // Still reconnectable once the Host owner turns the terminal back on.
    final off = TerminalCopy.isDisabledOnHost(error) ? TerminalCopy.disabledOnHost : null;
    _update(link.id, (t) {
      if (missing) return t.copyWith(phase: TerminalPhase.missing, writable: false);
      if (t.info != null && !t.info!.running) return t.copyWith(phase: TerminalPhase.ended, writable: false);
      return t.copyWith(phase: TerminalPhase.disconnected, writable: false, message: off, clearMessage: off == null);
    });
  }

  /// The Host ended the attachment: the terminal was closed.
  void _onDone(_Link link, int token) {
    if (token != link.generation) return;
    link.detach();
    _update(link.id, (t) => t.copyWith(phase: TerminalPhase.ended, writable: false));
  }

  void _closeQuietly(String id) {
    _links.remove(id)?.dispose();
    final backend = _backend;
    if (backend != null) unawaited(backend.close(id).catchError((Object _) {}));
  }

  Future<String?> _preferredShell(TerminalBackend backend) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final remembered = prefs.getString(_shellKey);
      if (remembered == null) return null;
      final installed = await shells();
      return installed.any((s) => s.path == remembered) ? remembered : null;
    } on Object {
      return null;
    }
  }

  Future<void> _rememberShell(String path) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_shellKey, path);
    } on Object {
      // Not remembering is fine.
    }
  }
}

final terminalWorkspaceProvider = NotifierProvider.autoDispose
    .family<TerminalWorkspace, TerminalWorkspaceState, String>(TerminalWorkspace.new);

// ── Font size ────────────────────────────────────────────────────────────────

/// Terminal font size (pinch on the screen); remembered across pages.
class TerminalFontSize extends Notifier<double> {
  static const min = 8.0;
  static const max = 24.0;
  static const fallback = 13.0;
  static const _key = 'terminal.fontSize';

  Timer? _save;

  @override
  double build() {
    ref.onDispose(() => _save?.cancel());
    unawaited(_restore());
    return fallback;
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getDouble(_key);
      if (saved != null && ref.mounted) state = saved.clamp(min, max);
    } on Object {
      // Default size.
    }
  }

  /// Sets [size] (clamped, half-point steps); saved shortly after.
  void set(double size) {
    final next = (size.clamp(min, max) * 2).roundToDouble() / 2;
    if (next == state) return;
    state = next;
    _save?.cancel();
    _save = Timer(const Duration(milliseconds: 400), () async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setDouble(_key, next);
      } on Object {
        // Kept for this run only.
      }
    });
  }
}

final terminalFontSizeProvider = NotifierProvider<TerminalFontSize, double>(TerminalFontSize.new);
