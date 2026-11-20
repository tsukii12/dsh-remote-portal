/// Exercises a running `dsh web` through the public `dsh_client` API.
///
/// It starts nothing itself. Examples:
/// ```sh
/// dart run bin/probe.dart --url 'http://127.0.0.1:3080/?token=...' --list-only
/// dart run bin/probe.dart --launch-log /tmp/dsh-web.log --cwd /tmp/ws \
///     --prompt 'Reply with OK' --record /tmp/frames.jsonl
/// dart run bin/probe.dart --base http://127.0.0.1:3080 --token ... \
///     --session <id> --prompt 'run echo hi' --approve allow --reconnect-test
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';

const _usage = '''
dsh_probe — talk to a running `dsh web` (DSH 0.2.0-rc.2 / 0.2.1-rc.2 API)

Connection (one of):
  --url <url>             launch URL printed by dsh web (with ?token=)
  --launch-log <file>     file containing the "dsh web: <url>" line
  --base <url> --token <t>
  --host-header <h:p>     override the Host header (tunnels)

Session:
  --session <id>          use an existing session
  --cwd <dir>             create a session with this cwd (default: Host cwd)
  --workspace-path <dir>  create/reuse a workspace and a session in it
  --model <prov/model[:effort]>

Actions:
  --list-only             list sessions, models and key status, then exit
  --prompt <text>         send a prompt and stream events until the turn ends
  --approve <allow|reject|pass>   answer approval requests (default: reject)
  --cancel-after <n>      cancel the turn after n streamed text/reasoning deltas
  --reconnect-test        drop the WebSocket mid-turn (on first approval or
                          first delta) and verify the watcher resyncs
  --record <file>         write every RPC/mux frame as JSON lines
  --timeout <seconds>     overall turn timeout (default 180)
  --quiet-deltas          do not print every delta
''';

Future<void> main(List<String> argv) async {
  final args = _Args.parse(argv);
  if (args.flag('help') || argv.isEmpty) {
    stdout.write(_usage);
    return;
  }
  IOSink? record;
  final recordPath = args.value('record');
  if (recordPath != null) record = File(recordPath).openWrite();
  void tracer(DshTraceEntry entry) => record?.writeln(jsonEncode(entry.toJson()));

  var launch = args.value('url');
  final launchLog = args.value('launch-log');
  if (launch == null && launchLog != null) {
    launch = File(launchLog).readAsLinesSync().firstWhere(
      (l) => l.startsWith('dsh web:'),
      orElse: () => throw StateError('no "dsh web:" line in $launchLog'),
    );
  }
  final base = args.value('base');
  final started = DateTime.now();
  String ts() => '+${DateTime.now().difference(started).inMilliseconds.toString().padLeft(6)}ms';
  void log(String line) => stdout.writeln('${ts()} $line');

  final DshClient client;
  try {
    client = await DshClient.connect(
      launchUrl: launch,
      baseUri: base == null ? null : Uri.parse(base),
      token: args.value('token'),
      hostHeader: args.value('host-header'),
      tracer: recordPath == null ? null : tracer,
    );
  } on DshException catch (error) {
    stderr.writeln('connect failed: $error');
    exitCode = 2;
    await record?.close();
    return;
  }
  final generation = client.mux.generation!;
  log(
    'connected: authority=${client.connection.authority} '
    'cookie=${client.connection.cookie?.name.substring(0, 12)}… expires=${client.connection.cookie?.expiresAt} '
    'clientId=${generation.clientId} home=${generation.home}',
  );
  log('health: ${(await client.connection.checkHealth()).name}');

  try {
    final sessions = await client.listSessions();
    log('sessions: ${sessions.length}');
    for (final s in sessions.take(5)) {
      log('  ${s.sessionId} title=${jsonEncode(s.title)} running=${s.running} blank=${s.blank} cwd=${s.cwd}');
    }
    final catalog = await client.listModels();
    log('models: default=${catalog.defaultSelection} routable=${catalog.routableProviders}');
    for (final m in catalog.models) {
      log(
        '  ${m.provider}/${m.id} "${m.name}" efforts=${m.efforts.map((e) => e.id).join(',')} default=${m.defaultEffort}',
      );
    }
    final keys = await client.describeCredentials(['DEEPSEEK_API_KEY']);
    final key = keys['DEEPSEEK_API_KEY'];
    log('DEEPSEEK_API_KEY: configured=${key?.configured} source=${key?.source} writable=${key?.writable}');
    if (args.flag('list-only')) return;

    var sessionId = args.value('session');
    if (sessionId == null) {
      final workspacePath = args.value('workspace-path');
      if (workspacePath != null) {
        final ws = await client.createWorkspace(workspacePath);
        log('workspace: ${ws.workspace.workspaceId} ${ws.workspace.path} created=${ws.created}');
        sessionId = (await client.createSession(workspaceId: ws.workspace.workspaceId)).sessionId;
      } else {
        sessionId = (await client.createSession(cwd: args.value('cwd'))).sessionId;
      }
      log('created session $sessionId');
    }
    final model = args.value('model');
    if (model != null) {
      final match = RegExp(r'^([^/]+)/([^:]+)(?::(.+))?$').firstMatch(model);
      if (match == null) throw ArgumentError('--model expects provider/model[:effort]');
      final selected = await client.setModel(
        sessionId,
        provider: match.group(1)!,
        model: match.group(2)!,
        reasoningEffort: match.group(3),
      );
      log('model selected: $selected');
    }
    await _watchAndPrompt(client, sessionId, args, log);
  } on DshException catch (error) {
    stderr.writeln('failed: $error');
    exitCode = 1;
  } finally {
    await client.close();
    await record?.flush();
    await record?.close();
  }
}

