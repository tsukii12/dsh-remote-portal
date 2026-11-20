/// The conversation's interactive terminals (`terminal/*`), as the official
/// right-sidebar terminal uses them.
///
/// Verified against DSH 0.2.1-rc.2 (`@deepseek-ai/dsh-api-terminal-controller`
/// typings and Host source, `dsh-client-ui-sidebar-terminal`, and a throwaway
/// `dsh web`):
/// * unary `environment`, `shells`, `create`, `rename`, `close` take
///   `agentId` (they wake the conversation's Agent); `list` takes `sessionId`
///   and reads retained terminals without waking anything;
/// * `retain` is a stream that acknowledges one window hold (`{type:
///   retained}`) and stays open: a held terminal is never reclaimed as idle;
/// * `attach` is a duplex stream: it starts with a full `snapshot` of the
///   screen, then ordered `output`, `state` and `ack` frames; the uplink
///   carries `write` / `resize` commands numbered from 1 per attachment. The
///   newest attachment holds input; older ones keep reading output and get
///   `ack.refusal: read-only`. Input is never replayed across attachments.
///
/// Attach needs uplink items, which the ds-harness-remote tunnel does not
/// carry. There the Host plugin (`harness.terminal.v1`, plugin
/// `terminal-carrier-compat.ts`) joins a `terminal/follow` stream bound to an
/// attachment id with unary `terminal/write` / `terminal/resize` calls into
/// the official attach; [TerminalApi.attachTerminal] picks that route when
/// the carrier has no uplink (see [_FollowLink]).
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'json.dart';
import 'mux.dart';
import 'session_api.dart';

// -----------------------------------------------------------------------------
// Models
// -----------------------------------------------------------------------------

/// An installed shell found in the conversation's execution environment.
class TerminalShell {
  const TerminalShell({required this.path, required this.name, this.args = const []});

  static TerminalShell? fromJson(Object? json) {
    final map = asMap(json);
    final path = asString(map?['path']);
    if (map == null || path == null || path.isEmpty) return null;
    return TerminalShell(
      path: path,
      name: asString(map['name']) ?? path.split('/').last,
      args: asStringList(map['args']),
    );
  }

  /// Executable path; pass it back to [TerminalApi.createTerminal].
  final String path;

  /// Display name (`bash`, `fish`, `zsh`).
  final String name;
  final List<String> args;
}

/// The conversation's directory and the Host's terminal limits.
class TerminalEnvironment {
  const TerminalEnvironment({
    this.cwd = '',
    this.maxInputBytes = 65536,
    this.maxBufferedBytes = 2097152,
    this.maxCols = 500,
    this.maxRows = 200,
    this.scrollback = 1000,
  });

  /// The Host defaults, for an attachment opened before `environment` came
  /// back.
  static const defaults = TerminalEnvironment();

  factory TerminalEnvironment.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    int positive(Object? value, int fallback) {
      final n = asInt(value);
      return n == null || n <= 0 ? fallback : n;
    }

    return TerminalEnvironment(
      cwd: asString(map['cwd']) ?? '',
      maxInputBytes: positive(map['maxInputBytes'], defaults.maxInputBytes),
      maxBufferedBytes: positive(map['maxBufferedBytes'], defaults.maxBufferedBytes),
      maxCols: positive(map['maxCols'], defaults.maxCols),
      maxRows: positive(map['maxRows'], defaults.maxRows),
      scrollback: asInt(map['scrollback']) ?? defaults.scrollback,
    );
  }

  /// Logged current directory of the conversation (new terminals start here).
  final String cwd;

  /// Raw UTF-8 bytes in one `write`.
  final int maxInputBytes;

  /// Encoded input frames kept on this side until acknowledged.
  final int maxBufferedBytes;
  final int maxCols;
  final int maxRows;

  /// Rows of history the Host keeps for the screen snapshot.
  final int scrollback;
}

enum TerminalProcessState {
  running,
  exited,

  /// The PTY or shell could not run (see [TerminalInfo.error]).
  failed,
}

