part of 'pet_library.dart';

Map<String, Object?> _petFields(Object? input, Iterable<String> keys) {
  final map = input is Map ? input : const {};
  return {for (final key in keys)
    if (map[key] is String || map[key] is bool || map[key] is num && (map[key] as num).isFinite) key: map[key],
  };
}

/// Copy only format fields, at each object boundary. In particular an extra
/// `key` next to an animation/rectangle cannot hitch a ride in its container.
Map<String, Object?> _petExportJson(Map<String, Object?> raw) {
  final out = _petFields(raw, ['schema', 'id', 'name', 'author', 'license', 'source', 'pixelArt', 'scale']);
  for (final entry in {
    'canvas': ['w', 'h'], 'anchor': ['x', 'baseline'], 'contentBox': ['x', 'y', 'w', 'h'],
    'roam': ['anim', 'faces', 'facing', 'flip'], 'sleep': ['afterMs'],
  }.entries) {
    if (raw.containsKey(entry.key)) out[entry.key] = _petFields(raw[entry.key], entry.value);
  }
  final animations = raw['animations'] as Map;
  out['animations'] = {
    for (final entry in animations.entries) entry.key: {
      ..._petFields(entry.value, ['sheet', 'frameW', 'frameH', 'cols', 'loop']),
      'box': _petFields((entry.value as Map)['box'], ['x', 'y', 'w', 'h']),
      'frames': [for (final frame in (entry.value as Map)['frames'] as List) _petFields(frame, ['i', 'ms'])],
    },
  };
  // These maps contain only parser-checked scalar names/numbers or lists.
  final pack = PetPack.parse(raw);
  out['states'] = pack.states;
  if (pack.reactions.isNotEmpty) {
    // Numbered names (tickle, tickle2, …) rather than a list: older apps read
    // only the plain first name and ignore the numbered ones, so the exported
    // pack stays usable on them.
    out['reactions'] = {
      for (final entry in pack.reactions.entries)
        for (final (index, name) in entry.value.indexed)
          (index == 0 ? entry.key : '${entry.key}${index + 1}'): name,
    };
  }
  if (pack.tiers.isNotEmpty) {
    out['tiers'] = {
      for (final tier in pack.tiers.entries) tier.key: [for (final item in tier.value) {'min': item.min, 'anim': item.anim}],
    };
  }
  final timings = _petFields(raw['timings'], ['wakeMs']);
  if (pack.minDisplay.isNotEmpty) timings['minDisplay'] = pack.minDisplay;
  if (pack.autoReturn.isNotEmpty) timings['autoReturn'] = pack.autoReturn;
  if (pack.playMs.isNotEmpty) timings['playMs'] = pack.playMs;
  if (timings.isNotEmpty) out['timings'] = timings;
  final hits = raw['hitBoxes'];
  if (hits is Map) {
    out['hitBoxes'] = {
      for (final key in ['default', 'wide', 'sleeping']) if (hits[key] is Map) key: _petFields(hits[key], ['x', 'y', 'w', 'h']),
      for (final key in ['wideAnims', 'sleepingAnims']) if (hits[key] is List) key: (hits[key] as List).whereType<String>().toList(),
      if (hits['byAnim'] is Map) 'byAnim': {
        for (final entry in (hits['byAnim'] as Map).entries) entry.key: _petFields(entry.value, ['x', 'y', 'w', 'h']),
      },
    };
  }
  if (pack.idlePool.isNotEmpty) {
    out['idlePool'] = {
      'anims': [for (final item in pack.idlePool) {'anim': item.anim, 'ms': item.ms, 'weight': item.weight}],
      'everyMs': {'mean': pack.idleEvery.mean, 'min': pack.idleEvery.min, 'max': pack.idleEvery.max},
    };
  }
  if (pack.bonus.isNotEmpty) {
    out['bonus'] = {
      for (final entry in pack.bonus.entries) entry.key: {'anims': entry.value.anims, 'chance': entry.value.chance},
    };
  }
  return out;
}

Future<Uint8List> _petExportRead(File file, int cap) async {
  if (await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.file) {
    throw const PetImportException(PetImportProblem.missingSheet);
  }
  final input = await file.open();
  try {
    if (await input.length() > cap) throw const PetImportException(PetImportProblem.tooLarge);
    final bytes = BytesBuilder(copy: false);
    while (bytes.length <= cap) {
      final remaining = cap + 1 - bytes.length;
      final chunk = await input.read(remaining < 65536 ? remaining : 65536);
      if (chunk.isEmpty) break;
      bytes.add(chunk);
    }
    if (bytes.length > cap) throw const PetImportException(PetImportProblem.tooLarge);
    return bytes.takeBytes();
  } finally { await input.close(); }
}

Future<void> _exportPet((String, String, Map<String, String>) args) async {
  final (folder, destination, attribution) = args;
  final temporary = File('$destination.part-${DateTime.now().microsecondsSinceEpoch}');
  try {
    if (await FileSystemEntity.type(folder, followLinks: false) != FileSystemEntityType.directory) {
      throw const PetImportException(PetImportProblem.noPack);
    }
    final decoded = decodePetJson(await _petExportRead(File('$folder/pack.json'), petJsonCap));
    if (decoded is! Map<String, Object?>) throw const PetImportException(PetImportProblem.badPack);
    final pack = PetPack.parse(decoded), sheets = <String, Uint8List>{};
    final names = pack.animations.values.map((a) => a.sheet).toSet();
    if (names.length > petSheetCountCap) throw const PetImportException(PetImportProblem.tooLarge);
    var total = 0;
    for (final name in names) {
      if (name.startsWith('.') || name.contains('/') || name.contains('\\') || name.contains('\u0000') ||
          !name.toLowerCase().endsWith('.png') || name.length > petSheetNameCap || utf8.encode(name).length > 255) {
        throw const PetImportException(PetImportProblem.badSheet);
      }
      final remaining = petTotalSheetByteCap - total;
      final bytes = await _petExportRead(File('$folder/$name'), remaining < petSheetByteCap ? remaining : petSheetByteCap);
      total += bytes.length;
      sheets[name] = bytes;
    }
    final json = {..._petExportJson(decoded), ...attribution};
    final checked = PetPackValidator.validateParts(json, sheets);
    final archive = Archive()..add(ArchiveFile.bytes('pack.json', utf8.encode(jsonEncode(checked.json))));
    for (final entry in checked.sheets.entries) { archive.add(ArchiveFile.bytes(entry.key, entry.value)); }
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
    PetPackValidator.validateArchive(bytes);
    final target = File(destination);
    if (await target.exists()) throw const PetImportException(PetImportProblem.storage, 'export_exists');
    await target.parent.create(recursive: true);
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(destination);
  } on PetValidationException catch (error) {
    throw _importProblem(error);
  } on FormatException {
    throw const PetImportException(PetImportProblem.badPack);
  } on FileSystemException catch (error) {
    throw PetImportException(PetImportProblem.storage, null, error.osError?.errorCode);
  } finally {
    try { if (await temporary.exists()) await temporary.delete(); } on FileSystemException { /* A later cache cleanup can remove it. */ }
  }
}
