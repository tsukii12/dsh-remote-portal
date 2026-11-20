import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';

import '../backup.dart';

const _backupFormat = 'dshgo-tavern-backup';
const _backupVersion = 1;
const _databaseName = 'tavern.sqlite3';
const _manifestName = 'manifest.json';
const _restoreFormat = 'dshgo-tavern-restore';
final _restoreOwners = <String>{};

/// The shared identity for facade admission and backup/recovery journals.
///
/// The URI ends in a slash, so directory-prefix comparisons preserve component
/// boundaries. Existing paths use native link resolution before URI conversion;
/// missing paths also follow a root alias left dangling between restore renames.
/// This inspects paths only and never creates the requested directory.
Future<String> tavernDirectoryIdentity(Directory directory) async => _rootKey(await _canonicalDirectory(directory));

/// Captures committed files while the facade holds its write-admission barrier.
///
/// [backupDatabase] must use SQLite's backup API, wait for real completion,
/// close its destination handle, and return its actual PRAGMA user_version.
/// The supplied destination does not yet exist. Neither this method nor the
/// callback may abandon an active native backup through Future.timeout.
///
/// The caller may release its barrier when this future completes. Compression
/// only reads the resulting immutable snapshot and can happen afterwards.
/// Root-level character-index is a recoverable cache and is excluded, including
/// any concurrent cache repair triggered by a read-only character watcher.
Future<TavernBackupSnapshot> captureTavernBackup(
  Directory root, {
  required Future<int> Function(File destination) backupDatabase,
  required DateTime createdAt,
}) async {
  final source = await _canonicalDirectory(root);
  if (!await source.exists()) {
    throw FileSystemException('Tavern directory does not exist.', source.path);
  }
  _requireNamedDirectory(source);
  final work = await source.parent.createTemp('.dshgo-tavern-backup-');
  final payload = Directory('${work.path}/data');
  try {
    await payload.create();
    final database = File('${payload.path}/$_databaseName');
    final version = await backupDatabase(database);
    if (version < 0 || await _type(database.path) != FileSystemEntityType.file) {
      throw const FormatException('The database backup did not produce a regular versioned file.');
    }
    final directories = <String>[];
    final paths = <String>[_databaseName];

    Future<void> copyDirectory(Directory directory, String prefix) async {
      final children = await directory.list(followLinks: false).toList();
      children.sort((left, right) => left.path.compareTo(right.path));
      for (final entity in children) {
        final name = _name(entity);
        final relative = prefix.isEmpty ? name : '$prefix/$name';
        if (_excludedSnapshotPath(relative)) {
          continue;
        }
        _checkRelativePath(relative);
        final type = await _type(entity.path);
        if (type == FileSystemEntityType.directory) {
          directories.add(relative);
          await Directory('${payload.path}/$relative').create();
          await copyDirectory(Directory(entity.path), relative);
        } else if (type == FileSystemEntityType.file) {
          await File(entity.path).copy('${payload.path}/$relative');
          paths.add(relative);
        } else {
          throw FileSystemException('A backup only contains regular files and directories.', entity.path);
        }
      }
    }

    await copyDirectory(source, '');
    paths.sort();
    directories.sort();
    _checkPathSet(paths, directories);
    final files = <_SnapshotFile>[];
    var total = 0;
    for (final path in paths) {
      final length = await File('${payload.path}/$path').length();
      files.add(_SnapshotFile(path, length));
      total += length;
    }
    return TavernBackupSnapshot._(
      source,
      work,
      List.unmodifiable(files),
      List.unmodifiable(directories),
      await _capturePersonaAvatars(root, source, payload, files),
      TavernBackupInfo(
        createdAt: createdAt.toUtc(),
        sqliteUserVersion: version,
        fileCount: files.length,
        totalBytes: total,
      ),
    );
  } catch (_) {
    await _discard(work);
    rethrow;
  }
}

/// A detached snapshot. Dispose it after its final ZIP write.
final class TavernBackupSnapshot {
  TavernBackupSnapshot._(this._source, this._work, this._files, this._directories, this._personaAvatars, this.info);

  final Directory _source;
  final Directory _work;
  final List<_SnapshotFile> _files;
  final List<String> _directories;
  final List<_PersonaAvatar> _personaAvatars;
  final TavernBackupInfo info;
  bool _disposed = false;
  Completer<void>? _writer;

