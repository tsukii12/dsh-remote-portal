// A loaded conversation → [ConversationShare]. Times come from the turn traces
// (first and last token of each reply, dispatch and result of each tool) and
// the durable log; every text goes through `conversation_redact.dart`.

import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_client/dsh_client.dart';

import '../l10n/l10n.dart';
import '../state/app_notes.dart';
import '../state/chat_state.dart' show CommandNotice;
import '../ui/chat/dsh_ui/dsh_ui_model.dart' show dshUiPlainText;
import '../ui/chat/tool_view.dart';
import 'conversation_redact.dart';
import 'conversation_share.dart';
import 'image_shrink.dart';

/// Tool output kept per call (start and end, the middle cut).
const exportToolOutputChars = 2400;

/// Longest string kept in a tool's arguments.
const exportToolArgChars = 2000;

/// What a conversation export reads: the chat as loaded.
class ConversationSource {
  const ConversationSource({
    required this.title,
    required this.items,
    this.turns = const [],
    this.commands = const [],
    this.events = const [],
    this.model,
  });

  final String title;
  final List<ChatItem> items;
  final List<TurnTrace> turns;
  final List<CommandNotice> commands;

  /// The durable log (todo and goal changes, times of notices).
  final Iterable<SessionLogEvent> events;

  /// The model the conversation uses now (when no reply names one).
  final String? model;
}

/// One round: a prompt and what followed it, up to the next prompt.
class ExportRound {
  const ExportRound({required this.index, required this.startSeq, required this.prompt});

  /// 1-based.
  final int index;

  /// Where the round starts in the log (its turn's start, when that comes
  /// first).
  final int startSeq;

  /// The prompt, one line.
  final String prompt;
}

/// Reads pictures a message carried; null when one can't be read.
typedef ExportImageLoader = Future<Uint8List?> Function(ImageAttachment image);

/// Builds shares of one loaded conversation with different options. The
/// pictures are read and shrunk once ([loadImages]).
class ConversationExport {
  ConversationExport(this.source) : rounds = _rounds(source);

  final ConversationSource source;
  final List<ExportRound> rounds;

  /// Attachment id → shrunk picture.
  final Map<String, ConversationAsset> _assets = {};

  bool get isEmpty => rounds.isEmpty;

  Iterable<ConversationAsset> get assets => _assets.values;

  /// Reads and shrinks every picture the messages carried (those it can).
  Future<void> loadImages(ExportImageLoader load) async {
    for (final item in source.items.whereType<UserChatItem>()) {
      for (final image in item.images) {
        if (_assets.containsKey(image.attachmentId)) continue;
        try {
          final bytes = await load(image);
          if (bytes == null) continue;
          final shrunk = await shrinkImage(bytes);
          if (shrunk == null) continue;
          _assets[image.attachmentId] = ConversationAsset.of(
            shrunk.bytes,
            mediaType: shrunk.mediaType,
            width: shrunk.width,
            height: shrunk.height,
          );
        } catch (_) {
          continue;
        }
      }
    }
  }

