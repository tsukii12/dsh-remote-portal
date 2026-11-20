/// Browsing a Session's workspace the way the official Web client's file
/// panel does (`@deepseek-ai/dsh-client-ui-sidebar-files`,
/// `@deepseek-ai/dsh-client-ui-sidebar-documentpreview`), over the Host's
/// `workspaceFiles` service (`@deepseek-ai/dsh-api-workspace-files`):
///
/// * `workspaceFiles/list` — a directory's direct children (workspace-scoped;
///   the root is `.` or the Session's absolute cwd, never the empty string,
///   which the Host refuses with `gateway/bad-request`);
/// * `workspaceFiles/read` — one page of a UTF-8 text file (1-based line
///   window, at most `maxLines` = 5000 lines and 2 MiB per page);
/// * `workspaceFiles/readBytes` with a `range` — one byte window;
/// * `workspaceFiles/changes` — a stream: `{kind: ready}` once the Host
///   watches the target, then `{kind: change, change}` for each invalidation
///   (a file's new version or `absent`; a directory's direct children);
///
/// Searching the workspace by name goes through `fileReferences/list`
/// (references_api.dart), as the `@` completion does.
///
/// Paths are absolute or relative to the Session's workspace root.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'errors.dart';
import 'json.dart';
import 'session_api.dart';

/// One direct child of a listed directory.
class DshWorkspaceEntry {
  const DshWorkspaceEntry({required this.name, required this.type, this.size});

  factory DshWorkspaceEntry.fromJson(Map<String, Object?> json) => DshWorkspaceEntry(
    name: asString(json['name']) ?? '',
    type: switch (asString(json['type'])) {
      'directory' => DshWorkspaceEntryType.directory,
      'file' => DshWorkspaceEntryType.file,
      _ => DshWorkspaceEntryType.other,
    },
    size: asInt(json['size']),
  );

  /// Basename inside the listed directory.
  final String name;
  final DshWorkspaceEntryType type;

  /// Byte size of a regular file, when the backend reports it.
  final int? size;

  bool get isDirectory => type == DshWorkspaceEntryType.directory;
  bool get isFile => type == DshWorkspaceEntryType.file;
}

/// What a listed child resolves to (a symlink reports its destination).
enum DshWorkspaceEntryType { file, directory, other }

/// A directory's direct children (`workspaceFiles/list`).
class DshWorkspaceListing {
  const DshWorkspaceListing({required this.path, required this.entries, this.truncated = false});

  factory DshWorkspaceListing.fromJson(Object? json, {String fallbackPath = ''}) {
    final map = asMapOrEmpty(json);
    return DshWorkspaceListing(
      path: asString(map['path']) ?? fallbackPath,
      entries: [
        for (final entry in asListOrEmpty(map['entries']))
          if (asMap(entry) case final e? when asString(e['name'])?.isNotEmpty ?? false) DshWorkspaceEntry.fromJson(e),
      ],
      truncated: map['truncated'] == true,
    );
  }

  /// The listed directory relative to the workspace root ('' for the root).
  final String path;

  /// In the backend's name order, cut to its entry cap (2000 by default).
  final List<DshWorkspaceEntry> entries;

  /// Whether the cap dropped children.
  final bool truncated;
}

/// One page of a text file (`workspaceFiles/read`).
class DshWorkspaceText {
  const DshWorkspaceText({
    required this.text,
    required this.lines,
    required this.eof,
    this.offset = 1,
    this.absolutePath = '',
    this.version = '',
    this.bytes,
  });

  factory DshWorkspaceText.fromJson(Object? json, {int offset = 1}) {
    final map = asMapOrEmpty(json);
    return DshWorkspaceText(
      text: asString(map['text']) ?? '',
      lines: asInt(map['lines']) ?? 0,
      eof: map['eof'] == true,
      offset: asInt(map['offset']) ?? offset,
      absolutePath: asString(map['absolutePath']) ?? '',
      version: asString(map['version']) ?? '',
      bytes: asInt(map['bytes']),
    );
  }

  /// The page's lines joined by `\n`, no terminator after the last one.
  final String text;

  /// Lines on the page; 0 past the end (and for an empty file).
  final int lines;

  /// Whether the page holds the file's last line.
  final bool eof;

  /// First line of the page (1-based).
  final int offset;
  final String absolutePath;

  /// Opaque freshness token of the file when the page was read.
  final String version;

  /// Size of the whole file, when the backend reports it.
  final int? bytes;
}

/// One byte window of a file (`workspaceFiles/readBytes` with a range).
class DshWorkspaceBytes {
  const DshWorkspaceBytes({
    required this.data,
    required this.eof,
    this.offset = 0,
    this.absolutePath = '',
    this.version = '',
    this.bytes,
  });

  final Uint8List data;
  final bool eof;
  final int offset;
  final String absolutePath;
  final String version;

  /// Size of the whole file, when the backend reports it.
  final int? bytes;
}

/// A frame of `workspaceFiles/changes`.
sealed class DshWorkspaceWatchFrame {
  const DshWorkspaceWatchFrame();

