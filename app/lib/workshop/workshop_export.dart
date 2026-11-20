import 'dart:io';
import 'dart:math';

import 'workshop_models.dart';

/// Resolve the existing parent, including aliases, without following the
/// destination itself. A dangling destination link is still an existing item.
Future<File> workshopExportTarget(File destination) async {
  try {
    final target = File(destination.absolute.uri.normalizePath().toFilePath());
    var parent = target.parent;
    final tail = <String>[target.uri.pathSegments.last];
    while (!await parent.exists()) {
      final next = parent.parent;
      if (next.path == parent.path) workshopInvalid('workshop_storage');
      tail.insert(0, parent.uri.pathSegments.lastWhere((part) => part.isNotEmpty));
      parent = next;
    }
    return File([await parent.resolveSymbolicLinks(), ...tail].join(Platform.pathSeparator));
  } on FileSystemException catch (error) {
    throw _exportStorage(error);
  }
}

Future<void> _exportTail = Future<void>.value();

/// Pet and companion export call this on the owning App isolate, before
/// compute starts. One queue covers both kinds and all destinations, including
/// different spellings that the filesystem treats as the same target. Distinct
/// targets also wait; this is not a cross-isolate or cross-process lock.
/// The writer must only produce its staging file, not await another export.
Future<void> workshopCommitExport(File target, Future<void> Function(File staging) write) {
  final Future<void> run = _exportTail.then((_) async {
    File? staging;
    try {
      Future<void> absent() async {
        if (await FileSystemEntity.type(target.path, followLinks: false) != FileSystemEntityType.notFound) {
          workshopInvalid('workshop_export_exists');
        }
      }
      await absent();
      await target.parent.create(recursive: true);
      final random = Random.secure();
      final nonce = List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      final temporary = File('${target.parent.path}/.workshop-export-$nonce.part');
      staging = temporary;
      await write(temporary);
      if (await FileSystemEntity.type(temporary.path, followLinks: false) != FileSystemEntityType.file) {
        workshopInvalid('workshop_storage');
      }
      // Check at commitment as well: another owner may have created the path
      // while the archive was being generated. Never replace that file.
      await absent();
      await temporary.rename(target.path);
    } on FileSystemException catch (error) {
      throw _exportStorage(error);
    } finally {
      final temporary = staging;
      try { if (temporary != null && await temporary.exists()) await temporary.delete(); }
      on FileSystemException { /* Only the private staging file may remain. */ }
    }
  });
  _exportTail = run.then<void>((_) {}, onError: (_) {});
  return run;
}

WorkshopException _exportStorage(FileSystemException error) => WorkshopException(
  const {28, 122}.contains(error.osError?.errorCode) ? 'workshop_no_space' : 'workshop_storage');
