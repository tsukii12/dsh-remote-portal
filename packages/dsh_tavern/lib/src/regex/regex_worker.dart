import 'dart:async';
import 'dart:isolate';

import 'regex_program.dart';
import 'regex_types.dart';

export 'regex_program.dart' show isNativeRegexLiteral;
export 'regex_types.dart';

/// Injectable transport for deterministic lifecycle tests. Production uses a
/// top-level entry point and plain command data, never an application closure.
typedef RegexWorkerSpawner =
    Future<Isolate> Function(void Function(SendPort) entryPoint, SendPort replies, SendPort errors, SendPort exits);

final class RegexCapture {
  const RegexCapture({
    required this.start,
    required this.end,
    required this.groupCount,
    required this.hasNamedGroups,
    required this.groups,
  });
  final int start;
  final int end;
  final int groupCount;
  final bool hasNamedGroups;
  final Map<String, String?> groups;
}

final class RegexCaptureResult {
  const RegexCaptureResult({required this.compilation, this.matches = const [], this.code, this.message});
  final RegexCompileResult compilation;
  final List<RegexCapture> matches;
  final String? code;
  final String? message;
  bool get skipped => code != null && code != 'literal-fallback';
}

/// One long-lived worker, with sequential bounded requests and fresh epochs
/// after termination. A deadline stops the owner's wait and requests immediate
/// kill; no replacement worker starts until the old worker's exit is observed.
final class RegexWorker implements RegexExecutor {
  RegexWorker({this.limits = const RegexLimits(), RegexWorkerSpawner? spawner}) : _spawner = spawner ?? _spawnWorker {
    if (limits.maxRules < 0 ||
        limits.maxInputBytes < 0 ||
        limits.maxOutputBytes < 0 ||
        limits.maxReplacements < 0 ||
        limits.maxCaptureBytes < 0 ||
        limits.maxPending < 1 ||
        limits.timeout <= Duration.zero) {
      throw ArgumentError('Regex limits must be nonnegative with a positive timeout and queue capacity.');
    }
  }

  @override
  final RegexLimits limits;
  final RegexWorkerSpawner _spawner;
  Future<void> _queue = Future.value();
  _WorkerSession? _session;
  var _epoch = 0;
  var _nextId = 0;
  var _pending = 0;
  var _closed = false;
  Future<void>? _closeFuture;

  @override
  Future<RegexCompileResult> compile(
    String pattern, {
    RegexDialect dialect = RegexDialect.script,
    bool caseSensitive = true,
  }) async {
    final reply = await _checkedRequest(pattern, {
      'operation': 'compile',
      'pattern': pattern,
      'dialect': dialect.name,
      'caseSensitive': caseSensitive,
    });
    return _compilation(reply);
  }

  @override
  Future<RegexMatchResult> hasMatch(
    String pattern,
    String text, {
    RegexDialect dialect = RegexDialect.script,
    bool caseSensitive = true,
  }) async {
    final reply = regexUtf8Length(text, stopAfter: limits.maxInputBytes) > limits.maxInputBytes
        ? _skipped('input-limit', '关键词扫描输入超过保护上限。')
        : await _checkedRequest(pattern, {
            'operation': 'match',
            'pattern': pattern,
            'text': text,
            'dialect': dialect.name,
            'caseSensitive': caseSensitive,
          });
    return RegexMatchResult(
      status: switch (reply['matched']) {
        true => RegexMatchStatus.matched,
        false => RegexMatchStatus.notMatched,
        _ => RegexMatchStatus.skipped,
      },
      compilation: _compilation(reply),
      code: reply['code'] as String?,
      message: reply['message'] as String?,
    );
  }

