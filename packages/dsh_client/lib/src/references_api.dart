/// `@` references in a prompt: workspace files and folders
/// (`fileReferences/list`) and other conversations
/// (`sessionReferenceResolver/candidates`), plus the prompt grammar the
/// official clients write for them.
///
/// Verified against DSH 0.2.1-rc.2 (`@deepseek-ai/dsh-file-reference`
/// grammar, `dsh-session-reference` URI encoding, `dsh-client-ui-reference`
/// source, and a throwaway `dsh web`):
/// * a file is plain prompt text: `@path`, `@"path with spaces"`, a folder
///   keeps a trailing slash (`@dir/`, quoted: `@"dir with spaces/` — the quote
///   stays open, as the official completion writes it);
/// * a conversation is `@[label](dsh-session:<base64url(JSON id)>)`; the Host
///   validates it at `agent/pre-step`, rewrites the stored user message to
///   `@label` and adds a read-only snapshot of that conversation.
library;

import 'dart:convert';

import 'json.dart';
import 'session_api.dart';

/// One `fileReferences/list` candidate, relative to the session's cwd.
class FileReferenceCandidate {
  const FileReferenceCandidate({required this.path, required this.isDirectory});

  static FileReferenceCandidate? fromJson(Object? json) {
    final map = asMap(json);
    final path = asString(map?['path']);
    if (map == null || path == null || path.isEmpty) return null;
    return FileReferenceCandidate(path: path, isDirectory: map['kind'] == 'directory');
  }

  final String path;
  final bool isDirectory;

  /// Last path segment (`main.dart`).
  String get name {
    final slash = path.lastIndexOf('/');
    return slash < 0 ? path : path.substring(slash + 1);
  }

  /// Parent directory, empty at the root.
  String get parent {
    final slash = path.lastIndexOf('/');
    return slash < 0 ? '' : path.substring(0, slash);
  }

  /// The prompt text for this candidate; null when the grammar cannot carry
  /// the path safely (control characters, double quotes).
  String? get mention => formatFileMention(path, directory: isDirectory);
}

/// One `sessionReferenceResolver/candidates` row: another conversation of the
/// same Host (the requesting one is never listed).
class SessionReferenceCandidate {
  const SessionReferenceCandidate({
    required this.sessionId,
    required this.label,
    required this.mention,
    required this.sameWorkspace,
    required this.createdAt,
    this.displayTitle,
    this.cwd,
  });

  static SessionReferenceCandidate? fromJson(Object? json) {
    final map = asMap(json);
    final id = asString(map?['sessionId']);
    final mention = asString(map?['mention']);
    if (map == null || id == null || id.isEmpty || mention == null || mention.isEmpty) return null;
    return SessionReferenceCandidate(
      sessionId: id,
      label: asString(map['label']) ?? id,
      mention: mention,
      sameWorkspace: map['sameWorkspace'] == true,
      createdAt: asEpochMs(map['createdAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
      displayTitle: asString(map['displayTitle']),
      cwd: asString(map['cwd']),
    );
  }

  final String sessionId;

  /// Latest log-backed title (falls back to the session id).
  final String label;

  /// A subagent's creation label, preferred for display and in [mention].
  final String? displayTitle;

  /// Canonical `@[label](dsh-session:…)` text to put into the prompt.
  final String mention;
  final bool sameWorkspace;
  final DateTime createdAt;
  final String? cwd;

  String get title => displayTitle ?? label;
}

extension ReferencesApi on DshClient {
  /// Whether this carrier serves `@` discovery (remote tunnels allow both).
  bool get canListReferences =>
      supportsEndpoint('fileReferences/list') && supportsEndpoint('sessionReferenceResolver/candidates');

  /// `fileReferences/list`: files and folders under [sessionId]'s cwd for the
  /// text after `@` (fuzzy for a bare name, a live listing once it has a `/`).
  Future<List<FileReferenceCandidate>> fileReferences(String sessionId, String query) async {
    final value = await rpc.call('fileReferences/list', {'agentId': sessionId, 'query': query});
    return [for (final item in asListOrEmpty(value)) ?FileReferenceCandidate.fromJson(item)];
  }

  /// `sessionReferenceResolver/candidates`: other conversations, those in the
  /// same cwd first; [query] is a case-insensitive id / cwd / title substring.
  Future<List<SessionReferenceCandidate>> sessionReferences(String sessionId, String query) async {
    final value = await rpc.call('sessionReferenceResolver/candidates', {'agentId': sessionId, 'query': query});
    return [for (final item in asListOrEmpty(value)) ?SessionReferenceCandidate.fromJson(item)];
  }
}

// -----------------------------------------------------------------------------
// Grammar (`@deepseek-ai/dsh-file-reference/grammar`, `dsh-session-reference/uri`)

const sessionReferenceScheme = 'dsh-session:';

final RegExp _unsafePath = RegExp(r'[\u0000-\u001f\u007f-\u009f"]');
final RegExp _whitespace = RegExp(r'\s');

/// `formatFileMention`: `@path`; whitespace switches to `@"path"`, and a
/// quoted directory keeps its quote open after the slash. Null for a path the
/// grammar cannot carry. [preserveQuote] keeps a quote the person opened.
String? formatFileMention(String path, {bool directory = false, bool preserveQuote = false}) {
  final text = directory ? '$path/' : path;
  if (_unsafePath.hasMatch(text)) return null;
  if (!preserveQuote && !_whitespace.hasMatch(text)) return '@$text';
  return directory ? '@"$text' : '@"$text"';
}

/// `encodeSessionReferenceUri`: `dsh-session:` + unpadded base64url of the
/// JSON-encoded id. Exact for the ASCII ids DSH issues.
String encodeSessionReferenceUri(String sessionId) =>
    '$sessionReferenceScheme${base64Url.encode(utf8.encode(jsonEncode(sessionId))).replaceAll('=', '')}';

/// The session id inside a canonical URI; null when it is not one.
String? decodeSessionReferenceUri(String uri) {
  if (!uri.startsWith(sessionReferenceScheme)) return null;
  final payload = uri.substring(sessionReferenceScheme.length);
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(payload)) return null;
  try {
    final decoded = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(payload))));
    return decoded is String && encodeSessionReferenceUri(decoded) == uri ? decoded : null;
  } on FormatException {
    return null;
  }
}

/// `formatSessionReferenceMention`: `@[label](dsh-session:…)` with `\` and
/// `]` escaped in the label.
String formatSessionMention(String sessionId, String label) {
  final escaped = label.replaceAllMapped(RegExp(r'[\\\]]'), (m) => '\\${m[0]}');
  return '@[$escaped](${encodeSessionReferenceUri(sessionId)})';
}

/// Matches one canonical session mention; group 1 is the escaped label,
/// group 2 the URI.
final RegExp sessionMentionPattern = RegExp(r'@\[((?:\\.|[^\\\]\n])*)\]\((dsh-session:[A-Za-z0-9_-]+)\)');

/// The label of an escaped mention label (`修复 登录\] 问题` → `修复 登录] 问题`).
String unescapeMentionLabel(String label) => label.replaceAllMapped(RegExp(r'\\(.)'), (m) => m[1]!);
