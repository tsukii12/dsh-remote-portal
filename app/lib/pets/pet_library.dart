// Pets the person brings: a schema-1 pack (docs/design/pets.md §3) zipped,
// unpacked into `<app support>/pets/<id>/`, which on Android is the very
// `files/pets/<id>/` the overlay falls back to (PetSprites.kt `sourceFor`:
// pack.json and the sheets side by side, nothing in folders).
//
// A pack from outside goes through the same parse as the built-in ones
// (PetPack.parse), then what the overlay's stricter parser (PetPack.kt) asks
// of it, then what a file nobody here made needs: safe names, whole PNG
// sheets with every cell inside them, and the format's size caps. Only
// pack.json and the sheets it names are kept; anything else in the zip is
// left behind.
//
// Installs and removals swap whole folders by rename, one at a time; what an
// interrupted one leaves (`.old-*`, `.trash-*`, `.staging-*`) is put right
// before the folder is next listed or read.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'codex_pet_converter.dart';
import 'overlay_channel.dart' show petOverlayChannelProvider;
import 'pet_pack.dart';
import 'pet_pack_validator.dart';
import '../workshop/workshop_models.dart';
import '../workshop/workshop_receipt.dart';
import '../workshop/workshop_export.dart';

export 'pet_pack_validator.dart' show petSheetDecodedCap, petSheetSideCap, overlayPackProblem, pngSize, pngIntact;

part 'pet_library_export.dart';

/// Ids of brought pets start with this; the built-in ones never do.
const userPetPrefix = 'user-';

bool isUserPet(String id) => id.startsWith(userPetPrefix);

/// Why a zip was turned away.
enum PetImportProblem {
  /// Not a zip at all.
  notAZip,

  /// No pack.json or Codex pet.json at its top (or in one top folder).
  noPack,

  /// pack.json didn't parse as a schema-1 pack; [PetImportException.detail] says where.
  badPack,

  /// A sheet pack.json names isn't in the zip.
  missingSheet,

  /// A sheet isn't a whole PNG, is too big, or its cells don't fit in it.
  badSheet,

  /// Bigger than a pet should be.
  tooLarge,

  /// The phone wouldn't let it be written.
  storage,
}

class PetImportException implements Exception {
  const PetImportException(this.problem, [this.detail, this.osErrorCode]);

  final PetImportProblem problem;
  final String? detail;
  final int? osErrorCode;

  @override
  String toString() => 'PetImportException(${problem.name}${detail == null ? '' : ': $detail'})';
}

/// A folder name as kept here: lower-case letters and digits in dash-joined runs.
final _plainId = RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$');

/// A replaced pet's folder while its replacement goes in: `.old-<stamp>-<id>`.
final _backupName = RegExp(r'^\.old-(\d+)-(user-[a-z0-9-]+)$');

/// Where brought pets are kept (tests swap in a temporary folder).
final petLibraryProvider = Provider<PetLibrary>(
  (ref) => PetLibrary(
    () async => Directory('${(await getApplicationSupportDirectory()).path}/pets'),
    // The overlay may have looked while the pet was away and marked it
    // broken (PetOverlay's failedIds): it reads it again.
    onRestored: (id) => unawaited(ref.read(petOverlayChannelProvider).reloadPack(id)),
  ),
);

/// The brought pets on this phone.
class PetLibrary {
  PetLibrary(this._root, {this.onRestored}) : _readWorkshopReceipt = WorkshopReceipt.read;

  /// Injects one listing read boundary; installs and receipt-fenced removals
  /// still use their real files and the ordinary transaction path.
  @visibleForTesting
  PetLibrary.withWorkshopReceiptReader(this._root, {
    required Future<WorkshopReceipt?> Function(Directory) readReceipt,
    this.onRestored,
  }) : _readWorkshopReceipt = readReceipt;

  final Future<WorkshopReceipt?> Function(Directory) _readWorkshopReceipt;

  /// `<app support>/pets` (tests: a temporary folder).
  final Future<Directory> Function() _root;

  /// A pet an interrupted replacement had taken away is back from its backup.
  final void Function(String id)? onRestored;

  /// The tail of the queue: installs, removals, listings and reads run one at
  /// a time, so none sees another's folders half swapped.
  Future<void> _queue = Future.value();

