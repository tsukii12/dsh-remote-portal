import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

// Rebuilt in wave 2 from HANDOFF and CANCEL-AND-STATE-RECOVERY. The lost
// first-wave 35-test file is not the source of this file.
void main() {
  group('T11 JSONL runtime state', () {
    late ChatStore store;
    late ChatJsonlCodec codec;
    var integrity = 0;
    setUp(() {
      store = ChatStore.inMemory(clock: () => _at);
      codec = ChatJsonlCodec(
        clock: () => _at,
        createIntegrity: () {
          integrity++;
          return 'state-$integrity';
        },
      );
    });
    tearDown(() => store.close());

    String load(List<StChatDocument> documents) =>
        codec.importBatch(store, characterId: 'card', documents: documents).chatIds.single;

    test('native file-end timers, decorators and greeting do not fill history or an unknown alternate', () {
      final chat = load([
        _document(
          'Review.jsonl',
          [
            _row('EARLY', user: true),
            {
              ..._row('SELECTED'),
              'swipes': ['SELECTED', 'UNKNOWN'],
              'swipe_id': 0,
              'swipe_info': [<String, Object?>{}, <String, Object?>{}],
            },
          ],
          metadata: {
            'variables': {'n': 3},
            'timedWorldInfo': _timers(3),
            'decoratorState': _admissions(2),
            'greetingIndex': 2,
            'chat_id_hash': 42,
            'opaque': {
              'keep': ['鲸', null],
            },
          },
        ),
      ]);
      final path = store.path(chat);
      final early = codec.metadataForNode(store, chat, nodeId: path.first.nodeId);
      expect(_map(early['timedWorldInfo']), isEmpty);
      expect(_map(early['decoratorState']), isEmpty);
      expect(early.containsKey('greetingIndex'), isFalse);
      final terminal = codec.metadataForNode(store, chat);
      expect(terminal['timedWorldInfo'], _timers(3));
      expect(terminal['decoratorState'], _admissions(2));
      expect(terminal['greetingIndex'], 2);
      expect(terminal['variables'], {'n': 3});
      (terminal['opaque']! as Map<String, Object?>)['keep'] = 'mutated';
      expect(codec.metadataForNode(store, chat)['opaque'], {
        'keep': ['鲸', null],
      });

      final alternate = store.children(chat, path.first.nodeId)[1].message;
      final unknown = codec.metadataForNode(store, chat, nodeId: alternate.nodeId);
      expect(_map(unknown['timedWorldInfo']), isEmpty);
      expect(_map(unknown['decoratorState']), isEmpty);
      expect(unknown.containsKey('greetingIndex'), isFalse);
      store.selectNode(chat, alternate.nodeId);
      final output = codec.exportChat(store, chat).first;
      expect(_map(_map(output.header['chat_metadata'])['timedWorldInfo']), isEmpty);
      expect(_map(_map(output.header['chat_metadata'])['decoratorState']), isEmpty);
      store.selectNode(chat, path.last.nodeId);
      final restored = codec.exportChat(store, chat).first;
      expect(_map(restored.header['chat_metadata'])['timedWorldInfo'], _timers(3));
      expect(_map(restored.header['chat_metadata'])['decoratorState'], _admissions(2));
      expect(_map(restored.header['chat_metadata'])['greetingIndex'], 2);
    });

    for (final hash in <num?>[null, 0, 0.5, 42]) {
      test('portable cache $hash and branch state win over a stale final header and survive roundtrip', () {
        final state = <String, Object?>{
          'variables': {'n': 7},
          'stChatId': 'CaseSensitive',
          'stChatIdHash': hash,
          'timedWorldInfo': _timers(7),
          'decoratorState': _admissions(7),
          'greetingIndex': 7,
        };
        final chat = load([
          _document(
            'original.jsonl',
            [_row('SAME', state: state)],
            metadata: {
              'variables': {'n': 99},
              'chat_id_hash': 999,
              'timedWorldInfo': _timers(99),
              'decoratorState': _admissions(99),
              'greetingIndex': 99,
            },
          ),
        ]);
        void check(ChatStore target, String id) {
          final metadata = codec.metadataForNode(target, id);
          expect(metadata['variables'], {'n': 7});
          expect(metadata['timedWorldInfo'], _timers(7));
          expect(metadata['decoratorState'], _admissions(7));
          expect(metadata['greetingIndex'], 7);
          expect(metadata.containsKey('chat_id_hash'), hash != null);
          if (hash != null) {
            expect(metadata['chat_id_hash'], hash);
          }
          final own = _nodeState(target, id, target.chat(id).currentLeafId!);
          expect(own['stChatId'], 'CaseSensitive');
          expect(own.containsKey('stChatIdHash'), isTrue);
          expect(own['stChatIdHash'], hash);
        }

        check(store, chat);
        final output = codec.exportChat(store, chat, fileName: 'renamed.jsonl');
        final other = ChatStore.inMemory(clock: () => _at);
        addTearDown(other.close);
        final imported = codec.importBatch(other, characterId: 'card', documents: output).chatIds.single;
        check(other, imported);
      });
    }

    const cacheCases = [
      (name: 'H1 portable zero overrides header 42', first: 42, second: 42, portable: 0, opaque: false, nodes: 2),
      (name: 'H2 portable null overrides header 42', first: 42, second: 42, portable: null, opaque: false, nodes: 2),
      (name: 'H3 portable 42 overrides header zero', first: 0, second: 0, portable: 42, opaque: false, nodes: 1),
      (
        name: 'H4 equivalent effective cache ignores stale header',
        first: 0,
        second: 999,
        portable: 42,
        opaque: false,
        nodes: 1,
      ),
      (
        name: 'H5 unknown configuration still separates branches',
        first: 0,
        second: 999,
        portable: 42,
        opaque: true,
        nodes: 2,
      ),
    ];
    for (final c in cacheCases) {
      test(c.name, () {
        final chat = load([
          _document(
            'Main.jsonl',
            [
              _row('SAME', state: {'variables': <String, Object?>{}, 'stChatId': 'review', 'stChatIdHash': c.portable}),
            ],
            metadata: {'chat_id_hash': c.first, if (c.opaque) 'opaqueMarker': 'M'},
          ),
          _document(
            'Branch.jsonl',
            [
              _row('SAME', state: {'variables': <String, Object?>{}, 'stChatId': 'Review', 'stChatIdHash': c.portable}),
            ],
            metadata: {'main_chat': 'Main', 'chat_id_hash': c.second, if (c.opaque) 'opaqueMarker': 'B'},
          ),
        ]);
        expect(store.allNodes(chat), hasLength(c.nodes));
        for (final node in store.allNodes(chat)) {
          final metadata = codec.metadataForNode(store, chat, nodeId: node.message.nodeId);
          expect(metadata.containsKey('chat_id_hash'), c.portable != null);
          if (c.portable != null) {
            expect(metadata['chat_id_hash'], c.portable);
          }
        }
        if (c.opaque) {
          expect(
            store
                .allNodes(chat)
                .map((node) => codec.metadataForNode(store, chat, nodeId: node.message.nodeId)['opaqueMarker']),
            unorderedEquals(['M', 'B']),
          );
        }
        // Retain raw provenance even when H4 can share a runtime node.
        final files = _map(_map(store.chat(chat).metadata['dshgo'])['chatJsonl'])['files']! as List<Object?>;
        expect(files.map((file) => _map(_map(_map(file)['header'])['chat_metadata'])['chat_id_hash']), [
          c.first,
          c.second,
        ]);
      });
    }

    for (final c in [
      (file: 'Review.JSONL', metadata: <String, Object?>{}, identity: 'Review'),
      (file: 'Review.jsonl', metadata: <String, Object?>{'main_chat': ''}, identity: ''),
      (file: 'Review.jsonl', metadata: <String, Object?>{'main_chat': 'OrIgIn'}, identity: 'OrIgIn'),
    ]) {
      test('native identity preserves case and explicit main_chat for ${c.identity}', () {
        final chat = load([
          _document(c.file, [_row('SAME')], metadata: c.metadata),
        ]);
        final state = _nodeState(store, chat, store.chat(chat).currentLeafId!);
        expect(state['stChatId'], c.identity);
        final exported = codec.exportChat(store, chat, fileName: 'Different.jsonl');
        final other = ChatStore.inMemory(clock: () => _at);
        addTearDown(other.close);
        final imported = codec.importBatch(other, characterId: 'card', documents: exported).chatIds.single;
        expect(_nodeState(other, imported, other.chat(imported).currentLeafId!)['stChatId'], c.identity);
      });
    }

    for (final hash in <num?>[null, 0]) {
      test('native multi-level main_chat retains the immediate identity with hash $hash', () {
        final chat = load([
          _document('Main.jsonl', [_row('SAME')], metadata: {'chat_id_hash': ?hash}),
          _document('Branch.jsonl', [_row('SAME')], metadata: {'main_chat': 'Main', 'chat_id_hash': ?hash}),
          _document('Child.jsonl', [_row('SAME')], metadata: {'main_chat': 'Branch', 'chat_id_hash': ?hash}),
        ]);
        void check(ChatStore target, String id) {
          final nodes = target.allNodes(id);
          expect(nodes, hasLength(2));
          expect(
            nodes.map((node) => _nodeState(target, id, node.message.nodeId)['stChatId']),
            unorderedEquals(['Main', 'Branch']),
          );
          for (final node in nodes) {
            final state = _nodeState(target, id, node.message.nodeId);
            expect(state.containsKey('stChatIdHash'), isTrue);
            expect(state['stChatIdHash'], hash);
          }
        }

        check(store, chat);
        final other = ChatStore.inMemory(clock: () => _at);
        addTearDown(other.close);
        final imported = codec
            .importBatch(other, characterId: 'card', documents: codec.exportChat(store, chat))
            .chatIds
            .single;
        check(other, imported);
      });
    }

    for (final externalEdit in [false, true]) {
      test('old v1 own source headers retain per-node cache with external edit=$externalEdit', () {
        final oldTerminal = <String, Object?>{
          'chat_id_hash': 12,
          'scenario': 'B',
          'timedWorldInfo': _timers(3),
          'decoratorState': _admissions(3),
          'greetingIndex': 3,
        };
        final metadata = <String, Object?>{
          ...oldTerminal,
          if (externalEdit) 'scenario': 'EDITED',
          'dshgo': {
            'chatJsonl': {'version': 1, 'runtimeContext': _canonical(oldTerminal)},
          },
        };
        Map<String, Object?> row(String label, int hash, int variable) => _row(
          label,
          state: {
            'variables': {'n': variable},
            // Missing stChatIdHash is intentional old-v1 input; not null.
          },
          own: {
            'version': 1,
            'sourceHeader': {
              'chat_metadata': {'scenario': label, 'chat_id_hash': hash},
            },
          },
        );
        final chat = load([
          _document('legacy.jsonl', [row('M', 11, 1), row('B', 12, 2)], metadata: metadata),
        ]);
        final path = store.path(chat);
        final first = codec.metadataForNode(store, chat, nodeId: path.first.nodeId);
        final last = codec.metadataForNode(store, chat, nodeId: path.last.nodeId);
        expect(first['scenario'], externalEdit ? 'EDITED' : 'M');
        expect(last['scenario'], externalEdit ? 'EDITED' : 'B');
        if (!externalEdit) {
          expect(first['chat_id_hash'], 11);
          expect(last['chat_id_hash'], 12);
          final other = ChatStore.inMemory(clock: () => _at);
          addTearDown(other.close);
          final again = codec
              .importBatch(other, characterId: 'card', documents: codec.exportChat(store, chat))
              .chatIds
              .single;
          final importedPath = other.path(again);
          expect(codec.metadataForNode(other, again, nodeId: importedPath.first.nodeId)['chat_id_hash'], 11);
          expect(codec.metadataForNode(other, again, nodeId: importedPath.first.nodeId)['scenario'], 'M');
          expect(codec.metadataForNode(other, again)['chat_id_hash'], 12);
        }
      });
    }
  });

  test('inactive edit uses its remembered old child rather than the newest child or current Main variables', () async {
    final directory = await Directory.systemTemp.createTemp('dsh-t11-edit-state-');
    Future<TavernEngine> open() => TavernEngine.openDirectory(
      directory,
      config: TavernModelConfig(apiKey: () async => 'unused'),
      clock: () => _at,
      random: () => 0.25,
    );
    var engine = await open();
    addTearDown(() async {
      await engine.close();
      await directory.delete(recursive: true);
    });
    final character = await engine.importCard(_card());
    Map<String, Object?> state(int value) => {
      'variables': {'n': value},
      'stChatId': 'shared',
      'stChatIdHash': 42,
    };
    final branchLeaf = <String, Object?>{
      ..._row('B-old', state: state(20)),
      'swipes': ['B-old', 'B-new'],
      'swipe_id': 0,
      'swipe_info': [
        {'extra': _extra(state(20))},
        {'extra': _extra(state(30))},
      ],
    };
    final result = await engine.importChats(character.id, [
      _file(_document('Main.jsonl', [_row('Main', state: state(10))], metadata: {'scenario': 'M', 'chat_id_hash': 42})),
      _file(
        _document(
          'Branch.jsonl',
          [_row('B-root', state: state(2)), _row('B-mid', state: state(3)), branchLeaf],
          metadata: {'main_chat': 'Main', 'scenario': 'B', 'chat_id_hash': 42},
        ),
      ),
    ]);
    final chat = result.chatIds.single;
    final main = (await engine.path(chat)).single;
    await engine.selectSibling(chat, main.nodeId, 1);
    final branch = await engine.path(chat);
    final branchRoot = branch.first.nodeId;
    final oldLeaf = branch.last.nodeId;
    await engine.selectSibling(chat, oldLeaf, 1);
    final newLeaf = (await engine.path(chat)).last.nodeId;
    await engine.selectSibling(chat, branchRoot, 0);
    const edit = '{{getvar::n}}|{{incvar::n}}|{{charScenario}}';
    await engine.edit(chat, branchRoot, edit);
    expect((await engine.path(chat)).map((m) => m.nodeId), [main.nodeId]);
    expect(engine.variables(chat), {'n': 10});
    await engine.selectSibling(chat, main.nodeId, 1);
    expect((await engine.path(chat)).first.text, '30|31|B');
    expect((await engine.path(chat)).last.nodeId, newLeaf);
    expect(engine.variables(chat), {'n': 31});

    await engine.selectSibling(chat, newLeaf, 0);
    expect(engine.variables(chat), {'n': 20});
    await engine.selectSibling(chat, branchRoot, 0);
    await engine.edit(chat, branchRoot, edit);
    expect((await engine.path(chat)).map((m) => m.nodeId), [main.nodeId]);
    expect(engine.variables(chat), {'n': 10});
    await engine.selectSibling(chat, main.nodeId, 1);
    expect((await engine.path(chat)).first.text, '20|21|B');
    expect((await engine.path(chat)).last.nodeId, oldLeaf);
    expect(engine.variables(chat), {'n': 21});
    await engine.selectSibling(chat, oldLeaf, 1);
    expect(engine.variables(chat), {'n': 31});
    await engine.selectSibling(chat, newLeaf, 0);
    await engine.selectSibling(chat, branchRoot, 0);
    await engine.close();
    engine = await open();
    expect(engine.variables(chat), {'n': 10});
    await engine.selectSibling(chat, main.nodeId, 1);
    expect((await engine.path(chat)).last.nodeId, oldLeaf);
    expect(engine.variables(chat), {'n': 21});
  });
}