  /// The share for rounds [from]..[to] (1-based, inclusive; null: all), or
  /// for the messages [only] names (`ChatItem.key`s of prompts and replies).
  ///
  /// With [only], the work around the picked replies comes along: the tool
  /// calls, todos and goals of the turns a picked reply belongs to, and the
  /// notices of any turn a picked message belongs to. Commands stay out.
  ///
  /// [tools] false leaves out every tool call, todo and goal; [images] false
  /// leaves out the pictures attached to prompts. [toolOutput] false keeps
  /// the calls without their output.
  ConversationShare build({
    int? from,
    int? to,
    Set<String>? only,
    bool thinking = true,
    bool toolOutput = true,
    bool tools = true,
    bool images = true,
    required DateTime now,
    String? app,
  }) {
    toolOutput = toolOutput && tools;
    final picked = only == null ? null : _picked(only);
    final first = picked?.from ?? (from ?? 1).clamp(1, rounds.isEmpty ? 1 : rounds.length);
    final last = picked?.to ?? (to ?? rounds.length).clamp(first, rounds.isEmpty ? 1 : rounds.length);
    final whole = picked == null && first == 1 && last == rounds.length;
    final lo = whole || rounds.isEmpty ? -1 << 52 : (first == 1 ? -1 << 52 : rounds[first - 1].startSeq);
    final hi = whole || rounds.isEmpty || last >= rounds.length ? 1 << 52 : rounds[last].startSeq;
    bool inRoundRange(int seq) => seq >= lo && seq < hi;
    // A message is in when picked; the rest by the turns of the picks.
    bool inRange(int seq) => picked == null ? inRoundRange(seq) : picked.turns.any((t) => t.contains(seq));
    bool workInRange(int seq) => picked == null ? inRoundRange(seq) : picked.replyTurns.any((t) => t.contains(seq));
    bool messageIn(ChatItem item, int seq) => picked == null ? inRoundRange(seq) : only!.contains(item.key);

    final times = <int, DateTime>{for (final e in source.events) e.seq: e.time};
    final modelSpans = <int, TraceSpan>{};
    final toolSpans = <String, TraceSpan>{};
    for (final trace in source.turns) {
      for (final span in trace.spans) {
        if (span.kind == TraceKind.model && span.seq >= 0) modelSpans[span.seq] = span;
        if (span.kind == TraceKind.tool && span.callId != null) toolSpans[span.callId!] = span;
      }
    }

    // (seq, absolute time, duration, entry builder).
    final timed = <({int seq, DateTime at, Duration? d, ConversationEntry Function(int t, int? d) make})>[];
    String? lastModel;

    for (final trace in source.turns) {
      if (picked == null ? !inRange(trace.startSeq) : !picked.turns.any((t) => t.trace == trace)) continue;
      final usage = trace.usage;
      timed.add((
        seq: trace.startSeq,
        at: trace.start,
        d: trace.duration,
        make: (t, d) => TurnEntry(
          t: t,
          d: d,
          end: trace.endReason?.kind,
          steps: trace.steps > 0 ? trace.steps : null,
          tokens: usage.isEmpty ? null : usage.total,
        ),
      ));
    }

    for (final item in source.items) {
      switch (item) {
        case UserChatItem(:final seq) when messageIn(item, seq):
          final pictures = [
            for (final image in images ? item.images : const <ImageAttachment>[])
              if (_assets[image.attachmentId] case final asset?)
                ImageRef(
                  id: asset.id,
                  width: asset.width,
                  height: asset.height,
                  name: image.name == null ? null : redactPaths(image.name!),
                ),
          ];
          final files = [
            for (final file in item.files)
              FileRef(name: redactPaths(file.name ?? appL10n.pluginsFile), size: file.bytes),
          ];
          final text = redactText(withoutAppNotes(item.text));
          timed.add((
            seq: seq,
            at: item.time,
            d: null,
            make: (t, _) => UserEntry(
              t: t,
              text: text,
              images: pictures,
              files: files,
              source: item.sourceKind == 'user' ? null : item.sourceKind,
            ),
          ));
        case AssistantChatItem(:final seq?) when messageIn(item, seq) && !item.streaming:
          final text = markdownWithoutImages(redactText(item.text.trimRight()));
          final reasoning = thinking ? redactText(item.reasoning.trim()) : '';
          if (text.isEmpty && reasoning.isEmpty && !item.interrupted) continue;
          final span = modelSpans[seq];
          final start = span?.firstToken ?? span?.start ?? item.time;
          final end = span?.lastToken ?? span?.end ?? item.time;
          if (start == null) continue;
          final model = item.model ?? span?.model;
          if (model != null) lastModel = model;
          final plain = item.text.contains('dsh-ui')
              ? markdownWithoutImages(redactText(dshUiPlainText(item.text)))
              : null;
          timed.add((
            seq: seq,
            at: start,
            d: end == null || end.isBefore(start) ? null : end.difference(start),
            make: (t, d) => ReplyEntry(
              t: t,
              d: d,
              text: text,
              thinking: reasoning.isEmpty ? null : reasoning,
              plain: plain == text ? null : plain,
              model: model,
              interrupted: item.interrupted,
            ),
          ));
        case ToolChatItem(:final seq?) when tools && workInRange(seq):
          if (item.status == ToolStatus.streaming) continue;
          final span = toolSpans[item.callId];
          final at = span?.start ?? times[seq];
          if (at == null) continue;
          final view = ToolView.of(item);
          final Object? decoded;
          try {
            decoded = item.arguments.trim().isEmpty ? null : jsonDecode(item.arguments);
          } on FormatException {
            continue;
          }
          final args = decoded is Map
              ? redactJson(decoded, maxChars: exportToolArgChars) as Map<String, Object?>
              : const <String, Object?>{};
          final output = toolOutput && item.resultText.isNotEmpty
              ? cutText(redactText(item.resultText), exportToolOutputChars)
              : null;
          final status = switch (item.status) {
            ToolStatus.failed => ToolOutcome.failed,
            ToolStatus.denied => ToolOutcome.denied,
            ToolStatus.cancelled => ToolOutcome.cancelled,
            ToolStatus.succeeded => ToolOutcome.ok,
            // Still running when exported.
            _ => ToolOutcome.cancelled,
          };
          final reason = item.failure?.reason;
          final summary = redactText(view.summary);
          final verb = view.verb;
          timed.add((
            seq: seq,
            at: at,
            d: span?.end?.difference(at),
            make: (t, d) => ToolEntry(
              t: t,
              d: d,
              name: item.name,
              args: args,
              summary: summary,
              verb: verb,
              status: status,
              result: output?.text,
              omitted: output?.omitted ?? 0,
              error: reason == null ? null : redactText(reason),
            ),
          ));
        case NoticeChatItem(:final seq) when inRange(seq):
          final at = times[seq];
          if (at == null) continue;
          final text = redactText(item.text);
          timed.add((seq: seq, at: at, d: null, make: (t, _) => NoticeEntry(t: t, kind: item.kind, text: text)));
        default:
          break;
      }
    }

    for (final command in source.commands) {
      final seq = command.seq;
      if (picked != null || seq == null || !command.done || !inRange(seq)) continue;
      final at = times[seq];
      if (at == null) continue;
      final line = redactText(command.line);
      final text = command.text == null ? null : redactText(command.text!);
      timed.add((
        seq: seq,
        at: at,
        d: null,
        make: (t, _) => CommandEntry(t: t, line: line, ok: command.success, text: text),
      ));
    }

    for (final event in source.events) {
      if (!tools || !workInRange(event.seq)) continue;
      switch (event) {
        case TodoWriteEvent(:final todos):
          final items = [
            for (final todo in todos)
              if (todo.content.trim().isNotEmpty) (text: redactText(todo.content.trim()), status: todo.status),
          ];
          timed.add((seq: event.seq, at: event.time, d: null, make: (t, _) => TodosEntry(t: t, items: items)));
        default:
          if (event.type != 'goal/change') break;
          final data = event.data;
          final goal = data['goal'];
          final clear = data['operation'] == 'clear';
          final objective = !clear && goal is Map && goal['objective'] is String ? goal['objective'] as String : null;
          final phase = !clear && goal is Map && goal['phase'] is String ? goal['phase'] as String : null;
          if (!clear && objective == null) break;
          final text = objective == null ? null : redactText(objective);
          timed.add((
            seq: event.seq,
            at: event.time,
            d: null,
            make: (t, _) => GoalEntry(t: t, text: text, phase: phase),
          ));
      }
    }

    timed.sort((a, b) => a.seq.compareTo(b.seq));
    final origin = timed.isEmpty ? now : timed.map((e) => e.at).reduce((a, b) => a.isBefore(b) ? a : b);
    final entries = [
      for (final e in timed)
        e.make(
          e.at.difference(origin).inMilliseconds.clamp(0, 1 << 40),
          e.d == null || e.d!.isNegative ? null : e.d!.inMilliseconds,
        ),
    ];
    return ConversationShare(
      title: redactText(source.title.trim().isEmpty ? appL10n.pluginsChat : source.title.trim()),
      start: origin,
      entries: entries,
      model: lastModel ?? source.model,
      app: app,
      created: now,
      range: whole || rounds.isEmpty ? null : (from: first, to: last, of: rounds.length),
      thinking: thinking,
      toolOutput: toolOutput,
    );
  }

