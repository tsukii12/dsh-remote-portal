// A conversation as a share code (对话文件, docs/design/share-codes.md). Not DSH's
// event log: a small, versioned, normalised schema that the app's replay page
// and the web viewer (site/share/viewer.js) both render, with times for
// replaying it.
//
// The body is a share code like any other (`v: 2`, `kind: conversation`).
// Pictures travel next to the code in the `.dshgo` envelope (`assets`), each
// named by its own hash. The same file goes out three ways: as a `.dshgo`
// file, inside a self-contained `.html`, or encrypted on the share host
// behind a link (`app/lib/share_hosted/`).

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../l10n/l10n.dart';
import 'share_codec.dart';
import 'share_models.dart';

/// Body version a conversation is written with. Older apps read `v: 1`
/// only, so they say 「需要更新」 instead of failing on an unknown kind.
const conversationBodyVersion = 2;

/// Version of the conversation schema below. A reader refuses newer ones.
const conversationSchema = 1;

/// Largest `.dshgo` / `.html` file a conversation export makes (the file
/// opener on Android hands over files up to 4 MB, LinksPlugin.kt).
const maxConversationFileBytes = 4 * 1024 * 1024;

/// Display limits on read: texts are cut, not refused.
const _maxTitle = 120;
const _maxText = 400 * 1000;
const _maxToolText = 64 * 1000;
const _maxEntries = 20000;
const _maxImagesPerMessage = 20;

/// A tool call's outcome.
enum ToolOutcome {
  ok,
  failed,
  denied,
  cancelled;

  static ToolOutcome parse(Object? v) => switch (v) {
    'failed' => failed,
    'denied' => denied,
    'cancelled' => cancelled,
    _ => ok,
  };
}

/// One timed thing in the conversation. [t] is milliseconds after
/// [ConversationShare.start].
@immutable
sealed class ConversationEntry {
  const ConversationEntry(this.t);

  final int t;

  String get type;

  Map<String, Object?> toJson();

  /// Null for an entry type this app doesn't know (a newer minor addition):
  /// it is skipped.
  static ConversationEntry? fromJson(Object? json) {
    if (json is! Map) throw const ShareFormatException('entry is not an object');
    final t = _int(json['t']) ?? 0;
    final d = _int(json['d']);
    switch (json['type']) {
      case 'turn':
        return TurnEntry(
          t: t,
          d: d,
          end: _str(json['end'], 32),
          steps: _int(json['steps']),
          tokens: _int(json['tokens']),
        );
      case 'user':
        final images = json['images'];
        final files = json['files'];
        return UserEntry(
          t: t,
          text: _str(json['text'], _maxText) ?? '',
          images: [
            if (images is List)
              for (final image in images.take(_maxImagesPerMessage)) ?ImageRef.fromJson(image),
          ],
          files: [
            if (files is List)
              for (final file in files.take(_maxImagesPerMessage))
                if (file is Map && _str(file['name'], 200) != null)
                  FileRef(name: _str(file['name'], 200)!, size: _int(file['size'])),
          ],
          source: _str(json['source'], 32),
        );
      case 'reply':
        return ReplyEntry(
          t: t,
          d: d,
          text: _str(json['text'], _maxText) ?? '',
          thinking: _str(json['think'], _maxText),
          plain: _str(json['plain'], _maxText),
          model: _str(json['model'], 80),
          interrupted: json['cut'] == true,
        );
      case 'tool':
        final args = json['args'];
        return ToolEntry(
          t: t,
          d: d,
          name: _str(json['name'], 80) ?? 'tool',
          args: args is Map ? {for (final e in args.entries) '${e.key}': e.value} : const {},
          summary: _str(json['summary'], 500) ?? '',
          verb: _str(json['verb'], 40),
          status: ToolOutcome.parse(json['status']),
          result: _str(json['result'], _maxToolText),
          omitted: _int(json['more']) ?? 0,
          error: _str(json['error'], 2000),
        );
      case 'notice':
        return NoticeEntry(t: t, kind: _str(json['kind'], 32) ?? 'error', text: _str(json['text'], 4000) ?? '');
      case 'todos':
        final items = json['items'];
        return TodosEntry(
          t: t,
          items: [
            if (items is List)
              for (final item in items.take(200))
                if (item is Map && _str(item['text'], 500) != null)
                  (text: _str(item['text'], 500)!, status: _str(item['status'], 20) ?? 'pending'),
          ],
        );
      case 'goal':
        return GoalEntry(t: t, text: _str(json['text'], 4000), phase: _str(json['phase'], 20));
      case 'command':
        return CommandEntry(
          t: t,
          line: _str(json['line'], 2000) ?? '/',
          ok: json['ok'] != false,
          text: _str(json['text'], 8000),
        );
      default:
        return null;
    }
  }
}

