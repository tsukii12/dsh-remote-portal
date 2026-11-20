import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/companion.dart';
import 'package:test/test.dart';

// Verify the actual app facade in this pure Dart suite without Flutter.
// ignore: avoid_relative_lib_imports
import '../../../app/lib/companion/companion_local.dart';

typedef Json = Map<String, Object?>;
const id1 = '22222222-2222-4222-8222-222222222222';
const id2 = '33333333-3333-4333-8333-333333333333';
const id3 = '44444444-4444-4444-8444-444444444444';

File disk(Directory dir) => File('${dir.path}/light-state.json');
CompanionMemory item(
  String id, {
  String text = '合成确认记忆',
  bool pinned = false,
  DateTime? expiresAt,
  List<String> keywords = const [],
  CompanionMemorySource source = const CompanionMemorySource(),
}) => CompanionMemory(id: id, text: text, pinned: pinned, expiresAt: expiresAt, keywords: keywords, source: source);

Future<void> code(Future<Object?> Function() operation, String expected) => expectLater(
  Future<Object?>.sync(operation),
  throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', expected)),
);

Json memoryJson(CompanionMemory m) => {
  ...m.toWrite(),
  'createdAt': m.createdAt?.millisecondsSinceEpoch,
  'updatedAt': m.updatedAt?.millisecondsSinceEpoch,
};

void equivalent(Object? actual, Object? expected, [String path = r'$']) {
  if (expected is num && actual is num) {
    if (expected is int && actual is int) {
      expect(actual, expected, reason: path);
    } else {
      expect(actual, closeTo(expected.toDouble(), 1e-13), reason: path);
    }
  } else if (expected is Map && actual is Map) {
    expect(actual.keys.toSet(), expected.keys.toSet(), reason: path);
    for (final key in expected.keys) {
      equivalent(actual[key], expected[key], '$path.$key');
    }
  } else if (expected is List && actual is List) {
    expect(actual.length, expected.length, reason: path);
    for (var i = 0; i < expected.length; i++) {
      equivalent(actual[i], expected[i], '$path[$i]');
    }
  } else {
    expect(actual, expected, reason: path);
  }
}

// Fault the native temp-file operations, without a production injection API.
final class FailingTemporaryIO extends IOOverrides {
  FailingTemporaryIO({required this.failRename});
  final bool failRename;
  @override
  File createFile(String path) {
    final native = super.createFile(path);
    return path.endsWith('.tmp') ? FailingTemporaryFile(native, failRename: failRename) : native;
  }
}