/// Host-owned metadata of one terminal. Process exit never starts a new shell.
class TerminalInfo {
  const TerminalInfo({
    required this.id,
    required this.title,
    required this.shell,
    this.cwd = '',
    this.cols = 80,
    this.rows = 24,
    this.state = TerminalProcessState.running,
    this.exitCode,
    this.error,
  });

  static TerminalInfo? fromJson(Object? json) {
    final map = asMap(json);
    final id = asString(map?['id']);
    if (map == null || id == null || id.isEmpty) return null;
    final shell = TerminalShell.fromJson(map['shell']) ?? const TerminalShell(path: '', name: '');
    final title = asString(map['title'])?.trim();
    return TerminalInfo(
      id: id,
      title: title == null || title.isEmpty ? shell.name : title,
      shell: shell,
      cwd: asString(map['cwd']) ?? '',
      cols: asInt(map['cols']) ?? 80,
      rows: asInt(map['rows']) ?? 24,
      state: switch (map['state']) {
        'exited' => TerminalProcessState.exited,
        'failed' => TerminalProcessState.failed,
        _ => TerminalProcessState.running,
      },
      exitCode: asInt(map['exitCode']),
      error: asString(map['error']),
    );
  }

  final String id;

  /// User title; the shell name until renamed.
  final String title;
  final TerminalShell shell;

  /// Directory the shell started in (`cd` inside the shell does not change it).
  final String cwd;
  final int cols;
  final int rows;
  final TerminalProcessState state;
  final int? exitCode;
  final String? error;

  bool get running => state == TerminalProcessState.running;

  TerminalInfo copyWith({String? title}) => TerminalInfo(
    id: id,
    title: title ?? this.title,
    shell: shell,
    cwd: cwd,
    cols: cols,
    rows: rows,
    state: state,
    exitCode: exitCode,
    error: error,
  );
}

/// The carrier's inbox for buffered uplink frames of one stream.
class TerminalInputWindow {
  const TerminalInputWindow({required this.maxBytes, required this.frameOverheadBytes});

  static TerminalInputWindow? fromJson(Object? json) {
    final map = asMap(json);
    final max = asInt(map?['maxBytes']);
    if (map == null || max == null || max <= 0) return null;
    return TerminalInputWindow(maxBytes: max, frameOverheadBytes: asInt(map['frameOverheadBytes']) ?? 0);
  }

  /// Encoded frame bytes that may wait for the Host at once.
  final int maxBytes;

  /// Envelope bytes the carrier adds to each JSON item.
  final int frameOverheadBytes;
}

/// One frame of an attachment ([TerminalAttachment.frames]).
sealed class TerminalFrame {
  const TerminalFrame();

  /// Null for a frame this client does not know.
  static TerminalFrame? fromJson(Object? json) {
    final map = asMap(json);
    if (map == null) return null;
    final info = TerminalInfo.fromJson(map['info']);
    switch (map['type']) {
      case 'snapshot' when info != null:
        return TerminalSnapshot(
          sequence: asInt(map['sequence']) ?? 0,
          screen: asString(map['screen']) ?? '',
          info: info,
          writable: map['writable'] == true,
          window: TerminalInputWindow.fromJson(map['inputWindow']),
        );
      case 'output':
        final sequence = asInt(map['sequence']);
        if (sequence == null) return null;
        return TerminalOutput(sequence: sequence, data: asString(map['data']) ?? '');
      case 'state' when info != null:
        return TerminalStatus(info: info, writable: map['writable'] == true);
      case 'ack':
        final sequence = asInt(map['sequence']);
        if (sequence == null) return null;
        return TerminalAck(sequence: sequence, refusal: asString(map['refusal']));
    }
    return null;
  }
}

/// The whole bounded screen (escape sequences included) at [sequence]; the
/// first frame of every attachment. Write it into a fresh emulator sized
/// [TerminalInfo.cols] × [TerminalInfo.rows].
final class TerminalSnapshot extends TerminalFrame {
  const TerminalSnapshot({
    required this.sequence,
    required this.screen,
    required this.info,
    required this.writable,
    this.window,
  });