  /// Writes to a temporary sibling and publishes only a fully closed ZIP.
  /// The destination must be outside both the live root and this snapshot.
  /// Its raw path must end in a file name, not a separator, dot or dot-dot.
  Future<TavernBackupInfo> writeZip(File destination) async {
    if (_disposed) {
      throw StateError('The backup snapshot has been disposed.');
    }
    if (_writer != null) {
      throw StateError('This snapshot is already being written.');
    }
    final writer = Completer<void>();
    _writer = writer;
    try {
      final name = _backupFileName(destination.path);
      final parent = await _canonicalDirectory(destination.parent);
      final target = File('${parent.path}/$name');
      if (_within(target, _source) || _within(target, _work)) {
        throw ArgumentError('The backup destination must be outside the Tavern directory and snapshot.');
      }
      final targetType = await _type(target.path);
      if (targetType != FileSystemEntityType.notFound && targetType != FileSystemEntityType.file) {
        throw FileSystemException('The backup destination is not a regular file.', target.path);
      }
      await parent.create(recursive: true);
      final workPath = _work.path;
      final fileRecords = _files;
      final directoryNames = _directories;
      final metadata = info;
      final targetPath = target.path;
      final personaAvatars = _personaAvatars;
      await Isolate.run(() => _writeZip(workPath, targetPath, fileRecords, directoryNames, personaAvatars, metadata));
      return info;
    } finally {
      _writer = null;
      writer.complete();
    }
  }

  /// Waits for any active encoder before deleting its input files.
  Future<void> dispose() async {
    _disposed = true;
    await _writer?.future;
    await _discard(_work);
  }
}

/// Restores into a directory whose engine and every database handle are closed.
///
/// The facade owns that admission rule. This module first validates the archive
/// and hashes in an independent sibling directory. [validateStaging] must check
/// the database's actual version against the supplied source version, reject
/// unsupported store versions, run integrity/FK checks and any migrations only
/// in staging, and close every opened handle before returning. It must not
/// re-import cards, execute embedded content, or rewrite opaque resources.
///
/// The input ZIP must be outside the destination, since restoration replaces
/// that whole directory. The returned information describes the source snapshot.
/// Only recorded, backed-up persona avatarPath fields are rebased to the final
/// root before validation; opaque data and external references stay unchanged.
Future<TavernBackupInfo> restoreTavernBackup(
  File archive,
  Directory root, {
  required Future<void> Function(Directory staging, int sourceSqliteUserVersion) validateStaging,
  Future<void> Function(Directory destination)? validateDestination,
}) async {
  final destination = await _canonicalDirectory(root);
  _requireNamedDirectory(destination);
  final owner = _rootKey(destination);
  if (!_restoreOwners.add(owner)) {
    throw StateError('A restore or recovery already owns this Tavern directory.');
  }
  Directory? work;
  var journalPublished = false;
  try {
    final input = File(await archive.resolveSymbolicLinks());
    if (_within(input, destination)) {
      throw ArgumentError('The input backup must be outside the directory being restored.');
    }
    await destination.parent.create(recursive: true);
    await _recover(destination);
    await validateDestination?.call(destination);
    final journalFile = _journalFile(destination);
    if (await _type(journalFile.path) != FileSystemEntityType.notFound) {
      throw StateError('The previous restore still has cleanup pending: ${journalFile.path}');
    }
    final targetType = await _type(destination.path);
    if (targetType != FileSystemEntityType.notFound && targetType != FileSystemEntityType.directory) {
      throw FileSystemException('The restore destination is not a directory.', destination.path);
    }
    work = await destination.parent.createTemp(_workPrefix(destination));
    final incoming = Directory('${work.path}/incoming');
    await incoming.create();
    final inputPath = input.path;
    final incomingPath = incoming.path;
    final workPath = work.path;
    final destinationPath = destination.path;
    final info = await Isolate.run(() => _extractSnapshot(inputPath, incomingPath, workPath, destinationPath));
    await validateStaging(incoming, info.sqliteUserVersion);
    if (await _type(incoming.path) != FileSystemEntityType.directory ||
        await _type('${incoming.path}/$_databaseName') != FileSystemEntityType.file) {
      throw const FormatException('The staging validator removed the restored database.');
    }
    final journal = _RestoreJournal(
      workName: _name(work),
      hadRoot: targetType == FileSystemEntityType.directory,
      phase: 'prepared',
    );
    await _writeJournal(destination, journal);
    journalPublished = true;
    try {
      if (journal.hadRoot) {
        await destination.rename('${work.path}/previous');
      }
      await incoming.rename(destination.path);
      await _writeJournal(destination, journal.withPhase('committed'));
    } catch (error, stack) {
      try {
        await _recover(destination);
      } catch (recoveryError) {
        throw TavernRestoreRecoveryError(journalFile.path, error, recoveryError);
      }
      Error.throwWithStackTrace(error, stack);
    }
    // A committed new root stays usable if deleting the old directory fails.
    // The committed journal remains available for another cleanup attempt.
    await _recover(destination);
    return info;
  } finally {
    if (!journalPublished && work != null) {
      await _discard(work);
    }
    _restoreOwners.remove(owner);
  }
}