  Future<T> _exclusive<T>(Future<T> Function() body) {
    final run = _queue.then((_) => body());
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<Directory> folder(String id) async => Directory('${(await _root()).path}/$id');

  /// Every brought pet that still parses, oldest first.
  Future<List<PetPack>> list() => _exclusive(() async {
    final root = await _root();
    await _tidy(root);
    if (!await root.exists()) return const <PetPack>[];
    final found = <(DateTime, PetPack)>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final id = _nameOf(entity);
      if (!isUserPet(id)) continue;
      try {
        final json = File('${entity.path}/pack.json');
        found.add((await json.lastModified(), await _load(root, id)));
      } on Object {
        // Half there or broken: not offered.
      }
    }
    found.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final (_, pack) in found) pack];
  });

  /// One brought pet, reading its sheets from its folder.
  Future<PetPack> load(String id) => _exclusive(() async {
    final root = await _root();
    await _tidy(root);
    return _load(root, id);
  });

  /// Checks and unpacks [zip]; a pet with the same id is replaced. Returns
  /// its id and whether it replaced one.
  Future<({String id, bool replaced})> install(File zip, {WorkshopReceipt? workshop, bool replaceExisting = false}) => _exclusive(() async {
    final root = await _root();
    await _tidy(root);
    final (:id, :backup) = await compute(_install, (zip.path, root.path, DateTime.now().microsecondsSinceEpoch,
      workshop == null ? null : jsonEncode(workshop.toJson()), replaceExisting));
    // The new one is in: the old one's folder goes when it can (else on a
    // later tidy), which is no reason to call the install failed.
    if (backup != null) await _discard(Directory(backup));
    return (id: id, replaced: backup != null);
  });

  Future<WorkshopReceipt?> workshopReceipt(String id) => _exclusive(() async {
    if (!isUserPet(id) || !_plainId.hasMatch(id)) workshopInvalid('workshop_install_record');
    final root = await _root();
    await _tidy(root);
    final receipt = await WorkshopReceipt.read(Directory('${root.path}/$id'));
    if (receipt != null && (receipt.kind != 'pet' || userPetIdFor(receipt.id) != id)) workshopInvalid('workshop_install_record');
    return receipt;
  });

  /// One result per workshop directory. A broken pack retains its trusted
  /// receipt for removal; an unreadable or invalid receipt has no identity.
  /// Root enumeration failures still fail the listing as a whole.
  Future<Map<String, ({WorkshopReceipt? receipt, String? issue})>> workshopReceipts() => _exclusive(() async {
    final root = await _root();
    await _tidy(root);
    if (!await root.exists()) return const {};
    final found = <String, ({WorkshopReceipt? receipt, String? issue})>{};
    await for (final dir in root.list(followLinks: false)) {
      if (dir is! Directory) continue;
      final id = _nameOf(dir);
      if (!isUserPet(id) || !_plainId.hasMatch(id)) continue;
      WorkshopReceipt? receipt;
      try {
        receipt = await _readWorkshopReceipt(dir);
        if (receipt == null) continue;
        if (receipt.kind != 'pet' || userPetIdFor(receipt.id) != id) workshopInvalid('workshop_install_record');
      } on FileSystemException {
        found[id] = (receipt: null, issue: 'workshop_storage');
        continue;
      } on WorkshopException {
        found[id] = (receipt: null, issue: 'workshop_install_record');
        continue;
      }
      try {
        await _load(root, id);
        found[id] = (receipt: receipt, issue: null);
      } on FileSystemException {
        found[id] = (receipt: receipt, issue: 'workshop_storage');
      } on FormatException {
        found[id] = (receipt: receipt, issue: 'workshop_pet_bad_pack');
      }
    }
    return found;
  });

  /// A normalized schema-1 archive containing only the manifest and its
  /// referenced PNGs. Unknown metadata and local workshop receipts stay out.
  /// Public attribution overrides are explicit, for a new workshop submission.
  Future<File> exportZip(String id, File destination, {String? publicId, String? author, String? license, String? source}) => _exclusive(() async {
    if (!isUserPet(id) || !_plainId.hasMatch(id)) throw const PetImportException(PetImportProblem.noPack);
    final root = await _root();
    await _tidy(root);
    final target = await workshopExportTarget(destination);
    final output = target.path;
    final home = await root.exists() ? await root.resolveSymbolicLinks() : root.absolute.uri.normalizePath().toFilePath();
    final prefix = home.endsWith(Platform.pathSeparator) ? home : '$home${Platform.pathSeparator}';
    if (output == home || output.startsWith(prefix)) throw const PetImportException(PetImportProblem.storage);
    await workshopCommitExport(target, (staging) => compute(_exportPet, ('${root.path}/$id', staging.path, <String, String>{
      'id': ?publicId, 'author': ?author, 'license': ?license, 'source': ?source,
    })));
    return destination;
  });

  /// Removes a brought pet. It leaves in one rename, so a removal that fails
  /// leaves it whole; its files are then deleted when they can be. Backups
  /// of it an earlier replacement couldn't delete are moved to the trash
  /// first: left as `.old-*`, the next tidy would bring the pet back.
  Future<void> remove(String id, {WorkshopReceipt? expectedWorkshop}) async {
    if (!isUserPet(id) || !_plainId.hasMatch(id)) return;
    await _exclusive(() async {
      final root = await _root();
      if (!await root.exists()) return;
      if (expectedWorkshop != null) await workshopCheckRemoval(Directory('${root.path}/$id'), expectedWorkshop);
      final going = await root
          .list(followLinks: false)
          .where((e) => e is Directory && _backupName.firstMatch(_nameOf(e))?[2] == id)
          .cast<Directory>()
          .toList();
      final dir = Directory('${root.path}/$id');
      if (await dir.exists()) going.add(dir);
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final trash = <Directory>[];
      try {
        // The pet itself last: if a backup won't move, the pet is still whole.
        for (final dir in going) {
          trash.add(await dir.rename('${root.path}/.trash-$stamp-${trash.length}-$id'));
        }
      } finally {
        for (final dir in trash) {
          await _discard(dir);
        }
      }
    });
  }

  Future<PetPack> _load(Directory root, String id) async {
    final dir = '${root.path}/$id';
    final json = jsonDecode(await File('$dir/pack.json').readAsString());
    if (json is! Map<String, Object?>) throw const FormatException('pack.json');
    final pack = PetPack.parse(json, dir: dir);
    if (pack.id != id) throw const FormatException('pack.json: id');
    return pack;
  }

  /// Puts right what an interrupted install or removal left (the app killed
  /// between its steps): a pet whose replacement never landed comes back
  /// from its backup; a backup whose pet is there (the replacement landed),
  /// a removed pet's trash and abandoned staging go. Run inside
  /// [_exclusive], so nothing it finds is still in use.
  Future<void> _tidy(Directory root) async {
    if (!await root.exists()) return;
    final backups = <String, List<(int, Directory)>>{};
    final junk = <Directory>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = _nameOf(entity);
      if (_backupName.firstMatch(name) case final m?) {
        (backups[m[2]!] ??= []).add((int.parse(m[1]!), entity));
      } else if (name.startsWith('.staging-') || name.startsWith('.trash-')) {
        junk.add(entity);
      }
    }
    for (final MapEntry(key: id, value: found) in backups.entries) {
      found.sort((a, b) => b.$1.compareTo(a.$1));
      var restored = false;
      if (!await Directory('${root.path}/$id').exists()) {
        try {
          await found.first.$2.rename('${root.path}/$id');
          restored = true;
          onRestored?.call(id);
        } on FileSystemException {
          continue; // Tried again next time; nothing of it is thrown away meanwhile.
        }
      }
      junk.addAll([for (final (_, dir) in found.skip(restored ? 1 : 0)) dir]);
    }
    for (final dir in junk) {
      await _discard(dir);
    }
  }
}

