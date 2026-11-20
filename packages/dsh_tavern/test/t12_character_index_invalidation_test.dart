import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late TavernEngine engine;
  late String id;
  late File card;
  late File original;
  late File index;
  late Uint8List cardBefore;
  late Uint8List originalBefore;
  late Uint8List indexBefore;

  Future<TavernEngine> open() => TavernEngine.openDirectory(
    root,
    config: TavernModelConfig(apiKey: () async => null),
    clock: () => DateTime.utc(2026, 11, 10, 22),
  );

  Future<void> expectNames(String name) async {
    expect((await engine.watchCharacters().first).single.name, name);
    expect((await engine.character(id))!.name, name);
    expect((await engine.characterFields(id))!['name'], name);
    expect((await _json(card))['data'], containsPair('name', name));
    expect((await _json(index))['name'], name);
  }

  Future<void> recoverAndReopen() async {
    expect((await engine.updateCharacterFields(id, {'name': 'After'})).name, 'After');
    await expectNames('After');
    expect(await original.readAsBytes(), orderedEquals(originalBefore));
    await engine.close();
    engine = await open();
    await expectNames('After');
  }

  Future<void> expectRejected(_IndexFault fault, Object expectedError) async {
    TavernCharacter? returned;
    Object? error;
    await fault.run(() async {
      try {
        returned = await engine.updateCharacterFields(id, {'name': 'After'});
      } catch (caught) {
        error = caught;
      }
    });
    expect(fault.hiddenLookups, greaterThan(0), reason: 'The real update must reach the selected lookup boundary.');
    final failure = error;
    // Collect the actual public and disk outcome before asserting. On the old
    // product this is a successful After edit with a still-readable Before
    // summary, not a timeout or a failure to enter the injected boundary.
    final observed = <String, Object?>{
      'returnedName': returned?.name,
      'receivedExpectedError': failure is TavernAuthoringException && identical(failure.cause, expectedError),
      'sourceName': ((await _json(card))['data']! as Map<String, Object?>)['name'],
      'indexName': (await _json(index))['name'],
      'listedName': (await engine.watchCharacters().first).single.name,
      'detailName': (await engine.character(id))!.name,
      'fieldsName': (await engine.characterFields(id))!['name'],
    };
    expect(observed, {
      'returnedName': null,
      'receivedExpectedError': true,
      'sourceName': 'Before',
      'indexName': 'Before',
      'listedName': 'Before',
      'detailName': 'Before',
      'fieldsName': 'Before',
    }, reason: 'Index invalidation did not complete. Error: $error; IO: ${fault.log.join(' -> ')}');
    expect(
      error,
      isA<TavernAuthoringException>()
          .having((error) => error.code, 'code', 'resource_write_failed')
          .having((error) => error.receipt?.state, 'state', TavernAuthoringOperationState.notAdopted)
          .having((error) => error.receipt?.committed, 'committed', false),
    );
    expect(await card.readAsBytes(), orderedEquals(cardBefore));
    expect(await original.readAsBytes(), orderedEquals(originalBefore));
    expect(await index.readAsBytes(), orderedEquals(indexBefore));
    expect(fault.liveHandles, 0);
  }

  setUp(() async {
    final temporary = await Directory.systemTemp.createTemp('dsh-tavern-index-invalidation-');
    // Canonicalize before opening the engine so both spellings select the
    // same real files on Windows and systems whose temp root is a symlink.
    root = Directory(await temporary.resolveSymbolicLinks());
    engine = await open();
    final imported = await engine.importCard(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'spec': 'chara_card_v3',
            'spec_version': '3.0',
            'data': {
              'name': 'Before',
              'description': 'Real card used for index failure recovery.',
              'first_mes': 'Hello.',
              'tags': ['index-fixture'],
              'extensions': <String, Object?>{},
            },
          }),
        ),
      ),
    );
    id = imported.id;
    card = File('${root.path}/characters/$id/card.json');
    original = File('${root.path}/characters/$id/original.json');
    index = File('${root.path}/character-index/$id.json');
    cardBefore = await card.readAsBytes();
    originalBefore = await original.readAsBytes();
    indexBefore = await index.readAsBytes();
    await expectNames('Before');
  });

  tearDown(() async {
    await engine.close();
    await root.delete(recursive: true);
  });

  test('a failed index lookup cannot publish a new card over an undiscarded old summary', () async {
    final denied = PathAccessException(
      index.path,
      OSError('Injected index search denial', Platform.isWindows ? 5 : 13),
    );
    final fault = _IndexFault(
      index,
      openError: denied,
      denyPendingWrite: true,
      deleteError: PathNotFoundException(index.path, const OSError('Linux delete folded lookup error', 2)),
    );
    await expectRejected(fault, denied);
    expect(fault.opens, 1);
    expect(fault.deletes, 0);
    expect(fault.pendingWrites, 0);
    await recoverAndReopen();
  });

  test('non-absence path-not-found error codes do not authorize source publication', () async {
    // Fixed Dart 3.13.5 maps these Windows network errors to the same class as
    // missing files. Exercise that class/code contract on every test host.
    for (final code in [53, 67]) {
      final unavailable = PathNotFoundException(index.path, OSError('Unavailable network path or name', code));
      final fault = _IndexFault(index, openError: unavailable, denyPendingWrite: true);
      await expectRejected(fault, unavailable);
      expect(fault.opens, 1);
      expect(fault.pendingWrites, 0);
    }
    await recoverAndReopen();
  });

  test('a successful ambiguity probe closes its real handle before removing the old summary', () async {
    final fault = _IndexFault(index);
    await fault.run(() async {
      expect((await engine.updateCharacterFields(id, {'name': 'After'})).name, 'After');
    });
    expect(fault.opens, 1);
    expect(fault.closedHandles, 1);
    expect(fault.liveHandles, 0);
    expect(fault.deletes, 1);
    expect(fault.handlesAtDelete, [0]);
    expect(fault.pendingWrites, 1);
    expect(fault.oldIndexPresentAtWrite, [false]);
    await expectNames('After');
    expect(await original.readAsBytes(), orderedEquals(originalBefore));
    await engine.close();
    engine = await open();
    await expectNames('After');
  });

  test('a delete path-not-found error after a successful probe still prevents publication', () async {
    final failedDelete = PathNotFoundException(index.path, const OSError('Delete lookup lost access', 2));
    final fault = _IndexFault(index, deleteError: failedDelete, denyPendingWrite: true);
    await expectRejected(fault, failedDelete);
    expect(fault.closedHandles, 1);
    expect(fault.deletes, 1);
    expect(fault.handlesAtDelete, [0]);
    expect(fault.pendingWrites, 0);
    await recoverAndReopen();
  });

  test('a failed probe close prevents card publication and leaves the next edit usable', () async {
    final failedClose = FileSystemException('Injected close failure', index.path, const OSError('I/O error', 5));
    final fault = _IndexFault(index, closeError: failedClose, denyPendingWrite: true);
    await expectRejected(fault, failedClose);
    expect(fault.closedHandles, 1);
    expect(fault.deletes, 0);
    expect(fault.pendingWrites, 0);
    await recoverAndReopen();
  });

  for (final missingParent in [false, true]) {
    test('an edit tolerates a genuinely missing index ${missingParent ? 'directory' : 'file'}', () async {
      final fault = _IndexFault(index, hideLeaf: false);
      if (missingParent) {
        await index.parent.delete(recursive: true);
      } else {
        await index.delete();
      }
      await fault.run(() async {
        expect((await engine.updateCharacterFields(id, {'name': 'After'})).name, 'After');
      });
      expect(fault.opens, 1);
      expect(fault.nativeOpenError, isA<PathNotFoundException>());
      final nativeError = fault.nativeOpenError! as PathNotFoundException;
      expect(nativeError.osError!.errorCode, isIn(Platform.isWindows ? [2, 3] : [2]));
      expect(fault.deletes, 0);
      expect(fault.liveHandles, 0);
      await expectNames('After');
      expect(await original.readAsBytes(), orderedEquals(originalBefore));
      await engine.close();
      engine = await open();
      await expectNames('After');
    });
  }
}

