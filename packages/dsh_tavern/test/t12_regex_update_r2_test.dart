import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

void main() {
  test('public regex updates preserve order identity caller snapshots and stored messages', () async {
    final h = await _open('identity');
    final tavern = h.tavern;
    final atImport = h.at;
    final greeting = (await tavern.path(h.chatId)).single;
    final firstRaw = _rule(
      '/A/g',
      'B',
      extra: {
        'foreign': {
          'keep': [false, null, '猫'],
          'nested': {'left': 'old', 'stay': 'saved'},
        },
        'replaceArray': [1, 2],
      },
    );
    final secondRaw = _rule('/Q/g', 'R');
    final source = '\uFEFF${jsonEncode([firstRaw, secondRaw])}\r\n';
    final imported = (await tavern.importRegexScripts(source)).scripts;
    final first = imported.first;
    final second = imported.last;
    final original = _record(first);
    final untouched = _record(second);
    expect(first.id, isNot(second.id));
    expect(first.raw['id'], second.raw['id']);
    final preset = (await tavern.importPreset('{"temperature":0.7}')).preset;
    await tavern.bindPreset(h.chatId, preset.id);
    final ordinary = await tavern.sendOnly(h.chatId, 'A');
    expect(ordinary.text, 'B');
    await tavern.setRegexEnabled(first.id, false);

    h.at = h.at.add(const Duration(minutes: 1));
    final nested = <String, Object?>{'left': 'submitted'};
    final member = <String, Object?>{'value': 1};
    final items = <Object?>['submitted', member];
    final replacement = <Object?>['captured'];
    final patch = <String, Object?>{
      'id': 'edited-raw-id',
      'findRegex': '/X/g',
      'replaceString': 'Q',
      'foreign': {'nested': nested, 'newList': items},
      'replaceArray': replacement,
      'nullable': null,
    };
    final pendingFirst = tavern.updateRegexScript(first.id, patch);
    patch['findRegex'] = '/LATE/g';
    nested['left'] = 'late';
    items[0] = 'late';
    member['value'] = 99;
    replacement.add('late');
    final pendingSecond = tavern.updateRegexScript(first.id, {
      'scriptName': 'edited',
      'foreign': {
        'nested': {'right': 'second'},
      },
    });
    await pendingFirst;
    final edited = await pendingSecond;
    final disabledRaw = <String, Object?>{
      ...firstRaw,
      'id': 'edited-raw-id',
      'scriptName': 'edited',
      'findRegex': '/X/g',
      'replaceString': 'Q',
      'disabled': true,
      'nullable': null,
      'replaceArray': ['captured'],
      'foreign': {
        'keep': [false, null, '猫'],
        'nested': {'left': 'submitted', 'stay': 'saved', 'right': 'second'},
        'newList': [
          'submitted',
          {'value': 1},
        ],
      },
    };
    expect(edited.raw, disabledRaw);
    expect(_record(first), original);
    expect(edited.enabled, isFalse);
    final disabled = await tavern.sendOnly(h.chatId, 'X');
    expect(disabled.text, 'X');
    final disabledAt = h.at;

    h.at = h.at.add(const Duration(minutes: 1));
    final enabled = await tavern.updateRegexScript(first.id, {'disabled': false});
    stdout.writeln('REGEX_UPDATE_R2_READY');
    final changed = await tavern.sendOnly(h.chatId, 'X');
    // Keeping X->Q before Q->R yields R. Delete/reimport would leave Q.
    expect(changed.text, 'R');

    final currentRaw = <String, Object?>{...disabledRaw, 'disabled': false};
    final records = await tavern.listRegexScripts();
    expect(records.map((value) => value.id), [first.id, second.id]);
    expect(records.first.raw, currentRaw);
    expect(_record(records.last), untouched);
    expect(records.first.sourceText, source);
    expect(records.first.importedAt, atImport);
    expect(records.first.diagnostics.single.identifier, 'edited-raw-id');
    expect(records.first.diagnostics.single.path, r'$.findRegex');
    expect(records.first.diagnostics.single.status, TavernRegexCompatibility.compatible);
    await _expectFresh(h, enabled, atImport);
    expect(jsonDecode(await tavern.exportRegex(regexId: first.id)), currentRaw);
    expect(jsonDecode(await tavern.exportRegex()), [currentRaw, secondRaw]);
    expect((await tavern.readSettings(chatId: h.chatId))['managedRegexScripts'], [currentRaw, secondRaw]);
    final selection = await tavern.presetSelection(chatId: h.chatId);
    expect(selection.source, PresetSelectionSource.chat);
    expect(selection.boundPresetId, preset.id);
    expect(selection.effectivePresetId, preset.id);
    final expectedPath = [
      _message(greeting.nodeId, null, TavernRole.character, 'G', atImport),
      _message(ordinary.nodeId, greeting.nodeId, TavernRole.user, 'B', atImport),
      _message(disabled.nodeId, ordinary.nodeId, TavernRole.user, 'X', disabledAt),
      _message(changed.nodeId, disabled.nodeId, TavernRole.user, 'R', h.at),
    ];
    expect((await tavern.path(h.chatId)).map(_messageRecord), expectedPath);
    expect(await _exportedTexts(h), ['G', 'B', 'X', 'R']);
    final stored = records.map(_record).toList();
    await h.reopen();
    expect((await h.tavern.listRegexScripts()).map(_record), stored);
    expect((await h.tavern.path(h.chatId)).map(_messageRecord), expectedPath);
    expect(await _exportedTexts(h), ['G', 'B', 'X', 'R']);
    expect((await h.tavern.presetSelection(chatId: h.chatId)).boundPresetId, preset.id);
    expect((await h.tavern.readSettings(chatId: h.chatId))['managedRegexScripts'], [currentRaw, secondRaw]);
    expect(jsonDecode(await h.tavern.exportRegex()), [currentRaw, secondRaw]);
    expect(await h.tavern.readVariables(h.chatId), isEmpty);
    expect(await h.tavern.inspectTurn(h.chatId), isNull);
    _expectNoModel(h);
  });

  test('public regex edits refresh intake and consume placement phase depth and trim fields', () async {
    final h = await _open('intake');
    final tavern = h.tavern;
    final first = (await tavern.importRegexScripts(jsonEncode(_rule('/A!/g', 'WRONG')))).scripts.single;
    h.at = h.at.add(const Duration(minutes: 1));
    final display = await tavern.updateRegexScript(first.id, {
      'findRegex': r'/(A!)/g',
      'replaceString': r'$1',
      'trimStrings': ['!'],
      'placement': [2],
      'markdownOnly': true,
      'promptOnly': false,
      'minDepth': 2,
      'maxDepth': 2,
    });
    await _expectFresh(h, display, first.importedAt);
    expect((await tavern.displayText(h.chatId, text: 'A!', depth: 2)).text, 'A');
    for (final depth in [1, 3]) {
      expect((await tavern.displayText(h.chatId, text: 'A!', depth: depth)).text, 'A!');
    }
    expect((await tavern.displayText(h.chatId, text: 'A!', depth: 2, role: TavernRole.user)).text, 'A!');
    await tavern.updateRegexScript(first.id, {'minDepth': null, 'maxDepth': null});
    for (final depth in [0, 3]) {
      expect((await tavern.displayText(h.chatId, text: 'A!', depth: depth)).text, 'A');
    }
    await tavern.updateRegexScript(first.id, {
      'placement': [1, 2],
      'markdownOnly': false,
      'promptOnly': true,
    });
    expect((await tavern.displayText(h.chatId, text: 'A!', depth: 2)).text, 'A!');
    expect((await tavern.sendOnly(h.chatId, 'A!')).text, 'A!');
    final writeBack = await tavern.updateRegexScript(first.id, {
      'placement': [1],
      'promptOnly': false,
    });
    expect(writeBack.raw['minDepth'], isNull);
    expect(writeBack.raw['maxDepth'], isNull);
    expect((await tavern.sendOnly(h.chatId, 'A!')).text, 'A');

    final badPattern = await tavern.updateRegexScript(first.id, {'findRegex': '[', 'disabled': false});
    expect(badPattern.raw['findRegex'], '[');
    expect(badPattern.raw['disabled'], isFalse);
    expect(badPattern.diagnostics.single.status, TavernRegexCompatibility.incompatible);
    expect(badPattern.diagnostics.single.path, r'$.findRegex');
    expect(badPattern.importReport!.verdict, TavernImportVerdict.preserveOnly);
    await _expectFresh(h, badPattern, first.importedAt);
    expect(jsonDecode(await tavern.exportRegex(regexId: first.id)), badPattern.raw);
    expect((await tavern.readSettings())['managedRegexScripts'], [
      {...badPattern.raw, 'disabled': true},
    ]);
    expect((await tavern.sendOnly(h.chatId, 'A!')).text, 'A!');
    final badField = await tavern.updateRegexScript(first.id, {
      'findRegex': r'/(A!)/g',
      'trimStrings': [1],
    });
    expect(badField.raw['trimStrings'], [1]);
    expect(badField.raw['disabled'], isFalse);
    expect(badField.diagnostics.single.status, TavernRegexCompatibility.incompatible);
    expect(badField.diagnostics.single.code, 'invalid-script');
    expect(badField.diagnostics.single.path, r'$');
    await _expectFresh(h, badField, first.importedAt);
    expect(jsonDecode(await tavern.exportRegex(regexId: first.id)), badField.raw);
    final repaired = await tavern.updateRegexScript(first.id, {
      'trimStrings': ['!'],
      'minDepth': null,
      'maxDepth': null,
    });
    expect(repaired.compatible, isTrue);
    expect((await tavern.sendOnly(h.chatId, 'A!')).text, 'A');
    final oldReport = repaired.importReport!;
    final toggled = await tavern.setRegexEnabled(first.id, false);
    expect(toggled.importReport!.stale, isTrue);
    expect((await tavern.readImportReport(TavernImportKind.regex, first.id))!.fingerprint, oldReport.fingerprint);
    expect((await tavern.readImportReport(TavernImportKind.regex, first.id))!.checkedAt, oldReport.checkedAt);
    h.at = h.at.add(const Duration(minutes: 1));
    final refreshed = await tavern.updateRegexScript(first.id, {});
    expect(refreshed.raw, toggled.raw);
    expect(refreshed.enabled, isFalse);
    await _expectFresh(h, refreshed, first.importedAt);

    await h.engine.setGlobalVariables({'kept': 'global'});
    final globals = h.engine.globalVariables;
    final variables = await tavern.readVariables(h.chatId);
    final randomCalls = h.randomCalls;
    const pattern = '{{setglobalvar::editSideEffect::bad}}{{random::A::B}}';
    final dynamicRule = await tavern.updateRegexScript(first.id, {'findRegex': pattern, 'substituteRegex': 1});
    expect(dynamicRule.raw['findRegex'], pattern);
    expect(dynamicRule.diagnostics.single.status, TavernRegexCompatibility.deferred);
    expect(dynamicRule.diagnostics.single.code, 'runtime-check');
    await _expectFresh(h, dynamicRule, first.importedAt);
    expect(h.engine.globalVariables, globals);
    expect(await tavern.readVariables(h.chatId), variables);
    expect(h.randomCalls, randomCalls);
    final saved = _record(dynamicRule);
    await h.reopen();
    expect(_record((await h.tavern.listRegexScripts()).single), saved);
    expect(jsonDecode(await h.tavern.exportRegex(regexId: first.id)), dynamicRule.raw);
    expect(h.engine.globalVariables, globals);
    expect(await h.tavern.readVariables(h.chatId), variables);
    expect(h.randomCalls, randomCalls);
    expect(
      (await h.tavern.readImportReport(TavernImportKind.regex, first.id))!.toJson(),
      dynamicRule.importReport!.toJson(),
    );
    _expectNoModel(h);
  });

  test('regex update publication failure preserves committed state and the queue recovers', () async {
    final h = await _open('publication');
    final tavern = h.tavern;
    final imported = (await tavern.importRegexScripts(jsonEncode([_rule('/A/g', 'B'), _rule('/Q/g', 'R')]))).scripts;
    final id = imported.first.id;
    expect((await tavern.sendOnly(h.chatId, 'A')).text, 'B');
    final file = File('${h.root.path}/regex-library.json');
    final beforeBytes = await file.readAsBytes();
    final beforeRecords = (await tavern.listRegexScripts()).map(_record).toList();
    final beforeExport = await tavern.exportRegex();
    final beforeProjection = (await tavern.readSettings())['managedRegexScripts'];
    final beforeReport = (await tavern.readImportReport(TavernImportKind.regex, id))!.toJson();
    final obstruction = await Directory('${file.path}.writing').create();
    h.at = h.at.add(const Duration(minutes: 1));
    try {
      await expectLater(
        tavern.updateRegexScript(id, {'findRegex': '/X/g', 'replaceString': 'Q'}),
        throwsA(isA<FileSystemException>()),
      );
      expect(await file.readAsBytes(), beforeBytes);
      expect((await tavern.listRegexScripts()).map(_record), beforeRecords);
      expect(await tavern.exportRegex(), beforeExport);
      expect((await tavern.readSettings())['managedRegexScripts'], beforeProjection);
      expect((await tavern.readImportReport(TavernImportKind.regex, id))!.toJson(), beforeReport);
      expect((await tavern.sendOnly(h.chatId, 'A')).text, 'B');
    } finally {
      if (await obstruction.exists()) await obstruction.delete(recursive: true);
    }
    h.at = h.at.add(const Duration(minutes: 1));
    final recovered = await tavern.updateRegexScript(id, {'findRegex': '/X/g', 'replaceString': 'Q'});
    expect((await tavern.sendOnly(h.chatId, 'X')).text, 'R');
    await _expectFresh(h, recovered, imported.first.importedAt);
    final savedBytes = await file.readAsBytes();
    final saved = (await tavern.listRegexScripts()).map(_record).toList();
    final exported = await tavern.exportRegex();
    await expectLater(tavern.updateRegexScript('missing', {'replaceString': 'bad'}), throwsA(isA<TavernImportError>()));
    expect(await file.readAsBytes(), savedBytes);
    expect((await tavern.listRegexScripts()).map(_record), saved);
    expect(await tavern.exportRegex(), exported);
    expect((await tavern.readSettings())['managedRegexScripts'], jsonDecode(exported));
    expect((await tavern.path(h.chatId)).map((value) => value.text), ['G', 'B', 'B', 'R']);
    expect(await _exportedTexts(h), ['G', 'B', 'B', 'R']);
    await h.reopen();
    expect((await h.tavern.listRegexScripts()).map(_record), saved);
    expect(await h.tavern.exportRegex(), exported);
    expect((await h.tavern.path(h.chatId)).map((value) => value.text), ['G', 'B', 'B', 'R']);
    expect(await _exportedTexts(h), ['G', 'B', 'B', 'R']);
    _expectNoModel(h);
  });
}

