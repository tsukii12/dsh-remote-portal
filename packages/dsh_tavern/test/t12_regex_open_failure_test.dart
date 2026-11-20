import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

void main() {
  test('regex lookup errors cannot replace a committed library with a later import', () async {
    final h = await _Fixture.open();
    addTearDown(h.dispose);
    final saved = await h.seedAAndClose();
    final denied = PathAccessException(
      h.file.path,
      OSError('Injected regex directory search denial', Platform.isWindows ? 5 : 13),
    );
    final fault = _ReadFault(h.file, readError: denied);
    final attempt = await h.attempt(fault);
    final bytesAfterFault = await h.file.readAsBytes();

    // Both products perform this same recovery and mutation. Keep a returned
    // owner, or acquire a fresh one after the failed startup releases its root.
    h.engine = attempt.engine ?? await h.openFresh();
    final added = (await h.engine.importRegexScripts(jsonEncode(_rule('B')))).scripts.single;
    await h.reopen();
    final records = await h.engine.listRegexScripts();

    // First defect-specific oracle: old code accepts an empty owner and
    // really overwrites A on the later import, yielding true / [B].
    expect(
      <String, Object?>{
        'faultOpenReturned': attempt.engine != null,
        'reopenedNames': records.map((record) => record.name).toList(),
      },
      {
        'faultOpenReturned': false,
        'reopenedNames': ['A', 'B'],
      },
      reason: 'Open error: ${attempt.error}; IO: ${fault.log.join(' -> ')}',
    );
    expect(attempt.error, same(denied));
    expect(bytesAfterFault, orderedEquals(saved.bytes));
    expect(_snapshot(records.first), _snapshot(saved.script));
    expect(_snapshot(records.last), _snapshot(added));
    expect(jsonDecode(await h.engine.exportRegex(regexId: saved.script.id)), saved.script.raw);
    expect((await h.engine.readImportReport(TavernImportKind.regex, saved.script.id))!.toJson(), saved.report);
    expect((await h.engine.readSettings())['regexRecoveryMarker'], 'root settings survived');
    expect((await h.engine.personaSelection()).defaultPersonaId, saved.personaId);
    expect(fault.reads, 1);
  });

  test('a genuinely missing regex file stays absent until a public import commits', () async {
    final h = await _Fixture.open();
    addTearDown(h.dispose);
    await h.engine.close();
    expect(await h.file.exists(), isFalse);
    final fault = _ReadFault(h.file, hideExists: false, typeResult: null);
    final attempt = await h.attempt(fault);
    h.engine = attempt.engine ?? await h.openFresh();

    expect(attempt.error, isNull);
    expect(attempt.engine, isNotNull);
    expect(await h.engine.listRegexScripts(), isEmpty);
    expect(await h.engine.exportRegex(), '[]');
    expect(await h.file.exists(), isFalse, reason: 'Opening an empty library does not create a committed file.');
    expect(fault.nativeReadError, isA<PathNotFoundException>());
    final missing = fault.nativeReadError! as PathNotFoundException;
    expect(missing.osError!.errorCode, isIn(Platform.isWindows ? [2, 3] : [2]));
    expect(fault.reads, 1);

    final created = (await h.engine.importRegexScripts(jsonEncode(_rule('Fresh')))).scripts.single;
    expect(await h.file.exists(), isTrue);
    await h.reopen();
    expect(_snapshot((await h.engine.listRegexScripts()).single), _snapshot(created));
    expect(jsonDecode(await h.engine.exportRegex()), [created.raw]);
  });

  test('non-absence errors and existing entities reject regex startup without losing the committed library', () async {
    final h = await _Fixture.open();
    addTearDown(h.dispose);
    final saved = await h.seedAAndClose();
    final errors = <Object>[
      PathNotFoundException(h.file.path, const OSError('Network path unavailable', 53)),
      PathNotFoundException(h.file.path, const OSError('Network name unavailable', 67)),
      FileSystemException('Not an explicit missing-path exception', h.file.path, const OSError('Other error', 2)),
      PathNotFoundException(h.file.path, const OSError('Unrecognized missing-path code', -1)),
      if (!Platform.isWindows) PathNotFoundException(h.file.path, const OSError('Not the POSIX missing-file code', 3)),
    ];
    for (final error in errors) {
      await _rejectAndRecover(h, saved, _ReadFault(h.file, readError: error), error);
    }

    // A socket may produce ENOENT from File::Open. A missing-like error
    // cannot establish absence when the post-error lookup sees any entity.
    for (final type in [FileSystemEntityType.file, FileSystemEntityType.unixDomainSock]) {
      final error = PathNotFoundException(h.file.path, const OSError('The entry still exists', 2));
      await _rejectAndRecover(h, saved, _ReadFault(h.file, readError: error, typeResult: type), error);
    }

    // Real directory control: no fabricated JSON, stat result, or read error.
    // Close any incorrectly returned owner before restoring the original file.
    final retained = await h.file.rename('${h.file.path}.retained');
    final obstruction = Directory(h.file.path);
    late final _OpenAttempt attempted;
    try {
      await obstruction.create();
      attempted = await h.attempt(_ReadFault(h.file, hideExists: false, typeResult: null));
    } finally {
      await h.engine.close();
      if (await obstruction.exists()) {
        await obstruction.delete();
      }
      await retained.rename(h.file.path);
    }
    h.engine = await h.openFresh();
    expect(
      <String, Object?>{
        'faultOpenReturned': attempted.engine != null,
        'recoveredNames': (await h.engine.listRegexScripts()).map((record) => record.name).toList(),
      },
      {
        'faultOpenReturned': false,
        'recoveredNames': ['A'],
      },
    );
    expect(attempted.error, isA<FileSystemException>());
    expect(await h.file.readAsBytes(), orderedEquals(saved.bytes));
    expect(_snapshot((await h.engine.listRegexScripts()).single), _snapshot(saved.script));
  });

  test('a misleading regex existence lookup does not discard a successfully read library', () async {
    final h = await _Fixture.open();
    addTearDown(h.dispose);
    final saved = await h.seedAAndClose();
    final fault = _ReadFault(h.file);
    final attempt = await h.attempt(fault);
    h.engine = attempt.engine ?? await h.openFresh();

    expect(
      <String, Object?>{
        'opened': attempt.engine != null,
        'names': (await h.engine.listRegexScripts()).map((record) => record.name).toList(),
      },
      {
        'opened': true,
        'names': ['A'],
      },
    );
    expect(attempt.error, isNull);
    expect(fault.nativeReadError, isNull);
    expect(fault.reads, 1);
    expect(await h.file.readAsBytes(), orderedEquals(saved.bytes));
    expect(_snapshot((await h.engine.listRegexScripts()).single), _snapshot(saved.script));
    final added = (await h.engine.importRegexScripts(jsonEncode(_rule('B')))).scripts.single;
    await h.reopen();
    final records = await h.engine.listRegexScripts();
    expect(records.map((record) => record.name), ['A', 'B']);
    expect(_snapshot(records.first), _snapshot(saved.script));
    expect(_snapshot(records.last), _snapshot(added));
  });
}