Future<Map<String, Object?>> _json(File file) async => jsonDecode(await file.readAsString()) as Map<String, Object?>;

class _IndexFault {
  _IndexFault(
    this.index, {
    this.hideLeaf = true,
    this.openError,
    this.closeError,
    this.deleteError,
    this.denyPendingWrite = false,
  });

  final File index;
  final bool hideLeaf;
  final Object? openError;
  final Object? closeError;
  final Object? deleteError;
  final bool denyPendingWrite;
  final log = <String>[];
  final handlesAtDelete = <int>[];
  final oldIndexPresentAtWrite = <bool>[];
  final handles = <_ProbeHandle>[];
  var hiddenLookups = 0;
  var opens = 0;
  var deletes = 0;
  var pendingWrites = 0;
  var liveHandles = 0;
  var closedHandles = 0;
  Object? nativeOpenError;

  Future<void> run(Future<void> Function() body) async {
    final parent = Zone.current;
    final leaf = index.absolute.uri;
    final pending = File('${index.path}.writing').absolute.uri;
    try {
      await IOOverrides.runZoned(
        body,
        fseGetType: (path, followLinks) {
          final uri = parent.run(() => File(path).absolute.uri);
          if (hideLeaf && uri == leaf) {
            hiddenLookups++;
            log.add('lookup:notFound');
            return Future.value(FileSystemEntityType.notFound);
          }
          return parent.run(() => FileSystemEntity.type(path, followLinks: followLinks));
        },
        createFile: (path) {
          final real = parent.run(() => File(path));
          final uri = parent.run(() => real.absolute.uri);
          if (uri == leaf || uri == pending) return _IndexFile(real, this, isPending: uri == pending);
          return real;
        },
      );
    } finally {
      // A failed assertion, or a broken product that forgets close, must not
      // retain a real descriptor and make Windows temp-directory cleanup fail.
      for (final handle in handles) {
        await handle.releaseForCleanup();
      }
    }
  }
}

