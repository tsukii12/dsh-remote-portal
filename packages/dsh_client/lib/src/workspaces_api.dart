/// Workspaces (`workspace/*`) and the in-app directory browser
/// (`directoryPicker/*`) as the official sidebar (`dsh-client-ui-workspace`)
/// and the browse picker (`dsh-client-ui-directory-picker-browse`) use them.
///
/// Verified against DSH 0.2.1-rc.2 (`dsh-api-workspace-controller`,
/// `dsh-host-directory-picker-browse` typings) and a throwaway `dsh web`:
/// * a new Workspace goes to the front of the registry order; `insertBefore`
///   without an anchor moves one to the end (DOM `insertBefore(x, null)`);
/// * only `session/create` with a `workspaceId` attaches a Session — a bare
///   `cwd` inside a Workspace's folder leaves it ungrouped;
/// * deleting a Workspace keeps its folder and Sessions (they become
///   ungrouped);
/// * `directoryPicker/list` refuses relative or missing paths with
///   `directory-picker/unreadable`; a native-picker Host refuses it with
///   `directory-picker/unavailable`.
library;

import 'errors.dart';
import 'json.dart';
import 'models.dart';
import 'session_api.dart';

/// One folder row of a [DirectoryLevel]: a child or a breadcrumb ancestor.
class DirectoryEntry {
  const DirectoryEntry({required this.name, required this.path, this.hidden = false});

  factory DirectoryEntry.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return DirectoryEntry(
      name: asString(map['name']) ?? '',
      path: asString(map['path']) ?? '',
      hidden: map['hidden'] == true,
    );
  }

  /// Base name (a root crumb carries its full path, e.g. `/`).
  final String name;

  /// Absolute Host path; clients never join segments themselves.
  final String path;

  /// Dot-prefixed on POSIX; the client decides whether to show it.
  final bool hidden;
}

/// One `directoryPicker/list` level: the folder, its ancestry and its child
/// folders (name-sorted, symlinks to folders included).
class DirectoryLevel {
  const DirectoryLevel({
    required this.path,
    required this.home,
    required this.crumbs,
    required this.entries,
    this.truncated = false,
  });

  factory DirectoryLevel.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    final path = asString(map['path']) ?? '';
    final crumbs = asListOrEmpty(map['crumbs']).map(DirectoryEntry.fromJson).toList(growable: false);
    return DirectoryLevel(
      path: path,
      home: asString(map['home']) ?? '',
      crumbs: crumbs.isEmpty && path.isNotEmpty ? [DirectoryEntry(name: path, path: path)] : crumbs,
      entries: asListOrEmpty(map['entries']).map(DirectoryEntry.fromJson).toList(growable: false),
      truncated: map['truncated'] == true,
    );
  }

  final String path;

  /// The Host account's home directory.
  final String home;

  /// Root → this folder inclusive; each crumb is a jump target.
  final List<DirectoryEntry> crumbs;
  final List<DirectoryEntry> entries;

  /// The Host cut [entries] at its bound (1,000 by default).
  final bool truncated;

  /// The folder's own name (its last crumb).
  String get name => crumbs.isEmpty ? path : crumbs.last.name;

  /// The parent folder, or null at the filesystem root.
  DirectoryEntry? get parent => crumbs.length < 2 ? null : crumbs[crumbs.length - 2];
}

/// Error codes of the workspace and directory-picker namespaces.
abstract final class WorkspaceErrors {
  /// The folder cannot back a Workspace (missing, a file, relative).
  static const invalidPath = 'workspace/invalid-path';

  /// Another Workspace already has that title.
  static const nameConflict = 'workspace/name-conflict';
  static const notFound = 'workspace/not-found';

  /// The Host composes the native OS chooser, not the in-app browser.
  static const pickerUnavailable = 'directory-picker/unavailable';

  /// Not fully qualified, missing, or not listable.
  static const unreadable = 'directory-picker/unreadable';

  /// A child of that name is already there.
  static const exists = 'directory-picker/exists';
  static const createFailed = 'directory-picker/create-failed';
}

extension WorkspacesApi on DshClient {
  /// Whether this carrier serves the in-app directory browser.
  bool get canBrowseDirectories => supportsEndpoint('directoryPicker/list');

  /// Whether this carrier can create folders (the DSH Remote allow-list
  /// serves listing only).
  bool get canCreateDirectories => supportsEndpoint('directoryPicker/createDirectory');

  /// `directoryPicker/list`: one level; omit [path] for the Host's home.
  Future<DirectoryLevel> browseDirectory([String? path]) async =>
      DirectoryLevel.fromJson(await rpc.call('directoryPicker/list', {'path': ?path}));

  /// `directoryPicker/createDirectory`: one child of [parent]; returns its
  /// absolute path. [name] must be a single path segment.
  Future<String> createDirectory(String parent, String name) async {
    final value = await rpc.call('directoryPicker/createDirectory', {'path': parent, 'name': name});
    final path = asString(value);
    if (path == null || path.isEmpty) {
      throw DshRemoteException(WorkspaceErrors.createFailed, 'the Host returned no path', {'path': parent});
    }
    return path;
  }

  /// `workspace/rename`: a unique, non-blank title.
  Future<Workspace> renameWorkspace(String workspaceId, String title) async {
    final value = asMapOrEmpty(
      await rpc.call('workspace/rename', {
        'request': {'workspaceId': workspaceId, 'title': title},
      }),
    );
    return Workspace.fromJson(value['workspace']);
  }

  /// `workspace/delete`: drops the registration only; the folder and its
  /// Sessions stay (the Sessions become ungrouped).
  Future<void> deleteWorkspace(String workspaceId) async {
    await rpc.call('workspace/delete', {
      'request': {'workspaceId': workspaceId},
    });
  }

  /// `workspace/insertBefore`: moves [workspaceId] before [beforeId] (to the
  /// end without one); returns the full registry order.
  Future<List<String>> moveWorkspace(String workspaceId, {String? beforeId}) async {
    final value = asMapOrEmpty(
      await rpc.call('workspace/insertBefore', {
        'request': {'workspaceId': workspaceId, 'beforeWorkspaceId': ?beforeId},
      }),
    );
    return asStringList(value['workspaceIds']);
  }

  /// `workspace/pinSession`; returns the pin set, most recently pinned first.
  /// Archived Sessions cannot be pinned (archiving clears the pin).
  Future<List<String>> pinSession(String sessionId) async {
    final value = asMapOrEmpty(
      await rpc.call('workspace/pinSession', {
        'request': {'sessionId': sessionId},
      }),
    );
    return asStringList(value['pinnedSessionIds']);
  }

  /// `workspace/unpinSession`; returns the remaining pin set.
  Future<List<String>> unpinSession(String sessionId) async {
    final value = asMapOrEmpty(
      await rpc.call('workspace/unpinSession', {
        'request': {'sessionId': sessionId},
      }),
    );
    return asStringList(value['pinnedSessionIds']);
  }
}

/// The full state carried by a `replace` frame of `workspace/follow` (sent
/// to non-owner Peers when access changes), which the shared parser reports
/// as an [UnknownWorkspaceUpdate]; null for anything else.
WorkspaceBaseline? workspaceReplaceFrame(WorkspaceUpdate update) {
  if (update is! UnknownWorkspaceUpdate || update.raw['type'] != 'replace') return null;
  final value = asMapOrEmpty(update.raw['value']);
  return WorkspaceBaseline(
    asListOrEmpty(value['items']).map(Workspace.fromJson).toList(growable: false),
    asStringList(value['archivedSessionIds']),
    asStringList(value['pinnedSessionIds']),
  );
}
