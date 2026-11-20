// SPDX-FileCopyrightText: 2026 DeepSeek
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

/// Files the agent declared for the user with the `present` tool.
///
/// `@deepseek-ai/dsh-tool-present` appends one durable
/// `deliverables/presented` event per successful call:
/// `{turn, callId, files: [{path, description?}]}`. Paths are absolute in new
/// declarations; historical ones may be relative to the Session's working
/// directory. Only the declaration is stored, never the file's content.
///
/// The validation and the per-turn selection follow the official Web client
/// (`@deepseek-ai/dsh-client-ui-deliverables`: `isPresentedData`,
/// `isPresentedFile`, `presentedForClosing`).
library;

import 'json.dart';
import 'models.dart';

/// Durable event type written by the `present` tool.
const presentedEventType = 'deliverables/presented';

/// One declared file, with the coordinates of the declaration.
class PresentedFile {
  const PresentedFile({
    required this.path,
    required this.seq,
    required this.index,
    required this.turn,
    required this.callId,
    this.description,
  });

  /// The path as declared: absolute, or relative to the Session's working
  /// directory (older declarations). Resolve with [resolveSessionPath].
  final String path;

  /// The model's one-line description, when given.
  final String? description;

  /// `deliverables/presented` event sequence.
  final int seq;

  /// Original index in that event's `files` array.
  final int index;

  /// The turn the declaration belongs to.
  final int turn;

  /// The `present` call that declared it.
  final String callId;
}

/// The declarations of one `deliverables/presented` event, in their order.
///
/// Null for any other event and for a malformed one (no positive integer
/// `turn`, empty `callId`, or `files` not a list). Malformed file entries
/// (no non-blank `path`, non-string `description`) are skipped; their index
/// is kept for the others.
List<PresentedFile>? presentedFilesOf(SessionLogEvent event) {
  if (event.type != presentedEventType) return null;
  final data = event.data;
  final turn = data['turn'];
  final callId = data['callId'];
  final files = data['files'];
  if (turn is! num || turn != turn.roundToDouble() || turn < 1) return null;
  if (callId is! String || callId.isEmpty) return null;
  if (files is! List) return null;
  final out = <PresentedFile>[];
  for (var index = 0; index < files.length; index++) {
    final file = asMap(files[index]);
    if (file == null) continue;
    final path = file['path'];
    final description = file['description'];
    if (path is! String || path.trim().isEmpty) continue;
    if (description != null && description is! String) continue;
    out.add(
      PresentedFile(
        path: path,
        description: description as String?,
        seq: event.seq,
        index: index,
        turn: turn.toInt(),
        callId: callId,
      ),
    );
  }
  return out;
}

/// Every loaded turn's deliveries, keyed by turn number.
///
/// Within a turn each path appears once, at its first declaration's place,
/// carrying its latest declaration (description and coordinates) — a file
/// declared again with a better description shows the newer one.
Map<int, List<PresentedFile>> presentedByTurn(Iterable<SessionLogEvent> events) {
  final byTurn = <int, Map<String, PresentedFile>>{};
  for (final event in events) {
    final files = presentedFilesOf(event);
    if (files == null) continue;
    for (final file in files) {
      // Map keeps the first insertion's position when a key is set again.
      (byTurn[file.turn] ??= {})[file.path] = file;
    }
  }
  return {
    for (final MapEntry(:key, :value) in byTurn.entries)
      if (value.isNotEmpty) key: List.unmodifiable(value.values),
  };
}

/// [path] as an absolute POSIX path: relative paths join [cwd] (when known);
/// `.` and `..` segments and repeated slashes are folded. A Windows path
/// (`C:\…`) or a relative path without [cwd] is returned unchanged.
String resolveSessionPath(String path, {String? cwd}) {
  // Whitespace belongs to the filename, including at the ends of a decoded URI path.
  var p = path;
  if (p.startsWith('file://')) p = Uri.decodeFull(p.substring('file://'.length));
  if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(p)) return p;
  if (!p.startsWith('/')) {
    if (cwd == null || !cwd.startsWith('/')) return p;
    p = '$cwd/$p';
  }
  final parts = <String>[];
  for (final segment in p.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (parts.isNotEmpty) parts.removeLast();
      continue;
    }
    parts.add(segment);
  }
  return '/${parts.join('/')}';
}