/// Must run before a factory creates or opens [root].
///
/// An interrupted, uncommitted directory switch rolls back. A committed switch
/// keeps the new root and retries cleanup. Ambiguous/damaged journals fail
/// closed instead of allowing a factory to silently create an empty database.
Future<void> recoverPendingTavernRestore(Directory root) async {
  final destination = await _canonicalDirectory(root);
  _requireNamedDirectory(destination);
  final owner = _rootKey(destination);
  if (!_restoreOwners.add(owner)) {
    throw StateError('A restore or recovery already owns this Tavern directory.');
  }
  try {
    await _recover(destination);
  } finally {
    _restoreOwners.remove(owner);
  }
}

/// Both the initiating operation and its rollback failed. Leave all journal
/// artifacts in place and run recovery before opening this directory again.
final class TavernRestoreRecoveryError implements Exception {
  const TavernRestoreRecoveryError(this.journalPath, this.cause, this.recoveryError);
  final String journalPath;
  final Object cause;
  final Object recoveryError;

  @override
  String toString() => 'Tavern restoration requires recovery at $journalPath: $cause; rollback: $recoveryError';
}

final class _SnapshotFile {
  const _SnapshotFile(this.path, this.size);
  final String path;
  final int size;
}

final class _ManifestFile {
  const _ManifestFile(this.path, this.size, this.hash);
  final String path;
  final int size;
  final String hash;
}

final class _PersonaAvatar {
  const _PersonaAvatar(this.id, this.sourcePath, this.path);
  final String id;
  final String sourcePath;
  final String path;
}

Future<void> _writeZip(
  String workPath,
  String targetPath,
  List<_SnapshotFile> files,
  List<String> directories,
  List<_PersonaAvatar> personaAvatars,
  TavernBackupInfo info,
) async {
  final manifestFiles = <Map<String, Object?>>[];
  for (final file in files) {
    final source = File('$workPath/data/${file.path}');
    if (await source.length() != file.size) {
      throw const FormatException('The detached backup snapshot changed.');
    }
    manifestFiles.add({'path': file.path, 'size': file.size, 'sha256': await _hash(source)});
  }
  final manifest = utf8.encode(
    jsonEncode({
      'format': _backupFormat,
      'version': _backupVersion,
      'createdAt': info.createdAt.toIso8601String(),
      'sqliteUserVersion': info.sqliteUserVersion,
      'directories': directories,
      'files': manifestFiles,
      if (personaAvatars.isNotEmpty)
        'personaAvatars': [
          for (final avatar in personaAvatars) {'id': avatar.id, 'sourcePath': avatar.sourcePath, 'path': avatar.path},
        ],
    }),
  );
  final target = File(targetPath);
  final outputWork = await target.parent.createTemp('.dshgo-tavern-zip-');
  final temporary = File('${outputWork.path}/backup.zip');
  try {
    final output = OutputFileStream(temporary.path);
    final encoder = ZipFileEncoder();
    try {
      encoder.createWithStream(output);
      encoder.addArchiveFile(ArchiveFile.bytes(_manifestName, manifest));
      encoder.addArchiveFile(ArchiveFile.directory('data/'));
      for (final directory in directories) {
        encoder.addArchiveFile(ArchiveFile.directory('data/$directory/'));
      }
      for (final file in files) {
        final input = InputFileStream('$workPath/data/${file.path}');
        try {
          encoder.addArchiveFile(ArchiveFile.stream('data/${file.path}', input));
        } finally {
          await input.close();
        }
      }
      await encoder.close();
    } finally {
      // ZipFileEncoder.close/addFile do not own every exceptional close path.
      await output.close();
    }
    await temporary.rename(target.path);
  } finally {
    await _discard(outputWork);
  }
}

