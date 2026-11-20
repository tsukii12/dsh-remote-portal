part of 'chat_store.dart';

const _gameplayPackSchema = '''
CREATE TABLE gameplay_packs (
  installed_pack_id TEXT NOT NULL PRIMARY KEY,
  external_pack_id TEXT NOT NULL UNIQUE
);
CREATE TABLE gameplay_pack_versions (
  installed_pack_id TEXT NOT NULL,
  pack_version TEXT NOT NULL,
  manifest_raw TEXT NOT NULL,
  digest TEXT NOT NULL,
  original_zip BLOB NOT NULL,
  inspection_json TEXT NOT NULL,
  availability_revision INTEGER NOT NULL,
  removed INTEGER NOT NULL,
  PRIMARY KEY (installed_pack_id, pack_version),
  FOREIGN KEY (installed_pack_id) REFERENCES gameplay_packs(installed_pack_id)
);
CREATE TABLE gameplay_pack_files (
  installed_pack_id TEXT NOT NULL,
  pack_version TEXT NOT NULL,
  path TEXT NOT NULL,
  bytes BLOB NOT NULL,
  PRIMARY KEY (installed_pack_id, pack_version, path),
  FOREIGN KEY (installed_pack_id, pack_version)
    REFERENCES gameplay_pack_versions(installed_pack_id, pack_version)
);
CREATE TABLE gameplay_operations (
  domain_id TEXT NOT NULL,
  operation_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  request_json TEXT NOT NULL,
  result_json TEXT NOT NULL,
  PRIMARY KEY (domain_id, operation_id)
);
''';

const _gameplayVersionColumns = '''
  p.installed_pack_id,
  char(1) || p.external_pack_id AS external_pack_id,
  char(1) || v.pack_version AS pack_version,
  char(1) || v.manifest_raw AS manifest_raw,
  v.digest, v.inspection_json, v.availability_revision, v.removed''';

extension GameplayPackStore on ChatStore {
  TavernPackImportResult importGameplayPackData(
    DecodedGameplayPack pack, {
    required Map<String, Object?> inspection,
    void Function(TavernPackImportResult result)? onCommitted,
  }) {
    late TavernPackImportResult result;
    return transaction(
      () {
        final domain = authoringDomainId;
        final existing = _readGameplayExternalRow(pack.externalPackId, pack.packVersion);
        if (existing != null) {
          if (existing['digest'] != pack.digest) {
            throw const TavernGameplayException(
              code: 'version_conflict',
              message: 'This external pack identity and version already contain different bytes.',
            );
          }
          result = TavernPackImportResult(version: _gameplayVersion(existing, domain), reused: true);
          return result;
        }
        final installed = _db.select('SELECT installed_pack_id FROM gameplay_packs WHERE external_pack_id = ?', [
          pack.externalPackId,
        ]);
        final installedId = installed.isEmpty ? ChatStore._newId() : installed.single['installed_pack_id'] as String;
        if (installed.isEmpty) {
          _db.execute('INSERT INTO gameplay_packs (installed_pack_id, external_pack_id) VALUES (?, ?)', [
            installedId,
            pack.externalPackId,
          ]);
        }
        _db.execute(
          '''
        INSERT INTO gameplay_pack_versions
          (installed_pack_id, pack_version, manifest_raw, digest, original_zip,
           inspection_json, availability_revision, removed)
        VALUES (?, ?, ?, ?, ?, ?, 1, 0)''',
          [installedId, pack.packVersion, pack.manifestRaw, pack.digest, pack.originalZip, jsonEncode(inspection)],
        );
        for (final file in pack.files.entries) {
          _db.execute(
            '''
          INSERT INTO gameplay_pack_files (installed_pack_id, pack_version, path, bytes)
          VALUES (?, ?, ?, ?)''',
            [installedId, pack.packVersion, file.key, file.value],
          );
        }
        final ref = TavernPackVersionRef(installedPackId: installedId, packVersion: pack.packVersion);
        result = TavernPackImportResult(version: _readGameplayVersion(ref)!, reused: false);
        return result;
      },
      onCommitted: () {
        onCommitted?.call(result);
      },
    );
  }

