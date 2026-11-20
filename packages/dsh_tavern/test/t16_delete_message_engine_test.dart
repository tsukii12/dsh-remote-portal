import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('single deletion retains descendant snapshots and deleting leaves then restores their parents', () async {
    final h = await _open();
    final character = await h.engine.importCard(
      _card({
        'first_mes': '{{setvar::n::1}}{{setglobalvar::g::9}}G',
        'character_book': {
          'extensions': {},
          'entries': [
            {
              'id': 1,
              'keys': <String>[],
              'constant': true,
              'enabled': true,
              'content': 'WORLD',
              'insertion_order': 100,
              'position': 'before_char',
              'extensions': {'sticky': 8},
            },
          ],
        },
      }),
    );
    final chat = await h.engine.createChat(character.id);
    // Card fields are prepared again each turn; remove the initialization
    // macros after they have established the greeting's own snapshot.
    await h.engine.updateCharacterFields(character.id, {'first_mes': 'G'});
    await h.engine.setSettings({
      'globalRegexScripts': [
        _script('state', r'^([\s\S]+)$', r'{{incvar::n}}|$1', [2]),
      ],
    });
    _done(await h.engine.send(chat, '{{setvar::n::2}}Q1{{pick::A::B}}').toList());
    _done(await h.engine.send(chat, '{{setvar::n::4}}Q2').toList());
    final path = await h.engine.path(chat);
    expect(h.engine.variables(chat)['n'], 5);
    await h.engine.nameBranch(chat, path[2].nodeId, 'PRESERVED ANSWER');
    final before = _map((await _snapshot(h.engine, chat))['metadata']);
    final calls = h.model.bodies.length;
    final Tavern facade = h.engine;
    await facade.deleteMessage(chat, path[1].nodeId);
    final after = await facade.path(chat);
    expect(after.map((node) => node.nodeId), [path[0].nodeId, path[2].nodeId, path[3].nodeId, path[4].nodeId]);
    expect(after[1].parentId, path[0].nodeId);
    expect(after.map((node) => node.text), [path[0].text, path[2].text, path[3].text, path[4].text]);
    expect(h.engine.variables(chat)['n'], 5);
    final metadata = _map((await _snapshot(h.engine, chat))['metadata']);
    for (final key in ['variables', 'timedWorldInfo', 'decoratorState', 'chat_id_hash']) {
      expect(metadata[key], before[key], reason: key);
    }
    expect(metadata['chat_id_hash'], isA<num>());
    expect(
      (await facade.tree(chat)).singleWhere((node) => node.nodeId == path[2].nodeId).branchName,
      'PRESERVED ANSWER',
    );
    expect(h.model.bodies, hasLength(calls));
    expect(h.engine.globalVariables['g'], '9');
    await h.reopen();
    expect(h.engine.variables(chat)['n'], 5);
    await h.engine.deleteMessage(chat, path[4].nodeId);
    expect(h.engine.variables(chat)['n'], '4');
    await h.engine.deleteMessage(chat, path[3].nodeId);
    expect(h.engine.variables(chat)['n'], 3);
    expect((await h.engine.path(chat)).last.nodeId, path[2].nodeId);
    expect(h.engine.globalVariables['g'], '9');
  });
  test('deleting an inactive answer preserves selected state and clears its deleted inspection anchor', () async {
    final h = await _open();
    final character = await h.engine.importCard(_card());
    final chat = await h.engine.createChat(character.id);
    await h.engine.setSettings({
      'globalRegexScripts': [
        _script('state', r'^([\s\S]+)$', r'{{incvar::n}}|$1', [2]),
      ],
    });
    final first = _done(await h.engine.send(chat, '{{setvar::n::2}}Q').toList());
    final originalInspection = (await h.engine.inspectTurn(chat, nodeId: first.nodeId))!.toJson();
    await h.engine.setSettings({
      'globalRegexScripts': [
        _script('state', r'^([\s\S]+)$', r'{{setvar::n::9}}$1', [2]),
      ],
    });
    final other = _done(await h.engine.regenerate(chat, first.nodeId).toList());
    expect(h.engine.variables(chat)['n'], '9');
    await h.engine.selectSibling(chat, first.nodeId, 0);
    expect(h.engine.variables(chat)['n'], 3);
    final selected = (await h.engine.path(chat)).map((node) => node.nodeId).toList();
    expect((await h.engine.inspectTurn(chat))!.nodeId, other.nodeId);
    await h.engine.deleteMessage(chat, other.nodeId);
    expect((await h.engine.path(chat)).map((node) => node.nodeId), selected);
    expect(h.engine.variables(chat)['n'], 3);
    expect(await h.engine.inspectTurn(chat), isNull);
    expect(await h.engine.inspectTurn(chat, nodeId: other.nodeId), isNull);
    expect((await h.engine.inspectTurn(chat, nodeId: first.nodeId))!.toJson(), originalInspection);
    await h.reopen();
    expect(h.engine.variables(chat)['n'], 3);
    expect(await h.engine.inspectTurn(chat), isNull);
  });
  test('deleting the selected root leaf leaves an empty path instead of choosing another root', () async {
    final h = await _open();
    final character = await h.engine.importCard(_card({'first_mes': '{{setvar::n::1}}FIRST'}));
    final chat = await h.engine.createChat(character.id);
    final first = (await h.engine.path(chat)).single;
    await h.engine.setSettings({
      'globalRegexScripts': [
        _script('state', r'^([\s\S]+)$', r'{{setvar::n::9}}$1', [2]),
      ],
    });
    final other = _done(await h.engine.regenerate(chat, first.nodeId).toList());
    await h.engine.deleteMessage(chat, other.nodeId);
    expect(await h.engine.path(chat), isEmpty);
    expect(h.engine.variables(chat), isEmpty);
    final remaining = (await h.engine.tree(chat)).single;
    expect(remaining.nodeId, first.nodeId);
    expect(remaining.isCurrentPath, isFalse);
    await h.engine.selectSibling(chat, first.nodeId, 0);
    expect((await h.engine.path(chat)).single.nodeId, first.nodeId);
    expect(h.engine.variables(chat)['n'], '1');
  });

  test('empty-path deletion retains the same chat lazy hash without replaying removed variables', () async {
    final h = await _open();
    final character = await h.engine.importCard(_card());
    final source = StChatDocument(
      fileName: 'zero.jsonl',
      header: {
        'user_name': 'User',
        'character_name': 'Guide',
        'chat_metadata': {
          'chat_id_hash': 0,
          'variables': {'n': 7},
        },
      },
      messages: [
        {'name': 'Guide', 'is_user': false, 'is_system': false, 'send_date': _at.toIso8601String(), 'mes': 'OLD'},
      ],
    );
    final chat = (await h.engine.importChats(character.id, [
      TavernChatFile(fileName: source.fileName, bytes: source.encode()),
    ])).chatIds.single;
    final root = (await h.engine.path(chat)).single.nodeId;
    await h.engine.deleteMessage(chat, root);
    expect(await h.engine.tree(chat), isEmpty);
    expect(h.engine.variables(chat), isEmpty);
    expect(_map((await _snapshot(h.engine, chat))['metadata'])['chat_id_hash'], 0);
    await h.reopen();
    const input = '{{pick::a::b::c::d}}';
    final expected = const MacroEngine().expand(
      input,
      MacroContext(chatIdHash: 0, now: _at, timeZoneOffset: Duration.zero),
    );
    _done(await h.engine.send(chat, input).toList());
    final path = await h.engine.path(chat);
    expect(path, hasLength(2));
    expect(path.first.text, expected);
    expect(h.engine.variables(chat), isEmpty);
    expect(_map((await _snapshot(h.engine, chat))['metadata'])['chat_id_hash'], 0);
  });
  test('single deletion keeps later messages and portable snapshots while deleteFrom removes a subtree', () async {
    final h = await _open();
    final character = await h.engine.importCard(_card());
    final chat = await h.engine.createChat(character.id);
    _done(await h.engine.send(chat, '{{incvar::n}}FIRST').toList());
    _done(await h.engine.send(chat, '{{incvar::n}}SECOND').toList());
    final before = await h.engine.path(chat);
    await h.engine.deleteMessage(chat, before[1].nodeId);
    expect((await h.engine.path(chat)).map((node) => node.nodeId), [
      before[0].nodeId,
      before[2].nodeId,
      before[3].nodeId,
      before[4].nodeId,
    ]);
    final imported = await h.engine.importChats(character.id, await h.engine.exportChat(chat));
    final copied = imported.chatIds.single;
    final path = await h.engine.path(copied);
    expect(path.map((node) => node.text), [before[0].text, before[2].text, before[3].text, before[4].text]);
    expect(path.map((node) => node.role), [
      TavernRole.character,
      TavernRole.character,
      TavernRole.user,
      TavernRole.character,
    ]);
    expect(h.engine.variables(copied)['n'], 2);
    await h.engine.deleteFrom(copied, path[2].nodeId);
    expect((await h.engine.path(copied)).map((node) => node.nodeId), [path[0].nodeId, path[1].nodeId]);
    expect(h.engine.variables(copied)['n'], 1);
    expect((await h.engine.path(chat)), hasLength(4));
  });
  test('foreign and missing nodes leave committed messages variables and inspections untouched', () async {
    final h = await _open();
    final character = await h.engine.importCard(_card());
    final a = await h.engine.createChat(character.id);
    final b = await h.engine.createChat(character.id);
    final root = (await h.engine.path(a)).single.nodeId;
    _done(await h.engine.send(a, '{{incvar::n}}Q').toList());
    final before = await _snapshot(h.engine, a);
    final inspection = (await h.engine.inspectTurn(a))!.toJson();
    await expectLater(h.engine.deleteMessage(b, root), throwsStateError);
    await expectLater(h.engine.deleteMessage(a, 'missing'), throwsStateError);
    expect(await _snapshot(h.engine, a), before);
    expect((await h.engine.inspectTurn(a))!.toJson(), inspection);
    expect(h.engine.variables(a)['n'], 1);
    expect((await h.engine.path(b)), hasLength(1));
  });
  test('deleting an in-flight input waits for terminal macros and keeps its promoted partial answer', () async {
    final h = await _open();
    final character = await h.engine.importCard(_card());
    final chat = await h.engine.createChat(character.id);
    final greeting = (await h.engine.path(chat)).single.nodeId;
    await h.engine.setSettings({
      'globalRegexScripts': [
        _script('state', r'^([\s\S]+)$', r'{{incvar::n}}|$1', [2]),
      ],
    });
    final held = h.model.hold();
    final events = <TavernEvent>[];
    final seen = Completer<void>();
    final ended = Completer<void>();
    final subscription = h.engine
        .send(chat, '{{setvar::n::4}}Q')
        .listen(
          (event) {
            events.add(event);
            if (event is TavernTextDelta && !seen.isCompleted) seen.complete();
          },
          onError: ended.completeError,
          onDone: ended.complete,
        );
    addTearDown(subscription.cancel);
    await held.listening.future;
    held.source.add(const ModelText('PARTIAL'));
    await seen.future;
    final reply = events.whereType<TavernTurnStarted>().single.message;
    await h.engine.deleteMessage(chat, reply.parentId!);
    await ended.future;
    expect(events.whereType<TavernTurnDone>(), isEmpty);
    expect(events.whereType<TavernTurnFailed>().single.kind, TavernFailure.cancelled);
    final path = await h.engine.path(chat);
    expect(path.map((node) => node.nodeId), [greeting, reply.nodeId]);
    expect(path.last.parentId, greeting);
    expect(path.last.text, '5|PARTIAL');
    expect(h.engine.variables(chat)['n'], 5);
    final inspection = (await h.engine.inspectTurn(chat, nodeId: reply.nodeId))!.toJson();
    await h.reopen();
    expect(h.engine.variables(chat)['n'], 5);
    expect((await h.engine.inspectTurn(chat, nodeId: reply.nodeId))!.toJson(), inspection);
    expect(h.model.cancellations.single.isCancelled, isTrue);
  }, timeout: const Timeout(Duration(seconds: 15)));
  test('deleting the greeting promotes its user child and later sends keep the retained state', () async {
    final h = await _open();
    final character = await h.engine.importCard(_card());
    final chat = await h.engine.createChat(character.id);
    _done(await h.engine.send(chat, '{{incvar::n}}Q').toList());
    final before = await h.engine.path(chat);
    await h.engine.deleteMessage(chat, before.first.nodeId);
    var path = await h.engine.path(chat);
    expect(path.map((node) => node.nodeId), before.skip(1).map((node) => node.nodeId));
    expect(path.first.role, TavernRole.user);
    expect(path.first.parentId, isNull);
    expect(h.engine.variables(chat)['n'], 1);
    _done(await h.engine.send(chat, '{{incvar::n}}NEXT').toList());
    path = await h.engine.path(chat);
    expect(path, hasLength(4));
    expect(path.first.nodeId, before[1].nodeId);
    expect(h.engine.variables(chat)['n'], 2);
  });
  test(
    'permanent deletion captures marked child portable state and its own legacy source hash before reparenting',
    () async {
      final h = await _open();
      final character = await h.engine.importCard(_card());
      final chat = await h.engine.createChat(character.id);
      final greeting = (await h.engine.path(chat)).single;
      final parent = await h.engine.sendOnly(chat, 'REMOVE PARENT');
      final child = await h.engine.sendOnly(chat, 'KEEP CHILD');
      final physical = <String, Object?>{
        'variables': {'physical': 'keep'},
        'foreignPhysical': [
          1,
          {'deep': true},
        ],
        'chatJsonlSourceFile': 'physical-source',
      };
      final portable = <String, Object?>{
        'variables': {'portable': 'keep'},
        'chatJsonlSourceFile': 'legacy-source',
        'timedWorldInfo': {
          'sticky': {
            'entry': {'end': 8},
          },
        },
        'foreignPortable': [false, null],
      };
      _inspect(h, (db) {
        final metadata = _map(
          jsonDecode(db.select('SELECT metadata FROM chats WHERE id = ?', [chat]).single['metadata'] as String),
        );
        final own = _map(metadata['dshgo']);
        final provenance = _map(own['chatJsonl']);
        provenance['sources'] = {
          ..._map(provenance['sources']),
          'legacy-source': {
            'chat_metadata': {'chat_id_hash': 41},
          },
          'physical-source': {
            'chat_metadata': {'chat_id_hash': 73},
          },
        };
        own['chatJsonl'] = provenance;
        metadata['dshgo'] = own;
        metadata['chat_id_hash'] = 999;
        db.execute('UPDATE chats SET metadata = ? WHERE id = ?', [jsonEncode(metadata), chat]);
        db.execute('UPDATE node_states SET full_json = ?, delta_json = ? WHERE node_id = ?', [
          jsonEncode(physical),
          '[]',
          child.nodeId,
        ]);
        db.execute('UPDATE nodes SET extra = ? WHERE id = ?', [
          jsonEncode({
            'foreign': ['unchanged'],
            'dshgo': {'tavernState': portable, 'branchName': 'MARKED'},
          }),
          child.nodeId,
        ]);
      });
      final token = await h.engine.deleteFrom(chat, child.nodeId);
      await h.engine.deleteMessage(chat, parent.nodeId);
      _inspect(h, (db) {
        final row = db.select('SELECT parent_id, deleted_by, extra FROM nodes WHERE id = ?', [child.nodeId]).single;
        expect(row['parent_id'], greeting.nodeId);
        expect(row['deleted_by'], token);
        final extra = _map(jsonDecode(row['extra'] as String));
        expect(extra['foreign'], ['unchanged']);
        expect(_map(extra['dshgo'])['branchName'], 'MARKED');
        expect(_map(_map(extra['dshgo'])['tavernState']), {...portable, 'stChatIdHash': 41});
        final saved = db.select('SELECT full_json FROM node_states WHERE node_id = ?', [child.nodeId]).single;
        expect(jsonDecode(saved['full_json'] as String), physical);
      });
      expect(await h.engine.undoDeleteFrom(chat, token), isTrue);
      // Permanent reparenting invalidates the old token's saved parent and
      // selection. Undo restores visibility, not the removed message edge.
      expect((await h.engine.path(chat)).single.nodeId, greeting.nodeId);
      await h.engine.selectSibling(chat, child.nodeId, 0);
      expect((await h.engine.path(chat)).map((node) => node.nodeId), [greeting.nodeId, child.nodeId]);
      expect(await h.engine.readVariables(chat), {'portable': 'keep'});
      final metadata = _map((await _snapshot(h.engine, chat))['metadata']);
      expect(metadata['chat_id_hash'], 41);
      expect(metadata['timedWorldInfo'], portable['timedWorldInfo']);
      await h.reopen();
      expect(await h.engine.readVariables(chat), {'portable': 'keep'});
      expect((await h.engine.tree(chat)).last.branchName, 'MARKED');
    },
  );

  test('failure restoring facade variables rolls back permanent reparent state search and latest inspection', () async {
    final h = await _open();
    final character = await h.engine.importCard(_card());
    final chat = await h.engine.createChat(character.id);
    final reply = _done(await h.engine.send(chat, '{{setvar::n::7}}REMOVE INPUT').toList());
    final before = await _snapshot(h.engine, chat);
    final inspection = (await h.engine.inspectTurn(chat))!.toJson();
    final states = _inspect(
      h,
      (db) =>
          db.select('SELECT * FROM node_states ORDER BY node_id').map((row) => Map<String, Object?>.from(row)).toList(),
    );
    _inspect(
      h,
      (db) => db.execute('''CREATE TRIGGER reject_single_runtime BEFORE UPDATE OF variables ON chats
      BEGIN SELECT RAISE(ABORT, 'single_runtime'); END'''),
    );
    await expectLater(h.engine.deleteMessage(chat, reply.parentId!), throwsA(isA<SqliteException>()));
    expect(await _snapshot(h.engine, chat), before);
    expect((await h.engine.inspectTurn(chat))!.toJson(), inspection);
    expect(await h.engine.readVariables(chat), {'n': '7'});
    expect((await h.engine.searchChat(chat, 'REMOVE INPUT')).single.nodeId, reply.parentId);
    _inspect(h, (db) {
      expect(
        db.select('SELECT * FROM node_states ORDER BY node_id').map((row) => Map<String, Object?>.from(row)).toList(),
        states,
      );
      db.execute('DROP TRIGGER reject_single_runtime');
    });
    await h.engine.deleteMessage(chat, reply.parentId!);
    expect((await h.engine.path(chat)), hasLength(2));
  });
}