Future<TavernBackupInfo> _extractSnapshot(
  String archivePath,
  String incomingPath,
  String workPath,
  String destinationPath,
) async {
  final input = InputFileStream(archivePath);
  try {
    final names = <String>{};
    final decoder = ZipDecoder();
    final archive = decoder.decodeStream(
      input,
      verify: true,
      callback: (entry) {
        final path = _archivePath(entry);
        if (!names.add(path)) {
          throw FormatException('Duplicate ZIP entry: $path');
        }
      },
    );
    final byName = <String, ArchiveFile>{for (final entry in archive) _archivePath(entry): entry};
    final manifestEntry = byName[_manifestName];
    if (manifestEntry == null || !manifestEntry.isFile || manifestEntry.size < 0) {
      throw const FormatException('The backup manifest is missing.');
    }
    final manifestFile = File('$workPath/$_manifestName');
    await _extractFile(manifestEntry, manifestFile, manifestEntry.size);
    final value = jsonDecode(await manifestFile.readAsString());
    if (value is! Map<String, Object?> ||
        value['format'] != _backupFormat ||
        value['version'] is! int ||
        value['version'] != _backupVersion) {
      throw const FormatException('Unsupported Tavern backup format or version.');
    }
    final created = value['createdAt'];
    final version = value['sqliteUserVersion'];
    final fileValues = value['files'];
    final directoryValues = value['directories'];
    if (created is! String ||
        DateTime.tryParse(created) == null ||
        version is! int ||
        version < 0 ||
        fileValues is! List<Object?> ||
        directoryValues is! List<Object?>) {
      throw const FormatException('Invalid Tavern backup manifest.');
    }
    final files = <_ManifestFile>[];
    var total = 0;
    for (final item in fileValues) {
      if (item is! Map<String, Object?>) {
        throw const FormatException('Invalid backup file record.');
      }
      final path = item['path'];
      final size = item['size'];
      final hash = item['sha256'];
      if (path is! String || size is! int || size < 0 || hash is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
        throw const FormatException('Invalid backup file record.');
      }
      _checkRelativePath(path);
      if (_excludedSnapshotPath(path) && path != _databaseName) {
        throw FormatException('The backup contains a store artifact excluded from snapshots: $path');
      }
      if (size > 0x7fffffffffffffff - total) {
        throw const FormatException('The backup byte count cannot be represented.');
      }
      files.add(_ManifestFile(path, size, hash));
      total += size;
    }
    final directories = <String>[];
    for (final directory in directoryValues) {
      if (directory is! String) {
        throw const FormatException('Invalid backup directory record.');
      }
      _checkRelativePath(directory);
      if (_excludedSnapshotPath(directory)) {
        throw FormatException('The backup contains a store artifact excluded from snapshots: $directory');
      }
      directories.add(directory);
    }
    _checkPathSet(files.map((file) => file.path), directories);
    if (!files.any((file) => file.path == _databaseName)) {
      throw const FormatException('The backup does not contain its SQLite database.');
    }
    final expected = <String>{
      _manifestName,
      'data',
      for (final directory in directories) 'data/$directory',
      for (final file in files) 'data/${file.path}',
    };
    if (names.length != expected.length || !names.containsAll(expected)) {
      throw const FormatException('The ZIP entries do not match the manifest.');
    }
    if (byName['data']!.isFile) {
      throw const FormatException('The backup data entry is not a directory.');
    }
    for (final directory in directories) {
      if (byName['data/$directory']!.isFile) {
        throw FormatException('A backup directory is encoded as a file: $directory');
      }
      await Directory('$incomingPath/$directory').create(recursive: true);
    }
    for (final file in files) {
      final entry = byName['data/${file.path}']!;
      if (!entry.isFile || entry.size != file.size) {
        throw FormatException('Backup file size or kind does not match: ${file.path}');
      }
      final destination = File('$incomingPath/${file.path}');
      await destination.parent.create(recursive: true);
      await _extractFile(entry, destination, file.size);
      if (await _hash(destination) != file.hash) {
        throw FormatException('Backup checksum does not match: ${file.path}');
      }
    }
    await _rebasePersonaAvatars(value['personaAvatars'], files, incomingPath, destinationPath);
    return TavernBackupInfo(
      createdAt: DateTime.parse(created).toUtc(),
      sqliteUserVersion: version,
      fileCount: files.length,
      totalBytes: total,
    );
  } finally {
    await input.close();
  }
}

String _archivePath(ArchiveFile entry) {
  final fileType = entry.mode & 0xf000;
  if (entry.symbolicLink != null || entry.isHardLink || (fileType != 0 && fileType != 0x8000 && fileType != 0x4000)) {
    throw FormatException('A backup cannot contain linked or special entries: ${entry.name}');
  }
  final path = entry.isDirectory && entry.name.endsWith('/')
      ? entry.name.substring(0, entry.name.length - 1)
      : entry.name;
  _checkRelativePath(path);
  if (path != _manifestName && path != 'data' && !path.startsWith('data/')) {
    throw FormatException('Unexpected ZIP entry: $path');
  }
  return path;
}

Future<void> _extractFile(ArchiveFile entry, File destination, int expectedSize) async {
  final output = _ExactFileOutput(OutputFileStream(destination.path), expectedSize);
  try {
    entry.writeContent(output);
    if (output.length != expectedSize) {
      throw FormatException('A backup entry expanded to an unexpected length: ${entry.name}');
    }
  } finally {
    await output.close();
  }
}