  /// Finds only the referenced groups. The caller expands trim/replacement
  /// macros afterwards, in the original order. Intermediate display input may
  /// reach maxOutputBytes; the pipeline checks its external input separately.
  Future<RegexCaptureResult> findCaptures(
    String pattern,
    String text, {
    required Iterable<String> references,
    required int maxMatches,
  }) async {
    final copiedReferences = <String>[];
    var referenceBytes = 0;
    for (final reference in references) {
      referenceBytes += regexUtf8Length(reference, stopAfter: limits.maxCaptureBytes) + 16;
      if (referenceBytes > limits.maxCaptureBytes) {
        break;
      }
      copiedReferences.add(reference);
    }
    final Map<String, Object?> reply;
    if (regexUtf8Length(text, stopAfter: limits.maxOutputBytes) > limits.maxOutputBytes) {
      reply = _skipped('input-limit', '显示中间文本超过保护上限。');
    } else if (referenceBytes > limits.maxCaptureBytes) {
      reply = _skipped('capture-limit', '捕获引用描述超过内部传输上限。');
    } else {
      reply = await _checkedRequest(pattern, {
        'operation': 'captures',
        'pattern': pattern,
        'text': text,
        'dialect': RegexDialect.script.name,
        'caseSensitive': true,
        'references': copiedReferences,
        'maxMatches': maxMatches < 0
            ? 0
            : maxMatches > limits.maxReplacements
            ? limits.maxReplacements
            : maxMatches,
        'maxCaptureBytes': limits.maxCaptureBytes,
      });
    }
    final rows = reply['captures'] as List<Object?>? ?? const [];
    return RegexCaptureResult(
      compilation: _compilation(reply),
      matches: List.unmodifiable(
        rows.map((row) {
          final value = row! as Map<String, Object?>;
          return RegexCapture(
            start: value['start']! as int,
            end: value['end']! as int,
            groupCount: value['groupCount']! as int,
            hasNamedGroups: value['hasNamedGroups']! as bool,
            groups: Map<String, String?>.unmodifiable((value['groups']! as Map).cast<String, String?>()),
          );
        }),
      ),
      code: reply['code'] as String?,
      message: reply['message'] as String?,
    );
  }

  Future<Map<String, Object?>> _checkedRequest(String pattern, Map<String, Object?> command) {
    if (regexUtf8Length(pattern, stopAfter: limits.maxInputBytes) > limits.maxInputBytes) {
      return Future.value(_skipped('pattern-limit', '正则模式超过保护上限。'));
    }
    return _request(command);
  }