  List<TavernPackVersion> listGameplayPackVersions({bool includeRemoved = false}) {
    _ensureOpen();
    final availabilityFilter = includeRemoved ? '' : 'AND v.removed = 0';
    final rows = _db.select('''
      SELECT d.domain_id AS gameplay_domain_id, $_gameplayVersionColumns
      FROM gameplay_packs p JOIN gameplay_pack_versions v
        ON v.installed_pack_id = p.installed_pack_id
      CROSS JOIN authoring_domain d
      WHERE d.singleton = 1 $availabilityFilter
      ORDER BY p.rowid, v.rowid''');
    return [for (final row in rows) _gameplayVersion(row, row['gameplay_domain_id'] as String)];
  }

  TavernPackVersion? readGameplayPackExternalVersion(String externalPackId, String packVersion) {
    _ensureOpen();
    final row = _readGameplayExternalRow(externalPackId, packVersion);
    return row == null ? null : _gameplayVersion(row, row['gameplay_domain_id'] as String);
  }

  TavernPackVersion? readGameplayPackVersion(TavernPackVersionRef ref) {
    _ensureOpen();
    return _readGameplayVersion(ref);
  }

  TavernPackResource? readGameplayPackResource(TavernPackVersionRef ref, String localId) {
    _ensureOpen();
    final version = _readGameplayVersion(ref);
    if (version == null) {
      return null;
    }
    for (final resource in gameplayPackResources(version.manifest)) {
      if (resource['localId'] != localId) {
        continue;
      }
      final path = resource['path']! as String;
      final rows = _db.select(
        '''
        SELECT bytes FROM gameplay_pack_files
        WHERE installed_pack_id = ? AND pack_version = ? AND path = ?''',
        [ref.installedPackId, ref.packVersion, path],
      );
      if (rows.isEmpty) {
        throw StateError('A stored gameplay resource file is missing.');
      }
      return TavernPackResource(
        localId: resource['localId']! as String,
        kind: resource['kind']! as String,
        path: path,
        bytes: Uint8List.fromList(rows.single['bytes'] as Uint8List),
      );
    }
    return null;
  }

  Uint8List? readGameplayPackArchive(TavernPackVersionRef ref) {
    _ensureOpen();
    final rows = _db.select(
      '''
      SELECT original_zip FROM gameplay_pack_versions
      WHERE installed_pack_id = ? AND pack_version = ?''',
      [ref.installedPackId, ref.packVersion],
    );
    return rows.isEmpty ? null : Uint8List.fromList(rows.single['original_zip'] as Uint8List);
  }

  TavernPackRemovalReceipt removeGameplayPackVersionData(
    TavernPackVersionRef ref, {
    required TavernGameplayRevision expected,
    required String operationId,
    void Function(TavernPackRemovalReceipt result)? onCommitted,
  }) {
    final request = jsonEncode({'ref': ref.toJson(), 'expected': expected.toJson(), 'operationId': operationId});
    late TavernPackRemovalReceipt result;
    return transaction(
      () {
        final recorded = _db.select(
          '''
        SELECT kind, request_json, result_json FROM gameplay_operations
        WHERE domain_id = ? AND operation_id = ?''',
          [expected.domainId, operationId],
        );
        if (recorded.isNotEmpty) {
          final row = recorded.single;
          if (row['kind'] != 'remove_version' || row['request_json'] != request) {
            throw const TavernGameplayException(
              code: 'operation_conflict',
              message: 'The operation identity has different parameters.',
            );
          }
          result = _gameplayRemovalReceipt(row['result_json'] as String);
          return result;
        }
        final domain = authoringDomainId;
        if (expected.domainId != domain) {
          throw const TavernGameplayException(
            code: 'revision_conflict',
            message: 'The captured gameplay revision belongs to another root domain.',
          );
        }
        final version = _readGameplayVersion(ref);
        if (version == null) {
          throw const TavernGameplayException(
            code: 'version_not_found',
            message: 'The gameplay pack version does not exist.',
          );
        }
        if (version.availability.revision != expected.revision) {
          throw const TavernGameplayException(
            code: 'revision_conflict',
            message: 'The gameplay pack availability has changed.',
          );
        }
        final changed = !version.removed;
        final revision = version.availability.revision + (changed ? 1 : 0);
        if (changed) {
          _db.execute(
            '''
          UPDATE gameplay_pack_versions SET removed = 1, availability_revision = ?
          WHERE installed_pack_id = ? AND pack_version = ?''',
            [revision, ref.installedPackId, ref.packVersion],
          );
        }
        result = TavernPackRemovalReceipt(
          ref: version.ref,
          operationId: operationId,
          availability: TavernGameplayRevision(domainId: domain, revision: revision),
          changed: changed,
        );
        _db.execute(
          '''
        INSERT INTO gameplay_operations (domain_id, operation_id, kind, request_json, result_json)
        VALUES (?, ?, 'remove_version', ?, ?)''',
          [domain, operationId, request, jsonEncode(result.toJson())],
        );
        return result;
      },
      onCommitted: () {
        onCommitted?.call(result);
      },
    );
  }