/// The actual decoder output is checked, not just its advertised ZIP length.
/// Payload writes use a file-backed sink instead of ArchiveFile.readBytes.
final class _ExactFileOutput extends OutputStream {
  _ExactFileOutput(this._output, this._expected) : super(byteOrder: _output.byteOrder);
  final OutputFileStream _output;
  final int _expected;

  void _check(int count) {
    if (count < 0 || count > _expected - length) {
      throw const FormatException('A backup entry exceeds its declared length.');
    }
  }

  @override
  int get length => _output.length;
  @override
  bool get isOpen => _output.isOpen;
  @override
  void flush() => _output.flush();
  @override
  Future<void> close() => _output.close();
  @override
  void closeSync() => _output.closeSync();
  @override
  void clear() => throw UnsupportedError('A restored file cannot be cleared.');
  @override
  Uint8List subset(int start, [int? end]) => _output.subset(start, end);

  @override
  void writeByte(int value) {
    _check(1);
    _output.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    _check(count);
    _output.writeBytes(bytes, length: count);
  }

  @override
  void writeRange(Uint8List bytes, int start, int end) {
    _check(end - start);
    _output.writeRange(bytes, start, end);
  }

  @override
  void writeStream(InputStream stream) {
    final position = stream.position;
    final buffer = Uint8List(64 * 1024);
    try {
      while (!stream.isEOS) {
        final count = stream.readInto(buffer, 0, buffer.length);
        if (count <= 0) {
          break;
        }
        writeBytes(buffer, length: count);
      }
    } finally {
      stream.setPosition(position);
    }
  }
}

final class _RestoreJournal {
  const _RestoreJournal({required this.workName, required this.hadRoot, required this.phase});
  final String workName;
  final bool hadRoot;
  final String phase;

  _RestoreJournal withPhase(String value) => _RestoreJournal(workName: workName, hadRoot: hadRoot, phase: value);
}

Future<void> _writeJournal(Directory root, _RestoreJournal journal) async {
  final file = _journalFile(root);
  final temporary = File('${file.path}.writing');
  try {
    await temporary.writeAsString(
      jsonEncode({
        'format': _restoreFormat,
        'version': 1,
        'root': _rootKey(root),
        'workName': journal.workName,
        'hadRoot': journal.hadRoot,
        'phase': journal.phase,
      }),
      flush: true,
    );
    await temporary.rename(file.path);
  } finally {
    await _discard(temporary);
  }
}