String _nameOf(FileSystemEntity entity) => entity.uri.pathSegments.lastWhere((s) => s.isNotEmpty);

/// Deletes [dir] if it can; what stays is deleted on a later tidy.
Future<void> _discard(Directory dir) async {
  try {
    await dir.delete(recursive: true);
  } on FileSystemException {
    // Busy or not allowed right now.
  }
}

/// The id a pack is kept under, after [userPetPrefix]. An id that already is
/// a plain folder name is kept as it is (with the prefix, which a pack
/// exported from here already has), so the same pet brought again replaces
/// itself. Any other is made folder-safe and told apart by a short hash of
/// the whole id: 「小猫」 and 「小狗」, `my cat` and `My Cat` stay two pets.
@visibleForTesting
String userPetIdFor(String packId) {
  final bare = packId.startsWith(userPetPrefix) ? packId.substring(userPetPrefix.length) : packId;
  if (bare.length <= 48 && _plainId.hasMatch(bare)) return '$userPetPrefix$bare';
  var slug = bare.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  if (slug.length > 32) slug = slug.substring(0, 32).replaceAll(RegExp(r'-+$'), '');
  final hash = sha256.convert(utf8.encode(packId)).toString().substring(0, 8);
  return '$userPetPrefix${slug.isEmpty ? 'pet' : slug}-$hash';
}