/// A turn starts here (before its prompt, as DSH logs it); [d] is how long it
/// ran. The entries after it, up to the next turn, are its own.
final class TurnEntry extends ConversationEntry {
  const TurnEntry({required int t, this.d, this.end, this.steps, this.tokens}) : super(t);

  final int? d;

  /// How it ended: `completed`, `aborted`, `error`, `max-tokens`, … (DSH's
  /// `turn/end` reason); null when it was still running.
  final String? end;
  final int? steps;

  /// Total tokens of the turn's model requests.
  final int? tokens;

  @override
  String get type => 'turn';

  @override
  Map<String, Object?> toJson() => {'type': type, 't': t, 'd': ?d, 'end': ?end, 'steps': ?steps, 'tokens': ?tokens};
}

/// An image a message carried, by asset id.
@immutable
class ImageRef {
  const ImageRef({required this.id, this.width, this.height, this.name});

  static final _id = RegExp(r'^[A-Za-z0-9_-]{8,32}$');

  static ImageRef? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! String || !_id.hasMatch(id)) return null;
    return ImageRef(id: id, width: _int(json['w']), height: _int(json['h']), name: _str(json['name'], 200));
  }

  final String id;
  final int? width;
  final int? height;
  final String? name;

  Map<String, Object?> toJson() => {'id': id, 'w': ?width, 'h': ?height, 'name': ?name};
}

/// A file a message carried: its name and size only.
@immutable
class FileRef {
  const FileRef({required this.name, this.size});

  final String name;
  final int? size;

  Map<String, Object?> toJson() => {'name': name, 'size': ?size};
}

final class UserEntry extends ConversationEntry {
  const UserEntry({required int t, required this.text, this.images = const [], this.files = const [], this.source})
    : super(t);

  final String text;
  final List<ImageRef> images;
  final List<FileRef> files;

  /// Who wrote it when not the person: `goal` (a goal's continuation),
  /// `schedule`, …; null for the person.
  final String? source;

  @override
  String get type => 'user';

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    't': t,
    'text': text,
    if (images.isNotEmpty) 'images': [for (final i in images) i.toJson()],
    if (files.isNotEmpty) 'files': [for (final f in files) f.toJson()],
    'source': ?source,
  };
}

/// One assistant message: [t] is its first streamed token, [d] how long it
/// streamed (thinking included).
final class ReplyEntry extends ConversationEntry {
  const ReplyEntry({
    required int t,
    this.d,
    required this.text,
    this.thinking,
    this.plain,
    this.model,
    this.interrupted = false,
  }) : super(t);

  final int? d;

  /// Markdown, as the app renders it (visual `dsh-ui` blocks included).
  final String text;

  /// The reasoning; null when it had none or the export left it out.
  final String? thinking;

  /// [text] with visual blocks as their one-line summaries, for viewers that
  /// don't draw them; null when the text has none.
  final String? plain;
  final String? model;
  final bool interrupted;