Future<void> _recover(Directory root) async {
  final file = _journalFile(root);
  final journalType = await _type(file.path);
  if (journalType == FileSystemEntityType.notFound) {
    try {
      // Unlike type(), identical() preserves lookup errors and does not read
      // file contents or follow the final link. A successful probe is not absence.
      await FileSystemEntity.identical(file.path, file.path);
    } on PathNotFoundException catch (error) {
      final code = error.osError?.errorCode;
      if (code != 2 && !(Platform.isWindows && code == 3)) {
        rethrow;
      }
      if (await _type(file.path) != FileSystemEntityType.notFound) {
        rethrow;
      }
      return;
    }
    throw FileSystemException('The restore journal could not be identified as absent.', file.path);
  }
  if (journalType != FileSystemEntityType.file) {
    throw FileSystemException('The restore journal is not a regular file.', file.path);
  }
  final value = jsonDecode(await file.readAsString());
  if (value is! Map<String, Object?> ||
      value['format'] != _restoreFormat ||
      value['version'] is! int ||
      value['version'] != 1 ||
      value['root'] != _rootKey(root) ||
      value['workName'] is! String ||
      value['hadRoot'] is! bool ||
      value['phase'] is! String) {
    throw FormatException('Invalid Tavern restore journal: ${file.path}');
  }
  final workName = value['workName']! as String;
  final prefix = _workPrefix(root);
  if (!workName.startsWith(prefix) || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(workName.substring(prefix.length))) {
    throw FormatException('Invalid restore workspace name: ${file.path}');
  }
  final journal = _RestoreJournal(
    workName: workName,
    hadRoot: value['hadRoot']! as bool,
    phase: value['phase']! as String,
  );
  if (!const {'prepared', 'committed', 'rolledBack'}.contains(journal.phase)) {
    throw FormatException('Unsupported restore phase: ${journal.phase}');
  }
  final work = Directory('${root.parent.path}/$workName');
  final incoming = Directory('${work.path}/incoming');
  final previous = Directory('${work.path}/previous');
  final workType = await _type(work.path);
  final rootType = await _type(root.path);
  if (rootType != FileSystemEntityType.notFound && rootType != FileSystemEntityType.directory) {
    throw FileSystemException('The recovering Tavern root is not a directory.', root.path);
  }
  if (workType != FileSystemEntityType.notFound && workType != FileSystemEntityType.directory) {
    throw FileSystemException('The restore workspace is not a directory.', work.path);
  }
  if (workType == FileSystemEntityType.notFound) {
    if ((journal.phase == 'committed' && rootType == FileSystemEntityType.directory) ||
        (journal.phase == 'rolledBack' && (rootType == FileSystemEntityType.directory) == journal.hadRoot)) {
      await _discard(file);
      return;
    }
    throw StateError('The restore workspace is missing; keep the journal for recovery: ${file.path}');
  }
  final incomingExists = await _directoryOrMissing(incoming);
  final previousExists = await _directoryOrMissing(previous);
  if (journal.phase == 'committed') {
    if (rootType != FileSystemEntityType.directory || incomingExists) {
      throw StateError('A committed restore has an inconsistent directory state: ${file.path}');
    }
    await _finishCleanup(file, work);
    return;
  }
  if (journal.phase == 'rolledBack') {
    if ((rootType == FileSystemEntityType.directory) != journal.hadRoot || previousExists) {
      throw StateError('A rolled-back restore has an inconsistent directory state: ${file.path}');
    }
    await _finishCleanup(file, work);
    return;
  }
  if (journal.hadRoot) {
    if (previousExists) {
      if (rootType == FileSystemEntityType.directory) {
        if (incomingExists) {
          throw StateError('Both restored roots are present; keep all data for recovery: ${file.path}');
        }
        await root.rename(incoming.path);
      }
      await previous.rename(root.path);
    } else if (rootType != FileSystemEntityType.directory || !incomingExists) {
      throw StateError('The original root cannot be identified for rollback: ${file.path}');
    }
  } else {
    if (previousExists || (rootType == FileSystemEntityType.directory && incomingExists)) {
      throw StateError('An empty-target restore has an inconsistent state: ${file.path}');
    }
    if (rootType == FileSystemEntityType.directory) {
      await root.rename(incoming.path);
    }
  }
  await _writeJournal(root, journal.withPhase('rolledBack'));
  await _finishCleanup(file, work);
}

Future<void> _finishCleanup(File journal, Directory work) async {
  try {
    await work.delete(recursive: true);
    await journal.delete();
  } on FileSystemException {
    // State was committed or rolled back before cleanup started. Keep its
    // journal until deletion succeeds, without making a valid root unusable.
  }
}

Future<bool> _directoryOrMissing(Directory directory) async {
  final type = await _type(directory.path);
  if (type != FileSystemEntityType.notFound && type != FileSystemEntityType.directory) {
    throw FileSystemException('A restore artifact is not a directory.', directory.path);
  }
  return type == FileSystemEntityType.directory;
}

bool _excludedSnapshotPath(String path) {
  if (const {
    _databaseName,
    'tavern.sqlite3-wal',
    'tavern.sqlite3-shm',
    'tavern.sqlite3-journal',
    'settings.json.writing',
    'regex-library.json.writing',
    'personas/index.json.writing',
    'character-index',
  }.contains(path)) {
    return true;
  }
  final parts = path.split('/');
  if (parts.first == 'character-index') {
    return true;
  }
  if (parts.length >= 2 &&
      parts.first == 'characters' &&
      (parts[1].startsWith('.staging-') || parts[1].startsWith('.trash-'))) {
    return true;
  }
  if (parts.length == 2 && parts.first == 'lorebooks' && parts.last.endsWith('.json.writing')) {
    return true;
  }
  return parts.length == 3 &&
      parts.first == 'characters' &&
      const {'card.json.writing', 'import-report.json.writing'}.contains(parts.last);
}

