import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:dsh_tavern/src/store/chat_store.dart';
import 'package:dsh_tavern/src/tool_policy.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

// Build genuine store records, then query through the public engine facade.
// SQL changes after open preserve states that startup recovery would consume.
void main() {
  test('usage totals selected replies by model and UTC time, then follows branch selection and deletion', () async {
    final h = await _Fixture.open();
    final empty = h.store.createChat(characterId: 'host');
    final chat = h.store.createChat(characterId: 'host');
    h.store.saveGroup(
      TavernGroupChat(
        chatId: chat,
        title: 'Group',
        hostCharacterId: 'host',
        members: const [
          TavernGroupMember(
            characterId: 'host',
            talkativeness: 0.5,
            muted: false,
            modelRole: TavernGroupModelRole.main,
          ),
          TavernGroupMember(
            characterId: 'guest',
            talkativeness: 0.5,
            muted: false,
            modelRole: TavernGroupModelRole.helper,
          ),
        ],
        activation: TavernGroupActivation.listOrder,
        maxSpeakersPerTurn: 2,
        allowSelfResponses: false,
      ),
    );
    final root = h.append(chat, null, reported: _reported(10, 2, 1, model: 'main'));
    final user = h.append(
      chat,
      root,
      role: TavernRole.user,
      reported: _reported(900, 90, 90, model: 'ignored-user'),
    );
    final hidden = h.append(
      chat,
      user,
      hidden: true,
      actor: 'guest',
      reported: _reported(20, 4, 3, model: 'helper'),
    );
    final anonymous = h.append(chat, hidden, reported: _reported(5, 1, 2));
    final zero = h.append(chat, anonymous, reported: _reported(0, 0, 0));
    final estimated = h.append(chat, zero);
    h.now = DateTime.utc(2026, 11, 16, 9);
    final tail = h.append(chat, estimated, reported: _reported(7, 1, 4, model: 'main'));
    final streaming = h.append(chat, tail, reported: _reported(100, 30, 50, model: 'helper'));
    final alternative = h.append(
      chat,
      user,
      makeCurrent: false,
      reported: _reported(800, 80, 80, model: 'alternative'),
    );
    final other = h.store.createChat(characterId: 'other');
    h.append(other, null, reported: _reported(700, 70, 70, model: 'other-chat'));
    final Tavern tavern = await h.engine();
    h.sql(
      (database) => database.execute('UPDATE nodes SET stream_text = ? WHERE id = ?', ['pending reply', streaming]),
    );

    const mainUsage = {
      ('main', 5, 12): [10, 2, 1, 1],
      ('main', 1, 9): [7, 1, 4, 1],
      ('helper', 5, 12): [20, 4, 3, 1],
      (null, 5, 12): [5, 1, 2, 2],
    };
    expect(await tavern.pathUsage(empty), isEmpty);
    expect(_usage(await tavern.pathUsage(chat)), mainUsage);
    expect(_usage(await tavern.pathUsage(other)), {
      ('other-chat', 1, 9): [700, 70, 70, 1],
    });
    await tavern.selectNode(chat, alternative);
    expect(_usage(await tavern.pathUsage(chat)), {
      ('main', 5, 12): [10, 2, 1, 1],
      ('alternative', 1, 9): [800, 80, 80, 1],
    });
    await tavern.deleteFrom(chat, alternative);
    expect((await tavern.path(chat)).map((message) => message.nodeId), [
      root,
      user,
      hidden,
      anonymous,
      zero,
      estimated,
      tail,
      streaming,
    ], reason: 'Deleting the selected branch restores its surviving sibling and remembered descendants.');
    expect(_usage(await tavern.pathUsage(chat)), mainUsage);
  });

  test('a continued report uses its new UTC request hour without changing the original reply time', () async {
    final h = await _Fixture.open();
    final chat = h.store.createChat(characterId: 'host');
    final older = h.append(chat, null, reported: _reported(10, 2, 1, model: 'main'));
    final continued = h.append(chat, older, reported: _reported(11, 3, 2, model: 'main'));
    final originalAt = h.store.message(chat, continued).at;
    h.store.updateMessage(
      chat,
      continued,
      extra: {
        'dshgo': {
          'inspection': {
            'version': 1,
            'chatId': chat,
            'nodeId': continued,
            'startedAt': '2026-11-15T01:30:00+02:00',
            'reportedUsage': _reported(19, 4, 3, model: 'main'),
          },
        },
      },
    );
    expect(h.store.message(chat, continued).at, originalAt);
    final Tavern tavern = await h.engine();
    expect(_usage(await tavern.pathUsage(chat)), {
      ('main', 5, 12): [10, 2, 1, 1],
      ('main', 6, 23): [19, 4, 3, 1],
    });
  });

  test('an active continuation excludes its old report before the first streaming checkpoint', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final reply = await h.reply(
      'OLD',
      usage: const TavernUsage(promptTokens: 31, cacheHitTokens: 7, completionTokens: 5, model: 'previous'),
    );
    final call = h.model.prepare();
    final events = T24Events(h.engine.continueReply(h.chatId, reply.nodeId));
    await call.listening.future.timeout(const Duration(seconds: 10));
    final database = sqlite3.open('${h.root.path}/tavern.sqlite3');
    try {
      final row = database.select('SELECT stream_text, reported_usage FROM nodes WHERE id = ?', [reply.nodeId]).single;
      expect(row['stream_text'], isNull);
      expect((jsonDecode(row['reported_usage'] as String) as Map<String, Object?>)['promptTokens'], 31);
    } finally {
      database.close();
    }
    expect(await h.engine.pathUsage(h.chatId), isEmpty);
    call.fail(TavernFailure.network, 'nothing received');
    await events.done.future;
    expect(events.values.whereType<TavernTurnFailed>(), hasLength(1));
    expect(_usage(await h.engine.pathUsage(h.chatId)), {
      ('previous', 2, 12): [31, 7, 5, 1],
    });
  });

  test('recent tool turns are ordered, scoped to the chat and limited', () async {
    final h = await _Fixture.open();
    final chat = h.store.createChat(characterId: 'host');
    final other = h.store.createChat(characterId: 'host');
    final empty = h.store.createChat(characterId: 'host');
    final first = h.completedTurn(chat);
    final foreign = h.completedTurn(other);
    final second = h.completedTurn(chat);
    final third = h.completedTurn(chat);
    final Tavern tavern = await h.engine();
    expect(_turns(await tavern.recentToolTurns(chat, limit: 2)), [
      [third.logicalTurnId, third.replyNodeId],
      [second.logicalTurnId, second.replyNodeId],
    ]);
    expect(_turns(await tavern.recentToolTurns(chat)), [
      [third.logicalTurnId, third.replyNodeId],
      [second.logicalTurnId, second.replyNodeId],
      [first.logicalTurnId, first.replyNodeId],
    ]);
    expect(_turns(await tavern.recentToolTurns(other, limit: 1)), [
      [foreign.logicalTurnId, foreign.replyNodeId],
    ]);
    expect(await tavern.recentToolTurns(empty), isEmpty);
    expect(await tavern.recentToolTurns(chat, limit: 0), isEmpty);
    await expectLater(tavern.recentToolTurns(chat, limit: -1), throwsArgumentError);
    await expectLater(tavern.recentToolTurns('missing-chat', limit: 0), throwsStateError);
  });

  test('tool summaries leave failed preparation unanchored and follow reply deletion and undo', () async {
    final h = await _Fixture.open();
    final chat = h.store.createChat(characterId: 'host');
    final kept = h.completedTurn(chat);
    final failed = h.failedContinuation(chat, kept.replyNodeId);
    final removed = h.completedTurn(chat);
    final Tavern tavern = await h.engine();
    final deletion = await tavern.deleteFrom(chat, removed.replyNodeId);
    expect(
      h.sql(
        (database) =>
            database.select('SELECT deleted_by FROM nodes WHERE id = ?', [removed.replyNodeId]).single['deleted_by'],
      ),
      deletion,
    );
    expect(_turns(await tavern.recentToolTurns(chat)), [
      [removed.logicalTurnId, null],
      [failed, null],
      [kept.logicalTurnId, kept.replyNodeId],
    ]);
    expect(await tavern.undoDeleteFrom(chat, deletion), isTrue);
    expect(_turns(await tavern.recentToolTurns(chat, limit: 1)), [
      [removed.logicalTurnId, removed.replyNodeId],
    ], reason: 'Undo restores the same physical reply; this link is not memory eligibility.');
  });
}

