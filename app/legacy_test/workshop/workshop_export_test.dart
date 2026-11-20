import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/pets/pet_library.dart';
import 'package:dsh_app/workshop/workshop_export.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// Observe errors immediately, then let finally await every started operation.
Future<Object?> _settled(Future<void> operation) async {
  try { await operation; return null; } on Object catch (error) { return error; }
}

Future<void> _waitForWriter(Completer<void> entered, Future<Object?> finished) => Future.any<void>([
  entered.future, finished.then<void>((error) { if (error != null) throw error; }),
]);

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('workshop-export'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('canonical destination queue spans independent writers and path aliases', () async {
    final real = Directory('${temp.path}/real')..createSync();
    final alias = Link('${temp.path}/alias')..createSync(real.path);
    final firstTarget = await workshopExportTarget(File('${real.path}/new/output.zip'));
    final secondTarget = await workshopExportTarget(File('${alias.path}/new/./output.zip'));
    expect(secondTarget.path, firstTarget.path);
    final entered = Completer<void>(), release = Completer<void>();
    final first = _settled(workshopCommitExport(firstTarget, (staging) async {
      entered.complete();
      await release.future;
      await staging.writeAsString('first');
    }));
    Future<Object?>? second;
    try {
      await _waitForWriter(entered, first);
      var secondWrites = 0;
      second = _settled(workshopCommitExport(secondTarget, (staging) async {
        secondWrites++;
        await staging.writeAsString('second');
      }));
      await Future<void>.delayed(Duration.zero);
      expect(secondWrites, 0);
      release.complete();
      expect(await first, isNull);
      expect(await second, isA<WorkshopException>().having((e) => e.code, 'code', 'workshop_export_exists'));
      expect(firstTarget.readAsStringSync(), 'first');
      expect(secondWrites, 0);
    } finally {
      if (!release.isCompleted) release.complete();
      await first;
      if (second != null) await second;
    }
  });

  test('commit rechecks a destination created while generation was pending', () async {
    final target = await workshopExportTarget(File('${temp.path}/output.zip'));
    final entered = Completer<void>(), release = Completer<void>();
    final result = _settled(workshopCommitExport(target, (staging) async {
      await staging.writeAsString('new');
      entered.complete();
      await release.future;
    }));
    try {
      await _waitForWriter(entered, result);
      target.writeAsStringSync('keep');
      release.complete();
      expect(await result, isA<WorkshopException>().having((e) => e.code, 'code', 'workshop_export_exists'));
      expect(target.readAsStringSync(), 'keep');
      expect(temp.listSync().where((e) => e.path.contains('.workshop-')), isEmpty);
    } finally {
      if (!release.isCompleted) release.complete();
      await result;
    }
  });

  test('different destination spellings queue and preserve a case-equivalent target', () async {
    // Observe this ordinary temp directory, rather than inferring from the OS.
    final probe = File('${temp.path}/CaseProbe.tmp')..writeAsStringSync('probe');
    final caseInsensitive = File('${temp.path}/caseprobe.tmp').existsSync();
    probe.deleteSync();
    final firstTarget = await workshopExportTarget(File('${temp.path}/Preview.zip'));
    final secondTarget = await workshopExportTarget(File('${temp.path}/preview.zip'));
    expect(firstTarget.path, isNot(secondTarget.path));
    final entered = Completer<void>(), release = Completer<void>();
    final first = _settled(workshopCommitExport(firstTarget, (staging) async {
      entered.complete();
      await release.future;
      await staging.writeAsString('first');
    }));
    Future<Object?>? second;
    try {
      await _waitForWriter(entered, first);
      var secondWrites = 0;
      second = _settled(workshopCommitExport(secondTarget, (staging) async {
        secondWrites++;
        expect(firstTarget.readAsStringSync(), 'first', reason: 'the earlier destination must already be committed');
        await staging.writeAsString('second');
      }));
      await Future<void>.delayed(Duration.zero);
      expect(secondWrites, 0, reason: 'different URI strings must share the same export queue');
      release.complete();
      expect(await first, isNull);
      final outcome = await second;
      expect(firstTarget.readAsStringSync(), 'first');
      if (caseInsensitive) {
        expect(outcome, isA<WorkshopException>().having((e) => e.code, 'code', 'workshop_export_exists'));
        expect(secondWrites, 0);
        expect(secondTarget.readAsStringSync(), 'first');
      } else {
        expect(outcome, isNull);
        expect(secondWrites, 1);
        expect(secondTarget.readAsStringSync(), 'second');
      }
      expect(temp.listSync().where((e) => e.path.contains('.workshop-export-')), isEmpty);
    } finally {
      if (!release.isCompleted) release.complete();
      await first;
      if (second != null) await second;
    }
  });

  test('a failed writer cleans staging and does not poison the shared export queue', () async {
    final firstTarget = await workshopExportTarget(File('${temp.path}/first.zip'));
    final secondTarget = await workshopExportTarget(File('${temp.path}/second.zip'));
    final entered = Completer<void>(), release = Completer<void>();
    late File failedStaging;
    final first = _settled(workshopCommitExport(firstTarget, (staging) async {
      failedStaging = staging;
      await staging.writeAsString('partial');
      entered.complete();
      await release.future;
      throw const FileSystemException('synthetic export failure', '', OSError('synthetic storage error', 5));
    }));
    Future<Object?>? second;
    try {
      await _waitForWriter(entered, first);
      var secondWrites = 0;
      second = _settled(workshopCommitExport(secondTarget, (staging) async {
        secondWrites++;
        expect(failedStaging.existsSync(), isFalse, reason: 'cleanup must finish before the next writer');
        await staging.writeAsString('second');
      }));
      await Future<void>.delayed(Duration.zero);
      expect(secondWrites, 0);
      release.complete();
      expect(await first, isA<WorkshopException>().having((e) => e.code, 'code', 'workshop_storage'));
      expect(await second, isNull);
      expect(firstTarget.existsSync(), isFalse);
      expect(secondTarget.readAsStringSync(), 'second');
      expect(failedStaging.existsSync(), isFalse);
      await workshopCommitExport(firstTarget, (staging) async { await staging.writeAsString('recovered'); });
      expect(firstTarget.readAsStringSync(), 'recovered');
      expect(temp.listSync().where((e) => e.path.contains('.workshop-export-')), isEmpty);
    } finally {
      if (!release.isCompleted) release.complete();
      await first;
      if (second != null) await second;
    }
  });

  test('a dangling destination link is not treated as an absent file', () async {
    final link = Link('${temp.path}/output.zip')..createSync('${temp.path}/missing');
    final target = await workshopExportTarget(File(link.path));
    await expectLater(workshopCommitExport(target, (staging) async { await staging.writeAsString('new'); }),
      workshopError('workshop_export_exists'));
    expect(Link(link.path).existsSync(), isTrue);
  });

  test('real pet and companion exports share the same final destination gate', () async {
    final pets = PetLibrary(() async => Directory('${temp.path}/pets'));
    await pets.install(workshopZip(temp, {'pack.json': utf8.encode(jsonEncode(workshopPet())), 'idle.png': workshopPng()}));
    final companion = CompanionPackStore(Directory('${temp.path}/companion'), expectedRuntime: workshopRuntimeDigest());
    await companion.install(workshopZip(temp, {...workshopRuntime(), ...workshopCharacter()}).path);
    final target = File('${temp.path}/shared.zip');
    Future<Object> attempt(Future<File> value) async {
      try { return await value; } on WorkshopException catch (error) { return error; }
    }
    final results = await Future.wait([
      attempt(pets.exportZip('user-cat', target)), attempt(companion.exportZip(target)),
    ]);
    expect(results.whereType<File>(), hasLength(1));
    expect(results.whereType<WorkshopException>().single.code, 'workshop_export_exists');
    final members = workshopUnzip(target);
    expect(members.containsKey('pack.json') != members.containsKey('character/character.json'), isTrue);
  });
}
