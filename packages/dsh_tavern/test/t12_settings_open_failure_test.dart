import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

const _settingsA = <String, Object?>{
  'recovery': {
    'A': {
      'keep': [1, '原值'],
    },
  },
};
const _globalsA = <String, Object?>{'globalMarker': 'kept'};

void main() {
  test('settings lookup errors cannot discard committed settings and globals on a later save', () async {
    final h = await _Fixture.open();
    addTearDown(h.dispose);
    final saved = await h.seedAndClose();
    final denied = PathAccessException(
      h.file.path,
      OSError('Injected settings directory search denial', Platform.isWindows ? 5 : 13),
    );
    final fault = _ReadFault(h.file, readError: denied);
    final attempt = await h.attempt(fault);
    final bytesAfterFault = await h.file.readAsBytes();

    // Reuse a returned owner, or reopen after failure releases the root.
    // Both products then perform the same successful public update.
    h.engine = attempt.engine ?? await h.openFresh();
    await h.engine.setSettings({
      'recovery': {'B': true},
    });
    await h.reopen();
    final settings = await h.engine.readSettings();

    // First defect-specific oracle: old code returns an empty owner and
    // commits B-only / empty globals over the original successful saves.
    expect(
      <String, Object?>{
        'faultOpenReturned': attempt.engine != null,
        'recovery': settings['recovery'],
        'globalVariables': h.engine.globalVariables,
      },
      {
        'faultOpenReturned': false,
        'recovery': {
          'A': {
            'keep': [1, '原值'],
          },
          'B': true,
        },
        'globalVariables': {'globalMarker': 'kept'},
      },
      reason: 'Open error: ${attempt.error}; IO: ${fault.log.join(' -> ')}',
    );
    expect(attempt.error, same(denied));
    expect(bytesAfterFault, orderedEquals(saved));
    expect(fault.reads, 1);
  });

  test('a genuinely missing settings file is not created until a public save', () async {
    final h = await _Fixture.open();
    addTearDown(h.dispose);
    expect(await h.file.exists(), isFalse);
    expect(h.engine.globalVariables, isEmpty);
    expect((await h.engine.readSettings())['recovery'], isNull);
    await h.reopen();
    expect(await h.file.exists(), isFalse, reason: 'Opening and closing defaults do not save settings.json.');

    await h.engine.setSettings({
      'fresh': {'value': 1},
    });
    await h.engine.setGlobalVariables({'freshGlobal': '保存'});
    expect(await h.file.exists(), isTrue);
    await h.reopen();
    expect((await h.engine.readSettings())['fresh'], {'value': 1});
    expect(h.engine.globalVariables, {'freshGlobal': '保存'});
  });

  test('a successful settings read retains BOM values unknown fields nulls and arrays', () async {
    final h = await _Fixture.open();
    addTearDown(h.dispose);
    const opaque = <String, Object?>{
      '\uFEFFkey': '\uFEFF海 🌊',
      'nullable': null,
      'array': [
        null,
        false,
        '\uFEFF',
        ['nested', 7],
      ],
    };
    const globals = <String, Object?>{
      'text': '\uFEFF全局',
      'array': [null, '海 🌊'],
    };
    await h.engine.setSettings({'opaque': opaque, 'topNull': null});
    await h.engine.setGlobalVariables(globals);
    await h.engine.close();

    // Add only a UTF-8 byte-order mark to JSON committed through public APIs.
    // Quoted BOM keys and values are distinct from this encoding prefix.
    final committed = await h.file.readAsBytes();
    await h.file.writeAsBytes([0xef, 0xbb, 0xbf, ...committed], flush: true);
    final saved = await h.file.readAsBytes();
    final fault = _ReadFault(h.file);
    final attempt = await h.attempt(fault);
    h.engine = attempt.engine ?? await h.openFresh();
    final settings = await h.engine.readSettings();

    expect(attempt.engine, isNotNull);
    expect(attempt.error, isNull);
    expect(settings['opaque'], opaque);
    expect(settings.containsKey('topNull'), isTrue);
    expect(settings['topNull'], isNull);
    expect(h.engine.globalVariables, globals);
    expect(await h.file.readAsBytes(), orderedEquals(saved));
    expect(fault.reads, 1);

    await h.engine.setSettings({
      'opaque': {
        'array': ['replacement'],
        'later': true,
      },
    });
    await h.reopen();
    final reopened = await h.engine.readSettings();
    expect(reopened['opaque'], {
      '\uFEFFkey': '\uFEFF海 🌊',
      'nullable': null,
      'array': ['replacement'],
      'later': true,
    });
    expect(reopened.containsKey('topNull'), isTrue);
    expect(reopened['topNull'], isNull);
    expect(h.engine.globalVariables, globals);
  });

  test('settings startup rejects non-absence errors and existing entities while releasing the root', () async {
    final h = await _Fixture.open();
    addTearDown(h.dispose);
    final saved = await h.seedAndClose();
    final errors = <Object>[
      PathNotFoundException(h.file.path, const OSError('Network path unavailable', 53)),
      FileSystemException('Not a missing-path exception', h.file.path, const OSError('Other error', 2)),
      if (!Platform.isWindows) PathNotFoundException(h.file.path, const OSError('Not the POSIX missing-file code', 3)),
    ];
    for (final error in errors) {
      await _rejectAndRecover(h, saved, _ReadFault(h.file, readError: error), error);
    }
    for (final type in [FileSystemEntityType.file, FileSystemEntityType.unixDomainSock]) {
      final error = PathNotFoundException(h.file.path, const OSError('The entry still exists', 2));
      await _rejectAndRecover(h, saved, _ReadFault(h.file, readError: error, typeResult: type), error);
    }

    // The directory control uses the real filesystem, with the committed
    // document retained intact and restored only after any owner has closed.
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
        'recovery': (await h.engine.readSettings())['recovery'],
        'globalVariables': h.engine.globalVariables,
      },
      {'faultOpenReturned': false, 'recovery': _settingsA['recovery'], 'globalVariables': _globalsA},
    );
    expect(attempted.error, isA<FileSystemException>());
    expect(await h.file.readAsBytes(), orderedEquals(saved));
  });
}