Map<String, Object?> _rule(String find, String replace, {Map<String, Object?> extra = const {}}) => {
  'id': 'duplicate',
  'scriptName': 'rule',
  'findRegex': find,
  'replaceString': replace,
  'trimStrings': <String>[],
  'placement': [1],
  'disabled': false,
  'markdownOnly': false,
  'promptOnly': false,
  'runOnEdit': true,
  'substituteRegex': 0,
  ...extra,
};

Map<String, Object?> _record(TavernRegexScript value) => {
  'id': value.id,
  'raw': value.raw,
  'sourceText': value.sourceText,
  'importedAt': value.importedAt.toIso8601String(),
  'diagnostics': value.diagnostics.map((item) => item.toJson()).toList(),
  'importReport': value.importReport?.toJson(),
};

Map<String, Object?> _message(String id, String? parent, TavernRole role, String text, DateTime at) => {
  'nodeId': id,
  'parentId': parent,
  'role': role.name,
  'text': text,
  'at': at.toUtc().toIso8601String(),
};
Map<String, Object?> _messageRecord(TavernMessage value) =>
    _message(value.nodeId, value.parentId, value.role, value.text, value.at);

Future<List<Object?>> _exportedTexts(_Harness h) async {
  final file = (await h.tavern.exportChat(h.chatId)).single;
  return utf8
      .decode(file.bytes)
      .split('\n')
      .where((line) => line.isNotEmpty)
      .skip(1)
      .map((line) => (jsonDecode(line) as Map<String, Object?>)['mes'])
      .toList();
}