  /// The rounds and turns [only] reaches.
  _Picked _picked(Set<String> only) {
    final seqs = <int>[];
    final replySeqs = <int>[];
    for (final item in source.items) {
      if (!only.contains(item.key)) continue;
      switch (item) {
        case UserChatItem(:final seq):
          seqs.add(seq);
        case AssistantChatItem(:final seq?):
          seqs.add(seq);
          replySeqs.add(seq);
        default:
          break;
      }
    }
    _Turn? turnOf(int seq) {
      for (final trace in source.turns.reversed) {
        final turn = _Turn(trace);
        if (turn.contains(seq)) return turn;
      }
      return null;
    }

    int roundOf(int seq) {
      var index = 1;
      for (final round in rounds) {
        if (round.startSeq <= seq) index = round.index;
      }
      return index;
    }

    seqs.sort();
    return _Picked(
      turns: {for (final seq in seqs) ?turnOf(seq)},
      replyTurns: {for (final seq in replySeqs) ?turnOf(seq)},
      from: seqs.isEmpty ? 1 : roundOf(seqs.first),
      to: seqs.isEmpty ? 1 : roundOf(seqs.last),
    );
  }

  /// The share as a file, and its size in bytes.
  ({String text, int bytes}) file(ConversationShare share) {
    final text = encodeConversationFile(share, _assets.values);
    return (text: text, bytes: utf8.encode(text).length);
  }

