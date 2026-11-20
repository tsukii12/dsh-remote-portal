import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

void main() {
  test('persona lookup errors cannot initialize an empty authoritative library', () async {
    final h = await _Fixture.open();
    addTearDown(h.dispose);
    final saved = await h.seedAAndClose();
    final denied = PathAccessException(
      h.index.path,
      OSError('Injected persona directory search denial', Platform.isWindows ? 5 : 13),
    );
    final fault = _ReadFault(h.index, readError: denied);
    final attempt = await h.attempt(fault);
    final bytesAfterFault = await h.index.readAsBytes();

    // Retain a returned engine, or acquire a new owner after a failed open.
    // No old-product switch changes the mutation or expectation below.
    h.engine = attempt.engine ?? await h.openFresh();
    final created = await h.engine.createPersona(name: 'B', description: 'B appended after the read fault');
    await h.reopen();
    final names = (await h.engine.watchPersonas().first).map((persona) => persona.name).toList()..sort();
    final selection = await h.engine.personaSelection();

    // First defect-specific oracle. Old code returns an empty owner and then
    // really overwrites the committed A with B: true / [B] / null.
    expect(
      <String, Object?>{
        'faultOpenReturned': attempt.engine != null,
        'reopenedNames': names,
        'defaultPersonaId': selection.defaultPersonaId,
      },
      {
        'faultOpenReturned': false,
        'reopenedNames': ['A', 'B'],
        'defaultPersonaId': saved.persona.id,
      },
      reason: 'Open error: ${attempt.error}; IO: ${fault.log.join(' -> ')}',
    );
    expect(attempt.error, same(denied));
    expect(bytesAfterFault, orderedEquals(saved.bytes));
    expect((await h.engine.persona(saved.persona.id))!.toJson(), saved.persona.toJson());
    expect((await h.engine.persona(created.id))!.name, 'B');
    expect(selection.source, PersonaSelectionSource.globalDefault);
    expect((await h.engine.readSettings())['personaRecoveryMarker'], 'root settings survived');
    expect(fault.reads, 1);
  });

  test('non-absence read errors fail persona startup and release the root reservation', () async {
    final h = await _Fixture.open();
    addTearDown(h.dispose);
    final saved = await h.seedAAndClose();
    final errors = <Object>[
      PathNotFoundException(h.index.path, const OSError('Network path unavailable', 53)),
      PathNotFoundException(h.index.path, const OSError('Network name unavailable', 67)),
      FileSystemException('Not an explicit missing-file exception', h.index.path, const OSError('Other error', 2)),
      if (!Platform.isWindows) PathNotFoundException(h.index.path, const OSError('Not the POSIX missing-file code', 3)),
    ];
    for (final error in errors) {
      final fault = _ReadFault(h.index, readError: error);
      final attempt = await h.attempt(fault);
      // Release an incorrectly returned public owner before checking recovery.
      // On the correct path the failed open has already released the root.
      await attempt.engine?.close();
      h.engine = await h.openFresh();
      final names = (await h.engine.watchPersonas().first).map((persona) => persona.name).toList();
      final selection = await h.engine.personaSelection();
      expect(
        <String, Object?>{
          'faultOpenReturned': attempt.engine != null,
          'recoveredNames': names,
          'defaultPersonaId': selection.defaultPersonaId,
        },
        {
          'faultOpenReturned': false,
          'recoveredNames': ['A'],
          'defaultPersonaId': saved.persona.id,
        },
      );
      expect(attempt.error, same(error));
      expect(await h.index.readAsBytes(), orderedEquals(saved.bytes));
      expect((await h.engine.persona(saved.persona.id))!.toJson(), saved.persona.toJson());
      expect(fault.reads, 1);
      await h.engine.close();
    }

    // Fixed Linux File::Open can map a socket to ENOENT. More generally a
    // missing-like read error cannot authorize an empty document when the
    // post-error lookup identifies any existing entry, including a file.
    for (final type in [FileSystemEntityType.file, FileSystemEntityType.unixDomainSock]) {
      final knownError = PathNotFoundException(h.index.path, const OSError('Read failed while the entry remains', 2));
      final knownFault = _ReadFault(h.index, readError: knownError, typeResult: type);
      final knownAttempt = await h.attempt(knownFault);
      await knownAttempt.engine?.close();
      h.engine = await h.openFresh();
      expect(
        <String, Object?>{
          'faultOpenReturned': knownAttempt.engine != null,
          'recoveredNames': (await h.engine.watchPersonas().first).map((persona) => persona.name).toList(),
          'defaultPersonaId': (await h.engine.personaSelection()).defaultPersonaId,
        },
        {
          'faultOpenReturned': false,
          'recoveredNames': ['A'],
          'defaultPersonaId': saved.persona.id,
        },
      );
      expect(knownAttempt.error, same(knownError));
      expect(await h.index.readAsBytes(), orderedEquals(saved.bytes));
      await h.engine.close();
    }
  });

  test('genuinely missing persona parent and leaf initialize without writing until public create', () async {
    for (final missingParent in [true, false]) {
      final h = await _Fixture.open();
      addTearDown(h.dispose);
      await h.engine.close();
      if (!missingParent) await h.index.parent.create(recursive: true);
      expect(await h.index.exists(), isFalse);
      expect(await h.index.parent.exists(), !missingParent);
      final fault = _ReadFault(h.index, hideType: false);
      final attempt = await h.attempt(fault);
      h.engine = attempt.engine ?? await h.openFresh();

      expect(await h.engine.watchPersonas().first, isEmpty);
      expect((await h.engine.personaSelection()).source, PersonaSelectionSource.none);
      expect(attempt.error, isNull);
      expect(attempt.engine, isNotNull);
      expect(await h.index.exists(), isFalse, reason: 'An empty startup is not a new file commit.');
      expect(await h.index.parent.exists(), !missingParent);
      expect(fault.nativeReadError, isA<PathNotFoundException>());
      final missing = fault.nativeReadError! as PathNotFoundException;
      expect(missing.osError!.errorCode, isIn(Platform.isWindows ? [2, 3] : [2]));
      expect(fault.reads, 1);

      final created = await h.engine.createPersona(name: 'Fresh', description: 'Saved only after explicit create');
      await h.engine.setDefaultPersona(created.id);
      expect(await h.index.exists(), isTrue);
      await h.reopen();
      expect((await h.engine.watchPersonas().first).map((persona) => persona.name), ['Fresh']);
      expect((await h.engine.personaSelection()).defaultPersonaId, created.id);
      expect((await h.engine.persona(created.id))!.description, 'Saved only after explicit create');
    }
  });

  test('a misleading persona type lookup cannot replace a successfully read committed library', () async {
    final h = await _Fixture.open();
    addTearDown(h.dispose);
    final saved = await h.seedAAndClose();
    final fault = _ReadFault(h.index);
    final attempt = await h.attempt(fault);
    h.engine = attempt.engine ?? await h.openFresh();
    final names = (await h.engine.watchPersonas().first).map((persona) => persona.name).toList();
    final selection = await h.engine.personaSelection();
    expect(
      <String, Object?>{
        'opened': attempt.engine != null,
        'names': names,
        'defaultPersonaId': selection.defaultPersonaId,
      },
      {
        'opened': true,
        'names': ['A'],
        'defaultPersonaId': saved.persona.id,
      },
    );
    expect(attempt.error, isNull);
    expect(await h.index.readAsBytes(), orderedEquals(saved.bytes));
    expect((await h.engine.persona(saved.persona.id))!.toJson(), saved.persona.toJson());
    expect(fault.reads, 1);
    expect(fault.nativeReadError, isNull);
    final created = await h.engine.createPersona(name: 'B');
    await h.reopen();
    expect((await h.engine.watchPersonas().first).map((persona) => persona.name), ['A', 'B']);
    expect((await h.engine.personaSelection()).defaultPersonaId, saved.persona.id);
    expect((await h.engine.persona(created.id))!.name, 'B');
  });
}