  final int sequence;
  final String screen;
  final TerminalInfo info;

  /// This attachment holds input and size control.
  final bool writable;
  final TerminalInputWindow? window;
}

/// Program output after the snapshot; sequences are consecutive.
final class TerminalOutput extends TerminalFrame {
  const TerminalOutput({required this.sequence, required this.data});

  final int sequence;
  final String data;
}

/// New metadata (size, title, exit) or a change of input control.
final class TerminalStatus extends TerminalFrame {
  const TerminalStatus({required this.info, required this.writable});

  final TerminalInfo info;
  final bool writable;
}

/// The Host accepted (or refused) input command [sequence].
final class TerminalAck extends TerminalFrame {
  const TerminalAck({required this.sequence, this.refusal});

  final int sequence;

  /// `read-only` (another attachment took control) or `not-running`.
  final String? refusal;
}

/// An attachment that cannot go on; the process itself is untouched and a
/// new attachment recovers the screen.
class TerminalStreamException implements Exception {
  const TerminalStreamException(this.issue, this.message);

  /// `invalidOutput` (frames out of order) or `inputFull` (input could not
  /// be buffered), the official client's issue keys.
  final String issue;
  final String message;

  @override
  String toString() => 'TerminalStreamException($issue): $message';
}

/// A fresh terminal identity (the Host accepts `[\w-]{1,128}`). Keep it
/// before calling [TerminalApi.createTerminal]: creating again with the same
/// id is idempotent, a closed id can never be created again.
String newTerminalId() => uuidV4();

// -----------------------------------------------------------------------------
// Attachment
// -----------------------------------------------------------------------------

class _Command {
  _Command(this.value, this.frameBytes);

  final Map<String, Object?> value;
  final int frameBytes;
  int get sequence => value['sequence']! as int;
}

/// One physical `terminal/attach` stream: validates the frame order, numbers
/// and paces input within the Host's budgets, and detaches without touching
/// the process.
///
/// [frames] emits every frame (acks included) and fails with a
/// [TerminalStreamException], the carrier's [DshCarrierLostException] or a
/// `terminal/unavailable` [DshRemoteException]; it closes when the Host ends
/// the stream (the terminal was closed). Reconnect with a new attachment.
class TerminalAttachment {
  /// Over any duplex item stream: [items] downlink, [send] uplink, [cancel]
  /// detaches. [TerminalApi.attachTerminal] wires it to the mux.
  TerminalAttachment.over({
    required Stream<Object?> items,
    required void Function(Object? value) send,
    required Future<void> Function() cancel,
    TerminalEnvironment environment = TerminalEnvironment.defaults,
  }) : _send = send,
       _cancel = cancel,
       _environment = environment {
    _frames = StreamController<TerminalFrame>(onCancel: close);
    _sub = items.listen(_onItem, onError: (Object error, StackTrace stack) => _fail(error, stack), onDone: _onDone);
  }

  /// Largest single `write`: big pastes go out as several commands so one
  /// frame never approaches the carrier window.
  static const chunkBytes = 8192;

  final void Function(Object? value) _send;
  final Future<void> Function() _cancel;
  final TerminalEnvironment _environment;
  late final StreamController<TerminalFrame> _frames;
  late final StreamSubscription<Object?> _sub;

  final Queue<_Command> _queued = Queue();
  final Map<int, _Command> _pending = {};
  int _sequence = 0;
  int _acknowledged = 0;
  int _bufferedBytes = 0;
  int _inFlightBytes = 0;
  int? _outputSequence;
  TerminalInputWindow? _window;
  TerminalInfo? _info;
  bool _writable = false;
  bool _closed = false;
  (int, int)? _requestedSize;

  Stream<TerminalFrame> get frames => _frames.stream;

  /// Latest metadata (null before the snapshot).
  TerminalInfo? get info => _info;

  /// This attachment holds input: the snapshot or a later state said so, the
  /// process runs and no command was refused since.
  bool get writable => _writable && !_closed;