final _at = DateTime.utc(2026, 11, 10, 12);

Future<_Harness> _open({double Function()? random}) async {
  final directory = await Directory.systemTemp.createTemp('dsh-t16-delete-');
  final model = _Model();
  final config = TavernModelConfig(apiKey: () async => 'fixture-only', model: 'fixture');
  final draw = random ?? () => 0.25;
  final engine = await TavernEngine.openDirectory(
    directory,
    config: config,
    modelClient: model,
    clock: () => _at,
    random: draw,
  );
  final h = _Harness(directory, config, model, engine, draw);
  addTearDown(h.dispose);
  return h;
}

class _Harness {
  _Harness(this.directory, this.config, this.model, this.engine, this.random);
  final Directory directory;
  final TavernModelConfig config;
  final _Model model;
  TavernEngine engine;
  final double Function() random;

  Future<String> importChat(
    String characterId,
    List<Map<String, Object?>> rows, {
    Map<String, Object?> variables = const {},
  }) async {
    final document = StChatDocument(
      fileName: 'main.jsonl',
      header: {
        'user_name': 'User',
        'character_name': 'Guide',
        'chat_metadata': {'variables': variables},
      },
      messages: rows,
    );
    return (await engine.importChats(characterId, [
      TavernChatFile(fileName: document.fileName, bytes: document.encode()),
    ])).chatIds.single;
  }

