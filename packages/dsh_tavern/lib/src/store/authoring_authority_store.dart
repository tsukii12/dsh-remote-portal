part of 'chat_store.dart';

final class StoredAuthoringResource {
  const StoredAuthoringResource({required this.revision, required this.snapshot, this.pendingOperationId});
  final int revision;
  final Map<String, Object?> snapshot;
  final String? pendingOperationId;
}

/// Synchronous primitives used by the authority on this same connection.
/// Mutations belong to its existing FULL transaction; no file I/O runs there.
extension AuthoringAuthorityStore on ChatStore {
  ({String? domainId, bool hasPending, Set<String> protectedArtifacts}) authoringRootStateData() {
    _ensureOpen();
    return inspectAuthoringDatabase(_db);
  }

  String get authoringDatabasePath {
    _ensureOpen();
    return _db.select('PRAGMA database_list').singleWhere((row) => row['name'] == 'main')['file'] as String;
  }

  String get authoringDomainId {
    _ensureOpen();
    return _db.select('SELECT domain_id FROM authoring_domain WHERE singleton = 1').single['domain_id'] as String;
  }

  String newAuthoringOperationId() => ChatStore._newId();

  void initializeAuthoringAuthority() => transaction(() {
    if (_db.select('SELECT domain_id FROM authoring_domain WHERE singleton = 1').isEmpty) {
      _db.execute('INSERT INTO authoring_domain (singleton, domain_id) VALUES (1, ?)', [ChatStore._newId()]);
    }
    _db.execute("UPDATE authoring_operations SET state = 'unconfirmed', updated_at = ? WHERE state = 'prepared'", [
      _clock().millisecondsSinceEpoch,
    ]);
  });

  void rotateAuthoringDomain() => transaction(() {
    _db.execute('UPDATE authoring_domain SET domain_id = ? WHERE singleton = 1', [ChatStore._newId()]);
  });

  StoredAuthoringResource? readAuthoringResource(String resourceId) {
    _ensureOpen();
    final rows = _db.select(
      'SELECT revision, present, char(1) || raw_text AS raw_text, '
      'char(1) || identity_text AS identity_text, char(1) || pending_operation_id AS pending_operation_id '
      'FROM authoring_resources WHERE physical_resource_id = ?',
      [resourceId],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return StoredAuthoringResource(
      revision: row['revision'] as int,
      snapshot: {
        'present': row['present'] == 1,
        'rawText': ChatStore._unguardText(row['raw_text']),
        'identityText': ChatStore._unguardText(row['identity_text']),
      },
      pendingOperationId: ChatStore._unguardText(row['pending_operation_id']),
    );
  }

  void putAuthoringResource(
    String resourceId,
    int revision,
    Map<String, Object?> snapshot, {
    String? pendingOperationId,
  }) {
    _db.execute(
      'INSERT INTO authoring_resources '
      '(physical_resource_id, revision, present, raw_text, identity_text, pending_operation_id) VALUES (?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(physical_resource_id) DO UPDATE SET revision = excluded.revision, present = excluded.present, '
      'raw_text = excluded.raw_text, identity_text = excluded.identity_text, pending_operation_id = excluded.pending_operation_id',
      [
        resourceId,
        revision,
        snapshot['present'] == true ? 1 : 0,
        snapshot['rawText'],
        snapshot['identityText'],
        pendingOperationId,
      ],
    );
  }

  TavernAuthoringOperation? readAuthoringOperationData(String domainId, String operationId) {
    _ensureOpen();
    final rows = _db.select(
      'SELECT *, char(1) || operation_id AS guarded_operation_id FROM authoring_operations '
      'WHERE domain_id = ? AND operation_id = ?',
      [domainId, operationId],
    );
    return rows.isEmpty ? null : _authoringOperationRow(rows.single);
  }

  List<TavernAuthoringRevisionSummary> listAuthoringRevisionsData(String resourceId) {
    _ensureOpen();
    return [
      for (final row in _db.select(
        'SELECT domain_id, char(1) || operation_id AS operation_id, '
        'adopted_revision, updated_at FROM authoring_operations WHERE physical_resource_id = ? '
        'AND adopted_revision IS NOT NULL ORDER BY created_at DESC, domain_id, adopted_revision DESC',
        [resourceId],
      ))
        TavernAuthoringRevisionSummary(
          domainId: row['domain_id'] as String,
          physicalResourceId: resourceId,
          revision: row['adopted_revision'] as int,
          operationId: ChatStore._unguardText(row['operation_id'])!,
          at: ChatStore._date(row['updated_at']),
        ),
    ];
  }

  TavernAuthoringOperation? readAuthoringRevisionData(String resourceId, TavernAuthorityRevision revision) {
    _ensureOpen();
    final rows = _db.select(
      'SELECT *, char(1) || operation_id AS guarded_operation_id FROM authoring_operations '
      'WHERE domain_id = ? AND physical_resource_id = ? AND adopted_revision = ?',
      [revision.domainId, resourceId, revision.revision],
    );
    return rows.isEmpty ? null : _authoringOperationRow(rows.single);
  }

  void insertAuthoringOperationData({
    required String domainId,
    required String operationId,
    required String resourceId,
    required Map<String, Object?> parameters,
    required int baseRevision,
    required Map<String, Object?> before,
    required Map<String, Object?> after,
    required List<String> artifacts,
    required TavernAuthoringOperationState state,
  }) {
    final now = _clock().millisecondsSinceEpoch;
    _db.execute(
      'INSERT INTO authoring_operations '
      '(domain_id, operation_id, physical_resource_id, request_json, base_revision, before_json, after_json, '
      'artifacts_json, state, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        domainId,
        operationId,
        resourceId,
        jsonEncode(parameters),
        baseRevision,
        jsonEncode(before),
        jsonEncode(after),
        jsonEncode(artifacts),
        state.name,
        now,
        now,
      ],
    );
  }