Map<(String?, int, int), List<int>> _usage(List<TavernPathUsage> values) => {
  for (final value in values)
    (value.model, value.utcWeekday, value.utcHour): [
      value.promptTokens,
      value.cacheHitTokens,
      value.completionTokens,
      value.replyCount,
    ],
};

List<List<String?>> _turns(List<TavernToolTurnSummary> values) => [
  for (final value in values) [value.logicalTurnId, value.replyNodeId],
];

Map<String, Object?> _reported(int prompt, int cache, int completion, {String? model}) => {
  'promptTokens': prompt,
  'cacheHitTokens': cache,
  'completionTokens': completion,
  'model': ?model,
};

class _Fixture {
  _Fixture(this.root) {
    store = ChatStore.open('${root.path}/tavern.sqlite3', clock: () => now, createId: nextId);
  }

  static Future<_Fixture> open() async {
    final h = _Fixture(await Directory.systemTemp.createTemp('dsh-cheap-reads-'));
    addTearDown(() async {
      if (h._engine != null) {
        await h._engine!.close();
      } else {
        await h.store.close();
      }
      await h.root.delete(recursive: true);
    });
    return h;
  }

  final Directory root;
  late final ChatStore store;
  TavernEngine? _engine;
  var now = DateTime.utc(2026, 11, 13, 12);
  var serial = 0;
  String nextId() => 'fixture-${++serial}';