  Future<void> reopen() async {
    await engine.close();
    engine = await TavernEngine.openDirectory(
      directory,
      config: config,
      modelClient: model,
      clock: () => _at,
      random: random,
    );
  }

  Future<void> dispose() async {
    await engine.close();
    for (final value in model.held) {
      if (!value.source.isClosed) {
        unawaited(value.source.close());
      }
    }
    await directory.delete(recursive: true);
  }
}

class _Held {
  _Held() {
    source = StreamController<ModelDelta>(sync: true, onListen: listening.complete);
  }
  final listening = Completer<void>();
  late final StreamController<ModelDelta> source;
}

class _Model extends TavernModelClient {
  final bodies = <Map<String, Object?>>[];
  final cancellations = <ModelCancellation>[];
  final held = <_Held>[];
  _Held? next;

  _Held hold() {
    final value = _Held();
    held.add(value);
    next = value;
    return value;
  }

  @override
  Stream<ModelDelta> generate({
    required TavernModelConfig config,
    required Map<String, Object?> body,
    required ModelCancellation cancellation,
    void Function(int attempt)? onRequestStarted,
  }) {
    bodies.add(_map(body));
    cancellations.add(cancellation);
    final waiting = next;
    next = null;
    return waiting?.source.stream ?? Stream.fromIterable(const [ModelText('OK'), ModelFinished('stop')]);
  }
}