  bool get isClosed => _closed;

  /// Sends [data] to the shell as typed (control characters included).
  /// False when this attachment cannot write; a buffer overflow fails
  /// [frames] with `inputFull`.
  bool write(String data) {
    if (!writable || data.isEmpty) return false;
    final limit = _environment.maxInputBytes < chunkBytes ? _environment.maxInputBytes : chunkBytes;
    if (limit < 4) {
      final maxRune = limit == 1 ? 0x7f : (limit == 2 ? 0x7ff : 0xffff);
      // Reject the whole write before enqueueing any prefix: a code point
      // larger than the Host's budget cannot be split into valid text frames.
      if (data.runes.any((rune) => rune > maxRune)) {
        _fail(const TerminalStreamException('inputFull', 'terminal input buffer is full'));
        return false;
      }
    }
    for (final chunk in _chunks(data, limit)) {
      if (!_enqueue({'type': 'write', 'sequence': _sequence + 1, 'data': chunk})) return false;
    }
    _flush();
    return true;
  }

  /// Asks the PTY for [cols] × [rows] (clamped to the Host limits). False
  /// when not writable or the size is already current.
  bool resize(int cols, int rows) {
    if (!writable) return false;
    final c = cols.clamp(2, _environment.maxCols);
    final r = rows.clamp(1, _environment.maxRows);
    final current = _requestedSize ?? (_info == null ? null : (_info!.cols, _info!.rows));
    if (current == (c, r)) return false;
    if (!_enqueue({'type': 'resize', 'sequence': _sequence + 1, 'cols': c, 'rows': r})) return false;
    _requestedSize = (c, r);
    _flush();
    return true;
  }

  /// Detaches; the terminal keeps running. Idempotent.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _queued.clear();
    _pending.clear();
    await _sub.cancel();
    if (!_frames.isClosed) unawaited(_frames.close());
    await _cancel();
  }

  // ---------------------------------------------------------------------------

  bool _enqueue(Map<String, Object?> command) {
    final frameBytes = utf8.encode(jsonEncode(command)).length + (_window?.frameOverheadBytes ?? 0);
    final window = _window;
    if (_bufferedBytes + frameBytes > _environment.maxBufferedBytes ||
        (window != null && frameBytes > window.maxBytes)) {
      _fail(const TerminalStreamException('inputFull', 'terminal input buffer is full'));
      return false;
    }
    _sequence = command['sequence']! as int;
    _bufferedBytes += frameBytes;
    _queued.add(_Command(command, frameBytes));
    return true;
  }

  void _flush() {
    while (writable && _queued.isNotEmpty) {
      final next = _queued.first;
      final window = _window;
      if (window != null && _inFlightBytes + next.frameBytes > window.maxBytes) return;
      _queued.removeFirst();
      try {
        _send(next.value);
      } on Object catch (error, stack) {
        _fail(error, stack);
        return;
      }
      _pending[next.sequence] = next;
      _inFlightBytes += next.frameBytes;
    }
  }

  void _onItem(Object? item) {
    if (_closed) return;
    final frame = TerminalFrame.fromJson(item);
    if (frame == null) return;
    if (_outputSequence == null) {
      if (frame is! TerminalSnapshot) {
        _protocol('the attachment did not start with a screen snapshot');
        return;
      }
      _outputSequence = frame.sequence;
      _window = frame.window;
      _info = frame.info;
      _writable = frame.writable && frame.info.running;
      _frames.add(frame);
      _flush();
      return;
    }
    switch (frame) {
      case TerminalSnapshot():
        _protocol('unexpected second screen snapshot');
        return;
      case TerminalOutput(:final sequence):
        if (sequence != _outputSequence! + 1) {
          _protocol('terminal output sequence has a gap');
          return;
        }
        _outputSequence = sequence;
      case TerminalStatus(:final info, :final writable):
        _info = info;
        _requestedSize = null;
        _writable = writable && info.running;
      case TerminalAck(:final sequence, :final refusal):
        final pending = _pending.remove(sequence);
        if (sequence != _acknowledged + 1 || pending == null) {
          _protocol('terminal input acknowledgement is out of order');
          return;
        }
        _acknowledged = sequence;
        _bufferedBytes -= pending.frameBytes;
        _inFlightBytes -= pending.frameBytes;
        if (refusal != null) _writable = false;
    }
    _frames.add(frame);
    _flush();
  }

  void _protocol(String message) => _fail(TerminalStreamException('invalidOutput', message));

  void _fail(Object error, [StackTrace? stack]) {
    if (_closed) return;
    if (!_frames.isClosed) _frames.addError(error, stack);
    unawaited(close());
  }

  void _onDone() {
    if (_closed) return;
    _closed = true;
    _writable = false;
    if (!_frames.isClosed) unawaited(_frames.close());
  }

  /// Splits [data] into pieces of at most [limit] UTF-8 bytes, never inside a
  /// code point.
  static Iterable<String> _chunks(String data, int limit) sync* {
    if (data.length * 3 <= limit) {
      yield data;
      return;
    }
    final buffer = StringBuffer();
    var bytes = 0;
    for (final rune in data.runes) {
      final size = rune < 0x80
          ? 1
          : rune < 0x800
          ? 2
          : rune < 0x10000
          ? 3
          : 4;
      if (bytes + size > limit && bytes > 0) {
        yield buffer.toString();
        buffer.clear();
        bytes = 0;
      }
      buffer.writeCharCode(rune);
      bytes += size;
    }
    if (bytes > 0) yield buffer.toString();
  }
}

