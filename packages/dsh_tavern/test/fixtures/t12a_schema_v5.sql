-- Genuine schema V5 from frozen event parent 63df5f4bc0f26d2a2898542d0cf905af5002c208.
-- Fixed fixture: do not derive it from the running ChatStore schema.
PRAGMA foreign_keys = ON;
BEGIN;

-- Original migration to version 1.
CREATE TABLE chats (
  id TEXT PRIMARY KEY NOT NULL,
  character_id TEXT NOT NULL,
  title TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  persona_id TEXT,
  preset_id TEXT,
  selected_root_id TEXT REFERENCES nodes(id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED,
  current_leaf_id TEXT REFERENCES nodes(id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED,
  metadata TEXT NOT NULL DEFAULT '{}',
  variables TEXT NOT NULL DEFAULT '{}',
  settings TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX chats_character_updated ON chats(character_id, updated_at DESC);
CREATE TABLE nodes (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  id TEXT UNIQUE NOT NULL,
  chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  parent_id TEXT REFERENCES nodes(id) DEFERRABLE INITIALLY DEFERRED,
  selected_child_id TEXT REFERENCES nodes(id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED,
  depth INTEGER NOT NULL CHECK(depth >= 1),
  role TEXT NOT NULL CHECK(role IN ('user', 'character', 'narrator', 'system')),
  speaker TEXT NOT NULL,
  text TEXT NOT NULL,
  reasoning TEXT,
  at INTEGER NOT NULL,
  hidden INTEGER NOT NULL DEFAULT 0 CHECK(hidden IN (0, 1)),
  usage TEXT,
  extra TEXT NOT NULL DEFAULT '{}',
  original TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX nodes_chat_parent ON nodes(chat_id, parent_id, seq);
CREATE INDEX nodes_parent ON nodes(parent_id);
CREATE INDEX nodes_selected_child ON nodes(selected_child_id);
CREATE INDEX chats_selected_root ON chats(selected_root_id);
CREATE INDEX chats_current_leaf ON chats(current_leaf_id);
CREATE TABLE node_states (
  node_id TEXT PRIMARY KEY NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
  delta_json TEXT NOT NULL DEFAULT '[]',
  full_json TEXT
);
CREATE TABLE summaries (
  id TEXT PRIMARY KEY NOT NULL,
  chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  from_node_id TEXT REFERENCES nodes(id) ON DELETE CASCADE,
  to_node_id TEXT REFERENCES nodes(id) ON DELETE CASCADE,
  text TEXT NOT NULL,
  manually_edited INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE memories (
  id TEXT PRIMARY KEY NOT NULL,
  chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  entry_json TEXT NOT NULL
);
CREATE TABLE agent_runs (
  id TEXT PRIMARY KEY NOT NULL,
  chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  node_id TEXT REFERENCES nodes(id) ON DELETE SET NULL,
  kind TEXT NOT NULL,
  at INTEGER NOT NULL,
  usage TEXT,
  result_json TEXT
);
CREATE VIRTUAL TABLE nodes_fts USING fts5(text, speaker, content = 'nodes', content_rowid = 'seq');
CREATE TRIGGER nodes_fts_insert AFTER INSERT ON nodes BEGIN
  INSERT INTO nodes_fts(rowid, text, speaker) VALUES (new.seq, new.text, new.speaker);
END;
CREATE TRIGGER nodes_fts_delete AFTER DELETE ON nodes BEGIN
  INSERT INTO nodes_fts(nodes_fts, rowid, text, speaker) VALUES ('delete', old.seq, old.text, old.speaker);
END;
CREATE TRIGGER nodes_fts_update AFTER UPDATE OF text, speaker ON nodes BEGIN
  INSERT INTO nodes_fts(nodes_fts, rowid, text, speaker) VALUES ('delete', old.seq, old.text, old.speaker);
  INSERT INTO nodes_fts(rowid, text, speaker) VALUES (new.seq, new.text, new.speaker);
END;

-- Original migration to version 2.
CREATE TABLE presets (
  id TEXT PRIMARY KEY NOT NULL,
  name TEXT NOT NULL,
  source_text TEXT NOT NULL,
  raw_json TEXT NOT NULL,
  envelope_json TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE TABLE preset_preferences (
  singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
  default_preset_id TEXT REFERENCES presets(id) ON DELETE SET NULL
);
INSERT INTO preset_preferences(singleton, default_preset_id) VALUES (1, NULL);
CREATE INDEX chats_preset ON chats(preset_id);

-- Original migration to version 3.
ALTER TABLE presets ADD COLUMN import_report_json TEXT;

-- Original migration to version 4.
ALTER TABLE nodes ADD COLUMN stream_text TEXT;
ALTER TABLE nodes ADD COLUMN stream_reasoning TEXT;
CREATE INDEX nodes_stream_pending ON nodes(chat_id) WHERE stream_text IS NOT NULL;

-- Original migration to version 5.
ALTER TABLE chats ADD COLUMN tree_revision INTEGER NOT NULL DEFAULT 0;
CREATE TABLE deleted_subtrees (
  id TEXT PRIMARY KEY NOT NULL,
  chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  root_node_id TEXT NOT NULL,
  parent_id TEXT,
  selected_child_id TEXT,
  selected_root_id TEXT,
  current_leaf_id TEXT,
  revision_after INTEGER NOT NULL
);
CREATE INDEX deleted_subtrees_chat ON deleted_subtrees(chat_id);
ALTER TABLE nodes ADD COLUMN deleted_by TEXT REFERENCES deleted_subtrees(id) DEFERRABLE INITIALLY DEFERRED;
CREATE INDEX nodes_deleted_by ON nodes(deleted_by) WHERE deleted_by IS NOT NULL;
ALTER TABLE nodes ADD COLUMN reported_usage TEXT;
UPDATE nodes SET reported_usage = CASE WHEN json_valid(extra) THEN CASE WHEN
  json_type(extra, '$.dshgo.inspection') = 'object'
  AND json_type(extra, '$.dshgo.inspection.version') IN ('integer', 'real')
  AND json_extract(extra, '$.dshgo.inspection.version') = 1
  AND json_type(extra, '$.dshgo.inspection.chatId') = 'text'
  AND json_extract(extra, '$.dshgo.inspection.chatId') = chat_id
  AND json_type(extra, '$.dshgo.inspection.nodeId') = 'text'
  AND json_extract(extra, '$.dshgo.inspection.nodeId') = id
  AND json_type(extra, '$.dshgo.inspection.reportedUsage') = 'object'
  AND json_type(extra, '$.dshgo.inspection.reportedUsage.promptTokens') = 'integer'
  AND json_type(extra, '$.dshgo.inspection.reportedUsage.cacheHitTokens') = 'integer'
  AND json_type(extra, '$.dshgo.inspection.reportedUsage.completionTokens') = 'integer'
  AND (json_type(extra, '$.dshgo.inspection.reportedUsage.model') IS NULL
    OR json_type(extra, '$.dshgo.inspection.reportedUsage.model') IN ('null', 'text'))
  THEN json_object(
    'promptTokens', json_extract(extra, '$.dshgo.inspection.reportedUsage.promptTokens'),
    'cacheHitTokens', json_extract(extra, '$.dshgo.inspection.reportedUsage.cacheHitTokens'),
    'completionTokens', json_extract(extra, '$.dshgo.inspection.reportedUsage.completionTokens'),
    'model', json_extract(extra, '$.dshgo.inspection.reportedUsage.model'))
  END END;

PRAGMA user_version = 5;
COMMIT;