final _at = DateTime.utc(2026, 11, 10, 12);

Map<String, Object?> _timers(int end) => {
  'sticky': {
    'book.1': {'hash': 1, 'start': 1, 'end': end, 'protected': false},
  },
  'cooldown': <String, Object?>{},
};
Map<String, Object?> _admissions(int count) => {
  '123': {'matches': count, 'lastMessageCount': count},
};
Map<String, Object?> _map(Object? value) =>
    value is Map<String, Object?> ? jsonDecode(jsonEncode(value)) as Map<String, Object?> : {};
Map<String, Object?> _nodeState(ChatStore store, String chat, String node) =>
    _map(_map(store.node(chat, node).extra['dshgo'])['tavernState']);
Map<String, Object?> _extra(Map<String, Object?> state, [Map<String, Object?> own = const {}]) => {
  'dshgo': {'tavernState': state, if (own.isNotEmpty) 'chatJsonl': own},
};
Map<String, Object?> _row(
  String text, {
  bool user = false,
  Map<String, Object?>? state,
  Map<String, Object?> own = const {},
}) => {
  'name': user ? 'User' : 'Guide',
  'is_user': user,
  'is_system': false,
  'send_date': _at.toIso8601String(),
  'mes': text,
  if (state != null) 'extra': _extra(state, own),
};
StChatDocument _document(String file, List<Map<String, Object?>> rows, {Map<String, Object?> metadata = const {}}) =>
    StChatDocument(
      fileName: file,
      header: {'user_name': 'unused', 'character_name': 'unused', 'chat_metadata': metadata},
      messages: rows,
    );
TavernChatFile _file(StChatDocument document) => TavernChatFile(fileName: document.fileName, bytes: document.encode());
String _canonical(Object? value) => jsonEncode(_ordered(value));
Object? _ordered(Object? value) {
  if (value is Map<String, Object?>) {
    final keys = value.keys.toList()..sort();
    return {for (final key in keys) key: _ordered(value[key])};
  }
  if (value is List<Object?>) {
    return value.map(_ordered).toList();
  }
  return value;
}

Uint8List _card() => Uint8List.fromList(
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
      },
    }),
  ),
);