Future<void> _rejectAndRecover(_Fixture h, _SavedRegex saved, _ReadFault fault, Object error) async {
  final attempt = await h.attempt(fault);
  await attempt.engine?.close();
  h.engine = await h.openFresh();
  final records = await h.engine.listRegexScripts();
  expect(
    <String, Object?>{
      'faultOpenReturned': attempt.engine != null,
      'recoveredNames': records.map((record) => record.name).toList(),
    },
    {
      'faultOpenReturned': false,
      'recoveredNames': ['A'],
    },
    reason: fault.log.join(' -> '),
  );
  expect(attempt.error, same(error));
  expect(await h.file.readAsBytes(), orderedEquals(saved.bytes));
  expect(_snapshot(records.single), _snapshot(saved.script));
  expect((await h.engine.personaSelection()).defaultPersonaId, saved.personaId);
  expect(fault.reads, 1);
  await h.engine.close();
}

Map<String, Object?> _snapshot(TavernRegexScript script) => {
  'id': script.id,
  'sourceText': script.sourceText,
  'raw': script.raw,
  'importedAt': script.importedAt.toIso8601String(),
  'diagnostics': [for (final diagnostic in script.diagnostics) diagnostic.toJson()],
  'importReport': script.importReport?.toJson(),
  'enabled': script.enabled,
  'compatible': script.compatible,
};

Map<String, Object?> _rule(String name) => {
  'id': 'upstream-$name',
  'scriptName': name,
  'findRegex': '/$name/g',
  'replaceString': '<$name>',
  'trimStrings': <String>[],
  'placement': [2],
  'disabled': false,
  'markdownOnly': true,
  'promptOnly': false,
  'runOnEdit': true,
  'substituteRegex': 0,
  'foreign': {
    'keep': [false, null, '海 🌊', '\uFEFFraw'],
  },
};

