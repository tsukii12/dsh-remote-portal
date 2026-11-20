import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

void main() {
  test('tree includes inactive descendants and all current ancestors beyond sixty nodes', () async {
    final h = await _open();
    final character = await h.engine.importCard(_card());
    final chat = await h.engine.createChat(character.id);
    for (var i = 0; i < 35; i++) {
      _done(await h.engine.send(chat, 'Q$i').toList());
    }
    final original = (await h.engine.path(chat)).last;
    final alternate = _done(await h.engine.regenerate(chat, original.nodeId).toList());
    _done(await h.engine.send(chat, 'alternate continuation').toList());
    await h.engine.selectSibling(chat, original.nodeId, 0);
    final Tavern facade = h.engine;
    final before = await h.engine.path(chat, limit: 1000);
    final inspection = (await facade.inspectTurn(chat))!.toJson();
    final calls = h.model.bodies.length;
    final nodes = await facade.tree(chat);
    expect(nodes, hasLength(74));
    expect(before, hasLength(71));
    expect(nodes.where((node) => node.isCurrentPath).map((node) => node.nodeId), before.map((node) => node.nodeId));
    expect(nodes.where((node) => !node.isCurrentPath), hasLength(3));
    final ids = nodes.map((node) => node.nodeId).toSet();
    expect(nodes.every((node) => node.parentId == null || ids.contains(node.parentId)), isTrue);
    final selected = nodes.singleWhere((node) => node.nodeId == original.nodeId);
    final other = nodes.singleWhere((node) => node.nodeId == alternate.nodeId);
    expect((selected.siblingIndex, other.siblingIndex), (0, 1));
    expect((selected.siblingCount, other.siblingCount), (2, 2));
    expect((await h.engine.path(chat, limit: 1000)).map((node) => node.nodeId), before.map((node) => node.nodeId));
    expect((await facade.inspectTurn(chat))!.toJson(), inspection);
    expect(h.model.bodies, hasLength(calls));
  });

  test('previews keep sixty-four Unicode code points and exact role speaker time and visibility', () async {
    final h = await _open();
    final text = '${List.filled(40, '😀汉').join()}\nTAIL';
    final character = await h.engine.importCard(_card({'first_mes': text}));
    final chat = await h.engine.createChat(character.id);
    final message = (await h.engine.path(chat)).single;
    await h.engine.setHidden(chat, message.nodeId, true);
    final node = (await h.engine.tree(chat)).single;
    expect(node.nodeId, message.nodeId);
    expect(node.parentId, isNull);
    expect(node.preview, String.fromCharCodes(text.runes.take(64)));
    expect(node.preview.runes.length, 64);
    expect(node.preview, isNot(contains('\uFFFD')));
    expect(node.role, TavernRole.character);
    expect(node.speaker, message.speaker);
    expect(node.at, message.at);
    expect(node.isCurrentPath, isTrue);
    expect(node.hidden, isTrue);
    expect((await h.engine.path(chat)).single.text, text);
  });
  test('labels stay on independent siblings and clearing only removes their names', () async {
    final h = await _open();
    final character = await h.engine.importCard(_card());
    final chat = await h.engine.createChat(character.id);
    final first = (await h.engine.path(chat)).single;
    final second = _done(await h.engine.regenerate(chat, first.nodeId).toList());
    final selection = (await h.engine.path(chat)).map((node) => node.nodeId).toList();
    final Tavern facade = h.engine;
    final notification = facade.pathChanges(chat).first;
    await facade.nameBranch(chat, first.nodeId, '  雨夜 🌧  ');
    await notification.timeout(const Duration(seconds: 5));
    await facade.nameBranch(chat, second.nodeId, '晴天');
    var nodes = await facade.tree(chat);
    expect(nodes.singleWhere((node) => node.nodeId == first.nodeId).branchName, '雨夜 🌧');
    expect(nodes.singleWhere((node) => node.nodeId == second.nodeId).branchName, '晴天');
    expect((await facade.path(chat)).map((node) => node.nodeId), selection);
    expect(h.engine.variables(chat), isEmpty);
    await facade.nameBranch(chat, first.nodeId, ' \n\t ');
    await facade.nameBranch(chat, second.nodeId, null);
    nodes = await facade.tree(chat);
    expect(nodes.every((node) => node.branchName == null), isTrue);
    expect(nodes.map((node) => node.preview), [first.text, second.text]);
  });

  test('names preserve unknown extras through reopen and selected and alternate JSONL rows', () async {
    final h = await _open();
    final character = await h.engine.importCard(_card());
    final chat = await h.importChat(
      character.id,
      [
        {
          'name': 'Guide',
          'is_user': false,
          'is_system': false,
          'send_date': _at.toIso8601String(),
          'mes': 'FIRST',
          'extra': {
            'foreign': ['keep'],
            'dshgo': {
              'other': {'kept': true},
            },
          },
        },
      ],
      variables: {'n': 7},
    );
    final first = (await h.engine.path(chat)).single;
    final second = _done(await h.engine.regenerate(chat, first.nodeId).toList());
    await h.engine.nameBranch(chat, first.nodeId, 'FIRST LABEL');
    await h.engine.nameBranch(chat, second.nodeId, 'SECOND LABEL');
    final values = h.engine.variables(chat);
    await h.reopen();
    expect((await h.engine.tree(chat)).map((node) => node.branchName), ['FIRST LABEL', 'SECOND LABEL']);
    final documents = await h.engine.exportChat(chat);
    final imported = await h.engine.importChats(character.id, documents);
    final after = await h.engine.tree(imported.chatIds.single);
    expect(after.map((node) => node.branchName).toSet(), {'FIRST LABEL', 'SECOND LABEL'});
    expect(after.singleWhere((node) => node.isCurrentPath).branchName, 'SECOND LABEL');
    final decoded = StChatDocument.decode(documents.first.fileName, documents.first.bytes);
    final row = decoded.messages.single;
    final swipeExtras = (row['swipe_info']! as List<Object?>).map((value) => _map(_map(value)['extra']));
    final original = swipeExtras.singleWhere((extra) => _map(extra['dshgo'])['branchName'] == 'FIRST LABEL');
    expect(original['foreign'], ['keep']);
    expect(_map(original['dshgo'])['other'], {'kept': true});
    expect(h.engine.variables(chat), values);
  });
  test('unknown and foreign nodes fail without relabeling either chat', () async {
    final h = await _open();
    final character = await h.engine.importCard(_card());
    final a = await h.engine.createChat(character.id);
    final b = await h.engine.createChat(character.id);
    final node = (await h.engine.path(a)).single.nodeId;
    await h.engine.nameBranch(a, node, 'UNCHANGED');
    await expectLater(h.engine.tree('missing'), throwsStateError);
    await expectLater(h.engine.nameBranch(b, node, 'WRONG CHAT'), throwsStateError);
    await expectLater(h.engine.nameBranch(a, 'missing', 'MISSING'), throwsStateError);
    expect((await h.engine.tree(a)).single.branchName, 'UNCHANGED');
    expect((await h.engine.tree(b)).single.branchName, isNull);
    expect(h.model.bodies, isEmpty);
  });

  test('tree reads preserve generation and naming waits for the partial cancellation commit', () async {
    final h = await _open();
    final character = await h.engine.importCard(_card());
    final chat = await h.engine.createChat(character.id);
    final held = h.model.hold();
    final events = <TavernEvent>[];
    final textSeen = Completer<void>();
    final ended = Completer<void>();
    final subscription = h.engine
        .send(chat, 'Q')
        .listen(
          (event) {
            events.add(event);
            if (event is TavernTextDelta && !textSeen.isCompleted) textSeen.complete();
          },
          onError: ended.completeError,
          onDone: ended.complete,
        );
    addTearDown(subscription.cancel);
    await held.listening.future;
    held.source.add(const ModelText('PARTIAL'));
    await textSeen.future;
    final target = events.whereType<TavernTurnStarted>().single.message.nodeId;
    expect((await h.engine.tree(chat)).any((node) => node.nodeId == target), isTrue);
    expect(h.model.cancellations.single.isCancelled, isFalse);
    await h.engine.nameBranch(chat, target, 'KEEP THIS');
    await ended.future;
    expect(h.model.cancellations.single.isCancelled, isTrue);
    final failed = events.whereType<TavernTurnFailed>().single;
    expect(failed.kind, TavernFailure.cancelled);
    expect(failed.partial!.nodeId, target);
    expect(failed.partial!.text, 'PARTIAL');
    expect((await h.engine.tree(chat)).singleWhere((node) => node.nodeId == target).branchName, 'KEEP THIS');
    final inspection = await h.engine.inspectTurn(chat, nodeId: target);
    expect(inspection, isNotNull);
    await h.reopen();
    expect((await h.engine.inspectTurn(chat, nodeId: target))!.toJson(), inspection!.toJson());
    expect((await h.engine.tree(chat)).last.branchName, 'KEEP THIS');
  }, timeout: const Timeout(Duration(seconds: 15)));
  test('an empty chat exposes no nodes and deleted labels cannot be restored by naming', () async {
    final h = await _open();
    final character = await h.engine.importCard(_card());
    final chat = await h.engine.createChat(character.id);
    final root = (await h.engine.path(chat)).single.nodeId;
    await h.engine.nameBranch(chat, root, 'REMOVED');
    await h.engine.deleteFrom(chat, root);
    expect(await h.engine.tree(chat), isEmpty);
    await expectLater(h.engine.nameBranch(chat, root, 'RESTORE'), throwsStateError);
    await h.reopen();
    expect(await h.engine.tree(chat), isEmpty);
  });

  test('root alternatives and remembered descendants are marked from the selected leaf', () async {
    final h = await _open();
    final character = await h.engine.importCard(_card());
    final chat = await h.engine.createChat(character.id);
    final first = (await h.engine.path(chat)).single;
    final leaf = _done(await h.engine.send(chat, 'FIRST PATH').toList());
    final second = _done(await h.engine.regenerate(chat, first.nodeId).toList());
    await h.engine.nameBranch(chat, first.nodeId, 'OLD ROOT');
    await h.engine.nameBranch(chat, second.nodeId, 'NEW ROOT');
    var nodes = await h.engine.tree(chat);
    expect(nodes.where((node) => node.isCurrentPath).map((node) => node.nodeId), [second.nodeId]);
    expect(nodes.where((node) => node.parentId == null).map((node) => node.siblingIndex), [0, 1]);
    await h.engine.selectSibling(chat, second.nodeId, 0);
    nodes = await h.engine.tree(chat);
    expect(nodes.where((node) => node.isCurrentPath), hasLength(3));
    expect((await h.engine.path(chat)).last.nodeId, leaf.nodeId);
    expect(nodes.singleWhere((node) => node.nodeId == second.nodeId).isCurrentPath, isFalse);
  });
  test('tree hides soft-deleted siblings and undo restores labels hidden flags and sibling numbers', () async {
    final h = await _open();
    final character = await h.engine.importCard(_card());
    final chat = await h.engine.createChat(character.id);
    final first = (await h.engine.path(chat)).single;
    final second = _done(await h.engine.regenerate(chat, first.nodeId).toList());
    await h.engine.nameBranch(chat, second.nodeId, 'SAVED LABEL');
    await h.engine.setHidden(chat, second.nodeId, true);
    final token = await h.engine.deleteFrom(chat, second.nodeId);
    final visible = (await h.engine.tree(chat)).single;
    expect(visible.nodeId, first.nodeId);
    expect((visible.siblingIndex, visible.siblingCount, visible.isCurrentPath), (0, 1, true));
    await expectLater(h.engine.nameBranch(chat, second.nodeId, 'BLOCKED'), throwsStateError);
    expect(await h.engine.undoDeleteFrom(chat, token), isTrue);
    final restored = (await h.engine.tree(chat)).last;
    expect(restored.nodeId, second.nodeId);
    expect(restored.branchName, 'SAVED LABEL');
    expect(restored.hidden, isTrue);
    expect((restored.siblingIndex, restored.siblingCount, restored.isCurrentPath), (1, 2, true));
  });

  test('same branch name preserves undo selection while an actual rename advances tree revision', () async {
    final h = await _open();
    final character = await h.engine.importCard(_card());
    final chat = await h.engine.createChat(character.id);
    final first = (await h.engine.path(chat)).single;
    await h.engine.nameBranch(chat, first.nodeId, 'A');
    final second = _done(await h.engine.regenerate(chat, first.nodeId).toList());
    final firstToken = await h.engine.deleteFrom(chat, second.nodeId);
    expect((await h.engine.path(chat)).single.nodeId, first.nodeId);
    await h.engine.nameBranch(chat, first.nodeId, '  A  ');
    expect(await h.engine.undoDeleteFrom(chat, firstToken), isTrue);
    expect((await h.engine.path(chat)).single.nodeId, second.nodeId);
    final secondToken = await h.engine.deleteFrom(chat, second.nodeId);
    await h.engine.nameBranch(chat, first.nodeId, 'B');
    expect(await h.engine.undoDeleteFrom(chat, secondToken), isTrue);
    expect((await h.engine.path(chat)).single.nodeId, first.nodeId);
    expect((await h.engine.tree(chat)).first.branchName, 'B');
    expect((await h.engine.tree(chat)).singleWhere((node) => node.isCurrentPath).nodeId, first.nodeId);
  });

  test('tree ranks imported swipe families across hidden deletion undo and reopen', () async {
    final h = await _open();
    final character = await h.engine.importCard(_card());
    final chat = await h.importChat(character.id, _swipeTreeRows());
    final ids = await _swipeTreeIds(h.engine, chat);
    final other = await h.importChat(character.id, [
      _swipeTreeRow('OTHER ZERO', swipes: ['OTHER ZERO', 'OTHER ONE']),
    ]);
    final otherNodes = await h.engine.tree(other);
    expect(
      otherNodes.map((node) => (node.preview, node.parentId, node.siblingIndex, node.siblingCount, node.isCurrentPath)),
      [('OTHER ZERO', null, 0, 2, true), ('OTHER ONE', null, 1, 2, false)],
    );
    final otherBefore = _treeFields(otherNodes);

    await h.engine.setHidden(chat, ids[4], true);
    await h.engine.nameBranch(chat, ids[4], '离线路');
    await h.engine.nameBranch(chat, ids[1], '主根');
    expect(_treeFields(await h.engine.tree(chat)), _swipeTreeExpected(ids));
    final selected = [ids[1], ids[2], ids[5], ids[6], ids[8]];
    expect((await h.engine.path(chat)).map((node) => node.nodeId), selected);

    final token = await h.engine.deleteFrom(chat, ids[4]);
    expect(_treeFields(await h.engine.tree(chat)), _swipeTreeExpected(ids, deleted: true));
    expect((await h.engine.path(chat)).map((node) => node.nodeId), selected);
    expect(_treeFields(await h.engine.tree(other)), otherBefore);
    // Undo belongs to this open-store lifetime, before selection or reopening.
    expect(await h.engine.undoDeleteFrom(chat, token), isTrue);
    expect(_treeFields(await h.engine.tree(chat)), _swipeTreeExpected(ids));

    await h.engine.selectNode(chat, ids[3]);
    expect((await h.engine.path(chat)).map((node) => node.nodeId), [ids[1], ids[2], ids[3]]);
    expect(_treeFields(await h.engine.tree(chat)), _swipeTreeExpected(ids, stopped: true));
    await h.reopen();
    expect((await h.engine.path(chat)).map((node) => node.nodeId), [ids[1], ids[2], ids[3]]);
    expect(_treeFields(await h.engine.tree(chat)), _swipeTreeExpected(ids, stopped: true));
    expect(_treeFields(await h.engine.tree(other)), otherBefore);
    expect(h.model.bodies, isEmpty);
  });

  test('JSONL export preserves explicit swipe families and Unicode payloads', () async {
    final h = await _open();
    final character = await h.engine.importCard(_card());
    final chat = await h.importChat(character.id, _swipeTreeRows(), variables: {'n': 7});
    final ids = await _swipeTreeIds(h.engine, chat);
    await h.engine.setHidden(chat, ids[4], true);
    await h.engine.nameBranch(chat, ids[4], '离线路');
    await h.engine.nameBranch(chat, ids[1], '主根');
    await h.reopen();
    expect(_treeFields(await h.engine.tree(chat)), _swipeTreeExpected(ids));

    final files = await h.engine.exportChat(chat);
    expect(files, hasLength(1));
    final document = StChatDocument.decode(files.single.fileName, files.single.bytes);
    final rows = document.messages;
    expect(rows.map((row) => row['mes']), [
      _swipeTreeBodies[1],
      _swipeTreeBodies[2],
      _swipeTreeBodies[5],
      _swipeTreeBodies[6],
      _swipeTreeBodies[8],
    ]);
    expect(rows.map((row) => row['swipe_id']), [1, 0, 2, 0, 1]);
    expect(rows.map((row) => row['swipes']), [
      [_swipeTreeBodies[0], _swipeTreeBodies[1]],
      [_swipeTreeBodies[2]],
      [_swipeTreeBodies[3], _swipeTreeBodies[4], _swipeTreeBodies[5]],
      [_swipeTreeBodies[6]],
      [_swipeTreeBodies[7], _swipeTreeBodies[8]],
    ]);
    expect(rows.map((row) => row['is_user']), [false, true, false, true, false]);
    expect(rows.map((row) => row['name']), ['Guide', 'User', 'Guide', 'User', 'Guide']);
    expect(rows.map((row) => row['send_date']), List.filled(5, _at.toIso8601String()));
    expect(_map(rows[2]['extra'])['reasoning'], '\ufeff思考🌙');
    expect(_map(rows[2]['extra'])['foreign'], {
      'keep': [null, '值'],
    });
    final infos = rows[2]['swipe_info']! as List<Object?>;
    expect(infos, hasLength(3));
    expect(_map(_map(infos[0])['extra'])['reasoning'], '\ufeff旧思考🐋');
    expect(_map(_map(infos[0])['extra'])['foreign'], {'old': true});
    final hiddenOwn = _map(_map(_map(infos[1])['extra'])['dshgo']);
    expect(hiddenOwn['branchName'], '离线路');
    expect(_map(hiddenOwn['chatJsonl'])['hidden'], isTrue);
    expect(rows[2]['is_system'], isFalse);
    expect(_map(_map(rows[0]['extra'])['dshgo'])['branchName'], '主根');
    expect(_map(document.header['chat_metadata'])['variables'], {'n': 7});
    expect(_treeFields(await h.engine.tree(chat)), _swipeTreeExpected(ids));
    expect((await h.engine.path(chat)).map((node) => node.nodeId), [ids[1], ids[2], ids[5], ids[6], ids[8]]);

    final imported = await h.engine.importChats(character.id, files);
    expect(imported.chatIds, hasLength(1));
    final next = imported.chatIds.single;
    final nextIds = await _swipeTreeIds(h.engine, next);
    expect(_treeFields(await h.engine.tree(next)), _swipeTreeExpected(nextIds));
    expect((await h.engine.path(next)).map((node) => node.nodeId), [
      nextIds[1],
      nextIds[2],
      nextIds[5],
      nextIds[6],
      nextIds[8],
    ]);
    expect(h.engine.variables(next), {'n': 7});
    expect(_treeFields(await h.engine.tree(chat)), _swipeTreeExpected(ids));
    expect(h.model.bodies, isEmpty);
  });
}