  @override
  String get type => 'reply';

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    't': t,
    'd': ?d,
    'think': ?thinking,
    'text': text,
    'plain': ?plain,
    'model': ?model,
    if (interrupted) 'cut': true,
  };
}

final class ToolEntry extends ConversationEntry {
  const ToolEntry({
    required int t,
    this.d,
    required this.name,
    this.args = const {},
    this.summary = '',
    this.verb,
    this.status = ToolOutcome.ok,
    this.result,
    this.omitted = 0,
    this.error,
  }) : super(t);

  final int? d;
  final String name;

  /// The call's arguments, long strings cut.
  final Map<String, Object?> args;

  /// One line, as the app's tool row shows it (command, path, query…).
  final String summary;

  /// The row's verb (「运行」「读取」…).
  final String? verb;
  final ToolOutcome status;

  /// Output text, cut in the middle when long; null when left out.
  final String? result;

  /// Characters cut out of [result].
  final int omitted;

  /// Why it failed or was refused, when the tool said.
  final String? error;

  @override
  String get type => 'tool';

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    't': t,
    'd': ?d,
    'name': name,
    if (args.isNotEmpty) 'args': args,
    'summary': summary,
    'verb': ?verb,
    'status': status.name,
    'result': ?result,
    if (omitted > 0) 'more': omitted,
    'error': ?error,
  };
}

/// A turn-level notice: `error`, `aborted`, `max-tokens`, `retry`, …
final class NoticeEntry extends ConversationEntry {
  const NoticeEntry({required int t, required this.kind, required this.text}) : super(t);

  final String kind;
  final String text;

  @override
  String get type => 'notice';

  @override
  Map<String, Object?> toJson() => {'type': type, 't': t, 'kind': kind, 'text': text};
}

/// The todo list replaced (a new turn clears it, as DSH's projection does).
final class TodosEntry extends ConversationEntry {
  const TodosEntry({required int t, required this.items}) : super(t);

  /// `status`: `pending`, `in_progress`, `completed`.
  final List<({String text, String status})> items;

  @override
  String get type => 'todos';

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    't': t,
    'items': [
      for (final i in items) {'text': i.text, 'status': i.status},
    ],
  };
}

/// The goal set or changed; [text] null clears it.
final class GoalEntry extends ConversationEntry {
  const GoalEntry({required int t, this.text, this.phase}) : super(t);

  final String? text;

  /// `active`, `paused`, `blocked`, `complete`.
  final String? phase;

  @override
  String get type => 'goal';

  @override
  Map<String, Object?> toJson() => {'type': type, 't': t, 'text': ?text, 'phase': ?phase};
}

/// A slash command and its result.
final class CommandEntry extends ConversationEntry {
  const CommandEntry({required int t, required this.line, this.ok = true, this.text}) : super(t);

  final String line;
  final bool ok;
  final String? text;

  @override
  String get type => 'command';

  @override
  Map<String, Object?> toJson() => {'type': type, 't': t, 'line': line, if (!ok) 'ok': false, 'text': ?text};
}

/// Which rounds of a longer conversation this is (1-based, inclusive).
typedef ConversationRange = ({int from, int to, int of});

/// A conversation to read and replay.
@immutable
class ConversationShare {
  const ConversationShare({
    required this.title,
    required this.start,
    required this.entries,
    this.model,
    this.app,
    this.created,
    this.range,
    this.thinking = true,
    this.toolOutput = true,
  });

