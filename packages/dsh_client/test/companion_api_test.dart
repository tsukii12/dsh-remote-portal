import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

void main() {
  test('reads a snapshot as the bridge sends it', () {
    final snapshot = CompanionSnapshot.fromJson({
      'v': 1,
      'storeId': 'd0a90d66-ff37-4f2a-b31c-194c791ec651',
      'companionId': 'whale-girl',
      'revision': 7,
      'memoryRevision': 2,
      'capabilities': {'persistence': 'host', 'memories': true, 'automaticRecall': false},
      'asOf': 1793899800000,
      'state': {
        'valence': 0.35,
        'energy': 0.75,
        'closeness': 0.01,
        'activity': 'idle',
        'activityUntil': null,
        'lastVisitAt': 1793899700000,
        'lastInteractionAt': 1793899700000,
        'thought': 'enjoy-company',
      },
    })!;
    expect(snapshot.storeId, 'd0a90d66-ff37-4f2a-b31c-194c791ec651');
    expect(snapshot.revision, 7);
    expect(snapshot.memoryRevision, 2);
    expect(snapshot.memories, isTrue);
    expect(snapshot.automaticRecall, isFalse);
    expect(snapshot.vitals.valence, 0.35);
    expect(snapshot.vitals.closeness, 0.01);
    expect(snapshot.vitals.lastVisitAt, DateTime.fromMillisecondsSinceEpoch(1793899700000));
    expect(snapshot.vitals.activityUntil, isNull);
  });

  test('what is left of her activity is counted on the host clock', () {
    CompanionSnapshot snap(String activity, int? until) => CompanionSnapshot.fromJson({
      'storeId': 's',
      'revision': 1,
      'asOf': 1793899800000,
      'state': {'activity': activity, 'activityUntil': until},
    })!;
    expect(snap('snack', 1793899800000 + 30000).activityLeft, const Duration(seconds: 30));
    expect(snap('rest', 1793899800000 - 5000).activityLeft, Duration.zero);
    expect(snap('idle', 1793899800000 + 30000).activityLeft, Duration.zero);
    expect(snap('play', null).activityLeft, Duration.zero);
  });

  test('a snapshot without identity is not one', () {
    expect(CompanionSnapshot.fromJson({'revision': 1}), isNull);
    expect(CompanionSnapshot.fromJson({'storeId': 'x'}), isNull);
    expect(CompanionSnapshot.fromJson('nope'), isNull);
  });

  test('out-of-range or missing state stays in range', () {
    final vitals = CompanionVitals.fromJson({'valence': 3, 'energy': -1});
    expect(vitals.valence, 1);
    expect(vitals.energy, 0);
    expect(vitals.closeness, 0);
    expect(vitals.activity, 'idle');
  });

  test('a stored memory preserves source and expiry when written again', () {
    final memory = CompanionMemory.fromJson({
      'id': '2dc91037-8de1-41af-96e0-482e7309bf34',
      'kind': 'preference',
      'text': '用户更喜欢无糖茶，不喜欢咖啡。',
      'keywords': ['茶', '咖啡'],
      'pinned': false,
      'source': {'kind': 'user-confirmed', 'sessionId': 'synthetic-session', 'messageId': 'synthetic-message'},
      'expiresAt': 1793986100000,
      'createdAt': 1793899700000,
      'updatedAt': 1793899700000,
    })!;
    expect(memory.kind, 'preference');
    expect(memory.source.kind, 'user-confirmed');
    expect(memory.expiresAt, DateTime.fromMillisecondsSinceEpoch(1793986100000));
    expect(memory.toWrite(), {
      'id': '2dc91037-8de1-41af-96e0-482e7309bf34',
      'kind': 'preference',
      'text': '用户更喜欢无糖茶，不喜欢咖啡。',
      'keywords': ['茶', '咖啡'],
      'pinned': false,
      'source': {'kind': 'user-confirmed', 'sessionId': 'synthetic-session', 'messageId': 'synthetic-message'},
      'expiresAt': 1793986100000,
    });
  });

  test('new manual memories keep the existing manual source and no-expiry defaults', () {
    const memory = CompanionMemory(id: '2dc91037-8de1-41af-96e0-482e7309bf34', text: '用户手动添加的合成事实。');
    expect(memory.source.kind, 'manual');
    expect(memory.expiresAt, isNull);
    expect(memory.toWrite(), {
      'id': '2dc91037-8de1-41af-96e0-482e7309bf34',
      'kind': 'fact',
      'text': '用户手动添加的合成事实。',
      'keywords': <String>[],
      'pinned': false,
      'source': {'kind': 'manual'},
      'expiresAt': null,
    });
  });
}