Future<void> _watchAndPrompt(DshClient client, String sessionId, _Args args, void Function(String) log) async {
  final transcript = ChatTranscript();
  final prompt = args.value('prompt');
  final approve = args.value('approve') ?? 'reject';
  final cancelAfter = int.tryParse(args.value('cancel-after') ?? '');
  final reconnectTest = args.flag('reconnect-test');
  final quietDeltas = args.flag('quiet-deltas');
  final timeout = Duration(seconds: int.tryParse(args.value('timeout') ?? '') ?? 180);

  final snapshotSeen = Completer<SessionSnapshotEvent>();
  final turnDone = Completer<TurnEndedEvent>();
  var promptSent = false;
  var promptCursor = 1 << 62;
  var deltas = 0;
  var cancelled = false;
  var reconnectDone = false;
  final approvalDeliveries = <String, int>{};
  final answered = <String>{};

  Future<void> forceReconnect(String why) async {
    reconnectDone = true;
    log('!! reconnect test: dropping the WebSocket ($why)');
    client.mux.reconnect();
  }

  final sub = client.watch(sessionId).listen((event) {
    transcript.apply(event);
    switch (event) {
      case SessionSnapshotEvent():
        log(
          'snapshot: cursor=${event.cursor} events=${event.events.length} hasMore=${event.hasMore} '
          'resync=${event.isResync} title=${jsonEncode(event.projections.title)} '
          'preset=${event.projections.permissionPreset} model=${event.projections.nextModel} '
          'activeAttempt=${event.activeAttempt == null ? 'none' : '${event.activeAttempt!.attemptId}@${event.activeAttempt!.nextIndex} (${event.activeAttempt!.chunks.length} chunks)'}',
        );
        if (!snapshotSeen.isCompleted) snapshotSeen.complete(event);
      case TurnStartedEvent(:final turn):
        log('[${event.seq}] turn/start turn=$turn');
      case TurnEndedEvent(:final turn, :final reason):
        log(
          '[${event.seq}] turn/end turn=$turn reason=${reason.kind}'
          '${reason.cancelCause == null ? '' : ' cause=${reason.cancelCause}'}'
          '${reason.error == null ? '' : ' error=${reason.error}'}',
        );
        if (promptSent && event.seq > promptCursor && !turnDone.isCompleted) {
          turnDone.complete(event);
        }
      case UserMessageEvent(:final message):
        log(
          '[${event.seq}] user/message source=${message.source.kind} requestId=${event.requestId} '
          'text=${jsonEncode(_clip(message.text, 80))}',
        );
      case AssistantMessageEvent(:final message, :final usage):
        log(
          '[${event.seq}] assistant/message text=${jsonEncode(_clip(message.text, 120))} '
          'reasoning=${message.reasoning.length}ch toolCalls=${message.toolCalls.map((c) => c.name).toList()} '
          'usage=in:${usage?.inputTokens}/out:${usage?.outputTokens} interrupted=${event.interrupted}',
        );
      case ToolCallEvent(:final name, :final callId, :final arguments):
        log('[${event.seq}] tool/call $name id=$callId args=${_clip(arguments, 160)}');
      case ToolResultEvent(:final message, :final failure):
        log(
          '[${event.seq}] tool/result id=${event.callId} isError=${event.isError} '
          'text=${jsonEncode(_clip(message.text, 160))}${failure == null ? '' : ' failure=${failure.code}'}',
        );
      case ApprovalAskedEvent(:final toolName, :final callId, :final reason):
        log('[${event.seq}] approval/asked tool=$toolName call=$callId reason=${jsonEncode(reason)}');
      case ApprovalDecidedEvent(:final outcome):
        log('[${event.seq}] approval/decided outcome=${outcome.name}');
      case TitleChangedEvent(:final title, :final sourceKind):
        log('[${event.seq}] session/title ${jsonEncode(title)} source=$sourceKind');
      case SessionLogEvent():
        log('[${event.seq}] ${event.type}');
      case AssistantStreamStarted(:final attemptId, :final turn, :final step):
        log('~ stream start $attemptId turn=$turn step=$step after=${event.startedAfterSeq} rev=${event.revision}');
      case AssistantChunkEvent(:final chunk, :final index):
        if (chunk is TextDeltaChunk || chunk is ReasoningDeltaChunk) {
          deltas++;
          if (reconnectTest && !reconnectDone && deltas == 2) {
            unawaited(forceReconnect('mid-stream'));
          }
          if (cancelAfter != null && deltas >= cancelAfter && !cancelled) {
            cancelled = true;
            log('!! cancelling the turn after $deltas deltas');
            unawaited(client.cancel(sessionId).then((_) => log('cancel accepted')));
          }
        }
        if (!quietDeltas || chunk is! TextDeltaChunk && chunk is! ReasoningDeltaChunk) {
          log('~ chunk #$index ${_describeChunk(chunk)}');
        }
      case AssistantStreamEnded(:final committed, :final committedSeq, :final committedEventType):
        log('~ stream end committed=$committed $committedEventType@$committedSeq');
      case ApprovalRequestedEvent(:final request):
        final count = approvalDeliveries[request.eventId] = (approvalDeliveries[request.eventId] ?? 0) + 1;
        log(
          '?? approval request eventId=${request.eventId} delivery#$count tool=${request.toolName} '
          'call=${request.callId} reason=${jsonEncode(request.describe())}',
        );
        if (reconnectTest && !reconnectDone) {
          unawaited(forceReconnect('approval pending'));
          return;
        }
        if (answered.add(request.eventId)) {
          final decision = switch (approve) {
            'allow' => ApprovalDecision.allowOnce,
            'pass' => ApprovalDecision.pass,
            _ => ApprovalDecision.reject,
          };
          unawaited(
            client
                .respondApproval(request, decision)
                .then((_) => log('approval answered: ${decision.wire}'))
                .catchError((Object e) => log('approval answer failed: $e')),
          );
        }
      case UserQuestionRequestedEvent(:final request):
        log('?? question eventId=${request.eventId} ${request.questions.map((q) => q.question).toList()}');
        unawaited(client.rejectQuestion(request, message: 'probe does not answer questions'));
      case HostRequestCancelledEvent(:final eventId):
        log('?? request settled/cancelled eventId=$eventId');
      case SessionStatusEvent(:final running):
        log('status running=$running');
      case SessionErrorEvent(:final message):
        log('session error: $message');
      case ConnectionStateEvent(:final state, :final error):
        log('connection: ${state.name}${error == null ? '' : ' ($error)'}');
      default:
        log('event: ${event.runtimeType}');
    }
  }, onError: (Object error) => log('watch error: $error'));

  final snapshot = await snapshotSeen.future.timeout(const Duration(seconds: 30));
  if (prompt != null) {
    promptCursor = snapshot.cursor;
    final requestId = await client.prompt(sessionId, prompt);
    promptSent = true;
    log('prompt accepted requestId=$requestId');
    try {
      await turnDone.future.timeout(timeout);
    } on TimeoutException {
      log('timed out waiting for turn/end');
    }
    // Give the Host a moment for the auto title and trailing frames.
    await Future<void>.delayed(const Duration(seconds: 4));
  }
  await sub.cancel();
  log(
    'transcript: title=${jsonEncode(transcript.title)} running=${transcript.running} items=${transcript.items.length}',
  );
  for (final item in transcript.items) {
    final line = switch (item) {
      UserChatItem(:final text, :final requestId) => 'user: ${jsonEncode(_clip(text, 80))} (requestId=$requestId)',
      AssistantChatItem(:final text, :final reasoning, :final streaming, :final interrupted) =>
        'assistant: ${jsonEncode(_clip(text, 100))} reasoning=${reasoning.length}ch streaming=$streaming interrupted=$interrupted',
      ToolChatItem(:final name, :final status, :final approvalOutcome) =>
        'tool: $name status=${status.name} approval=${approvalOutcome?.name} result=${jsonEncode(_clip(item.resultText, 80))}',
      NoticeChatItem(:final kind, :final text) => 'notice[$kind]: $text',
    };
    log('  - $line');
  }
  if (approvalDeliveries.isNotEmpty) log('approval deliveries per eventId: $approvalDeliveries');
}