  /// Null for an item this client does not know.
  static DshWorkspaceWatchFrame? fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    switch (asString(map['kind'])) {
      case 'ready':
        return const DshWorkspaceWatchReady();
      case 'change':
        final change = asMapOrEmpty(map['change']);
        return DshWorkspaceWatchChange(
          absolutePath: asString(change['absolutePath']) ?? '',
          version: asString(change['version']),
          absent: change['absent'] == true,
        );
    }
    return null;
  }
}

/// The Host watches the target. Every (re)opened watch starts with one, so a
/// consumer re-reads on it after the first: changes made while the link was
/// down were not reported.
final class DshWorkspaceWatchReady extends DshWorkspaceWatchFrame {
  const DshWorkspaceWatchReady();
}

/// The target changed: a file's new [version], or [absent] once it is gone.
/// A directory's frames say only "its children changed" (list it again).
final class DshWorkspaceWatchChange extends DshWorkspaceWatchFrame {
  const DshWorkspaceWatchChange({required this.absolutePath, this.version, this.absent = false});

  final String absolutePath;
  final String? version;
  final bool absent;
}

/// Lines one `workspaceFiles/read` page may hold at most (the Host's
/// default `maxLines`).
const int workspaceMaxPageLines = 5000;

extension DshWorkspaceApi on DshClient {
  /// `workspaceFiles/list`; [path] '' means the workspace root.
  Future<DshWorkspaceListing> listWorkspace(String sessionId, String path) async {
    final wire = path.isEmpty ? '.' : path;
    final value = await rpc.call('workspaceFiles/list', {'workspaceFileScopeId': sessionId, 'path': wire});
    return DshWorkspaceListing.fromJson(value, fallbackPath: path);
  }

  /// `workspaceFiles/read`: up to [limit] lines from line [offset] (1-based).
  ///
  /// Fails with `workspace-file/not-text` for binary content and
  /// `workspace-file/too-large` when the page would pass 2 MiB (one very long
  /// line is enough).
  Future<DshWorkspaceText> readWorkspaceText(String sessionId, String path, {int offset = 1, int limit = 500}) async {
    final value = await rpc.call('workspaceFiles/read', {
      'workspaceFileScopeId': sessionId,
      'path': path,
      'range': {'offset': offset, 'limit': limit.clamp(1, workspaceMaxPageLines)},
    });
    return DshWorkspaceText.fromJson(value, offset: offset);
  }

  /// `workspaceFiles/readBytes` with a byte window ([length] at most the
  /// Host's 2 MiB window).
  Future<DshWorkspaceBytes> readWorkspaceWindow(
    String sessionId,
    String path, {
    int offset = 0,
    required int length,
  }) async {
    final map = asMapOrEmpty(
      await rpc.call('workspaceFiles/readBytes', {
        'workspaceFileScopeId': sessionId,
        'path': path,
        'options': {
          'range': {'offset': offset, 'length': length},
        },
      }),
    );
    return DshWorkspaceBytes(
      data: _bytes(map['data']),
      eof: map['eof'] == true,
      offset: asInt(map['offset']) ?? offset,
      absolutePath: asString(map['absolutePath']) ?? '',
      version: asString(map['version']) ?? '',
      bytes: asInt(map['bytes']),
    );
  }

  /// `workspaceFiles/changes` for one file or directory ('' = the root).
  ///
  /// Opens on the current link and again on every new link generation (each
  /// opening starts with [DshWorkspaceWatchReady]); it never starts a
  /// connection itself, so a client nobody connected stays quiet. A Host
  /// refusal (`workspace-file/watch-unsupported` on backends without
  /// watching, `workspace-file/not-found`, …) arrives as an error and ends
  /// the stream.
  Stream<DshWorkspaceWatchFrame> watchWorkspace(String sessionId, String path) {
    final wire = path.isEmpty ? '.' : path;
    late final StreamController<DshWorkspaceWatchFrame> out;
    StreamSubscription<Object?>? generations;
    StreamSubscription<Object?>? items;
    var stopped = false;

    void open() {
      if (stopped) return;
      unawaited(items?.cancel());
      final stream = mux.open('workspaceFiles/changes', {'workspaceFileScopeId': sessionId, 'path': wire});
      items = stream.items.listen(
        (item) {
          final frame = DshWorkspaceWatchFrame.fromJson(item);
          if (frame != null && !stopped) out.add(frame);
        },
        onError: (Object error) {
          // A lost link reopens with the next generation; anything else is
          // the Host's answer for this target.
          if (error is DshCarrierLostException || error is DshClosedException || stopped) return;
          stopped = true;
          out.addError(error);
          unawaited(generations?.cancel());
          unawaited(out.close());
        },
      );
    }

    out = StreamController<DshWorkspaceWatchFrame>(
      onListen: () {
        generations = mux.generations.listen((_) => open());
        if (mux.generation != null) open();
      },
      onCancel: () async {
        stopped = true;
        await generations?.cancel();
        await items?.cancel();
      },
    );
    return out.stream;
  }
}

/// Binary `data`: bytes over HTTP (multipart), base64 over the remote
/// tunnel, a JSON byte array from a test double.
Uint8List _bytes(Object? data) {
  if (data is Uint8List) return data;
  if (data is String) return base64Decode(data);
  if (data is List) return Uint8List.fromList([for (final b in data) asInt(b) ?? 0]);
  return Uint8List(0);
}