  /// Validates a decoded body; throws [ShareFormatException].
  /// [fallbackTitle] lets a background reader use its caller's language.
  factory ConversationShare.fromJson(Map<Object?, Object?> json, {String? fallbackTitle}) {
    final v = json['v'];
    if (v is! int || v < 1) throw const ShareFormatException('no format version');
    if (v > conversationBodyVersion) throw const ShareFormatException('newer format');
    if (ShareKind.parse(json['kind']) != ShareKind.conversation) throw const ShareFormatException('not a conversation');
    final schema = json['schema'];
    if (schema is! int || schema < 1) throw const ShareFormatException('no schema');
    if (schema > conversationSchema) throw const ShareFormatException('newer format');
    final start = json['start'] is String ? DateTime.tryParse(json['start'] as String) : null;
    if (start == null) throw const ShareFormatException('no start time');
    final raw = json['entries'];
    if (raw is! List || raw.length > _maxEntries) throw const ShareFormatException('bad entries');
    final range = json['range'];
    final include = json['include'];
    return ConversationShare(
      title: _line(json['title'], _maxTitle) ?? fallbackTitle ?? appL10n.pluginsChat,
      start: start,
      model: _line(json['model'], 80),
      app: _line(json['app'], 40),
      created: json['created'] is String ? DateTime.tryParse(json['created'] as String) : null,
      range: range is Map && _int(range['from']) != null && _int(range['to']) != null && _int(range['of']) != null
          ? (from: _int(range['from'])!, to: _int(range['to'])!, of: _int(range['of'])!)
          : null,
      thinking: include is! Map || include['thinking'] != false,
      toolOutput: include is! Map || include['tools'] != false,
      entries: List.unmodifiable([for (final entry in raw) ?ConversationEntry.fromJson(entry)]),
    );
  }

  final String title;

  /// Time of `t: 0`.
  final DateTime start;
  final List<ConversationEntry> entries;

  /// The model of its last reply.
  final String? model;

  /// `dsh-go 1.0.0`.
  final String? app;

  /// When it was exported.
  final DateTime? created;
  final ConversationRange? range;

  /// What the export kept.
  final bool thinking;
  final bool toolOutput;

  ShareKind get kind => ShareKind.conversation;

  /// When it ended (the last entry's end), from [start].
  Duration get span {
    var end = 0;
    for (final e in entries) {
      final d = switch (e) {
        TurnEntry(:final d) || ReplyEntry(:final d) || ToolEntry(:final d) => d ?? 0,
        _ => 0,
      };
      if (e.t + d > end) end = e.t + d;
    }
    return Duration(milliseconds: end);
  }

  int get messageCount => entries.where((e) => e is UserEntry || (e is ReplyEntry && e.text.trim().isNotEmpty)).length;
  int get toolCount => entries.whereType<ToolEntry>().length;
  Iterable<ImageRef> get images => entries.whereType<UserEntry>().expand((e) => e.images);

  Map<String, Object?> toJson() => {
    'v': conversationBodyVersion,
    'kind': 'conversation',
    'schema': conversationSchema,
    'title': title,
    'model': ?model,
    'app': ?app,
    if (created != null) 'created': created!.toUtc().toIso8601String(),
    'start': start.toUtc().toIso8601String(),
    if (range case final r?) 'range': {'from': r.from, 'to': r.to, 'of': r.of},
    if (!thinking || !toolOutput) 'include': {'thinking': thinking, 'tools': toolOutput},
    'entries': [for (final e in entries) e.toJson()],
  };
}

/// A picture carried in a conversation file.
@immutable
class ConversationAsset {
  const ConversationAsset({required this.id, required this.mediaType, required this.bytes, this.width, this.height});

  /// Builds one named by its hash.
  factory ConversationAsset.of(Uint8List bytes, {required String mediaType, int? width, int? height}) =>
      ConversationAsset(id: assetIdOf(bytes), mediaType: mediaType, bytes: bytes, width: width, height: height);

  final String id;

  /// `image/jpeg`, `image/png`, `image/webp`, `image/gif`.
  final String mediaType;
  final Uint8List bytes;
  final int? width;
  final int? height;

  static const types = {'image/jpeg', 'image/png', 'image/webp', 'image/gif'};

  Map<String, Object?> toJson() => {'type': mediaType, 'w': ?width, 'h': ?height, 'data': base64.encode(bytes)};
}