  Row? _readGameplayExternalRow(String externalPackId, String packVersion) {
    final rows = _db.select(
      '''
      SELECT d.domain_id AS gameplay_domain_id, $_gameplayVersionColumns
      FROM gameplay_packs p JOIN gameplay_pack_versions v
        ON v.installed_pack_id = p.installed_pack_id
      CROSS JOIN authoring_domain d
      WHERE d.singleton = 1 AND p.external_pack_id = ? AND v.pack_version = ?''',
      [externalPackId, packVersion],
    );
    return rows.isEmpty ? null : rows.single;
  }

  TavernPackVersion? _readGameplayVersion(TavernPackVersionRef ref) {
    final rows = _db.select(
      '''
      SELECT d.domain_id AS gameplay_domain_id, $_gameplayVersionColumns
      FROM gameplay_packs p JOIN gameplay_pack_versions v
        ON v.installed_pack_id = p.installed_pack_id
      CROSS JOIN authoring_domain d
      WHERE d.singleton = 1 AND v.installed_pack_id = ? AND v.pack_version = ?''',
      [ref.installedPackId, ref.packVersion],
    );
    return rows.isEmpty ? null : _gameplayVersion(rows.single, rows.single['gameplay_domain_id'] as String);
  }
}

TavernPackVersion _gameplayVersion(Row row, String domain) {
  final raw = ChatStore._unguardText(row['manifest_raw'])!;
  return TavernPackVersion(
    ref: TavernPackVersionRef(
      installedPackId: row['installed_pack_id'] as String,
      packVersion: ChatStore._unguardText(row['pack_version'])!,
    ),
    externalPackId: ChatStore._unguardText(row['external_pack_id'])!,
    digest: row['digest'] as String,
    manifestRaw: raw,
    manifest: decodeGameplayPackManifest(utf8.encode(raw)).manifest,
    inspection: jsonDecode(row['inspection_json'] as String) as Map<String, Object?>,
    availability: TavernGameplayRevision(domainId: domain, revision: row['availability_revision'] as int),
    removed: row['removed'] == 1,
  );
}

TavernPackRemovalReceipt _gameplayRemovalReceipt(String source) {
  final value = jsonDecode(source) as Map<String, Object?>;
  final ref = value['ref']! as Map<String, Object?>;
  final token = value['availability']! as Map<String, Object?>;
  return TavernPackRemovalReceipt(
    ref: TavernPackVersionRef(
      installedPackId: ref['installedPackId']! as String,
      packVersion: ref['packVersion']! as String,
    ),
    operationId: value['operationId']! as String,
    availability: TavernGameplayRevision(domainId: token['domainId']! as String, revision: token['revision']! as int),
    changed: value['changed']! as bool,
  );
}
