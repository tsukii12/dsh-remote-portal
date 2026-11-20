import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

// Real SQLite and facade source authentication. Corruption is deliberate and
// restored byte-for-byte; the narrower membership read is not a JSON repair.
const _beat = 'T12A-ORIGINAL-SOURCE-BEAT';
const _deadline = Duration(seconds: 10);

void main() {
  for (final column in ['extra', 'original']) {
    test('unrelated descendant $column is not decoded merely to authenticate source membership', () async {
      final h = await _open();
      final source = await h.engine.sendOnly(h.chatId, 'source before descendants');
      final run = await _direct(h);
      final middle = await h.engine.sendOnly(h.chatId, 'unrelated later body');
      await h.engine.sendOnly(h.chatId, 'current valid leaf');
      final before = _cell(h, middle.nodeId, column);
      _setCell(h, middle.nodeId, column, '{');
      try {
        // Full export retains its full document validation. Only the director
        // membership projection avoids this unrelated decoding dependency.
        await expectLater(h.engine.exportChat(h.chatId), throwsFormatException);
        final view = await h.engine.readDirector(h.chatId);
        expect(view.latestSuccess!.id, run.id);
        expect(view.latestSuccess!.sourceNodeId, source.nodeId);
        expect(view.stale, isFalse);
        expect(view.issues, isEmpty);
        expect(_cell(h, middle.nodeId, column), '{');
        expect(h.model.generated, 1);
      } finally {
        _setCell(h, middle.nodeId, column, before);
      }
      await h.reply('main after restoring the unrelated row');
      expect(jsonEncode(h.model.allCalls.last.body), contains(_beat));
      expect((await h.engine.readDirector(h.chatId)).stale, isFalse);
    });
  }

  for (final column in ['extra', 'original']) {
    test('source $column remains fully authenticated and a later repair is freshly read', () async {
      final h = await _open();
      final source = await h.engine.sendOnly(h.chatId, 'original source');
      final run = await _direct(h);
      await h.engine.sendOnly(h.chatId, 'valid later leaf');
      final before = _cell(h, source.nodeId, column);
      _setCell(h, source.nodeId, column, '{');
      try {
        final view = await h.engine.readDirector(h.chatId);
        expect(view.latestSuccess!.id, run.id);
        expect(view.stale, isTrue);
        expect(view.issues.any((issue) => issue['code'] == 'director_source_unavailable'), isTrue);
        expect(_cell(h, source.nodeId, column), '{');
      } finally {
        _setCell(h, source.nodeId, column, before);
      }
      expect((await h.engine.readDirector(h.chatId)).stale, isFalse);
      expect(h.model.generated, 1);
    });
  }

  test(
    'a source streaming shadow invalidates every fresh read and main admission without a tree revision change',
    () async {
      final h = await _open();
      final source = await h.reply('original source answer');
      final run = await _direct(h);
      await h.engine.sendOnly(h.chatId, 'ordinary later node');
      final revision = _db(
        h,
        (db) => db.select('SELECT tree_revision FROM chats WHERE id = ?', [h.chatId]).single['tree_revision'],
      );
      _setCell(h, source.nodeId, 'stream_text', 'uncommitted changed source body');
      try {
        for (var read = 0; read < 2; read++) {
          final view = await h.engine.readDirector(h.chatId);
          expect(view.latestSuccess!.id, run.id);
          expect(view.stale, isTrue);
          expect(view.issues.any((issue) => issue['code'] == 'director_source_changed'), isTrue);
        }
        expect(
          _db(h, (db) => db.select('SELECT tree_revision FROM chats WHERE id = ?', [h.chatId]).single['tree_revision']),
          revision,
        );
        await h.reply('main must not reuse the source plan');
        expect(jsonEncode(h.model.allCalls.last.body), isNot(contains(_beat)));
        expect(jsonEncode(h.model.allCalls.last.body), contains('uncommitted changed source body'));
      } finally {
        _setCell(h, source.nodeId, 'stream_text', null);
      }
      expect((await h.engine.readDirector(h.chatId)).stale, isFalse);
      expect(_cell(h, source.nodeId, 'text'), 'original source answer');
    },
  );

  test(
    'a cyclic later identity chain remains unavailable and repairing the chain restores source eligibility',
    () async {
      final h = await _open();
      final source = await h.engine.sendOnly(h.chatId, 'authenticated source');
      final run = await _direct(h);
      final middle = await h.engine.sendOnly(h.chatId, 'middle');
      final leaf = await h.engine.sendOnly(h.chatId, 'leaf');
      _setCell(h, middle.nodeId, 'parent_id', leaf.nodeId);
      try {
        final view = await h.engine.readDirector(h.chatId);
        expect(view.latestSuccess!.id, run.id);
        expect(view.stale, isTrue);
        expect(view.issues.any((issue) => issue['code'] == 'director_source_unavailable'), isTrue);
        expect(_cell(h, middle.nodeId, 'parent_id'), leaf.nodeId);
      } finally {
        _setCell(h, middle.nodeId, 'parent_id', source.nodeId);
      }
      expect((await h.engine.readDirector(h.chatId)).stale, isFalse);
      expect(h.model.generated, 1);
    },
  );

  test('cyclic state ancestry reports unavailable defined views and recovers without rewriting state', () async {
    final h = await _open();
    final raw = jsonDecode(utf8.decode(t24Card())) as Map<String, Object?>;
    final data = raw['data']! as Map<String, Object?>;
    data['extensions'] = {
      'dshgo': {
        'v': 1,
        'state': {
          'schema': {
            'type': 'object',
            'additionalProperties': false,
            'required': ['n'],
            'properties': {
              'n': {'type': 'integer'},
            },
          },
          'init': {'n': 7},
        },
        'story': {
          'acts': [
            {'id': 'a', 'title': 'A', 'goal': 'unchanged preview', 'when': false},
          ],
          'endings': <Object?>[],
        },
        'director': {
          'eventRules': {
            'v': 1,
            'rules': [
              {
                'id': 'notice',
                'name': 'fixed',
                'when': true,
                'do': [
                  {'type': 'notice', 'text': 'must stay unexecuted'},
                ],
              },
            ],
          },
        },
      },
    };
    final card = await h.engine.importCard(Uint8List.fromList(utf8.encode(jsonEncode(raw))));
    final chat = await h.engine.createChat(card.id);
    await h.engine.setSettings({
      'director': {'enabled': true, 'every': 1000},
    });
    final source = await h.engine.sendOnly(chat, 'source with state');
    final run = await _direct(h, chatId: chat);
    final middle = await h.engine.sendOnly(chat, 'middle with state');
    final leaf = await h.engine.sendOnly(chat, 'leaf with state');
    final before = await h.engine.readDirector(chat);
    expect(before.stale, isFalse);
    expect(before.automaticEnabled, isTrue);
    expect(before.story!['defined'], isTrue);
    expect(before.story!['executable'], isTrue);
    expect(before.story!['valid'], isTrue);
    expect(before.story!['actTurns'], 0);
    expect(before.eventRules!['defined'], isTrue);
    expect(before.eventRules!['executable'], isTrue);
    expect(before.eventRules!['valid'], isTrue);
    expect(before.eventRules!['automaticEnabled'], isTrue);
    expect((await h.engine.readState(chat)).values, {'n': 7});
    List<Map<String, Object?>> stateRows() => _db(
      h,
      (db) => [
        for (final row in db.select(
          '''SELECT node_id, delta_json, full_json FROM node_states
        WHERE node_id IN (?, ?, ?) ORDER BY node_id''',
          [source.nodeId, middle.nodeId, leaf.nodeId],
        ))
          Map<String, Object?>.from(row),
      ],
    );
    final saved = stateRows();
    expect(saved, hasLength(3));
    expect(
      saved
          .where((row) => row['node_id'] == leaf.nodeId || row['node_id'] == middle.nodeId)
          .every((row) => row['full_json'] == null),
      isTrue,
    );
    _setCell(h, middle.nodeId, 'parent_id', leaf.nodeId, chatId: chat);
    try {
      // Exercise the state reader itself, not only a director-side fallback.
      await expectLater(h.engine.readState(chat), throwsStateError);
      final view = await h.engine.readDirector(chat);
      expect(view.latestSuccess!.id, run.id);
      expect(view.latestSuccess!.output, before.latestSuccess!.output);
      expect(view.latestAttempt!.id, before.latestAttempt!.id);
      expect(view.stale, isTrue);
      expect(view.automaticEnabled, isFalse);
      expect(view.issues.any((issue) => issue['code'] == 'director_settings_unavailable'), isTrue);
      expect(view.issues.any((issue) => issue['code'] == 'director_source_unavailable'), isTrue);
      expect(view.story, isNull);
      expect(view.eventRules, isNull);
      expect(view.issues.any((issue) => issue['code'] == 'director_story_snapshot_unavailable'), isTrue);
      expect(view.issues.any((issue) => issue['code'] == 'director_event_snapshot_unavailable'), isTrue);
      expect(_cell(h, middle.nodeId, 'parent_id', chatId: chat), leaf.nodeId);
      expect(stateRows(), saved);
    } finally {
      _setCell(h, middle.nodeId, 'parent_id', source.nodeId, chatId: chat);
    }
    final repaired = await h.engine.readDirector(chat);
    expect(repaired.latestSuccess!.id, run.id);
    expect(repaired.stale, isFalse);
    expect(repaired.automaticEnabled, isTrue);
    expect(repaired.issues, isEmpty);
    expect(repaired.story, before.story);
    expect(repaired.eventRules, before.eventRules);
    expect((await h.engine.readState(chat)).values, {'n': 7});
    expect(stateRows(), saved);
    expect(h.model.generated, 1);
  });
}