class FailingTemporaryFile implements File {
  FailingTemporaryFile(this.native, {required this.failRename});
  final File native;
  final bool failRename;
  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) async {
    await native.create(recursive: recursive, exclusive: exclusive);
    return this;
  }

  @override
  Future<File> writeAsBytes(List<int> bytes, {FileMode mode = FileMode.write, bool flush = false}) async {
    await native.writeAsBytes(failRename ? bytes : bytes.take(19).toList(), mode: mode, flush: flush);
    if (!failRename) throw FileSystemException('synthetic partial temporary write failure');
    return this;
  }

  @override
  Future<File> rename(String newPath) async => throw FileSystemException('synthetic rename failure');
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) => native.delete(recursive: recursive);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory dir;
  late CompanionLocalStore store;
  var now = 1000000;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('companion-local-test-');
    now = 1000000;
    store = CompanionLocalStore(appDirectory: dir, nowMilliseconds: () => now);
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('first read persists once, with common models and isolate-wide queue', () async {
    final alias = CompanionLocalStore(appDirectory: Directory('${dir.path}/unused/..'), nowMilliseconds: () => now);
    final snapshots = await Future.wait([store.companionSnapshot(), alias.companionSnapshot()]);
    expect(snapshots[0].storeId, snapshots[1].storeId);
    expect(snapshots[0].revision, 0);
    expect(snapshots[0].memoryRevision, 0);
    expect(snapshots[0].vitals.valence, 0.25);
    expect(snapshots[0].vitals.energy, 0.75);
    expect(snapshots[0].vitals.closeness, 0);
    expect(snapshots[0].memories, isTrue);
    expect(snapshots[0].automaticRecall, isFalse);
    final before = await disk(dir).readAsString();
    now += 86400000;
    await alias.companionSnapshot();
    expect(await disk(dir).readAsString(), before);
    expect((await store.exportCompanion())['capabilities'], containsPair('persistence', 'app-local'));
  });

  test('ADDENDUM-02 facade has three-argument events and keeps chat and pack separate', () async {
    final local = CompanionLocal.at(dir, nowMilliseconds: () => now);
    final chat = File('${dir.path}/light-chat.json');
    await chat.writeAsString('synthetic chat placeholder');
    final pack = Directory('${dir.path}/pack');
    await pack.create();
    await File('${pack.path}/placeholder').writeAsString('synthetic asset');
    final initial = await local.companionSnapshot();
    final next = await local.companionEvent(initial.storeId, initial.revision, 'visit');
    expect(next.revision, 1);
    expect(await disk(dir).exists(), isTrue);
    await pack.delete(recursive: true);
    expect((await local.companionSnapshot()).storeId, initial.storeId);
    await code(() => local.companionEvent(initial.storeId, initial.revision, 'visit'), 'companion/conflict');
    await local.resetCompanion(next.storeId, next.revision);
    expect(await chat.readAsString(), 'synthetic chat placeholder');
  });

  test('analytic state: half-life, activity boundary and no absence penalty', () async {
    var read = await store.companionSnapshot();
    read = await store.companionEvent(read.storeId, read.revision, 'snack');
    expect(read.vitals.valence, closeTo(0.30, 1e-15));
    expect(read.vitals.energy, closeTo(0.78, 1e-15));
    expect(read.vitals.closeness, 0.01);
    expect(read.activityLeft, const Duration(seconds: 45));
    final saved = await disk(dir).readAsString();
    now += 45000;
    expect((await store.companionSnapshot()).vitals.activity, 'idle');
    now = 1000000 + 40 * 60000;
    expect((await store.companionSnapshot()).vitals.valence, closeTo(0.275, 1e-15));
    now = 1000000 + 2 * 3600000;
    expect((await store.companionSnapshot()).vitals.energy, closeTo(0.765, 1e-15));
    now = 1000000 + 365 * 86400000;
    read = await store.companionSnapshot();
    expect(read.vitals.closeness, 0.01);
    expect(read.vitals.valence, 0.25);
    expect(read.vitals.energy, 0.75);
    expect(await disk(dir).readAsString(), saved);
  });

  test('parallel writers cannot both pass stale CAS, queue recovers after failure', () async {
    final read = await store.companionSnapshot();
    final second = CompanionLocalStore(appDirectory: dir, nowMilliseconds: () => now);
    final results = await Future.wait<Object?>([
      store.companionEvent(read.storeId, read.revision, 'pet').then<Object?>((v) => v, onError: (Object e) => e),
      second.companionEvent(read.storeId, read.revision, 'snack').then<Object?>((v) => v, onError: (Object e) => e),
    ]);
    expect(results.whereType<CompanionSnapshot>(), hasLength(1));
    expect(results.whereType<DshRemoteException>().single.code, 'companion/conflict');
    final current = await second.companionSnapshot();
    expect(current.revision, 1);
    await second.companionEvent(current.storeId, current.revision, 'rest');
    expect((await store.companionSnapshot()).revision, 2);
  });

  test('input is detached before queueing and returned memories do not change disk', () async {
    final read = await store.companionSnapshot();
    final keywords = ['原值'];
    final pending = store.saveCompanionMemory(read.storeId, read.revision, item(id1, keywords: keywords));
    keywords[0] = '后来改动';
    await pending;
    var list = await store.companionMemories();
    expect(list.memories.single.keywords, ['原值']);
    list.memories.single.keywords[0] = '返回对象改动';
    list = await store.companionMemories();
    expect(list.memories.single.keywords, ['原值']);
  });

  test('source and expiry survive shared model read/write; no-op keeps versions and times', () async {
    final read = await store.companionSnapshot();
    final source = const CompanionMemorySource(kind: 'user-confirmed', sessionId: 's1', messageId: 'm1');
    await store.saveCompanionMemory(
      read.storeId,
      read.revision,
      item(id1, source: source, expiresAt: DateTime.fromMillisecondsSinceEpoch(now + 1000)),
    );
    final list = await store.companionMemories();
    final before = await disk(dir).readAsString();
    now += 500;
    final revision = await store.saveCompanionMemory(list.storeId, list.revision, list.memories.single);
    expect(revision, list.revision);
    expect(await disk(dir).readAsString(), before);
    expect(list.memoryRevision, 1);
    expect(list.memories.single.source.toJson(), source.toJson());
    expect(list.memories.single.expiresAt?.millisecondsSinceEpoch, 1001000);
  });

  test('delete and clear remove current exits; reset rotates identity and rejects queued old writes', () async {
    var read = await store.companionSnapshot();
    read = await store.companionEvent(read.storeId, read.revision, 'pet');
    await store.saveCompanionMemory(read.storeId, read.revision, item(id1, text: '仅供删除测试-secret', pinned: true));
    var list = await store.companionMemories();
    await store.deleteCompanionMemory(list.storeId, list.revision, id1.toUpperCase());
    expect((await store.companionMemories()).memories, isEmpty);
    expect((await store.pinnedCompanionContext()).memories, isEmpty);
    expect(jsonEncode(await store.exportCompanion()), isNot(contains('仅供删除测试-secret')));
    expect(await disk(dir).readAsString(), isNot(contains('仅供删除测试-secret')));
    list = await store.companionMemories();
    final unchanged = await store.deleteCompanionMemory(list.storeId, list.revision, id1);
    expect(unchanged, list.revision);
    await store.saveCompanionMemory(list.storeId, list.revision, item(id2));
    list = await store.companionMemories();
    final old = await store.companionSnapshot();
    await store.clearCompanionMemories(list.storeId, list.revision);
    read = await store.companionSnapshot();
    expect(read.storeId, old.storeId);
    expect(read.vitals.closeness, old.vitals.closeness);
    expect(read.memoryRevision, list.memoryRevision + 1);
    final fresh = await store.resetCompanion(read.storeId, read.revision);
    expect(fresh.storeId, isNot(read.storeId));
    expect(fresh.revision, 0);
    expect(fresh.memoryRevision, 0);
    expect(fresh.vitals.closeness, 0);
    await code(() => store.companionEvent(read.storeId, read.revision, 'pet'), 'companion/store-changed');
  });

  test('pinned selection has whole-record budget, expiry without writes and no third fallback', () async {
    var read = await store.companionSnapshot();
    await store.saveCompanionMemory(
      read.storeId,
      read.revision,
      item(id1, text: '旧', pinned: true, expiresAt: DateTime.fromMillisecondsSinceEpoch(now + 100)),
    );
    read = await store.companionSnapshot();
    now++;
    await store.saveCompanionMemory(read.storeId, read.revision, item(id2, text: '中' * 300, pinned: true));
    read = await store.companionSnapshot();
    now++;
    await store.saveCompanionMemory(read.storeId, read.revision, item(id3, text: '新' * 300, pinned: true));
    final saved = await disk(dir).readAsString();
    var context = await store.pinnedCompanionContext();
    expect(context.memories.map((m) => m.id), [id3]);
    expect(context.textCodePoints, 300);
    expect(context.truncated, isTrue);
    expect(context.nextExpiryAt?.millisecondsSinceEpoch, 1000100);
    context = await store.pinnedCompanionContext(textCodePointBudget: 250);
    expect(context.memories, isEmpty); // Third pinned record was outside C303's background-two shortlist.
    now = 1000100;
    context = await store.pinnedCompanionContext();
    expect(context.nextExpiryAt, isNull);
    expect((await store.companionMemories()).memories, hasLength(3));
    expect(await disk(dir).readAsString(), saved);
  });

  test('Unicode scalar limits, UTF-16 source limit and confirmation source validation', () async {
    final read = await store.companionSnapshot();
    final accepted = item(
      id1,
      text: '😀' * 512,
      keywords: ['🫖' * 24],
      source: CompanionMemorySource(kind: 'user-confirmed', sessionId: '😀' * 64),
    );
    await store.saveCompanionMemory(read.storeId, read.revision, accepted);
    final current = await store.companionMemories();
    final before = await disk(dir).readAsBytes();
    final invalid = [
      item(id2, text: '😀' * 513),
      item(id2, text: String.fromCharCode(0xd800)),
      item(id2, text: ' '),
      item(id2, text: 'bad\u0000text'),
      item(id2, keywords: ['x\ny']),
      item(id2, keywords: ['x' * 25]),
      item(id2, keywords: List.filled(9, 'x')),
      item(id2, source: CompanionMemorySource(sessionId: '😀' * 65)),
      item(id2, source: const CompanionMemorySource(kind: 'model-said-yes')),
      item(id2, expiresAt: DateTime.fromMillisecondsSinceEpoch(-1)),
    ];
    for (final memory in invalid) {
      await code(
        () => store.saveCompanionMemory(current.storeId, current.revision, memory),
        'companion/invalid-request',
      );
    }
    expect(await disk(dir).readAsBytes(), before);
  });

  test('no 257th memory or silent eviction', () async {
    final initial = await store.companionSnapshot();
    final doc = jsonDecode(await disk(dir).readAsString()) as Json;
    doc['memories'] = [
      for (var i = 0; i < 256; i++)
        {
          ...item('${i.toString().padLeft(8, '0')}-2222-4222-8222-222222222222').toWrite(),
          'createdAt': now,
          'updatedAt': now,
        },
    ];
    await disk(dir).writeAsString(jsonEncode(doc));
    final before = await disk(dir).readAsBytes();
    await code(
      () => store.saveCompanionMemory(initial.storeId, initial.revision, item(id1)),
      'companion/limit-reached',
    );
    expect(await disk(dir).readAsBytes(), before);
    expect((await store.companionMemories()).memories, hasLength(256));
  });

  test('clock failure does not create or rewrite data', () async {
    now = -1;
    await code(store.companionSnapshot, 'companion/unavailable');
    expect(await disk(dir).exists(), isFalse);
    now = 1000000;
    await store.companionSnapshot();
    final before = await disk(dir).readAsBytes();
    now = 8640000000000000;
    await code(store.companionSnapshot, 'companion/unavailable');
    expect(await disk(dir).readAsBytes(), before);
  });

  test('write failure is not successful and does not publish an identity', () async {
    final obstacle = File('${dir.path}/blocked');
    await obstacle.writeAsString('existing unrelated bytes');
    final blocked = CompanionLocal.at(Directory(obstacle.path), nowMilliseconds: () => now);
    await code(blocked.companionSnapshot, 'companion/io-error');
    expect(await obstacle.readAsString(), 'existing unrelated bytes');
    await obstacle.delete();
    expect((await blocked.companionSnapshot()).revision, 0);
  });

  for (final failRename in [false, true]) {
    test('atomic ${failRename ? 'rename' : 'partial write'} failure preserves old bytes and recovers', () async {
      final initial = await store.companionSnapshot();
      await store.saveCompanionMemory(initial.storeId, initial.revision, item(id1));
      final current = await store.companionSnapshot();
      final before = await disk(dir).readAsBytes();
      await IOOverrides.runWithIOOverrides(
        () => code(() => store.companionEvent(current.storeId, current.revision, 'pet'), 'companion/io-error'),
        FailingTemporaryIO(failRename: failRename),
      );
      expect(await disk(dir).readAsBytes(), before);
      // No temporary file is left behind (compared by name: Windows lists with backslashes).
      expect((await disk(dir).parent.list().toList()).map((e) => e.uri.pathSegments.last), [
        disk(dir).uri.pathSegments.last,
      ]);
      expect((await store.companionSnapshot()).revision, current.revision);
      expect((await store.companionMemories()).memories.single.text, '合成确认记忆');
      final retried = await store.companionEvent(current.storeId, current.revision, 'pet');
      expect(retried.revision, current.revision + 1);
      expect(retried.vitals.closeness, 0.01);
    });
  }

  test('corrupt files remain byte-for-byte intact even on reset', () async {
    final initial = await store.companionSnapshot();
    final valid = await disk(dir).readAsString();
    final unsupported = jsonDecode(valid) as Json;
    unsupported['v'] = 2;
    final unknownField = jsonDecode(valid) as Json;
    unknownField['unexpected'] = 'preserve me';
    final wrongTime = jsonDecode(valid) as Json;
    (wrongTime['state']! as Json)['anchorAt'] = 9007199254740991;
    final duplicate = jsonDecode(valid) as Json;
    duplicate['memories'] = [
      for (final id in [id1, id1.toUpperCase()]) {...item(id).toWrite(), 'createdAt': now, 'updatedAt': now},
    ];
    final corruptions = <List<int>>[
      utf8.encode('{broken private text'),
      [0xc3, 0x28],
      utf8.encode(jsonEncode(unsupported)),
      utf8.encode(jsonEncode(unknownField)),
      utf8.encode(jsonEncode(wrongTime)),
      utf8.encode(jsonEncode(duplicate)),
      List.filled(1024 * 1024 + 1, 32),
    ];
    for (final bytes in corruptions) {
      await disk(dir).writeAsBytes(bytes);
      await code(store.companionSnapshot, 'companion/corrupt-store');
      await code(() => store.resetCompanion(initial.storeId, initial.revision), 'companion/corrupt-store');
      expect(await disk(dir).readAsBytes(), bytes);
    }
  });

  test('revision exhaustion refuses writes while leaving original bytes', () async {
    final initial = await store.companionSnapshot();
    final doc = jsonDecode(await disk(dir).readAsString()) as Json;
    doc['revision'] = 9007199254740991;
    await disk(dir).writeAsString(jsonEncode(doc));
    final current = await store.companionSnapshot();
    final before = await disk(dir).readAsBytes();
    await code(() => store.companionEvent(current.storeId, current.revision, 'pet'), 'companion/unavailable');
    expect(await disk(dir).readAsBytes(), before);
    expect((await store.resetCompanion(initial.storeId, current.revision)).revision, 0);
  });

  final fixture = jsonDecode(File('test/fixtures/companion_local_parity.json').readAsStringSync()) as Json;
  for (final value in fixture['scenarios']! as List) {
    final scenario = value as Json;
    test('C303 oracle parity: ${scenario['name']}', () async {
      await disk(dir).parent.create(recursive: true);
      await disk(dir).writeAsString(jsonEncode(scenario['initial']));
      for (final value in scenario['actions']! as List) {
        final action = value as Json;
        now = action['at']! as int;
        final current = await store.companionSnapshot();
        final storeId = action['storeId'] as String? ?? current.storeId;
        final revision = action['revision'] as int? ?? current.revision;
        String? error;
        try {
          switch (action['op']) {
            case 'event':
              await store.companionEvent(storeId, revision, action['type']! as String);
            case 'save':
              await store.saveCompanionMemory(storeId, revision, CompanionMemory.fromJson(action['memory'])!);
            case 'delete':
              await store.deleteCompanionMemory(storeId, revision, action['id']! as String);
            case 'clear':
              await store.clearCompanionMemories(storeId, revision);
            case 'read':
              break;
            default:
              fail('unknown fixture operation');
          }
        } on DshRemoteException catch (e) {
          error = e.code;
        }
        final expected = action['expected']! as Json;
        expect(error, expected['error'], reason: '${scenario['name']}: $action');
        final exported = await store.exportCompanion()
          ..remove('capabilities');
        equivalent(exported, expected['exported']);
        equivalent(jsonDecode(await disk(dir).readAsString()), expected['stored']);
        final context = await store.pinnedCompanionContext(textCodePointBudget: 2048);
        equivalent({
          'v': 1,
          'storeId': context.storeId,
          'revision': context.revision,
          'memoryRevision': context.memoryRevision,
          'memories': context.memories.map(memoryJson).toList(),
          'truncated': context.truncated,
          'textCodePoints': context.textCodePoints,
          'nextExpiryAt': context.nextExpiryAt?.millisecondsSinceEpoch,
        }, expected['pinned']);
      }
    });
  }
}