// -----------------------------------------------------------------------------
// Remote calls
// -----------------------------------------------------------------------------

extension TerminalApi on DshClient {
  /// Whether this connection can run terminals: a duplex `terminal/attach`,
  /// or on a carrier without uplink (ds-harness-remote) `terminal/follow`
  /// plus unary `terminal/write` / `terminal/resize`. A Remote Host whose
  /// owner turned the terminal off answers `TERMINAL_DISABLED`.
  bool get supportsTerminals => carrier.supportsUplink ? carrier.allowsEndpoint('terminal/attach') : _followTerminals;

  /// A Remote Host that announced its features without `harness.terminal.v1`:
  /// its owner turned the terminal off in the Host's local Remote settings
  /// (or the plugin predates it). Calls answer `TERMINAL_DISABLED` until the
  /// owner turns it on, which takes effect without reconnecting.
  bool get terminalsOffOnHost =>
      !carrier.supportsUplink &&
      _followTerminals &&
      !(carrier.peerCapabilities?.contains('harness.terminal.v1') ?? true);

  bool get _followTerminals =>
      carrier.allowsEndpoint('terminal/follow') &&
      carrier.allowsEndpoint('terminal/write') &&
      carrier.allowsEndpoint('terminal/resize');

  /// `terminal/environment`: the conversation's directory and the limits.
  Future<TerminalEnvironment> terminalEnvironment(String sessionId) async =>
      TerminalEnvironment.fromJson(await rpc.call('terminal/environment', {'agentId': sessionId}));

  /// `terminal/shells`: installed shells, the environment's default first.
  Future<List<TerminalShell>> terminalShells(String sessionId) async => [
    for (final shell in asListOrEmpty(await rpc.call('terminal/shells', {'agentId': sessionId})))
      ?TerminalShell.fromJson(shell),
  ];

  /// `terminal/list`: terminals the Host keeps for this conversation, exited
  /// ones included (they count toward the limit until closed).
  Future<List<TerminalInfo>> listTerminals(String sessionId) async => [
    for (final info in asListOrEmpty(await rpc.call('terminal/list', {'sessionId': sessionId})))
      ?TerminalInfo.fromJson(info),
  ];