/// 12 base64url characters: the first 9 bytes of SHA-256 over [bytes].
String assetIdOf(List<int> bytes) => base64Url.encode(sha256.convert(bytes).bytes.sublist(0, 9));

/// A conversation read from a link or a file, with the pictures that came
/// with it (checked against their names).
@immutable
class DecodedConversation {
  const DecodedConversation(this.share, this.assets, {required this.code});

  final ConversationShare share;
  final Map<String, ConversationAsset> assets;

  /// The share code it came in.
  final String code;
}

/// Reads a conversation's share code, with the pictures of its file.
DecodedConversation decodeConversationCode(String code, {Map<Object?, Object?>? assets, String? fallbackTitle}) {
  final json = decodeShareJson(code, large: true);
  final share = ConversationShare.fromJson(json, fallbackTitle: fallbackTitle);
  return DecodedConversation(share, readConversationAssets(assets, share), code: code);
}

/// The pictures in a file's `assets` that the conversation uses and whose
/// bytes match their names; the others are dropped.
Map<String, ConversationAsset> readConversationAssets(Map<Object?, Object?>? raw, ConversationShare share) {
  if (raw == null || raw.isEmpty) return const {};
  final wanted = {for (final image in share.images) image.id};
  final out = <String, ConversationAsset>{};
  for (final MapEntry(:key, :value) in raw.entries) {
    if (key is! String || !wanted.contains(key) || value is! Map) continue;
    final type = value['type'];
    final data = value['data'];
    if (type is! String || !ConversationAsset.types.contains(type) || data is! String) continue;
    final Uint8List bytes;
    try {
      bytes = base64.decode(data);
    } on FormatException {
      continue;
    }
    if (assetIdOf(bytes) != key) continue;
    out[key] = ConversationAsset(
      id: key,
      mediaType: type,
      bytes: bytes,
      width: _int(value['w']),
      height: _int(value['h']),
    );
  }
  return out;
}

/// A `.dshgo` file for [share]: the readable header, the code, the pictures.
String encodeConversationFile(ConversationShare share, Iterable<ConversationAsset> assets, {String? code}) {
  final used = {for (final image in share.images) image.id};
  final kept = {
    for (final a in assets)
      if (used.contains(a.id)) a.id: a.toJson(),
  };
  return '${jsonEncode({'dshgo': conversationBodyVersion, 'kind': 'conversation', 'name': share.title, 'code': code ?? encodeShareJson(share.toJson()), if (kept.isNotEmpty) 'assets': kept})}\n';
}

/// Reads a conversation file's text.
DecodedConversation decodeConversationFile(String text, {String? fallbackTitle}) {
  final envelope = readShareEnvelope(text);
  return decodeConversationCode(envelope.code, assets: envelope.assets, fallbackTitle: fallbackTitle);
}

int? _int(Object? v) => v is int && v >= 0 ? v : (v is double && v.isFinite && v >= 0 ? v.round() : null);

/// Text as written, at most [max] characters; null for anything not a string
/// or empty.
String? _str(Object? v, int max) {
  if (v is! String || v.isEmpty) return null;
  return v.length <= max ? v : '${prefixKeepingPairs(v, max)}…';
}

/// One line of display text.
String? _line(Object? v, int max) {
  if (v is! String) return null;
  final t = v.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (t.isEmpty) return null;
  return t.length <= max ? t : '${prefixKeepingPairs(t, max - 1)}…';
}

/// The first [end] code units of [text], one fewer if that would split a
/// surrogate pair. For truncation only: [end] must be inside [text].
String prefixKeepingPairs(String text, int end) {
  final lead = text.codeUnitAt(end - 1);
  final trail = text.codeUnitAt(end);
  if (lead >= 0xd800 && lead <= 0xdbff && trail >= 0xdc00 && trail <= 0xdfff) end--;
  return text.substring(0, end);
}