class _Fixture {
  _Fixture._(this.root, this.engine);
  final Directory root;
  TavernEngine engine;
  File get file => File('${root.path}/regex-library.json');

  static Future<_Fixture> open() async {
    final temporary = await Directory.systemTemp.createTemp('dsh-t12-regex-open-');
    final root = Directory(await temporary.resolveSymbolicLinks());
    try {
      return _Fixture._(root, await _openEngine(root));
    } catch (_) {
      await root.delete(recursive: true);
      rethrow;
    }
  }

  static Future<TavernEngine> _openEngine(Directory root) => TavernEngine.openDirectory(
    root,
    config: TavernModelConfig(apiKey: () async => null),
    clock: () => DateTime.utc(2026, 11, 11, 2),
  );

  Future<TavernEngine> openFresh() => _openEngine(root);

  Future<void> reopen() async {
    await engine.close();
    engine = await openFresh();
  }

  Future<_SavedRegex> seedAAndClose() async {
    await engine.setSettings({'regexRecoveryMarker': 'root settings survived'});
    final persona = await engine.createPersona(name: 'Unaffected default');
    await engine.setDefaultPersona(persona.id);
    final source = '\uFEFF${jsonEncode(_rule('A'))}\r\n';
    final script = (await engine.importRegexScripts(source)).scripts.single;
    final report = (await engine.readImportReport(TavernImportKind.regex, script.id))!.toJson();
    expect((await engine.listRegexScripts()).single.id, script.id);
    expect(script.sourceText, source);
    expect(script.compatible, isTrue);
    final bytes = await file.readAsBytes();
    await engine.close();
    return _SavedRegex(script, report, persona.id, bytes);
  }

  Future<_OpenAttempt> attempt(_ReadFault fault) async {
    TavernEngine? opened;
    Object? error;
    await fault.run(() async {
      try {
        opened = await openFresh();
      } catch (caught) {
        error = caught;
      }
    });
    // Own every returned engine before a later assertion can fail.
    final accepted = opened;
    if (accepted != null) {
      engine = accepted;
    }
    return _OpenAttempt(opened, error);
  }

  Future<void> dispose() async {
    try {
      await engine.close();
    } finally {
      await root.delete(recursive: true);
    }
  }
}

class _SavedRegex {
  _SavedRegex(this.script, this.report, this.personaId, this.bytes);
  final TavernRegexScript script;
  final Map<String, Object?> report;
  final String personaId;
  final Uint8List bytes;
}

class _OpenAttempt {
  _OpenAttempt(this.engine, this.error);
  final TavernEngine? engine;
  final Object? error;
}

class _ReadFault {
  _ReadFault(this.file, {this.hideExists = true, this.readError, this.typeResult = FileSystemEntityType.notFound});
  final File file;
  final bool hideExists;
  final Object? readError;
  final FileSystemEntityType? typeResult;
  final log = <String>[];
  var reads = 0;
  Object? nativeReadError;

  Future<void> run(Future<void> Function() body) async {
    final parent = Zone.current;
    final selected = file.absolute.uri;
    await IOOverrides.runZoned(
      body,
      createFile: (path) {
        final real = parent.run(() => File(path));
        final uri = parent.run(() => real.absolute.uri);
        return uri == selected ? _RegexFile(real, this) : real;
      },
      fseGetType: (path, followLinks) {
        final uri = parent.run(() => File(path).absolute.uri);
        final type = typeResult;
        if (type != null && uri == selected) {
          log.add('type:$type');
          return Future.value(type);
        }
        return parent.run(() => FileSystemEntity.type(path, followLinks: followLinks));
      },
    );
  }
}

class _RegexFile implements File {
  _RegexFile(this.real, this.fault);
  final File real;
  final _ReadFault fault;
  @override
  String get path => real.path;
  @override
  Uri get uri => real.uri;
  @override
  bool get isAbsolute => real.isAbsolute;
  @override
  File get absolute => real.absolute;
  @override
  Directory get parent => real.parent;
  @override
  Future<bool> exists() {
    fault.log.add('exists');
    return fault.hideExists ? Future.value(false) : real.exists();
  }

  @override
  Future<String> readAsString({Encoding encoding = utf8}) async {
    fault.reads++;
    fault.log.add('readAsString');
    if (fault.readError case final error?) {
      throw error;
    }
    try {
      return await real.readAsString(encoding: encoding);
    } catch (error) {
      fault.nativeReadError = error;
      rethrow;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