  /// `terminal/create`: starts [shellPath] (a path from [terminalShells];
  /// null picks the default) in the conversation's directory. Idempotent for
  /// an open [id]. Fails with `terminal/limit-reached` (details `limit`) or
  /// `terminal/unavailable` for a closed id.
  Future<TerminalInfo> createTerminal(
    String sessionId, {
    required String id,
    required int cols,
    required int rows,
    String? shellPath,
  }) async {
    final value = await rpc.call('terminal/create', {
      'agentId': sessionId,
      'request': {'id': id, 'cols': cols, 'rows': rows, 'shellPath': ?shellPath},
    });
    return TerminalInfo.fromJson(value) ??
        TerminalInfo(
          id: id,
          title: '',
          shell: TerminalShell(path: shellPath ?? '', name: ''),
          cols: cols,
          rows: rows,
        );
  }

  /// `terminal/rename`: 1–120 characters, trimmed by the Host.
  Future<void> renameTerminal(String sessionId, String id, String title) =>
      rpc.call('terminal/rename', {'agentId': sessionId, 'id': id, 'title': title});

  /// `terminal/close`: ends the process tree and frees the slot; repeating it
  /// succeeds. The id can never be created again.
  Future<void> closeTerminal(String sessionId, String id) =>
      rpc.call('terminal/close', {'agentId': sessionId, 'id': id});

  /// `terminal/retain`: holds [id] for as long as the subscription lasts
  /// (one event per acknowledged hold). Fails with `terminal/unavailable`
  /// when it is gone; ends when it closes.
  Stream<void> retainTerminal(String sessionId, String id) {
    late final StreamController<void> out;
    MuxStream? stream;
    StreamSubscription<Object?>? sub;
    out = StreamController<void>(
      onListen: () {
        try {
          stream = mux.open('terminal/retain', {'sessionId': sessionId, 'id': id});
        } on Object catch (error, stack) {
          out.addError(error, stack);
          unawaited(out.close());
          return;
        }
        sub = stream!.items.listen(
          (item) {
            if (asMap(item)?['type'] == 'retained') out.add(null);
          },
          onError: out.addError,
          onDone: out.close,
        );
      },
      onCancel: () async {
        await sub?.cancel();
        await stream?.cancel();
      },
    );
    return out.stream;
  }

  /// `terminal/attach`: one attachment that takes input control from older
  /// ones. Pass the [environment] for its input limits.
  TerminalAttachment attachTerminal(
    String sessionId,
    String id, {
    TerminalEnvironment environment = TerminalEnvironment.defaults,
  }) {
    if (!carrier.supportsUplink) {
      final link = _FollowLink(this, sessionId, id, maxInputBytes: environment.maxInputBytes);
      return TerminalAttachment.over(items: link.items, send: link.send, cancel: link.cancel, environment: environment);
    }
    final MuxStream stream;
    try {
      stream = mux.open('terminal/attach', {'agentId': sessionId, 'id': id});
    } on Object catch (error) {
      return TerminalAttachment.over(
        items: Stream.error(error),
        send: (_) {},
        cancel: () async {},
        environment: environment,
      );
    }
    return TerminalAttachment.over(
      items: stream.items,
      send: stream.send,
      cancel: stream.cancel,
      environment: environment,
    );
  }
}

// -----------------------------------------------------------------------------
// Follow route (carriers without uplink items)
// -----------------------------------------------------------------------------

/// One attachment over ds-harness-remote: a `terminal/follow` stream bound to
/// a fresh [attachmentId], with input sent as unary calls that carry it. The
/// Host plugin turns both into the official attach. Mirrors the plugin's own
/// Desktop client (`openRemoteTerminal`):
/// * `snapshot` / `state` frames are writable when `info.controllerId` is
///   this attachment (the Host stamps it on the attachment holding input);
/// * commands go out one call at a time, in order, and each is acknowledged
///   here once its call succeeded; a command while read-only is refused
///   locally without a call;
/// * a failed call fails the attachment: input is never replayed.
///
/// Consecutive writes queued behind a call go out as one `terminal/write`
/// (then acknowledged together, in order), so typing over a slow relay does
/// not wait one round trip per key.
class _FollowLink {
  _FollowLink(this._client, this._sessionId, this._id, {required this.maxInputBytes}) : attachmentId = uuidV4() {
    _items = StreamController<Object?>(onListen: _open, onCancel: cancel);
  }