Future<List<_PersonaAvatar>> _capturePersonaAvatars(
  Directory suppliedRoot,
  Directory source,
  Directory payload,
  List<_SnapshotFile> files,
) async {
  if (!files.any((file) => file.path == 'personas/index.json')) {
    return const [];
  }
  final Object? value;
  try {
    value = jsonDecode(await File('${payload.path}/personas/index.json').readAsString());
  } on FormatException {
    // A backup preserves opaque source bytes; the restore loader owns validity.
    return const [];
  }
  if (value is! Map<String, Object?> || value['version'] != 1 || value['personas'] is! List<Object?>) {
    return const [];
  }
  final capturedPaths = {for (final file in files) _pathKey(file.path): file.path};
  final result = <_PersonaAvatar>[];
  for (final item in value['personas']! as List<Object?>) {
    if (item is! Map<String, Object?> || item['id'] is! String || item['avatarPath'] is! String) {
      continue;
    }
    final path = item['avatarPath']! as String;
    final absolute = Platform.isWindows
        ? RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path) || path.startsWith(r'\\')
        : path.startsWith('/');
    if (!absolute) {
      continue;
    }
    final original = File(path);
    if (!_within(original, source) && !_within(original, suppliedRoot.absolute)) {
      continue;
    }
    try {
      final resolved = File(await original.resolveSymbolicLinks());
      if (!_within(resolved, source)) {
        continue;
      }
      final rootParts = source.uri.pathSegments.where((part) => part.isNotEmpty).length;
      final relative = resolved.uri.pathSegments.skip(rootParts).join('/');
      final captured = capturedPaths[_pathKey(relative)];
      if (captured != null) {
        result.add(_PersonaAvatar(item['id']! as String, path, captured));
      }
    } on FileSystemException {
      // Missing references stay unchanged; outside files are never copied.
    }
  }
  return List.unmodifiable(result);
}

Future<void> _rebasePersonaAvatars(
  Object? mappings,
  List<_ManifestFile> files,
  String incomingPath,
  String destinationPath,
) async {
  if (mappings == null) {
    return;
  }
  if (mappings is! List<Object?>) {
    throw const FormatException('Invalid persona avatar mapping.');
  }
  if (mappings.isEmpty) {
    return;
  }
  final filePaths = files.map((file) => file.path).toSet();
  if (!filePaths.contains('personas/index.json')) {
    throw const FormatException('Persona avatar mappings have no persona index.');
  }
  final byId = <String, _PersonaAvatar>{};
  for (final item in mappings) {
    if (item is! Map<String, Object?> ||
        item['id'] is! String ||
        item['sourcePath'] is! String ||
        item['path'] is! String) {
      throw const FormatException('Invalid persona avatar mapping.');
    }
    final id = item['id']! as String;
    final path = item['path']! as String;
    _checkRelativePath(path);
    if (!filePaths.contains(path) || byId.containsKey(id)) {
      throw const FormatException('Duplicate or unbacked persona avatar mapping.');
    }
    byId[id] = _PersonaAvatar(id, item['sourcePath']! as String, path);
  }
  final file = File('$incomingPath/personas/index.json');
  final value = jsonDecode(await file.readAsString());
  if (value is! Map<String, Object?> || value['version'] != 1 || value['personas'] is! List<Object?>) {
    throw const FormatException('Persona avatar mappings have an invalid persona index.');
  }
  final found = <String>{};
  for (final item in value['personas']! as List<Object?>) {
    if (item is! Map<String, Object?> || item['id'] is! String) {
      continue;
    }
    final mapping = byId[item['id']];
    if (mapping == null) {
      continue;
    }
    if (!found.add(mapping.id) || item['avatarPath'] != mapping.sourcePath) {
      throw const FormatException('Persona avatar mapping does not match its source record.');
    }
    item['avatarPath'] = '$destinationPath/${mapping.path}';
  }
  if (found.length != byId.length) {
    throw const FormatException('A mapped persona does not exist in the backup.');
  }
  await file.writeAsString(jsonEncode(value), flush: true);
}

void _checkRelativePath(String path) {
  final parts = path.split('/');
  if (path.isEmpty ||
      path.contains('\\') ||
      path.contains(':') ||
      path.contains('\u0000') ||
      parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
    throw FormatException('Unsafe backup path: $path');
  }
  if (Platform.isWindows &&
      parts.any(
        (part) =>
            part.endsWith('.') ||
            part.endsWith(' ') ||
            RegExp(r'[<>"|?*\x00-\x1f]').hasMatch(part) ||
            RegExp(r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)', caseSensitive: false).hasMatch(part),
      )) {
    throw FormatException('This backup path cannot be represented on Windows: $path');
  }
}

void _checkPathSet(Iterable<String> files, List<String> directories) {
  final all = <String, bool>{};
  for (final path in directories) {
    _checkRelativePath(path);
    if (all.containsKey(_pathKey(path))) {
      throw FormatException('Duplicate backup path: $path');
    }
    all[_pathKey(path)] = false;
  }
  for (final path in files) {
    _checkRelativePath(path);
    if (all.containsKey(_pathKey(path))) {
      throw FormatException('Conflicting backup path: $path');
    }
    all[_pathKey(path)] = true;
  }
  for (final path in all.keys) {
    final parts = path.split('/');
    for (var length = 1; length < parts.length; length++) {
      if (all[parts.take(length).join('/')] != false) {
        throw FormatException('A backup parent directory is missing or is a file: $path');
      }
    }
  }
}