Future<Uint8List> _readArchive(File file) async {
  final input = await file.open();
  try {
    if (await input.length() > petArchiveByteCap) throw const PetValidationException('archive-size');
    final output = BytesBuilder(copy: false);
    var total = 0;
    while (total <= petArchiveByteCap) {
      final remaining = petArchiveByteCap + 1 - total;
      final chunk = await input.read(remaining < 65536 ? remaining : 65536);
      if (chunk.isEmpty) break;
      output.add(chunk);
      total += chunk.length;
    }
    if (total > petArchiveByteCap) throw const PetValidationException('archive-size');
    return output.takeBytes();
  } finally {
    await input.close();
  }
}

PetImportException _importProblem(PetValidationException error) {
  final code = error.code;
  final detail = error.path ?? code;
  if (const {
    'archive-size',
    'archive-entries',
    'archive-expanded-size',
    'archive-member-size',
    'pack-size',
    'pack-normalized-size',
    'sheet-size',
    'sheet-count',
    'sheet-total-size',
  }.contains(code)) {
    return PetImportException(PetImportProblem.tooLarge, detail);
  }
  if (code == 'sheet-missing' || code == 'archive-member-missing') {
    return PetImportException(PetImportProblem.missingSheet, detail);
  }
  if (code == 'archive-path' ||
      code.startsWith('sheet-') ||
      code.startsWith('png-') ||
      code == 'codex-sheet-name' ||
      code == 'codex-atlas-size' ||
      code.startsWith('codex-webp-')) {
    return PetImportException(PetImportProblem.badSheet, detail);
  }
  if (code.startsWith('json-') ||
      code.startsWith('pack-') ||
      code.startsWith('codex-') ||
      code.startsWith('metadata-') ||
      code.startsWith('market-') ||
      code == 'archive-pack-count') {
    return PetImportException(PetImportProblem.badPack, detail);
  }
  return PetImportException(PetImportProblem.notAZip, detail);
}

Future<({String id, String? backup})> _install((String, String, int, String?, bool) args) async {
  final (zipPath, rootPath, stamp, receiptJson, replaceExisting) = args;
  final staging = Directory('$rootPath/.staging-$stamp');
  try {
    final archive = PetArchive.read(await _readArchive(File(zipPath)));
    final ValidatedPetPack validated;
    if (archive.manifestPaths('pack.json').isNotEmpty) {
      // A schema-1 manifest is authoritative; a bad pack never falls back to
      // a second format hidden in the same archive.
      validated = PetPackValidator.validatePetArchive(archive);
    } else {
      if (archive.manifestPaths('pet.json').isEmpty) throw const PetImportException(PetImportProblem.noPack);
      validated = CodexPetConverter.convert(archive).validated;
    }
    final json = validated.json, pack = validated.pack, bytes = validated.sheets;
    if (receiptJson != null) {
      final receipt = WorkshopReceipt.fromJson(jsonDecode(receiptJson));
      if (receipt.kind != 'pet' || receipt.id != pack.id) throw const PetImportException(PetImportProblem.badPack, 'workshop_identity');
    }

    // Written aside, then swapped in, so a pet is never half there.
    final id = userPetIdFor(pack.id);
    await staging.create(recursive: true);
    for (final MapEntry(key: sheet, value: data) in bytes.entries) {
      await File('${staging.path}/$sheet').writeAsBytes(data, flush: true);
    }
    // What the app read where pack.json left it out, spelled out for the
    // overlay: it requires a scale, and reads a missing pixelArt the other way.
    final kept = {...json, 'id': id, 'scale': pack.scale, 'pixelArt': pack.pixelArt};
    await File('${staging.path}/pack.json').writeAsString(jsonEncode(kept), flush: true);
    if (receiptJson != null) await File('${staging.path}/$workshopReceiptName').writeAsString(receiptJson, flush: true);
    final live = Directory('$rootPath/$id');
    if (receiptJson != null) await workshopCheckReplacement(live, WorkshopReceipt.fromJson(jsonDecode(receiptJson)), replaceExisting: replaceExisting);
    final old = Directory('$rootPath/.old-$stamp-$id');
    final replaced = await live.exists();
    if (replaced) await live.rename(old.path);
    try {
      await staging.rename(live.path);
    } on FileSystemException {
      // Killed here, or this fails too: the next tidy brings the old one back.
      if (replaced) await old.rename(live.path);
      rethrow;
    }
    return (id: id, backup: replaced ? old.path : null);
  } on PetValidationException catch (error) {
    throw _importProblem(error);
  } on PetImportException {
    rethrow;
  } on FileSystemException catch (error) {
    throw PetImportException(PetImportProblem.storage, error.osError?.message, error.osError?.errorCode);
  } finally {
    if (await staging.exists()) await _discard(staging);
  }
}