  Future<Map<String, Object?>> _request(Map<String, Object?> command) {
    if (_closed) {
      return Future.value(_skipped('worker-closed', '正则服务已关闭。'));
    }
    if (_pending >= limits.maxPending) {
      return Future.value(_skipped('worker-busy', '正则等待队列已满，本次规则跳过。'));
    }
    _pending++;
    final result = _queue.then((_) async {
      _pending--;
      if (_closed) {
        return _skipped('worker-closed', '正则服务已关闭。');
      }
      final session = await _readySession();
      if (_closed) {
        return _skipped('worker-closed', '正则服务已关闭。');
      }
      final port = session.commands;
      if (session.retiring || port == null) {
        return _skipped(session.failure ?? 'worker-unavailable', '正则 worker 尚未恢复，本次规则跳过。');
      }
      final job = _WorkerJob(++_nextId);
      session.active = job;
      job.timer = Timer(limits.timeout, () {
        if (identical(session.active, job)) {
          _retire(session, 'timeout', '规则执行超过时限，已请求终止 worker。');
        }
      });
      try {
        port.send({...command, 'epoch': session.epoch, 'id': job.id});
      } catch (_) {
        _retire(session, 'worker-transport', '无法发送正则工作请求。');
      }
      return job.result.future;
    });
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<_WorkerSession> _readySession() async {
    final existing = _session;
    if (existing != null) {
      if (existing.retiring) {
        // All queued calls share one bounded exit wait, rather than each
        // adding another timeout or spawning a replacement prematurely.
        await existing.retireWait;
        if (existing.exited.isCompleted && !_closed) {
          return _readySession();
        }
        return existing;
      }
      if (!existing.retiring && existing.commands == null) {
        await _waitReady(existing);
      }
      return existing;
    }
    final session = _WorkerSession(++_epoch);
    _session = session;
    session.responses.listen((message) => _receive(session, message));
    session.errors.listen((_) => _retire(session, 'worker-error', '正则 worker 发生错误，本次规则跳过。'));
    session.exits.listen((_) => _exited(session));
    unawaited(
      Future<Isolate>.sync(
        () => _spawner(_workerMain, session.responses.sendPort, session.errors.sendPort, session.exits.sendPort),
      ).then<void>(
        (isolate) {
          session.isolate = isolate;
          if (_closed || session.retiring) {
            isolate.kill(priority: Isolate.immediate);
          }
        },
        onError: (Object _, StackTrace _) {
          _retire(session, 'worker-start-failed', '无法启动正则 worker。');
          // A failed spawn has no live isolate whose exit must be awaited.
          _exited(session);
        },
      ),
    );
    await _waitReady(session);
    return session;
  }

  Future<void> _waitReady(_WorkerSession session) async {
    await session.ready.future.timeout(
      limits.timeout,
      onTimeout: () {
        _retire(session, 'worker-start-timeout', '正则 worker 启动超过时限。');
        return null;
      },
    );
  }

  void _receive(_WorkerSession session, Object? message) {
    if (session.retiring || _closed) {
      return;
    }
    if (message is SendPort) {
      session.commands = message;
      if (!session.ready.isCompleted) {
        session.ready.complete(message);
      }
      return;
    }
    final active = session.active;
    if (message is! Map<String, Object?> ||
        active == null ||
        message['epoch'] != session.epoch ||
        message['id'] != active.id) {
      return;
    }
    active.timer?.cancel();
    session.active = null;
    active.result.complete(message);
  }

  void _retire(_WorkerSession session, String code, String message) {
    if (session.retiring) {
      return;
    }
    session.retiring = true;
    session.failure = code;
    session.retireWait = session.exited.future.timeout(limits.timeout, onTimeout: () {});
    if (!session.ready.isCompleted) {
      session.ready.complete(null);
    }
    final active = session.active;
    session.active = null;
    active?.timer?.cancel();
    if (active != null && !active.result.isCompleted) {
      active.result.complete(_skipped(code, message));
    }
    session.isolate?.kill(priority: Isolate.immediate);
  }

  void _exited(_WorkerSession session) {
    if (session.exited.isCompleted) {
      return;
    }
    _retire(session, 'worker-exited', '正则 worker 已退出，本次规则跳过。');
    session.exited.complete();
    session.responses.close();
    session.errors.close();
    session.exits.close();
    if (identical(_session, session)) {
      _session = null;
    }
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closed = true;
    final session = _session;
    if (session != null) {
      _retire(session, 'worker-closed', '正则服务已关闭。');
    }
    await _queue;
    // A stuck VM must not make the owner's close future wait forever. The
    // exit listener stays alive for eventual cleanup; closed never respawns.
    await session?.retireWait;
  }
}

final class _WorkerSession {
  _WorkerSession(this.epoch);
  final int epoch;
  final responses = ReceivePort();
  final errors = ReceivePort();
  final exits = ReceivePort();
  final ready = Completer<SendPort?>();
  final exited = Completer<void>();
  Isolate? isolate;
  SendPort? commands;
  _WorkerJob? active;
  bool retiring = false;
  String? failure;
  Future<void>? retireWait;
}

final class _WorkerJob {
  _WorkerJob(this.id);
  final int id;
  final result = Completer<Map<String, Object?>>();
  Timer? timer;
}

Future<Isolate> _spawnWorker(void Function(SendPort) entryPoint, SendPort replies, SendPort errors, SendPort exits) =>
    Isolate.spawn(
      entryPoint,
      replies,
      onError: errors,
      onExit: exits,
      errorsAreFatal: true,
      debugName: 'dsh-tavern-regex',
    );

Map<String, Object?> _skipped(String code, String message) => {
  'status': RegexCompileStatus.skipped.name,
  'code': code,
  'message': message,
};

RegexCompileResult _compilation(Map<String, Object?> reply) => RegexCompileResult(
  status: RegexCompileStatus.values.byName(reply['status']! as String),
  code: reply['code'] as String?,
  message: reply['message'] as String?,
);

void _workerMain(SendPort replies) {
  final commands = ReceivePort();
  final cache = <(String, String, bool), RegexProgram>{};
  replies.send(commands.sendPort);
  commands.listen((Object? message) {
    if (message is! Map<String, Object?>) {
      return;
    }
    Map<String, Object?> reply;
    try {
      final dialectName = message['dialect']! as String;
      final pattern = message['pattern']! as String;
      final sensitive = message['caseSensitive']! as bool;
      final key = (dialectName, pattern, sensitive);
      var program = cache.remove(key);
      program ??= compileRegexProgram(pattern, RegexDialect.values.byName(dialectName), caseSensitive: sensitive);
      if (cache.length >= 1000) {
        cache.remove(cache.keys.first);
      }
      cache[key] = program;
      final diagnostic = program.compilation;
      reply = {
        'status': diagnostic.status.name,
        if (diagnostic.code != null) 'code': diagnostic.code,
        if (diagnostic.message != null) 'message': diagnostic.message,
      };
      final operation = message['operation'];
      final regex = program.regex;
      if (regex != null && operation == 'match') {
        final text = message['text']! as String;
        reply['matched'] = program.sticky ? regex.matchAsPrefix(text) != null : regex.hasMatch(text);
      } else if (regex != null && operation == 'captures') {
        reply = _captureReply(program, message, reply);
      }
    } on FormatException {
      reply = {
        'status': RegexCompileStatus.incompatible.name,
        'code': 'incompatible-pattern',
        'message': '当前运行时无法执行此正则，保留原文并跳过。',
      };
    } on ArgumentError {
      reply = {
        'status': RegexCompileStatus.incompatible.name,
        'code': 'incompatible-pattern',
        'message': '当前运行时无法执行此正则，保留原文并跳过。',
      };
    } catch (_) {
      reply = _skipped('worker-error', '正则工作失败，本次规则跳过。');
    }
    replies.send({...reply, 'epoch': message['epoch'], 'id': message['id']});
  });
}

Map<String, Object?> _captureReply(
  RegexProgram program,
  Map<String, Object?> command,
  Map<String, Object?> diagnostic,
) {
  final text = command['text']! as String;
  final references = (command['references']! as List).cast<String>();
  final maxMatches = command['maxMatches']! as int;
  final maxBytes = command['maxCaptureBytes']! as int;
  final output = <Map<String, Object?>>[];
  // Descriptor overhead is included, so zero-length captures cannot create an
  // unbounded object graph despite contributing no text bytes.
  var bytes = 32;
  final matches = program.global ? program.regex!.allMatches(text) : program.regex!.allMatches(text).take(1);
  for (final match in matches) {
    if (output.length >= maxMatches) {
      return {...diagnostic, 'code': 'replacement-limit', 'message': '本次显示累计替换次数将超过保护上限。'};
    }
    bytes += 64;
    final groups = <String, String?>{};
    for (final reference in references) {
      final number = int.tryParse(reference);
      String? value;
      if (number != null) {
        if (number >= 0 && number <= match.groupCount) {
          value = match[number];
        }
      } else if (reference.startsWith('n:')) {
        final name = reference.substring(2);
        if (match.groupNames.contains(name)) {
          value = match.namedGroup(name);
        }
      }
      bytes += regexUtf8Length(reference) + 16;
      if (value != null) {
        bytes += regexUtf8Length(value, stopAfter: maxBytes);
      }
      if (bytes > maxBytes) {
        return {...diagnostic, 'code': 'capture-limit', 'message': '捕获数据超过内部传输上限。'};
      }
      groups[reference] = value;
    }
    if (bytes > maxBytes) {
      return {...diagnostic, 'code': 'capture-limit', 'message': '匹配描述超过内部传输上限。'};
    }
    output.add({
      'start': match.start,
      'end': match.end,
      'groupCount': match.groupCount,
      'hasNamedGroups': match.groupNames.isNotEmpty,
      'groups': groups,
    });
  }
  return {...diagnostic, 'captures': output};
}
