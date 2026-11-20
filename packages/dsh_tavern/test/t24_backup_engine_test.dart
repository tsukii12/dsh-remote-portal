import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

void main() {
  test('full backup restores identities, both branches, state, resources, libraries and reports', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final work = await Directory.systemTemp.createTemp('dsh-t24-backup-engine-');
    TavernEngine? restored;
    addTearDown(() async {
      await restored?.close();
      await work.delete(recursive: true);
    });
    final original = await h.reply('original', usage: const TavernUsage(promptTokens: 9, completionTokens: 2));
    final call = h.model.prepare();
    final regeneration = T24Events(h.engine.regenerate(h.chatId, original.nodeId));
    await call.listening.future;
    call.add(const ModelText('replacement'));
    await call.finish();
    await regeneration.done.future;
    final replacement = regeneration.values.whereType<TavernTurnDone>().single.message;
    await h.engine.edit(h.chatId, replacement.nodeId, '{{setvar::score::7}}replacement');
    final tail = await h.reply('tail', usage: const TavernUsage(promptTokens: 15, cacheHitTokens: 6));
    final variables = h.engine.variables(h.chatId);
    expect(variables, contains('score'));

    const presetSource = ' {"name":"Archive preset","prompts":[],"prompt_order":[],"vendor":{"keep":true}} ';
    final preset = (await h.engine.importPreset(presetSource)).preset;
    await h.engine.bindPreset(h.chatId, preset.id);
    await h.engine.setDefaultPreset(preset.id);
    final book = (await h.engine.importLorebook(
      '{"name":"Book","entries":{},"vendor":"keep"}',
      fileName: 'book-native.json',
    )).book;
    await h.engine.bindLorebooks([book.id], source: WorldInfoSource.chat, chatId: h.chatId);
    const regexSource =
        ' {"scriptName":"kept","findRegex":"never-match","replaceString":"kept",'
        '"placement":[2],"vendor":{"unknown":true}} ';
    final script = (await h.engine.importRegexScripts(regexSource)).scripts.single;
    await h.engine.setRegexEnabled(script.id, false);
    await h.engine.setSettings({
      'backupMarker': {
        'opaque': [1, 'two'],
      },
    });
    await h.engine.setGlobalVariables({'globalMarker': 'kept'});

    final avatar = File('${h.root.path}/owned-media/avatar.bin');
    await avatar.parent.create();
    await avatar.writeAsBytes([0, 1, 2, 255]);
    final persona = await h.engine.createPersona(name: 'Me', avatarPath: avatar.path, description: 'persona');
    await h.engine.bindPersona(h.chatId, persona.id);
    await h.engine.setDefaultPersona(persona.id);
    final resource = File('${h.root.path}/characters/${h.characterId}/opaque/keep.writing');
    await resource.parent.create();
    await resource.writeAsBytes([3, 0, 4, 255]);
    final cardBytes = await File('${h.root.path}/characters/${h.characterId}/card.json').readAsBytes();
    final cardReport = (await h.engine.readImportReport(TavernImportKind.character, h.characterId))!.toJson();
    final presetReport = (await h.engine.readImportReport(TavernImportKind.preset, preset.id))!.toJson();
    final snapshotPath = await h.engine.path(h.chatId);

    final archive = File('${work.path}/all.zip');
    final info = await h.engine.backup(archive.path);
    expect(info.sqliteUserVersion, ChatStore.schemaVersion);
    expect(info.fileCount, greaterThan(5));
    expect(info.totalBytes, greaterThan(0));
    expect(info.createdAt, T24Harness.at);
    final destination = Directory('${work.path}/restored');
    final restoredInfo = await restoreTavernDirectory(archive.path, destination.path);
    expect(restoredInfo.fileCount, info.fileCount);
    restored = await TavernEngine.openDirectory(destination);
    final engine = restored;
    expect((await engine.path(h.chatId)).map((m) => m.nodeId), snapshotPath.map((m) => m.nodeId));
    expect((await engine.path(h.chatId)).last.nodeId, tail.nodeId);
    expect((await engine.path(h.chatId)).last.reportedUsage!.cacheHitTokens, 6);
    expect(engine.variables(h.chatId), variables);
    expect(engine.globalVariables, {'globalMarker': 'kept'});
    expect((await engine.readSettings())['backupMarker'], {
      'opaque': [1, 'two'],
    });
    expect((await engine.presetSelection(chatId: h.chatId)).effectivePresetId, preset.id);
    expect((await engine.preset(preset.id))!.sourceText, presetSource);
    expect((await engine.lorebook(book.id))!['vendor'], 'keep');
    expect((await engine.listRegexScripts()).single.sourceText, regexSource);
    expect((await engine.listRegexScripts()).single.enabled, isFalse);
    expect((await engine.personaSelection(chatId: h.chatId)).persona!.id, persona.id);
    final restoredAvatar = (await engine.persona(persona.id))!.avatarPath!;
    expect(File(restoredAvatar).absolute.path, File('${destination.path}/owned-media/avatar.bin').absolute.path);
    expect(await File(restoredAvatar).readAsBytes(), [0, 1, 2, 255]);
    expect(await File('${destination.path}/characters/${h.characterId}/opaque/keep.writing').readAsBytes(), [
      3,
      0,
      4,
      255,
    ]);
    expect(await File('${destination.path}/characters/${h.characterId}/card.json').readAsBytes(), cardBytes);
    expect((await engine.readImportReport(TavernImportKind.character, h.characterId))!.toJson(), cardReport);
    expect((await engine.readImportReport(TavernImportKind.preset, preset.id))!.toJson(), presetReport);

    await engine.selectSibling(h.chatId, replacement.nodeId, 0);
    expect((await engine.path(h.chatId)).last.nodeId, original.nodeId);
    expect((await engine.path(h.chatId)).last.text, 'original');
    expect((await engine.path(h.chatId)).last.reportedUsage!.promptTokens, 9);
    await engine.selectSibling(h.chatId, original.nodeId, 1);
    expect((await engine.path(h.chatId)).last.nodeId, tail.nodeId);
    expect(engine.variables(h.chatId), variables);
  });

  test('backup refuses an active detached turn without stopping it', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final work = await Directory.systemTemp.createTemp('dsh-t24-backup-busy-');
    addTearDown(() => work.delete(recursive: true));
    final call = h.model.prepare();
    final events = T24Events(h.engine.send(h.chatId, 'question'));
    await call.listening.future;
    await events.detach();
    final archive = File('${work.path}/busy.zip');
    await expectLater(
      h.engine.backup(archive.path),
      throwsA(isA<TavernModelException>().having((e) => e.kind, 'kind', TavernFailure.busy)),
    );
    expect(call.cancellation!.isCancelled, isFalse);
    expect(call.sourceCancelCalls, 0);
    expect(await archive.exists(), isFalse);
    final resumed = T24Events(h.engine.resumeTurn(h.chatId));
    call.add(const ModelText('still running'));
    await call.finish();
    await resumed.done.future;
    expect(resumed.values.whereType<TavernTurnDone>().single.message.text, 'still running');
  });

  test('capture drains an accepted edit and rejects later writes without poisoning character deletion', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final work = await Directory.systemTemp.createTemp('dsh-t24-backup-gate-');
    TavernEngine? restored;
    addTearDown(() async {
      await restored?.close();
      await work.delete(recursive: true);
    });
    final edit = h.engine.updateCharacterFields(h.characterId, {'description': 'accepted before capture'});
    final archive = File('${work.path}/capture.zip');
    final backup = h.engine.backup(archive.path);
    final busy = isA<TavernModelException>().having((e) => e.kind, 'kind', TavernFailure.busy);
    expect(() => h.engine.setSettings({'rejected': true}), throwsA(busy));
    expect(() => h.engine.deleteCharacter(h.characterId), throwsA(busy));
    final refusedTurn = h.engine.send(h.chatId, 'rejected turn').toList();
    await edit;
    expect((await refusedTurn).whereType<TavernTurnFailed>().single.kind, TavernFailure.busy);
    await backup;
    expect(h.model.generated, 0);
    expect((await h.engine.readSettings()).containsKey('rejected'), isFalse);
    // A denied delete must not leave the admission marker behind.
    await h.engine.createChat(h.characterId);
    final target = Directory('${work.path}/restored');
    await restoreTavernDirectory(archive.path, target.path);
    restored = await TavernEngine.openDirectory(target);
    expect((await restored.characterFields(h.characterId))!['description'], 'accepted before capture');
  });

  test('close waits for an already accepted backup without a self-wait cycle', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final work = await Directory.systemTemp.createTemp('dsh-t24-backup-close-');
    TavernEngine? restored;
    addTearDown(() async {
      await restored?.close();
      await work.delete(recursive: true);
    });
    final settings = h.engine.setSettings({'beforeClose': 'kept'});
    final archive = File('${work.path}/close.zip');
    final backup = h.engine.backup(archive.path);
    final closing = h.engine.close();
    await settings;
    await backup.timeout(const Duration(seconds: 10));
    await closing.timeout(const Duration(seconds: 10));
    final target = Directory('${work.path}/restored');
    await restoreTavernDirectory(archive.path, target.path);
    restored = await TavernEngine.openDirectory(target);
    expect((await restored.readSettings())['beforeClose'], 'kept');
  });

  test('a failed ZIP publication releases admission and preserves existing destination data', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final work = await Directory.systemTemp.createTemp('dsh-t24-backup-fail-');
    addTearDown(() => work.delete(recursive: true));
    final blocked = Directory('${work.path}/blocked.zip');
    await blocked.create();
    final marker = File('${blocked.path}/old.txt');
    await marker.writeAsString('untouched');
    await expectLater(h.engine.backup(blocked.path), throwsA(isA<FileSystemException>()));
    expect(await marker.readAsString(), 'untouched');
    await h.engine.setSettings({'afterFailure': true});
    expect((await h.engine.readSettings())['afterFailure'], isTrue);
    expect((await h.engine.character(h.characterId))!.id, h.characterId);
  });

  test('same-isolate restore and duplicate open cannot replace a live root through a dot alias', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    await expectLater(restoreTavernDirectory('missing.zip', '${h.root.path}/.'), throwsStateError);
    await expectLater(TavernEngine.openDirectory(Directory('${h.root.path}/.')), throwsStateError);
    expect((await h.engine.path(h.chatId)).single.text, 'G');
    await h.reopen();
    expect((await h.engine.path(h.chatId)).single.text, 'G');
  });

  test('restoring or opening an ancestor cannot move a live descendant engine', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final work = await Directory.systemTemp.createTemp('dsh-t24-backup-ancestor-');
    TavernEngine? child;
    addTearDown(() async {
      await child?.close();
      await work.delete(recursive: true);
    });
    final archive = File('${work.path}/outside.zip');
    await h.engine.backup(archive.path);
    final parent = Directory('${work.path}/parent');
    final root = Directory('${parent.path}/child');
    child = await TavernEngine.openDirectory(root);
    final character = await child.importCard(t24Card(greeting: 'live descendant'));
    final chat = await child.createChat(character.id);
    await expectLater(restoreTavernDirectory(archive.path, parent.path), throwsStateError);
    await expectLater(TavernEngine.openDirectory(parent), throwsStateError);
    expect((await child.path(chat)).single.text, 'live descendant');
  });

  test('opening or restoring a nested root cannot bypass its live ancestor admission', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final work = await Directory.systemTemp.createTemp('dsh-t24-backup-descendant-');
    addTearDown(() => work.delete(recursive: true));
    final archive = File('${work.path}/outside.zip');
    await h.engine.backup(archive.path);
    final nested = Directory('${h.root.path}/child');
    await expectLater(TavernEngine.openDirectory(nested), throwsStateError);
    await expectLater(restoreTavernDirectory(archive.path, nested.path), throwsStateError);
    expect(await nested.exists(), isFalse);
    expect((await h.engine.path(h.chatId)).single.text, 'G');
  });

  test('engine open recovers a prepared gap between renames before creating its data directory', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final reply = await h.reply('old committed data', usage: const TavernUsage(promptTokens: 23));
    final fixture = await _interruptedReplacement(h, phase: 'prepared');
    addTearDown(() async {
      if (await fixture.journal.exists()) await fixture.journal.delete();
      if (await fixture.work.exists()) await fixture.work.delete(recursive: true);
    });
    expect(await h.root.exists(), isFalse);
    await h.reopen();
    expect((await h.engine.path(h.chatId)).last.nodeId, reply.nodeId);
    expect((await h.engine.path(h.chatId)).last.text, 'old committed data');
    expect((await h.engine.path(h.chatId)).last.reportedUsage!.promptTokens, 23);
    expect((await h.engine.character(h.characterId))!.name, 'Guide');
    expect(await fixture.journal.exists(), isFalse);
    expect(await fixture.work.exists(), isFalse);
  });

  test('opening a dangling alias recovers the real root and reserves it against duplicate ownership', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final reply = await h.reply('recovered through alias', usage: const TavernUsage(promptTokens: 29));
    final alias = Link('${h.root.path}-alias');
    await alias.create(h.root.path);
    addTearDown(() async {
      await h.engine.close();
      if (await FileSystemEntity.type(alias.path, followLinks: false) == FileSystemEntityType.link) {
        await alias.delete();
      }
    });
    final fixture = await _interruptedReplacement(h, phase: 'prepared');
    addTearDown(() async {
      if (await fixture.journal.exists()) await fixture.journal.delete();
      if (await fixture.work.exists()) await fixture.work.delete(recursive: true);
    });
    expect(await Directory(alias.path).exists(), isFalse);
    h.engine = await TavernEngine.openDirectory(
      Directory(alias.path),
      config: h.config,
      modelClient: h.model,
      clock: () => T24Harness.at,
      random: () => 0.25,
    );
    final path = await h.engine.path(h.chatId);
    expect(path.last.nodeId, reply.nodeId);
    expect(path.last.text, 'recovered through alias');
    expect(path.last.reportedUsage!.promptTokens, 29);
    expect(await fixture.journal.exists(), isFalse);
    expect(await fixture.work.exists(), isFalse);
    final realRoot = Directory(await h.root.resolveSymbolicLinks());
    for (final overlapping in [realRoot, realRoot.parent]) {
      await expectLater(TavernEngine.openDirectory(overlapping), throwsStateError);
      await expectLater(restoreTavernDirectory('missing.zip', overlapping.path), throwsStateError);
    }
    expect((await h.engine.path(h.chatId)).last.nodeId, reply.nodeId);
    await h.reopen();
    expect((await h.engine.path(h.chatId)).last.nodeId, reply.nodeId);
  }, skip: Platform.isWindows ? 'Creating a directory symlink requires platform privileges.' : false);

  test('an inconsistent committed journal blocks engine open without creating an empty root', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final fixture = await _interruptedReplacement(h, phase: 'committed');
    addTearDown(() async {
      if (await fixture.journal.exists()) await fixture.journal.delete();
      if (await fixture.work.exists()) await fixture.work.delete(recursive: true);
    });
    await expectLater(TavernEngine.openDirectory(h.root), throwsStateError);
    expect(await h.root.exists(), isFalse);
    expect(await File('${fixture.work.path}/previous/tavern.sqlite3').exists(), isTrue);
    expect(await fixture.journal.exists(), isTrue);
    // A failed factory must release its reservation. After the explicit
    // fixture repair, the original root can be opened again.
    await Directory('${fixture.work.path}/previous').rename(h.root.path);
    await fixture.journal.delete();
    await fixture.work.delete();
    await h.reopen();
    expect((await h.engine.path(h.chatId)).single.text, 'G');
  });

  test('restore validates preset report versions before replacing the old root', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final work = await Directory.systemTemp.createTemp('dsh-t24-preset-report-version-');
    addTearDown(() => work.delete(recursive: true));
    final preset = (await h.engine.importPreset('{"name":"v","prompts":[],"prompt_order":[]}')).preset;
    final database = sqlite3.open('${h.root.path}/tavern.sqlite3');
    try {
      database.execute(
        r'''UPDATE presets SET import_report_json = json_set(import_report_json, '$.version', 999)
        WHERE id = ?''',
        [preset.id],
      );
      expect(
        database
            .select(
              r'''SELECT json_extract(import_report_json, '$.version') AS version
        FROM presets WHERE id = ?''',
              [preset.id],
            )
            .single['version'],
        999,
      );
    } finally {
      database.close();
    }
    final archive = File('${work.path}/unsupported.zip');
    await h.engine.backup(archive.path);
    final (target, oldChat) = await _oldTarget(work);
    await expectLater(restoreTavernDirectory(archive.path, target.path), throwsFormatException);
    final old = await TavernEngine.openDirectory(target);
    try {
      expect((await old.path(oldChat)).single.text, 'old root stays');
    } finally {
      await old.close();
    }
  });

  for (final kind in ['settings', 'persona', 'regex', 'character', 'lorebook']) {
    test('restore rejects unsupported $kind metadata before replacing the old root', () async {
      final h = await T24Harness.open();
      addTearDown(h.dispose);
      final work = await Directory.systemTemp.createTemp('dsh-t24-backup-version-');
      addTearDown(() => work.delete(recursive: true));
      await h.engine.createPersona(name: 'version fixture');
      await h.engine.importRegexScripts('{"scriptName":"v","findRegex":"v","replaceString":"v","placement":[2]}');
      final book = (await h.engine.importLorebook('{"name":"v","entries":{}}')).book;
      final relative = switch (kind) {
        'settings' => 'settings.json',
        'persona' => 'personas/index.json',
        'regex' => 'regex-library.json',
        'character' => 'characters/${h.characterId}/library.json',
        _ => 'lorebooks/${book.id}.json',
      };
      final versionFile = File('${h.root.path}/$relative');
      final document = jsonDecode(await versionFile.readAsString()) as Map<String, Object?>;
      document['version'] = 999;
      await versionFile.writeAsString(jsonEncode(document));
      final archive = File('${work.path}/unsupported.zip');
      await h.engine.backup(archive.path);
      final (target, oldChat) = await _oldTarget(work);
      await expectLater(
        restoreTavernDirectory(archive.path, target.path),
        kind == 'character' ? throwsA(isA<TavernImportError>()) : throwsFormatException,
      );
      final old = await TavernEngine.openDirectory(target);
      try {
        expect((await old.path(oldChat)).single.text, 'old root stays');
      } finally {
        await old.close();
      }
    });
  }
}

