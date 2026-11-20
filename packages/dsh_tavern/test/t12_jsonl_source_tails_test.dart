import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

final _at = DateTime.utc(2026, 11, 11);
const _mainTails = <String, Object?>{
  'swipe_info': [
    <String, Object?>{'vendor': 'MAIN'},
  ],
  'variables': ['MAIN-V'],
};
const _branchTails = <String, Object?>{
  'swipe_info': [
    <String, Object?>{'vendor': 'BRANCH'},
  ],
  'variables': ['BRANCH-V'],
};
const _emptyTails = <String, Object?>{'swipe_info': <Object?>[], 'variables': <Object?>[]};

void main() {
  test('public JSONL export preserves each source tail after shared-node import and reopen', () async {
    final root = await Directory.systemTemp.createTemp('dsh-t12-source-tails-');
    TavernEngine? ownedEngine;
    addTearDown(() async {
      try {
        await ownedEngine?.close();
      } finally {
        if (await root.exists()) await root.delete(recursive: true);
      }
      expect(await root.exists(), isFalse);
      stdout.writeln('JSONL_SOURCE_TAILS_CLEANUP');
    });
    final model = T24Model();
    var keyReads = 0;
    final config = TavernModelConfig(
      apiKey: () async {
        keyReads++;
        return 'fixture-key';
      },
    );
    Future<TavernEngine> open() =>
        TavernEngine.openDirectory(root, config: config, modelClient: model, clock: () => _at);
    var engine = await open();
    ownedEngine = engine;
    Tavern facade = engine;
    final character = await facade.importCard(t24Card());

    // Ordinary single-file retention is green on the old product too.
    final ordinary = (await facade.importChats(character.id, [
      _file(_document('solo.jsonl', _branchTails)),
    ])).chatIds.single;
    expect(_tailProjection(_decode(await facade.exportChat(ordinary))), {'solo.jsonl': _branchTails});
    expect((await facade.path(ordinary)).single.text, 'A');
    expect(await facade.tree(ordinary), hasLength(1));

    final imported = await facade.importChats(character.id, [
      _file(_document('main.jsonl', _mainTails)),
      _file(_document('branch.jsonl', _branchTails, branch: true)),
    ]);
    expect(imported.chatIds, hasLength(1));
    final chatId = imported.chatIds.single;
    expect(imported.chatsByFile, {'main.jsonl': chatId, 'branch.jsonl': chatId});
    final node = (await facade.path(chatId)).single;
    expect(node.text, 'A');
    expect(node.role, TavernRole.character);
    expect(node.parentId, isNull);
    expect(await facade.tree(chatId), hasLength(1));
    expect(model.generated, 0);
    expect(keyReads, 0);

    await facade.close();
    ownedEngine = null;
    engine = await open();
    ownedEngine = engine;
    facade = engine;
    expect((await facade.path(chatId)).map((message) => (message.nodeId, message.text)), [(node.nodeId, 'A')]);
    expect(await facade.tree(chatId), hasLength(1));
    final before = _decode(await facade.exportChat(chatId));
    expect(before.map((document) => document.fileName), ['main.jsonl', 'branch.jsonl']);
    for (final document in before) {
      final row = document.messages.single;
      expect(row['mes'], 'A');
      expect(row['swipes'], ['A']);
      expect((row['variables'] as List<Object?>).take(1).toList(), [
        {'slot': 0},
      ]);
    }
    expect(model.generated, 0);
    expect(keyReads, 0);
    stdout.writeln('JSONL_SOURCE_TAILS_READY');

    // First target oracle is the complete public per-file tail projection.
    // Old raw097 returns MAIN / MAIN-V for both files after this same reopen.
    expect(_tailProjection(_decode(await facade.exportChat(chatId))), {
      'main.jsonl': _mainTails,
      'branch.jsonl': _branchTails,
    });
    final renamed = await facade.exportChat(chatId, fileName: 'renamed.jsonl');
    expect(_tailProjection(_decode(renamed)), {'renamed.jsonl': _mainTails, 'branch.jsonl': _branchTails});
    final copy = (await facade.importChats(character.id, renamed)).chatIds.single;
    expect(await facade.tree(copy), hasLength(1));
    await facade.close();
    ownedEngine = null;
    engine = await open();
    ownedEngine = engine;
    facade = engine;
    expect(_tailProjection(_decode(await facade.exportChat(copy))), {
      'renamed.jsonl': _mainTails,
      'branch.jsonl': _branchTails,
    });
    expect((await facade.path(chatId)).single.nodeId, node.nodeId);
    expect((await facade.path(copy)).single.text, 'A');
    expect(await facade.tree(copy), hasLength(1));
    expect(model.generated, 0);
    expect(keyReads, 0);
    expect(await facade.inspectTurn(chatId), isNull);
    expect(await facade.inspectTurn(copy), isNull);
  });

  test('JSONL source tails stay independent across empty, growing and portable round trips', () {
    final store = ChatStore.inMemory(clock: () => _at);
    addTearDown(store.close);
    var integrity = 0;
    final codec = ChatJsonlCodec(clock: () => _at, createIntegrity: () => 'tail-${integrity++}');
    const cases =
        <({String name, Map<String, Object?> main, Map<String, Object?> branch, bool grow, bool noActiveVariables})>[
          (name: 'same', main: _mainTails, branch: _mainTails, grow: false, noActiveVariables: false),
          (name: 'empty override', main: _mainTails, branch: _emptyTails, grow: false, noActiveVariables: false),
          (
            name: 'info only',
            main: _mainTails,
            branch: {
              'swipe_info': [
                <String, Object?>{'vendor': 'BRANCH'},
              ],
              'variables': ['MAIN-V'],
            },
            grow: false,
            noActiveVariables: false,
          ),
          (
            name: 'variables only',
            main: _mainTails,
            branch: {
              'swipe_info': [
                <String, Object?>{'vendor': 'MAIN'},
              ],
              'variables': ['BRANCH-V'],
            },
            grow: false,
            noActiveVariables: false,
          ),
          (name: 'growing family', main: _mainTails, branch: _branchTails, grow: true, noActiveVariables: false),
          (
            name: 'portable absent variable state',
            main: _emptyTails,
            branch: {
              'swipe_info': <Object?>[],
              'variables': ['BRANCH-V'],
            },
            grow: false,
            noActiveVariables: true,
          ),
        ];
    for (final value in cases) {
      var documents = [
        _document('main.jsonl', value.main, noActiveVariables: value.noActiveVariables),
        _document(
          'branch.jsonl',
          value.branch,
          branch: true,
          grow: value.grow,
          noActiveVariables: value.noActiveVariables,
        ),
      ];
      final expected = {'label.jsonl': value.main, 'branch.jsonl': value.branch};
      for (var round = 0; round < 3; round++) {
        final reason = '${value.name}, round $round';
        final imported = codec.importBatch(store, characterId: 'card', documents: documents);
        expect(imported.chatIds, hasLength(1), reason: reason);
        final chatId = imported.chatIds.single;
        expect(imported.chatsByFile.values.toSet(), {chatId}, reason: reason);
        expect(store.allNodes(chatId), hasLength(value.grow ? 2 : 1), reason: reason);
        final output = codec.exportChat(store, chatId, fileName: 'label.jsonl');
        expect(_tailProjection(output), expected, reason: reason);
        expect(output.map(_sourceName), ['main.jsonl', 'branch.jsonl'], reason: reason);
        for (final document in output) {
          final row = document.messages.single;
          expect(row['mes'], 'A', reason: reason);
          expect(row['swipes'], value.grow ? ['A', 'B'] : ['A'], reason: reason);
          final own = _ownHeader(document);
          expect(own.containsKey('files'), isFalse, reason: reason);
          if (value.noActiveVariables) {
            // The branch still needs an array despite no node owning slot 0.
            expect(store.nodeState(chatId, store.path(chatId).single.nodeId).containsKey('messageVariables'), isFalse);
            if (document.fileName == 'branch.jsonl') expect(row['variables'], [null, 'BRANCH-V']);
          }
        }
        if (round == 0 && value.name == 'same') {
          // Old catalogues have no tail table. Their original-node fallback
          // must remain usable without a schema migration.
          final metadata = store.chat(chatId).metadata;
          final own = (metadata['dshgo'] as Map<String, Object?>)['chatJsonl'] as Map<String, Object?>;
          for (final file in (own['files'] as List<Object?>).cast<Map<String, Object?>>()) {
            file.remove('unusedTails');
          }
          store.updateChat(chatId, metadata: metadata);
          expect(_tailProjection(codec.exportChat(store, chatId, fileName: 'label.jsonl')), expected);
        }
        if (round == 0 && value.grow) {
          // Selecting the previously inactive B creates a job with no matching
          // source row. It uses B's original tail, not A's per-file record.
          final selected = store.path(chatId).single.nodeId;
          final other = store.allNodes(chatId).singleWhere((node) => node.message.text == 'B');
          store.selectNode(chatId, other.message.nodeId);
          final generated = codec.exportChat(store, chatId).first;
          expect(generated.messages.single['mes'], 'B');
          expect(_tailProjection([generated])[generated.fileName], value.branch);
          store.selectNode(chatId, selected);
        }
        // Two full JSONL encoding/reimport cycles; do not reuse node IDs or
        // carry the new private catalogue directly between imports.
        documents = [for (final document in output) StChatDocument.decode(document.fileName, document.encode())];
      }
    }
  });
}