class _Fixture {
  _Fixture._(this.root, this.engine);
  final Directory root;
  TavernEngine engine;
  File get index => File('${root.path}/personas/index.json');

  static Future<_Fixture> open() async {
    final temporary = await Directory.systemTemp.createTemp('dsh-t12-persona-open-');
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
    clock: () => DateTime.utc(2026, 11, 10, 23),
  );

  Future<TavernEngine> openFresh() => _openEngine(root);

  Future<void> reopen() async {
    await engine.close();
    engine = await openFresh();
  }

  Future<_SavedPersona> seedAAndClose() async {
    await engine.setSettings({'personaRecoveryMarker': 'root settings survived'});
    final persona = await engine.createPersona(name: 'A', description: 'A kept {{user}}\r\n海 🌊');
    await engine.setDefaultPersona(persona.id);
    expect((await engine.watchPersonas().first).single.id, persona.id);
    expect((await engine.personaSelection()).defaultPersonaId, persona.id);
    final bytes = await index.readAsBytes();
    await engine.close();
    return _SavedPersona(persona, bytes);
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
    // Own every returned engine before any later observation can fail, so
    // teardown also closes the old product's incorrectly accepted owner.
    final accepted = opened;
    if (accepted != null) engine = accepted;
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

class _SavedPersona {
  _SavedPersona(this.persona, this.bytes);
  final TavernPersona persona;
  final Uint8List bytes;
}

class _OpenAttempt {
  _OpenAttempt(this.engine, this.error);
  final TavernEngine? engine;
  final Object? error;
}

class _ReadFault {
  _ReadFault(this.file, {this.hideType = true, this.readError, this.typeResult = FileSystemEntityType.notFound});
  final File file;
  final bool hideType;
  final Object? readError;
  final FileSystemEntityType typeResult;
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
        return uri == selected ? _PersonaFile(real, this) : real;
      },
      fseGetType: (path, followLinks) {
        final uri = parent.run(() => File(path).absolute.uri);
        if (hideType && uri == selected) {
          log.add('type:$typeResult');
          return Future.value(typeResult);
        }
        return parent.run(() => FileSystemEntity.type(path, followLinks: followLinks));
      },
    );
  }
}

class _PersonaFile implements File {
  _PersonaFile(this.real, this.fault);
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
  Future<bool> exists() => real.exists();
  @override
  Future<String> readAsString({Encoding encoding = utf8}) async {
    fault.reads++;
    fault.log.add('readAsString');
    if (fault.readError case final error?) throw error;
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
