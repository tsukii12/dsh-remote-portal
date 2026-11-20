part of 'engine.dart';

extension _GameplayPackOperations on TavernEngine {
  Future<TavernPackImportResult> _importGameplayPack(Uint8List bytes) => _authoringOperation(() async {
    final captured = Uint8List.fromList(bytes);
    final pack = await _decodeGameplayPackForImport(captured);
    final existing = _store.readGameplayPackExternalVersion(pack.externalPackId, pack.packVersion);
    if (existing != null) {
      if (existing.digest != pack.digest) {
        throw const TavernGameplayException(
          code: 'version_conflict',
          message: 'This external pack identity and version already contain different bytes.',
        );
      }
      return TavernPackImportResult(version: existing, reused: true);
    }
    final inspection = await _inspectGameplayPack(pack, _clock().toUtc());
    return _commitGameplay<TavernPackImportResult>(
      (onCommitted) => _store.importGameplayPackData(pack, inspection: inspection, onCommitted: onCommitted),
    );
  });

  Future<List<TavernPackVersion>> _listGameplayPacks({bool includeRemoved = false}) =>
      _authoringOperation(() => _store.listGameplayPackVersions(includeRemoved: includeRemoved));

  Future<TavernPackVersion?> _readGameplayPack(TavernPackVersionRef ref) =>
      _authoringOperation(() => _store.readGameplayPackVersion(ref));

  Future<TavernPackResource?> _readGameplayPackResource(TavernPackVersionRef ref, String localId) =>
      _authoringOperation(() => _store.readGameplayPackResource(ref, localId));

  Future<Uint8List> _exportInstalledGameplayPack(TavernPackVersionRef ref) => _authoringOperation(() {
    final bytes = _store.readGameplayPackArchive(ref);
    if (bytes == null) {
      throw const TavernGameplayException(
        code: 'version_not_found',
        message: 'The gameplay pack version does not exist.',
      );
    }
    return bytes;
  });

  Future<TavernPackRemovalReceipt> _removeGameplayPackVersion(
    TavernPackVersionRef ref, {
    required TavernGameplayRevision expected,
    required String operationId,
  }) => _authoringOperation(() {
    if (operationId.isEmpty) {
      throw ArgumentError.value(operationId, 'operationId', 'must not be empty');
    }
    return _commitGameplay<TavernPackRemovalReceipt>(
      (onCommitted) => _store.removeGameplayPackVersionData(
        ref,
        expected: expected,
        operationId: operationId,
        onCommitted: onCommitted,
      ),
    );
  });

  Future<Map<String, Object?>> _inspectGameplayPack(DecodedGameplayPack pack, DateTime checkedAt) =>
      _inspectGameplayPackParts(pack.manifest, pack.files, checkedAt);