Future<void> _rejectAndRecover(_Fixture h, Uint8List saved, _ReadFault fault, Object error) async {
  final attempt = await h.attempt(fault);
  await attempt.engine?.close();
  h.engine = await h.openFresh();
  expect(
    <String, Object?>{
      'faultOpenReturned': attempt.engine != null,
      'recovery': (await h.engine.readSettings())['recovery'],
      'globalVariables': h.engine.globalVariables,
    },
    {'faultOpenReturned': false, 'recovery': _settingsA['recovery'], 'globalVariables': _globalsA},
    reason: fault.log.join(' -> '),
  );
  expect(attempt.error, same(error));
  expect(await h.file.readAsBytes(), orderedEquals(saved));
  await h.engine.close();
}

class _Fixture {
  _Fixture._(this.root, this.engine);
  final Directory root;
  TavernEngine engine;
  File get file => File('${root.path}/settings.json');

  static Future<_Fixture> open() async {
    final temporary = await Directory.systemTemp.createTemp('dsh-t12-settings-open-');
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
    clock: () => DateTime.utc(2026, 11, 11, 3),
  );

  Future<TavernEngine> openFresh() => _openEngine(root);

  Future<void> reopen() async {
    await engine.close();
    engine = await openFresh();
  }

  Future<Uint8List> seedAndClose() async {
    await engine.setSettings(_settingsA);
    await engine.setGlobalVariables(_globalsA);
    final bytes = await file.readAsBytes();
    await engine.close();
    return bytes;
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
    // Own every returned engine before an assertion can fail.
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

  Future<void> run(Future<void> Function() body) async {
    final parent = Zone.current;
    final selected = file.absolute.uri;
    await IOOverrides.runZoned(
      body,
      createFile: (path) {
        final real = parent.run(() => File(path));
        final uri = parent.run(() => real.absolute.uri);
        return uri == selected ? _SettingsFile(real, this) : real;
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

class _SettingsFile implements File {
  _SettingsFile(this.real, this.fault);
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
    return real.readAsString(encoding: encoding);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