  Future<TavernEngine> engine() async {
    await store.close();
    final opened = await TavernEngine.openDirectory(root);
    _engine = opened;
    return opened;
  }

  T sql<T>(T Function(Database) action) {
    final database = sqlite3.open('${root.path}/tavern.sqlite3');
    try {
      return action(database);
    } finally {
      database.close();
    }
  }

  String append(
    String chat,
    String? parent, {
    String? id,
    String actor = 'host',
    TavernRole role = TavernRole.character,
    bool hidden = false,
    bool makeCurrent = true,
    Map<String, Object?>? reported,
  }) {
    final node = id ?? nextId();
    return store
        .append(
          chat,
          id: node,
          parentId: parent,
          role: role,
          speaker: actor,
          speakerCharacterId: actor,
          text: 'ordinary reply',
          hidden: hidden,
          makeCurrent: makeCurrent,
          state: const {},
          usage: const TavernUsage(promptTokens: 9999, completionTokens: 8888),
          extra: reported == null
              ? const {}
              : {
                  'dshgo': {
                    'inspection': {'version': 1, 'chatId': chat, 'nodeId': node, 'reportedUsage': reported},
                  },
                },
        )
        .nodeId;
  }

  StoredToolTurnOwner begin(String chat, {String? target}) {
    final scope = toolPolicySnapshot(globalSettings: const {});
    final card = captureToolCardPolicy(const {}, characterId: 'host');
    final policy = captureToolPolicy(scope: scope, host: card, actor: card);
    final owner = store
        .beginToolTurn(
          owner: Object(),
          logicalTurnId: nextId(),
          chatId: chat,
          operation: target == null ? StoredToolOperation.send : StoredToolOperation.continueReply,
          actorCharacterId: 'host',
          hostCharacterId: 'host',
          groupRoundId: null,
          operationTargetNodeId: target,
          policyScope: scope,
          capturedPolicy: policy.toJson(),
          onCommitted: (_) {},
        )
        .value;
    store.sealToolPreparation(owner, capture: (chat, target) => chat, onCommitted: (_) {});
    return owner;
  }

  ({String logicalTurnId, String replyNodeId}) completedTurn(String chat) {
    final owner = begin(chat);
    final user = store
        .commitToolUserAppend(
          owner,
          parentId: store.chat(chat).currentLeafId,
          speaker: 'User',
          text: 'question',
          state: const {},
          variables: const {},
          prepare: (message, source) => message,
          onCommitted: (_) {},
        )
        .value;
    final reply = store
        .bindToolCandidate(
          owner,
          parentId: user.nodeId,
          speaker: 'Guide',
          state: const {},
          variables: const {},
          extra: const {},
          prepare: (message, source) => message,
          onCommitted: (_) {},
        )
        .value;
    store.finishToolTurn(
      owner,
      kind: StoredToolFinishKind.normal,
      outcome: 'normal',
      summary: const {},
      stateSettlements: const [],
      action: () => store.updateMessage(chat, reply.nodeId, text: 'finished reply'),
      onCommitted: (_) {},
    );
    return (logicalTurnId: owner.logicalTurnId, replyNodeId: reply.nodeId);
  }

  String failedContinuation(String chat, String target) {
    final owner = begin(chat, target: target);
    final cleanup = store.rollbackPreparingToolTurn(
      owner,
      plan: StoredToolRollbackPlan(
        appendedUserSource: null,
        continuationRestore: null,
        firstMessageRestore: null,
        previousSelections: const [],
        selectedLeafId: target,
        variables: const {},
      ),
      outcome: 'cancelled',
      summary: const {},
      audit: (facts) => facts,
      onCommitted: (_) {},
    );
    expect(cleanup.snapshot.replyCommitAdopted, isFalse);
    expect(cleanup.facts.visibleReply!.nodeId, target);
    return owner.logicalTurnId;
  }
}