Future<T24Harness> _open() async {
  final h = await T24Harness.open(thinking: false);
  addTearDown(h.dispose);
  return h;
}

Future<TavernDirectorRun> _direct(T24Harness h, {String? chatId}) async {
  final call = h.model.prepare();
  final result = h.engine.runDirector(chatId ?? h.chatId);
  await Future.any<void>([
    call.listening.future,
    result.then<void>((run) {
      throw TestFailure('Director ended before the fixture request: ${run.failure}');
    }),
  ]).timeout(_deadline);
  call.add(
    ModelToolFragment(
      index: 0,
      id: 'direct-source',
      type: 'function',
      name: 'direct',
      arguments: jsonEncode({
        'notes': '',
        'beat': _beat,
        'prefetch': <Object?>[],
        'suggestions': [
          for (var i = 0; i < 3; i++) {'text': 'choice-$i', 'risk': ''},
        ],
        'events': <Object?>[],
      }),
    ),
  );
  await call.finish('tool_calls');
  final run = await result.timeout(_deadline);
  expect(run.success, isTrue, reason: run.failure);
  return run;
}

T _db<T>(T24Harness h, T Function(Database) action) {
  final db = sqlite3.open('${h.root.path}/tavern.sqlite3');
  try {
    return action(db);
  } finally {
    db.close();
  }
}

Object? _cell(T24Harness h, String nodeId, String column, {String? chatId}) => _db(
  h,
  (db) =>
      db.select('SELECT $column FROM nodes WHERE chat_id = ? AND id = ?', [chatId ?? h.chatId, nodeId]).single[column],
);

void _setCell(T24Harness h, String nodeId, String column, Object? value, {String? chatId}) {
  _db(
    h,
    (db) =>
        db.execute('UPDATE nodes SET $column = ? WHERE chat_id = ? AND id = ?', [value, chatId ?? h.chatId, nodeId]),
  );
}