final _at = DateTime.utc(2026, 11, 10, 12);

Future<_Harness> _open({double Function()? random}) async {
  final directory = await Directory.systemTemp.createTemp('dsh-t16-tree-');
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

TavernMessage _done(List<TavernEvent> events) {
  expect(events.whereType<TavernTurnFailed>(), isEmpty);
  return events.whereType<TavernTurnDone>().single.message;
}

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

const _swipeTreeBodies = ['\ufeff根零🌊', '根一', '问一', '\ufeff答零🐋', '答一', '答二', '问二', '尾零', '\ufeff尾一🌙'];

Map<String, Object?> _swipeTreeRow(
  String text, {
  bool user = false,
  List<String>? swipes,
  int selected = 0,
  Map<String, Object?> extra = const {},
  List<Map<String, Object?>>? swipeInfo,
}) => {
  'name': user ? 'User' : 'Guide',
  'is_user': user,
  'is_system': false,
  'send_date': _at.toIso8601String(),
  'mes': text,
  'extra': extra,
  'swipes': ?swipes,
  if (swipes != null) 'swipe_id': selected,
  'swipe_info': ?swipeInfo,
};

List<Map<String, Object?>> _swipeTreeRows() => [
  _swipeTreeRow(_swipeTreeBodies[1], swipes: [_swipeTreeBodies[0], _swipeTreeBodies[1]], selected: 1),
  _swipeTreeRow(_swipeTreeBodies[2], user: true),
  _swipeTreeRow(
    _swipeTreeBodies[5],
    swipes: [_swipeTreeBodies[3], _swipeTreeBodies[4], _swipeTreeBodies[5]],
    selected: 2,
    extra: {
      'reasoning': '\ufeff思考🌙',
      'foreign': {
        'keep': [null, '值'],
      },
    },
    swipeInfo: [
      {
        'send_date': _at.toIso8601String(),
        'extra': {
          'reasoning': '\ufeff旧思考🐋',
          'foreign': {'old': true},
        },
      },
      {'send_date': _at.toIso8601String(), 'extra': <String, Object?>{}},
      {
        'send_date': _at.toIso8601String(),
        'extra': {'reasoning': 'stale selected info'},
      },
    ],
  ),
  _swipeTreeRow(_swipeTreeBodies[6], user: true),
  _swipeTreeRow(_swipeTreeBodies[8], swipes: [_swipeTreeBodies[7], _swipeTreeBodies[8]], selected: 1),
];

Future<List<String>> _swipeTreeIds(TavernEngine engine, String chat) async {
  final nodes = await engine.tree(chat);
  expect(nodes.map((node) => node.preview), _swipeTreeBodies);
  return nodes.map((node) => node.nodeId).toList();
}

List<List<Object?>> _treeFields(List<TavernTreeNode> nodes) => [
  for (final node in nodes)
    [
      node.nodeId,
      node.parentId,
      node.role,
      node.speaker,
      node.preview,
      node.at,
      node.isCurrentPath,
      node.siblingIndex,
      node.siblingCount,
      node.hidden,
      node.branchName,
    ],
];

// Independent fixture table: fixed parent/index/count values, never regrouping
// the result. The two flags select the three explicit lifecycle expectations.
List<List<Object?>> _swipeTreeExpected(List<String> id, {bool deleted = false, bool stopped = false}) => [
  [id[0], null, TavernRole.character, 'Guide', _swipeTreeBodies[0], _at, false, 0, 2, false, null],
  [id[1], null, TavernRole.character, 'Guide', _swipeTreeBodies[1], _at, true, 1, 2, false, '主根'],
  [id[2], id[1], TavernRole.user, 'User', _swipeTreeBodies[2], _at, true, 0, 1, false, null],
  [id[3], id[2], TavernRole.character, 'Guide', _swipeTreeBodies[3], _at, stopped, 0, deleted ? 2 : 3, false, null],
  if (!deleted) [id[4], id[2], TavernRole.character, 'Guide', _swipeTreeBodies[4], _at, false, 1, 3, true, '离线路'],
  [
    id[5],
    id[2],
    TavernRole.character,
    'Guide',
    _swipeTreeBodies[5],
    _at,
    !stopped,
    deleted ? 1 : 2,
    deleted ? 2 : 3,
    false,
    null,
  ],
  [id[6], id[5], TavernRole.user, 'User', _swipeTreeBodies[6], _at, !stopped, 0, 1, false, null],
  [id[7], id[6], TavernRole.character, 'Guide', _swipeTreeBodies[7], _at, false, 0, 2, false, null],
  [id[8], id[6], TavernRole.character, 'Guide', _swipeTreeBodies[8], _at, !stopped, 1, 2, false, null],
];