Map<String, Object?> _map(Object? value) =>
    value is Map<String, Object?> ? jsonDecode(jsonEncode(value)) as Map<String, Object?> : {};
Future<Map<String, Object?>> _snapshot(TavernEngine engine, String chat) async {
  final file = (await engine.exportChat(chat, fileName: 'snapshot.jsonl')).first;
  final document = StChatDocument.decode(file.fileName, file.bytes);
  final metadata = _map(document.header['chat_metadata'])..remove('integrity');
  return {'metadata': metadata, 'messages': document.messages};
}

TavernMessage _done(List<TavernEvent> events) {
  expect(events.whereType<TavernTurnFailed>(), isEmpty);
  return events.whereType<TavernTurnDone>().single.message;
}

Map<String, Object?> _script(
  String id,
  String pattern,
  String replacement,
  List<int> placements, {
  bool prompt = false,
}) => {
  'id': id,
  'scriptName': id,
  'findRegex': pattern,
  'replaceString': replacement,
  'placement': placements,
  'promptOnly': prompt,
  'markdownOnly': false,
  'disabled': false,
  'runOnEdit': false,
  'substituteRegex': 0,
  'trimStrings': <String>[],
};
Uint8List _card([Map<String, Object?> fields = const {}]) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'spec': 'chara_card_v3',
      'spec_version': '3.0',
      'data': {
        'name': 'Guide',
        'description': '',
        'personality': '',
        'scenario': '',
        'first_mes': 'G',
        'mes_example': '',
        'creator_notes': '',
        'system_prompt': '',
        'post_history_instructions': '',
        'alternate_greetings': <String>[],
        'tags': <String>[],
        'creator': '',
        'character_version': '',
        'extensions': <String, Object?>{},
        ...fields,
      },
    }),
  ),
);

T _inspect<T>(_Harness h, T Function(Database db) inspect) {
  final db = sqlite3.open('${h.directory.path}/tavern.sqlite3');
  try {
    return inspect(db);
  } finally {
    db.close();
  }
}