class _IndexFile implements File {
  _IndexFile(this.real, this.fault, {required this.isPending});
  final File real;
  final _IndexFault fault;
  final bool isPending;
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
  Future<String> readAsString({Encoding encoding = utf8}) => real.readAsString(encoding: encoding);
  @override
  Future<File> rename(String newPath) => real.rename(newPath);
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    if (isPending) return real.delete(recursive: recursive);
    fault.deletes++;
    fault.handlesAtDelete.add(fault.liveHandles);
    fault.log.add('delete:handles=${fault.liveHandles}');
    if (fault.deleteError case final error?) throw error;
    return real.delete(recursive: recursive);
  }

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async {
    fault.opens++;
    fault.log.add('open:$mode');
    if (mode != FileMode.read) throw StateError('An invalidation probe must not create or truncate the index.');
    if (fault.openError case final error?) throw error;
    final RandomAccessFile opened;
    try {
      opened = await real.open(mode: mode);
    } catch (error) {
      fault.nativeOpenError = error;
      rethrow;
    }
    final handle = _ProbeHandle(opened, fault);
    fault.handles.add(handle);
    fault.liveHandles++;
    return handle;
  }

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    if (isPending) {
      fault.pendingWrites++;
      fault.oldIndexPresentAtWrite.add(await fault.index.exists());
      fault.log.add('write:oldIndex=${fault.oldIndexPresentAtWrite.last}');
      if (fault.denyPendingWrite) {
        throw PathAccessException(real.path, OSError('Injected index search denial', Platform.isWindows ? 5 : 13));
      }
    }
    return real.writeAsString(contents, mode: mode, encoding: encoding, flush: flush);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ProbeHandle implements RandomAccessFile {
  _ProbeHandle(this.real, this.fault);
  final RandomAccessFile real;
  final _IndexFault fault;
  var released = false;

  @override
  Future<RandomAccessFile> close() async {
    await releaseForCleanup();
    fault.closedHandles++;
    fault.log.add('close:completed');
    if (fault.closeError case final error?) throw error;
    return this;
  }

  Future<void> releaseForCleanup() async {
    if (released) return;
    await real.close();
    released = true;
    fault.liveHandles--;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