  void finishAuthoringOperationData(
    String domainId,
    String operationId,
    TavernAuthoringOperationState state, {
    int? adoptedRevision,
    TavernAuthoringIssue? issue,
  }) {
    _db.execute(
      'UPDATE authoring_operations SET state = ?, adopted_revision = ?, issue_json = ?, updated_at = ? '
      'WHERE domain_id = ? AND operation_id = ?',
      [
        state.name,
        adoptedRevision,
        issue == null ? null : jsonEncode({'type': issue.type, 'message': issue.message}),
        _clock().millisecondsSinceEpoch,
        domainId,
        operationId,
      ],
    );
  }

  TavernAuthoringOperation _authoringOperationRow(Row row) {
    final state = TavernAuthoringOperationState.values.byName(row['state'] as String);
    final issue = row['issue_json'] == null ? null : ChatStore._map(row['issue_json']);
    return TavernAuthoringOperation(
      domainId: row['domain_id'] as String,
      operationId: ChatStore._unguardText(row['guarded_operation_id'])!,
      physicalResourceId: row['physical_resource_id'] as String,
      state: state,
      adoptedRevision: row['adopted_revision'] as int?,
      historyPending: state == TavernAuthoringOperationState.prepared || state == TavernAuthoringOperationState.adopted,
      issue: issue == null
          ? null
          : TavernAuthoringIssue(type: issue['type']! as String, message: issue['message']! as String),
      request: ChatStore._map(row['request_json']),
      before: ChatStore._map(row['before_json']),
      after: ChatStore._map(row['after_json']),
      createdAt: ChatStore._date(row['created_at']),
      updatedAt: ChatStore._date(row['updated_at']),
    );
  }
}

/// Shared read-only probe for an open owner and a closed root. It does not
/// create tables, migrate a database, or guess an outcome from file contents.
({String? domainId, bool hasPending, Set<String> protectedArtifacts}) inspectAuthoringDatabase(Database database) {
  if (database.select("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'authoring_domain'").isEmpty) {
    return (domainId: null, hasPending: false, protectedArtifacts: <String>{});
  }
  final domains = database.select('SELECT domain_id FROM authoring_domain WHERE singleton = 1');
  final domainId = domains.isEmpty ? null : domains.single['domain_id'] as String;
  final operations = database.select(
    "SELECT domain_id, char(1) || operation_id AS operation_id, artifacts_json "
    "FROM authoring_operations WHERE state IN ('prepared', 'unconfirmed')",
  );
  final pending = <(String, String)>{};
  final artifacts = <String>{};
  for (final operation in operations) {
    pending.add((operation['domain_id'] as String, ChatStore._unguardText(operation['operation_id'])!));
    artifacts.addAll((jsonDecode(operation['artifacts_json'] as String) as List<Object?>).cast<String>());
  }
  for (final resource in database.select(
    'SELECT char(1) || pending_operation_id AS operation_id '
    'FROM authoring_resources WHERE pending_operation_id IS NOT NULL',
  )) {
    if (domainId == null || !pending.contains((domainId, ChatStore._unguardText(resource['operation_id'])!))) {
      throw const FormatException('An authoring pending resource has no unresolved operation.');
    }
  }
  return (domainId: domainId, hasPending: operations.isNotEmpty, protectedArtifacts: artifacts);
}

const _schemaV11 = r'''
CREATE TABLE authoring_domain (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  domain_id TEXT NOT NULL
);
CREATE TABLE authoring_resources (
  physical_resource_id TEXT PRIMARY KEY,
  revision INTEGER NOT NULL,
  present INTEGER NOT NULL,
  raw_text TEXT,
  identity_text TEXT,
  pending_operation_id TEXT
);
CREATE TABLE authoring_operations (
  domain_id TEXT NOT NULL,
  operation_id TEXT NOT NULL,
  physical_resource_id TEXT NOT NULL,
  request_json TEXT NOT NULL,
  base_revision INTEGER NOT NULL,
  before_json TEXT NOT NULL,
  after_json TEXT NOT NULL,
  artifacts_json TEXT NOT NULL,
  state TEXT NOT NULL,
  adopted_revision INTEGER,
  issue_json TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (domain_id, operation_id),
  UNIQUE (domain_id, physical_resource_id, adopted_revision)
);
''';