String _describeChunk(StreamChunk chunk) => switch (chunk) {
  BlockStartChunk(:final blockIndex, :final blockType) => 'block-start[$blockIndex] $blockType',
  TextDeltaChunk(:final blockIndex, :final text) => 'text[$blockIndex] ${jsonEncode(text)}',
  ReasoningDeltaChunk(:final blockIndex, :final text) => 'reasoning[$blockIndex] ${jsonEncode(_clip(text, 60))}',
  ToolCallDeltaChunk(:final blockIndex, :final name, :final argumentsDelta) =>
    'tool-call[$blockIndex] ${name ?? ''} ${jsonEncode(argumentsDelta)}',
  BlockEndChunk(:final blockIndex, :final block) => 'block-end[$blockIndex] ${block.runtimeType}',
  UsageChunk(:final usage) => 'usage in=${usage.inputTokens} out=${usage.outputTokens}',
  FinishChunk(:final reason, :final failure) => 'finish $reason${failure == null ? '' : ' $failure'}',
  UnknownChunk(:final raw) => 'unknown ${jsonEncode(raw)}',
};

String _clip(String text, int max) => text.length <= max ? text : '${text.substring(0, max)}…(${text.length})';

class _Args {
  _Args(this._values, this._flags);

  static const _flagNames = {'help', 'list-only', 'reconnect-test', 'quiet-deltas'};

  factory _Args.parse(List<String> argv) {
    final values = <String, String>{};
    final flags = <String>{};
    for (var i = 0; i < argv.length; i++) {
      final arg = argv[i];
      if (!arg.startsWith('--')) throw ArgumentError('unexpected argument $arg');
      final name = arg.substring(2);
      final eq = name.indexOf('=');
      if (eq > 0) {
        values[name.substring(0, eq)] = name.substring(eq + 1);
      } else if (_flagNames.contains(name)) {
        flags.add(name);
      } else {
        if (i + 1 >= argv.length) throw ArgumentError('--$name needs a value');
        values[name] = argv[++i];
      }
    }
    return _Args(values, flags);
  }

  final Map<String, String> _values;
  final Set<String> _flags;

  String? value(String name) => _values[name];
  bool flag(String name) => _flags.contains(name);
}