List<StChatDocument> _decode(List<TavernChatFile> files) => [
  for (final file in files) StChatDocument.decode(file.fileName, file.bytes),
];

Map<String, Object?> _tailProjection(List<StChatDocument> documents) => {
  for (final document in documents)
    document.fileName: {
      for (final key in ['swipe_info', 'variables'])
        key: (document.messages.single[key] as List<Object?>? ?? const <Object?>[])
            .skip((document.messages.single['swipes'] as List<Object?>).length)
            .toList(),
    },
};

Map<String, Object?> _ownHeader(StChatDocument document) =>
    ((document.header['chat_metadata'] as Map<String, Object?>)['dshgo'] as Map<String, Object?>)['chatJsonl']
        as Map<String, Object?>;
String _sourceName(StChatDocument document) => _ownHeader(document)['sourceFileName'] as String;
TavernChatFile _file(StChatDocument document) => TavernChatFile(fileName: document.fileName, bytes: document.encode());

StChatDocument _document(
  String name,
  Map<String, Object?> tails, {
  bool branch = false,
  bool grow = false,
  bool noActiveVariables = false,
}) {
  final count = grow ? 2 : 1;
  final infoTail = tails['swipe_info'] as List<Object?>;
  final variableTail = tails['variables'] as List<Object?>;
  return StChatDocument(
    fileName: name,
    header: {
      'user_name': 'unused',
      'character_name': 'unused',
      'chat_metadata': {if (branch) 'main_chat': 'main'},
    },
    messages: [
      {
        'name': 'Alice',
        'is_user': false,
        'is_system': false,
        'send_date': _at.toIso8601String(),
        'mes': 'A',
        'swipes': grow ? ['A', 'B'] : ['A'],
        'swipe_id': 0,
        'swipe_info': [<String, Object?>{}, if (grow) null, ...infoTail],
        if (!noActiveVariables || variableTail.isNotEmpty)
          'variables': [
            for (var index = 0; index < count; index++) noActiveVariables ? null : {'slot': index},
            ...variableTail,
          ],
        'extra': <String, Object?>{
          if (noActiveVariables)
            'dshgo': <String, Object?>{
              'chatJsonl': <String, Object?>{'version': 1, 'hasMessageVariables': false},
            },
        },
      },
    ],
  );
}
