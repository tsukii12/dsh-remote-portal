part of 'chat_store.dart';

extension AuthoringSeedStore on ChatStore {
  StoredAuthoringDraft createAuthoringSeedDraftData(
    Map<String, Object?> data,
    String resourceId,
    Map<String, Uint8List> blobs,
  ) => transaction(() {
    final draft = createAuthoringDraftData(data);
    for (final blob in blobs.entries) {
      _db.execute('INSERT INTO authoring_seed_blobs (draft_id, resource_id, path, bytes) VALUES (?, ?, ?, ?)', [
        draft.id,
        resourceId,
        blob.key,
        blob.value,
      ]);
    }
    return draft;
  });

  Map<String, Uint8List> readAuthoringSeedBlobs(String draftId, String resourceId) {
    _ensureOpen();
    return {
      for (final row in _db.select(
        'SELECT path, bytes FROM authoring_seed_blobs '
        'WHERE draft_id = ? AND resource_id = ? ORDER BY path',
        [draftId, resourceId],
      ))
        row['path'] as String: row['bytes'] as Uint8List,
    };
  }
}

const _authoringSeedSchema = r'''
CREATE TABLE authoring_seed_blobs (
  draft_id TEXT NOT NULL REFERENCES authoring_drafts(id) ON DELETE CASCADE,
  resource_id TEXT NOT NULL,
  path TEXT NOT NULL,
  bytes BLOB NOT NULL,
  PRIMARY KEY (draft_id, resource_id, path)
);
''';