Future<(Directory, String)> _oldTarget(Directory parent) async {
  final target = Directory('${parent.path}/old');
  final engine = await TavernEngine.openDirectory(target);
  try {
    final card = await engine.importCard(t24Card(greeting: 'old root stays'));
    final chat = await engine.createChat(card.id);
    return (target, chat);
  } finally {
    await engine.close();
  }
}

// Builds the persistent state left by a process exit. This does not claim to
// simulate an OS power loss or the durability of parent-directory fsync.
Future<({Directory work, File journal})> _interruptedReplacement(T24Harness h, {required String phase}) async {
  final root = Directory(await h.root.resolveSymbolicLinks());
  await h.engine.close();
  var key = root.uri.toString();
  if (Platform.isWindows || Platform.isMacOS) key = key.toLowerCase();
  final id = sha256.convert(utf8.encode(key)).toString().substring(0, 16);
  final work = await root.parent.createTemp('.dshgo-restore-$id-');
  if (phase == 'prepared') {
    await Directory('${work.path}/incoming').create();
    await File('${work.path}/incoming/tavern.sqlite3').writeAsString('unpublished candidate must not be opened');
  }
  final journal = File('${root.parent.path}/.dshgo-restore-$id.json');
  await journal.writeAsString(
    jsonEncode({
      'format': 'dshgo-tavern-restore',
      'version': 1,
      'root': key,
      'workName': work.uri.pathSegments.where((part) => part.isNotEmpty).last,
      'hadRoot': true,
      'phase': phase,
    }),
    flush: true,
  );
  await root.rename('${work.path}/previous');
  return (work: work, journal: journal);
}