  Future<Map<String, Object?>> _inspectGameplayPackParts(
    Map<String, Object?> manifest,
    Map<String, Uint8List> files,
    DateTime checkedAt,
  ) async {
    final resources = <Map<String, Object?>>[];
    for (final resource in gameplayPackResources(manifest)) {
      final localId = resource['localId']! as String;
      final kind = resource['kind']! as String;
      final path = resource['path']! as String;
      final bytes = files[path]!;
      final reports = <Map<String, Object?>>[];
      var diagnostics = <TavernRegexDiagnostic>[];
      var opaque = false;
      if (kind == 'lorebook') {
        final raw = _decodeObject(decodeAuthoringText(bytes).text, 'Gameplay lorebook');
        final book = WorldInfoBook.fromJson(id: localId, source: WorldInfoSource.global, json: raw);
        _checkGameplayBookMappings(resource, book);
        diagnostics = await _checkWorldBookRegex(book);
        reports.add({
          'pointer': '',
          'report': assessImport(
            kind: TavernImportKind.lorebook,
            document: raw,
            regexDiagnostics: diagnostics,
            checkedAt: checkedAt,
          ).toJson(),
        });
      } else if (kind == 'regex') {
        final raw = jsonDecode(decodeAuthoringText(bytes).text);
        if (raw is Map<String, Object?>) {
          _checkGameplayMappings(resource, {''}, {''}, implicitRoot: true);
          diagnostics = [await inspectRegexScript(raw, _regexWorker)];
          reports.add({
            'pointer': '',
            'report': assessImport(
              kind: TavernImportKind.regex,
              document: raw,
              regexDiagnostics: diagnostics,
              checkedAt: checkedAt,
            ).toJson(),
          });
        } else if (raw is List<Object?>) {
          final pointers = <String>{
            for (var i = 0; i < raw.length; i++)
              if (raw[i] is Map<String, Object?>) '/$i',
          };
          _checkGameplayMappings(resource, pointers, pointers);
          diagnostics = await inspectRegexScripts(raw, _regexWorker, path: r'$');
          for (var i = 0; i < raw.length; i++) {
            final item = raw[i];
            if (item is Map<String, Object?>) {
              reports.add({
                'pointer': '/$i',
                'report': assessImport(
                  kind: TavernImportKind.regex,
                  document: item,
                  regexDiagnostics: [diagnostics[i]],
                  checkedAt: checkedAt,
                  path: '\$[$i]',
                ).toJson(),
              });
            }
          }
        } else {
          throw const FormatException('A gameplay regex resource must be an object or an explicit array.');
        }
      } else if (kind == 'castCard') {
        final envelope = const CardCodec().decodeAuthority(bytes);
        diagnostics = await _checkCardRegex(envelope['data']! as Map<String, Object?>);
        reports.add({
          'pointer': '',
          'report': assessImport(
            kind: TavernImportKind.character,
            document: envelope,
            regexDiagnostics: diagnostics,
            checkedAt: checkedAt,
          ).toJson(),
        });
      } else {
        opaque = true;
      }
      resources.add({
        'localId': localId,
        'kind': kind,
        'path': path,
        if (opaque) 'opaque': true,
        'reports': reports,
        'regexDiagnostics': [for (final diagnostic in diagnostics) diagnostic.toJson()],
      });
    }
    return {
      'dshgo': inspectDshgoExtension(manifest['dshgo'], present: manifest.containsKey('dshgo')).toJson(),
      'resources': resources,
    };
  }
}

Future<DecodedGameplayPack> _decodeGameplayPackForImport(Uint8List bytes) =>
    Isolate.run(() => decodeGameplayPack(bytes));

T _commitGameplay<T extends Object>(T Function(void Function(T result) onCommitted) action) {
  T? adopted;
  try {
    return action((result) {
      adopted = result;
    });
  } catch (error, stack) {
    final result = adopted;
    if (result != null) {
      Error.throwWithStackTrace(TavernGameplayCommittedException<T>(result: result, cause: error), stack);
    }
    rethrow;
  }
}

void _checkGameplayBookMappings(Map<String, Object?> resource, WorldInfoBook book) {
  final executable = Set<Map<String, Object?>>.identity()..addAll(book.entries.map((entry) => entry.raw));
  final targets = <String>{};
  final required = <String>{};
  final raw = book.raw['entries'];
  if (raw is Map<String, Object?>) {
    for (final entry in raw.entries) {
      final pointer = '/entries/${_gameplayPointerToken(entry.key)}';
      targets.add(pointer);
      if (executable.contains(entry.value)) {
        required.add(pointer);
      }
    }
  } else {
    final entries = raw! as List<Object?>;
    for (var i = 0; i < entries.length; i++) {
      final pointer = '/entries/$i';
      targets.add(pointer);
      if (executable.contains(entries[i])) {
        required.add(pointer);
      }
    }
  }
  _checkGameplayMappings(resource, targets, required);
}

void _checkGameplayMappings(
  Map<String, Object?> resource,
  Set<String> targets,
  Set<String> required, {
  bool implicitRoot = false,
}) {
  final entries = resource['entries'] as List<Object?>? ?? const <Object?>[];
  if (implicitRoot && entries.isEmpty) {
    // A single regex object already has its resource's stable localId.
    return;
  }
  final mapped = <String>{};
  final localId = resource['localId']! as String;
  for (final item in entries) {
    final entry = item as Map<String, Object?>;
    final pointer = entry['pointer']! as String;
    if (!targets.contains(pointer)) {
      throw FormatException('Resource $localId has an entry pointer outside its actual entries.');
    }
    mapped.add(pointer);
  }
  for (final pointer in required) {
    if (!mapped.contains(pointer)) {
      throw FormatException('Resource $localId requires a stable entry mapping for $pointer.');
    }
  }
}

String _gameplayPointerToken(String key) => key.replaceAll('~', '~0').replaceAll('/', '~1');