String _pathKey(String path) => Platform.isWindows || Platform.isMacOS ? path.toLowerCase() : path;
String _rootKey(Directory directory) => _pathKey(directory.absolute.uri.toString());
String _rootId(Directory root) => sha256.convert(utf8.encode(_rootKey(root))).toString().substring(0, 16);
String _workPrefix(Directory root) => '.dshgo-restore-${_rootId(root)}-';
File _journalFile(Directory root) => File('${root.parent.path}/.dshgo-restore-${_rootId(root)}.json');

void _requireNamedDirectory(Directory directory) {
  if (directory.absolute.uri.normalizePath() == directory.parent.absolute.uri.normalizePath()) {
    throw ArgumentError('A filesystem root cannot be replaced by a Tavern restore.');
  }
}

String _name(FileSystemEntity entity) => entity.uri.pathSegments.where((part) => part.isNotEmpty).last;

String _backupFileName(String path) {
  // Uri.file removes a final dot/dot-dot, changing the requested destination.
  // Inspect the raw last component before resolving or creating its parent.
  final name = path.split(Platform.isWindows ? RegExp(r'[/\\]') : RegExp('/')).last;
  if (path.isEmpty || name.isEmpty || name == '.' || name == '..') {
    throw ArgumentError.value(path, 'destination', 'The backup destination must end in a file name.');
  }
  return name;
}

bool _within(FileSystemEntity file, Directory root) {
  final path = _pathKey(file.absolute.uri.normalizePath().toString());
  final parent = _rootKey(root);
  return path == parent || path.startsWith(parent);
}

Future<Directory> _canonicalDirectory(Directory directory) => _resolveDirectory(directory.absolute, <String>{});

Future<Directory> _resolveDirectory(Directory directory, Set<String> resolvingLinks) async {
  final absolute = directory.absolute;
  final followedType = await FileSystemEntity.type(absolute.path);
  if (followedType == FileSystemEntityType.directory) {
    // Directory.uri already removes dot segments. Keep the raw path here so
    // the OS resolves link/.. in its own order (different on POSIX/Windows).
    return Directory(await absolute.resolveSymbolicLinks());
  }
  if (followedType != FileSystemEntityType.notFound) {
    throw FileSystemException('A parent path is not a directory.', absolute.path);
  }

  // A trailing separator follows a dangling directory link even with lstat.
  // Strip it for the link inspection, preserving POSIX and Windows drive roots.
  var path = absolute.path;
  while (path.length > 1 && (path.endsWith('/') || (Platform.isWindows && path.endsWith(r'\')))) {
    if (Platform.isWindows && path[path.length - 2] == ':') {
      break;
    }
    path = path.substring(0, path.length - 1);
  }
  final current = Directory(path);
  final parent = current.parent;
  if (parent.path == path) {
    throw FileSystemException('No existing ancestor for the Tavern path.', absolute.path);
  }
  final name = path.split(Platform.isWindows ? RegExp(r'[/\\]') : RegExp('/')).last;
  final resolvedParent = await _resolveDirectory(parent, resolvingLinks);
  if (name == '.') {
    return resolvedParent;
  }
  if (name == '..') {
    return resolvedParent.parent;
  }
  final candidate = Directory('${resolvedParent.path}/$name');
  final type = await _type(candidate.path);
  if (type == FileSystemEntityType.directory) {
    return Directory(await candidate.resolveSymbolicLinks());
  }
  if (type == FileSystemEntityType.notFound) {
    return candidate;
  }
  if (type != FileSystemEntityType.link) {
    throw FileSystemException('A parent path is not a directory.', candidate.path);
  }
  final identity = candidate.absolute.uri.toString();
  if (!resolvingLinks.add(identity)) {
    throw FileSystemException('A Tavern directory alias contains a link cycle.', candidate.path);
  }
  try {
    final target = await Link(candidate.path).target();
    final targetDirectory = Directory(target);
    return await _resolveDirectory(
      targetDirectory.isAbsolute ? targetDirectory : Directory('${resolvedParent.path}/$target'),
      resolvingLinks,
    );
  } finally {
    resolvingLinks.remove(identity);
  }
}

Future<FileSystemEntityType> _type(String path) => FileSystemEntity.type(path, followLinks: false);
Future<String> _hash(File file) async => (await sha256.bind(file.openRead()).first).toString();

Future<void> _discard(FileSystemEntity entity) async {
  try {
    if (await _type(entity.path) != FileSystemEntityType.notFound) {
      await entity.delete(recursive: true);
    }
  } on FileSystemException {
    // Cleanup is best-effort; never hide the operation's original failure.
  }
}
