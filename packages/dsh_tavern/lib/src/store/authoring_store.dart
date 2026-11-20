part of 'chat_store.dart';

/// Internal serialized draft storage. The facade validates JSON and changes at
/// admission; reading this database row is the persistence boundary.
final class StoredAuthoringDraft {
  const StoredAuthoringDraft({
    required this.id,
    required this.revision,
    required this.data,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final int revision;
  final Map<String, Object?> data;
  final DateTime createdAt;
  final DateTime updatedAt;
}

extension AuthoringStore on ChatStore {
  /// The simulator copies an unselected default too. Retain its SQL columns
  /// without parsing JSON that native preset precedence would not inspect.
  Map<String, Map<String, Object?>?> readAuthoringSimulationPresetRows(Iterable<String> ids) {
    _ensureOpen();
    final result = <String, Map<String, Object?>?>{};
    for (final id in ids) {
      final rows = _db.select(
        'SELECT id, char(1) || name AS name, char(1) || source_text AS source_text, '
        'char(1) || raw_json AS raw_json, char(1) || envelope_json AS envelope_json, '
        'char(1) || import_report_json AS import_report_json, created_at, updated_at FROM presets WHERE id = ?',
        [id],
      );
      if (rows.isEmpty) {
        result[id] = null;
        continue;
      }
      final row = rows.single;
      result[id] = {
        'id': row['id'] as String,
        'name': ChatStore._unguardText(row['name'])!,
        'sourceText': ChatStore._unguardText(row['source_text'])!,
        'rawJson': ChatStore._unguardText(row['raw_json'])!,
        'envelopeJson': ChatStore._unguardText(row['envelope_json']),
        'importReportJson': ChatStore._unguardText(row['import_report_json']),
        'createdAt': row['created_at'] as int,
        'updatedAt': row['updated_at'] as int,
      };
    }
    return result;
  }

  /// Installs already captured inputs into the simulator's new, exclusively
  /// owned database. Existing append owns physical depth/state/selection.
  String bootstrapAuthoringSimulation({
    required StoredChat chat,
    required List<StoredNode> history,
    required Map<String, Object?> state,
    required Iterable<Map<String, Object?>> presets,
    required String? defaultPresetId,
  }) => transaction(() {
    var hasPresets = false;
    for (final row in presets) {
      _db.execute(
        'INSERT INTO presets '
        '(id, name, source_text, raw_json, envelope_json, import_report_json, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        [
          row['id'],
          row['name'],
          row['sourceText'],
          row['rawJson'],
          row['envelopeJson'],
          row['importReportJson'],
          row['createdAt'],
          row['updatedAt'],
        ],
      );
      hasPresets = true;
    }
    // The real FK keeps the copied default tied to its original identity;
    // setDefaultPreset would parse an otherwise unselected row.
    _db.execute('UPDATE preset_preferences SET default_preset_id = ? WHERE singleton = 1', [defaultPresetId]);
    if (hasPresets || defaultPresetId != null) {
      _presetsChanged = true;
    }
    final id = createChat(
      id: chat.id,
      characterId: chat.characterId,
      title: chat.title,
      personaId: chat.personaId,
      presetId: chat.presetId,
      metadata: chat.metadata,
      variables: chat.variables,
      settings: chat.settings,
    );
    for (var index = 0; index < history.length; index++) {
      final node = history[index];
      final message = node.message;
      final saved = index + 1 == history.length ? state : const <String, Object?>{};
      append(
        id,
        id: message.nodeId,
        parentId: index == 0 ? null : history[index - 1].message.nodeId,
        role: message.role,
        speaker: message.speaker,
        text: message.text,
        reasoning: message.reasoning,
        speakerCharacterId: message.speakerCharacterId,
        at: message.at,
        hidden: message.hidden,
        extra: {
          'dshgo': {'tavernState': saved},
        },
        state: saved,
      );
    }
    return id;
  });

  /// Keeps current JSON columns intact, including unknown report fields that
  /// the runtime report DTO does not expose. sourceText remains archival.
  Map<String, Object?>? readAuthoringPresetData(String id) {
    _ensureOpen();
    final rows = _db.select(
      'SELECT id, char(1) || name AS name, char(1) || source_text AS source_text, '
      'raw_json, envelope_json, import_report_json, created_at, updated_at FROM presets WHERE id = ?',
      [id],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return {
      'id': row['id'] as String,
      'name': ChatStore._unguardText(row['name'])!,
      'sourceText': ChatStore._unguardText(row['source_text'])!,
      'raw': ChatStore._map(row['raw_json']),
      'envelope': row['envelope_json'] == null ? null : ChatStore._map(row['envelope_json']),
      'importReport': row['import_report_json'] == null ? null : ChatStore._map(row['import_report_json']),
      'createdAt': row['created_at'] as int,
      'updatedAt': row['updated_at'] as int,
    };
  }

  StoredAuthoringDraft createAuthoringDraftData(Map<String, Object?> data) => transaction(() {
    final id = _createId();
    final at = _clock().millisecondsSinceEpoch;
    _db.execute(
      'INSERT INTO authoring_drafts (id, revision, data_json, created_at, updated_at) VALUES (?, 1, ?, ?, ?)',
      [id, jsonEncode(data), at, at],
    );
    return readAuthoringDraftData(id)!;
  });

  StoredAuthoringDraft? readAuthoringDraftData(String id) {
    _ensureOpen();
    final rows = _db.select('SELECT * FROM authoring_drafts WHERE id = ?', [id]);
    return rows.isEmpty ? null : _authoringRow(rows.single);
  }

  List<StoredAuthoringDraft> listAuthoringDraftData() {
    _ensureOpen();
    return [
      for (final row in _db.select('SELECT * FROM authoring_drafts ORDER BY updated_at DESC, id')) _authoringRow(row),
    ];
  }

  StoredAuthoringDraft updateAuthoringDraftData(String id, int revision, Map<String, Object?> data) => transaction(() {
    _db.execute(
      'UPDATE authoring_drafts SET revision = revision + 1, data_json = ?, updated_at = ? '
      'WHERE id = ? AND revision = ?',
      [jsonEncode(data), _clock().millisecondsSinceEpoch, id, revision],
    );
    if (_db.select('SELECT changes() AS n').single['n'] != 1) _authoringRevisionFailure(id);
    return readAuthoringDraftData(id)!;
  });

  void deleteAuthoringDraftData(String id, int revision) => transaction(() {
    _db.execute('DELETE FROM authoring_drafts WHERE id = ? AND revision = ?', [id, revision]);
    if (_db.select('SELECT changes() AS n').single['n'] != 1) _authoringRevisionFailure(id);
  });

  Never _authoringRevisionFailure(String id) {
    if (readAuthoringDraftData(id) == null) {
      throw const TavernAuthoringException('not_found', 'The authoring draft does not exist.');
    }
    throw const TavernAuthoringException('revision_conflict', 'The authoring draft changed.');
  }

  StoredAuthoringDraft _authoringRow(Row row) {
    final data = jsonDecode(row['data_json'] as String);
    if (data is! Map<String, Object?> ||
        data['version'] != 1 ||
        data['sources'] is! List<Object?> ||
        data['changes'] is! List<Object?>) {
      throw const FormatException('Unsupported authoring draft.');
    }
    return StoredAuthoringDraft(
      id: row['id'] as String,
      revision: row['revision'] as int,
      data: data,
      createdAt: ChatStore._date(row['created_at']),
      updatedAt: ChatStore._date(row['updated_at']),
    );
  }
}

const _schemaV10 = r'''
CREATE TABLE authoring_drafts (
  id TEXT PRIMARY KEY,
  revision INTEGER NOT NULL,
  data_json TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
''';