Future<void> _expectFresh(_Harness h, TavernRegexScript value, DateTime importedAt) async {
  final report = (await h.tavern.readImportReport(TavernImportKind.regex, value.id))!;
  expect(value.importedAt, importedAt);
  expect(report.kind, TavernImportKind.regex);
  expect(report.checkedAt, h.at);
  expect(report.stale, isFalse);
  expect(report.fingerprint, importFingerprint(TavernImportKind.regex, value.raw));
  expect(value.importReport!.toJson(), report.toJson());
}

void _expectNoModel(_Harness h) {
  expect(h.model.generated, 0);
  expect(h.keyCalls, 0);
}

Future<_Harness> _open(String label) async {
  final h = _Harness(await Directory.systemTemp.createTemp('t12-regex-update-r2-'), label);
  addTearDown(h.dispose);
  await h.open();
  h.chatId = await h.tavern.createChat((await h.tavern.importCard(t24Card())).id);
  return h;
}

class _Harness {
  _Harness(this.root, this.label);
  final Directory root;
  final String label;
  final model = T24Model();
  DateTime at = DateTime.utc(2026, 11, 12, 12);
  int keyCalls = 0;
  int randomCalls = 0;
  TavernEngine? owned;
  TavernEngine get engine => owned!;
  Tavern get tavern => engine;
  late String chatId;
  late final config = TavernModelConfig(
    apiKey: () async {
      keyCalls++;
      return 'unused';
    },
  );

  Future<void> open() async {
    owned = await TavernEngine.openDirectory(
      root,
      config: config,
      modelClient: model,
      clock: () => at,
      random: () {
        randomCalls++;
        return 0.25;
      },
    );
  }

  Future<void> reopen() async {
    await engine.close();
    owned = null;
    await open();
  }

  Future<void> dispose() async {
    try {
      await owned?.close();
    } finally {
      if (await root.exists()) await root.delete(recursive: true);
    }
    expect(await root.exists(), isFalse);
    stdout.writeln('REGEX_UPDATE_R2_CLEANUP_$label');
  }
}