  /// Largest coalesced `terminal/write` (the Host accepts 64 Ki UTF-16 units).
  static const maxWriteChars = 32 * 1024;

  /// The Host's per-write UTF-8 budget ([TerminalEnvironment.maxInputBytes]):
  /// a coalesced write stays within it as each command already does.
  final int maxInputBytes;

  final DshClient _client;
  final String _sessionId;
  final String _id;
  final String attachmentId;
  late final StreamController<Object?> _items;
  final Queue<Map<String, Object?>> _queue = Queue();
  MuxStream? _stream;
  StreamSubscription<Object?>? _sub;
  bool _writable = false;
  bool _sending = false;
  bool _closed = false;

  Stream<Object?> get items => _items.stream;

  Map<String, Object?> get _target => {'agentId': _sessionId, 'id': _id, 'attachmentId': attachmentId};

  void _open() {
    final MuxStream stream;
    try {
      stream = _stream = _client.mux.open('terminal/follow', _target);
    } on Object catch (error, stack) {
      _fail(error, stack);
      return;
    }
    _sub = stream.items.listen(_onItem, onError: _fail, onDone: () => unawaited(cancel()));
  }

  void _onItem(Object? item) {
    if (_closed) return;
    final map = asMap(item);
    if (map == null) return;
    final info = asMap(map['info']);
    switch (map['type']) {
      case 'snapshot' || 'state' when info != null:
        _writable = info['controllerId'] == attachmentId;
        _items.add({...map, 'writable': _writable});
      case 'ack':
        // The Host settles the official acks itself; ours come from [_drain].
        return;
      default:
        _items.add(map);
    }
  }

  void send(Object? value) {
    final command = asMap(value);
    if (_closed || command == null) return;
    _queue.add(command);
    if (_sending) return;
    _sending = true;
    unawaited(_drain());
  }

  Future<void> _drain() async {
    try {
      while (!_closed && _queue.isNotEmpty) {
        final first = _queue.removeFirst();
        final sequences = [asInt(first['sequence']) ?? 0];
        if (!_writable) {
          _items.add({'type': 'ack', 'sequence': sequences.single, 'refusal': 'read-only'});
          continue;
        }
        switch (first['type']) {
          case 'write':
            final firstData = asString(first['data']) ?? '';
            final data = StringBuffer(firstData);
            var bytes = utf8.encode(firstData).length;
            while (_queue.isNotEmpty && _queue.first['type'] == 'write') {
              final more = asString(_queue.first['data']) ?? '';
              final moreBytes = utf8.encode(more).length;
              if (data.length + more.length > maxWriteChars || bytes + moreBytes > maxInputBytes) break;
              data.write(more);
              bytes += moreBytes;
              sequences.add(asInt(_queue.removeFirst()['sequence']) ?? 0);
            }
            await _client.rpc.call('terminal/write', {..._target, 'data': data.toString()});
          case 'resize':
            await _client.rpc.call('terminal/resize', {..._target, 'cols': first['cols'], 'rows': first['rows']});
          default:
            throw const TerminalStreamException('invalidOutput', 'unknown terminal input command');
        }
        if (_closed) return;
        for (final sequence in sequences) {
          _items.add({'type': 'ack', 'sequence': sequence});
        }
      }
    } on Object catch (error, stack) {
      _fail(error, stack);
    } finally {
      _sending = false;
    }
  }

  void _fail(Object error, [StackTrace? stack]) {
    if (_closed) return;
    _items.addError(error, stack);
    unawaited(cancel());
  }

  /// Detaches; the terminal keeps running. Idempotent.
  Future<void> cancel() async {
    if (_closed) return;
    _closed = true;
    _queue.clear();
    final sub = _sub;
    final stream = _stream;
    _sub = null;
    _stream = null;
    if (!_items.isClosed) unawaited(_items.close());
    await sub?.cancel();
    await stream?.cancel();
  }
}