  static List<ExportRound> _rounds(ConversationSource source) {
    final users = [
      for (final item in source.items)
        if (item is UserChatItem) item,
    ];
    if (users.isEmpty) return const [];
    final turnStarts = [for (final t in source.turns) t.startSeq]..sort();
    final out = <ExportRound>[];
    int? previous;
    for (final (i, user) in users.indexed) {
      // The turn this prompt opened starts just before it (DSH logs
      // `turn/start`, then the prompt); turns between two prompts that no
      // prompt opened (a goal going on by itself) stay with the round before.
      var start = user.seq;
      for (final s in turnStarts) {
        if (s < user.seq && (previous == null || s > previous)) start = s;
      }
      out.add(ExportRound(index: i + 1, startSeq: start, prompt: _oneLine(withoutAppNotes(user.text))));
      previous = user.seq;
    }
    return out;
  }

  static String _oneLine(String text) {
    final t = redactText(text).replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.isEmpty ? appL10n.pluginsImage : (t.length <= 80 ? t : '${t.substring(0, 79)}…');
  }
}

/// One turn's stretch of the log.
class _Turn {
  const _Turn(this.trace);

  final TurnTrace trace;

  bool contains(int seq) => trace.startSeq <= seq && (trace.endSeq == null || seq <= trace.endSeq!);

  @override
  bool operator ==(Object other) => other is _Turn && identical(other.trace, trace);

  @override
  int get hashCode => identityHashCode(trace);
}

/// What a picked set of messages reaches.
class _Picked {
  const _Picked({required this.turns, required this.replyTurns, required this.from, required this.to});

  /// Turns holding a picked message.
  final Set<_Turn> turns;

  /// Turns holding a picked reply: their work comes along.
  final Set<_Turn> replyTurns;

  /// The rounds the picks span (1-based).
  final int from;
  final int to;
}
