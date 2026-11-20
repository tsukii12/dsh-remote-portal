import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart' show t24Card;

void main() {
  late _Harness h;

  setUp(() async {
    h = await _Harness.open();
  });
  tearDown(() => h.dispose());

  test('lorebook deletion cannot acknowledge an inaccessible retained source', () async {
    final saved = await h.importA();
    final denied = PathAccessException(
      saved.file.path,
      OSError('Injected lorebook search denial', Platform.isWindows ? 5 : 13),
    );
    final fault = _DeleteFault(
      saved.file,
      openError: denied,
      deleteError: PathNotFoundException(saved.file.path, const OSError('Linux delete folded lookup error', 2)),
    );
    await _expectRejected(h, saved, fault, denied);
    // These algorithm-specific checks deliberately follow the public outcome
    // oracle. The old product must first fail with acknowledged=true / A.
    expect(fault.opens, 1);
    expect(fault.deletes, 0);
    expect(fault.followLinks, [true]);
    await h.recover(saved);
  });

  test('only explicit missing-file open errors authorize a missing lorebook result', () async {
    final saved = await h.importA();
    final errors = <Object>[
      PathNotFoundException(saved.file.path, const OSError('Network path unavailable', 53)),
      PathNotFoundException(saved.file.path, const OSError('Network name unavailable', 67)),
      FileSystemException('Not an explicit PathNotFoundException', saved.file.path, const OSError('Other error', 2)),
      if (!Platform.isWindows)
        PathNotFoundException(saved.file.path, const OSError('Not the POSIX missing-file code', 3)),
    ];
    for (final error in errors) {
      final fault = _DeleteFault(saved.file, openError: error);
      await _expectRejected(h, saved, fault, error);
      expect(fault.opens, 1);
      expect(fault.deletes, 0);
    }
    await h.recover(saved);
  });

  test('an ambiguous lookup closes its real read handle before actual lorebook deletion', () async {
    final saved = await h.importA();
    final fault = _DeleteFault(saved.file);
    await fault.run(() => h.engine.deleteLorebook(saved.id));
    await h.expectAbsent(saved.id);
    expect(fault.log, [
      'exists:false',
      'type:followLinks=true:notFound',
      'open:read',
      'close:completed',
      'delete:handles=0:recursive=false',
    ]);
    expect(fault.opens, 1);
    expect(fault.closedHandles, 1);
    expect(fault.handlesAtDelete, [0]);
    expect(fault.cleanupCloses, 0);
    await h.reopen();
    await h.expectAbsent(saved.id);
    await h.putB(saved.id);
  });

  test('a delete error after a successful lorebook probe is not swallowed as missing', () async {
    final saved = await h.importA();
    final failedDelete = PathNotFoundException(saved.file.path, const OSError('Delete lookup lost access', 2));
    final fault = _DeleteFault(saved.file, deleteError: failedDelete);
    final failure = await _expectRejected(h, saved, fault, failedDelete, adoptionUnconfirmed: true);
    expect(fault.closedHandles, 1);
    expect(fault.deletes, 1);
    expect(fault.handlesAtDelete, [0]);
    final receipt = (failure as TavernAuthoringException).receipt!;
    final operation = await h.engine.readAuthoringOperation(receipt.operationId, domainId: receipt.domainId);
    expect(operation!.state, TavernAuthoringOperationState.unconfirmed);
    expect(operation.committed, isNull);
    await expectLater(
      h.engine.deleteLorebook(saved.id),
      throwsA(
        isA<TavernAuthoringException>()
            .having((error) => error.code, 'code', 'pending_operation')
            .having((error) => error.receipt, 'no new operation', isNull)
            .having((error) => error.blockedOperationId, 'blocked operation', receipt.operationId)
            .having((error) => error.blockedDomainId, 'blocked domain', receipt.domainId),
      ),
    );
    expect(await saved.file.readAsBytes(), orderedEquals(saved.bytes));
  });

  test('a failed probe close retains the lorebook and the next deletion remains usable', () async {
    final saved = await h.importA();
    final failedClose = FileSystemException('Injected close failure', saved.file.path, const OSError('I/O error', 5));
    final fault = _DeleteFault(saved.file, closeError: failedClose);
    await _expectRejected(h, saved, fault, failedClose);
    expect(fault.closedHandles, 1);
    expect(fault.deletes, 0);
    await h.recover(saved);
  });

  test('a managed regular file requires a readable source before deletion', () async {
    // Cover both the original exists=true route and a file revealed by the
    // follow-up type lookup after exists had returned false.
    for (final hiddenExists in [false, true]) {
      final saved = await h.importA();
      final denied = PathAccessException(
        saved.file.path,
        OSError('Opening this book would be denied', Platform.isWindows ? 5 : 13),
      );
      final fault = _DeleteFault(saved.file, hideExists: hiddenExists, hideType: false, openError: denied);
      await _expectRejected(h, saved, fault, denied);
      expect(fault.opens, 0);
      expect(fault.byteReads, 1);
      expect(fault.deletes, 0);
      expect(fault.followLinks, hiddenExists ? [true] : isEmpty);
      expect(fault.handlesAtDelete, isEmpty);
      expect(fault.cleanupCloses, 0);
      await h.recover(saved);
    }
  });

  test('missing directory leaf and repeated deletion preserve bindings and clear warm metadata', () async {
    final folder = Directory('${h.root.path}/lorebooks');
    const absent = 'never-written';
    final missing = File('${folder.path}/$absent.json');
    await h.bind(absent);
    expect(await folder.exists(), isFalse);
    await _deleteActuallyMissing(h, missing, absent);
    expect(await folder.exists(), isFalse, reason: 'Read-only absence probing must not create the parent directory.');
    await h.expectAbsent(absent);

    await h.engine.putLorebook('kept', _book('KEEP'));
    final other = File('${folder.path}/kept.json');
    final otherBytes = await other.readAsBytes();
    await _deleteActuallyMissing(h, missing, absent);
    await h.expectAbsent(absent);

    final nonFile = await Directory('${folder.path}/not-a-file.json').create();
    final marker = await File('${nonFile.path}/keep.txt').writeAsString('not a lorebook file');
    await h.engine.deleteLorebook('not-a-file');
    expect(await marker.readAsString(), 'not a lorebook file');

    final saved = await h.importA();
    // Remove only the real source to create a genuine missing leaf while the
    // public reads still have the imported A / source name / report cached.
    // No private cache or SQL writes are used to establish this condition.
    await saved.file.delete();
    expect(await h.engine.lorebook(saved.id), saved.raw);
    expect(await h.engine.readImportReport(TavernImportKind.lorebook, saved.id), isNotNull);
    await _deleteActuallyMissing(h, saved.file, saved.id);
    await h.expectAbsent(saved.id);
    await _deleteActuallyMissing(h, saved.file, saved.id);
    await h.expectAbsent(saved.id);
    expect(await other.readAsBytes(), orderedEquals(otherBytes));
    expect((await h.engine.lorebook('kept'))!['name'], 'KEEP');
    await h.putB(saved.id);
    await h.reopen();
    expect((await h.engine.lorebook(saved.id))!['name'], 'B');
    expect((await h.engine.lorebook('kept'))!['name'], 'KEEP');
    await h.expectBindings(saved.id);
  });
}

Future<Object> _expectRejected(
  _Harness h,
  _SavedBook saved,
  _DeleteFault fault,
  Object expectedError, {
  bool adoptionUnconfirmed = false,
}) async {
  Object? failure;
  late Map<String, Object?> whileFaulted;
  await fault.run(() async {
    try {
      await h.engine.deleteLorebook(saved.id);
    } catch (error) {
      failure = error;
    }
    // Keep the lookup fault active while observing the public cache views.
    // Clearing a cache before a failed delete would make these reads absent.
    whileFaulted = await h.snapshot(saved.id);
  });
  final sourceAfter = await saved.file.readAsBytes();
  await h.reopen();
  final reopened = await h.engine.lorebook(saved.id);

  // First defect-specific assertion: old code acknowledges deletion, yet an
  // actual engine reopen still returns A. Missing new open() calls, timing,
  // compile errors and failure to reach an injected gate are not this oracle.
  expect(
    <String, Object?>{'deleteAcknowledged': failure == null, 'reopenedName': reopened?['name']},
    {'deleteAcknowledged': false, 'reopenedName': 'A'},
    reason: 'Failure: $failure; IO: ${fault.log.join(' -> ')}',
  );
  if (adoptionUnconfirmed) {
    expect(
      failure,
      isA<TavernAuthoringException>()
          .having((error) => error.code, 'code', 'resource_write_failed')
          .having((error) => error.cause, 'original failure', same(expectedError))
          .having((error) => error.receipt?.state, 'state', TavernAuthoringOperationState.unconfirmed)
          .having((error) => error.receipt?.committed, 'committed', isNull),
    );
  } else {
    expect(failure, same(expectedError));
  }
  expect(sourceAfter, orderedEquals(saved.bytes));
  expect(whileFaulted, saved.view);
  expect(await h.snapshot(saved.id), saved.view);
  expect(jsonDecode(await h.engine.exportLorebook(saved.id)), saved.raw);
  expect(fault.existsCalls, greaterThan(0));
  expect(fault.cleanupCloses, 0, reason: 'Product code must close every successfully opened probe handle.');
  return failure!;
}

Future<void> _deleteActuallyMissing(_Harness h, File file, String id) async {
  final fault = _DeleteFault(file, hideExists: false, hideType: false);
  await fault.run(() => h.engine.deleteLorebook(id));
  expect(fault.nativeOpenError, isA<PathNotFoundException>());
  final error = fault.nativeOpenError! as PathNotFoundException;
  expect(error.osError!.errorCode, isIn(Platform.isWindows ? [2, 3] : [2]));
  expect(fault.opens, 1);
  expect(fault.deletes, 0);
  expect(fault.followLinks, [true]);
  expect(fault.cleanupCloses, 0);
}

Map<String, Object?> _book(String name) => {
  'name': name,
  'opaque': {
    'kept': [null, '海 🌊', false],
  },
  'entries': {
    '0': {
      'uid': 0,
      'key': ['beacon'],
      'content': '$name BODY',
      'position': 0,
      'constant': true,
    },
  },
};

class _Harness {
  _Harness._(this.root, this.engine, this.chatId);
  final Directory root;
  TavernEngine engine;
  final String chatId;

  static Future<_Harness> open() async {
    final temporary = await Directory.systemTemp.createTemp('dsh-t12-lorebook-delete-');
    final root = Directory(await temporary.resolveSymbolicLinks());
    TavernEngine? engine;
    try {
      engine = await _openEngine(root);
      final card = await engine.importCard(t24Card());
      final chatId = await engine.createChat(card.id);
      return _Harness._(root, engine, chatId);
    } catch (_) {
      await engine?.close();
      await root.delete(recursive: true);
      rethrow;
    }
  }

  static Future<TavernEngine> _openEngine(Directory root) => TavernEngine.openDirectory(
    root,
    config: TavernModelConfig(apiKey: () async => null),
    clock: () => DateTime.utc(2026, 11, 10, 23),
  );

  Future<void> reopen() async {
    await engine.close();
    engine = await _openEngine(root);
  }

  Future<void> bind(String id) async {
    await engine.bindLorebooks([id]);
    await engine.bindLorebooks([id], source: WorldInfoSource.chat, chatId: chatId);
  }

  Future<void> expectBindings(String id) async {
    expect((await engine.readSettings())['lorebooks'], {
      'global': [id],
    });
    expect((await engine.readSettings(chatId: chatId))['lorebooks'], {
      'global': [id],
      'chat': [id],
    });
  }

  Future<_SavedBook> importA() async {
    final raw = _book('A');
    final imported = await engine.importLorebook(jsonEncode(raw), fileName: r'exports\来源-A.json');
    final id = imported.book.id;
    await bind(id);
    final file = File('${root.path}/lorebooks/$id.json');
    final view = await snapshot(id);
    expect(imported.book.raw, raw);
    expect(imported.book.stWorldName, '来源-A');
    expect(view['report'], isNotNull);
    expect(view['raw'], raw);
    return _SavedBook(id, file, raw, await file.readAsBytes(), view);
  }

  Future<Map<String, Object?>> snapshot(String id) async {
    final raw = await engine.lorebook(id);
    final summary = (await engine.listLorebooks()).where((book) => book.id == id).firstOrNull;
    final report = await engine.readImportReport(TavernImportKind.lorebook, id);
    return {
      'raw': raw,
      'summary': summary == null
          ? null
          : {'name': summary.name, 'entryCount': summary.entryCount, 'stWorldName': summary.stWorldName},
      'report': report?.toJson(),
      'globalBindings': (await engine.readSettings())['lorebooks'],
      'chatBindings': (await engine.readSettings(chatId: chatId))['lorebooks'],
    };
  }

  Future<void> expectAbsent(String id) async {
    expect(await engine.lorebook(id), isNull);
    expect(await engine.readImportReport(TavernImportKind.lorebook, id), isNull);
    expect((await engine.listLorebooks()).map((book) => book.id), isNot(contains(id)));
    expect(await File('${root.path}/lorebooks/$id.json').exists(), isFalse);
    await expectBindings(id);
  }

  Future<void> putB(String id) async {
    final raw = _book('B');
    await engine.putLorebook(id, raw);
    expect(await engine.lorebook(id), raw);
    expect(jsonDecode(await engine.exportLorebook(id)), raw);
    final summary = (await engine.listLorebooks()).singleWhere((book) => book.id == id);
    expect(summary.stWorldName, isNull, reason: 'The removed imported source name must not attach to a new raw book.');
    expect(await engine.readImportReport(TavernImportKind.lorebook, id), isNull);
    await expectBindings(id);
  }

  Future<void> recover(_SavedBook saved) async {
    await engine.deleteLorebook(saved.id);
    await expectAbsent(saved.id);
    await reopen();
    await expectAbsent(saved.id);
    await putB(saved.id);
    await reopen();
    expect(await engine.lorebook(saved.id), _book('B'));
    await expectBindings(saved.id);
  }

  Future<void> dispose() async {
    try {
      await engine.close();
    } finally {
      await root.delete(recursive: true);
    }
  }
}

class _SavedBook {
  _SavedBook(this.id, this.file, this.raw, this.bytes, this.view);
  final String id;
  final File file;
  final Map<String, Object?> raw;
  final Uint8List bytes;
  final Map<String, Object?> view;
}

class _DeleteFault {
  _DeleteFault(
    this.file, {
    this.hideExists = true,
    this.hideType = true,
    this.openError,
    this.closeError,
    this.deleteError,
  });
  final File file;
  final bool hideExists;
  final bool hideType;
  final Object? openError;
  final Object? closeError;
  final Object? deleteError;
  final log = <String>[];
  final followLinks = <bool>[];
  final handlesAtDelete = <int>[];
  final handles = <_ProbeHandle>[];
  var existsCalls = 0;
  var opens = 0;
  var byteReads = 0;
  var deletes = 0;
  var liveHandles = 0;
  var closedHandles = 0;
  var cleanupCloses = 0;
  Object? nativeOpenError;

  Future<void> run(Future<void> Function() body) async {
    final parent = Zone.current;
    final selected = file.absolute.uri;
    try {
      await IOOverrides.runZoned(
        body,
        createFile: (path) {
          final real = parent.run(() => File(path));
          final uri = parent.run(() => real.absolute.uri);
          return uri == selected ? _BookFile(real, this) : real;
        },
        fseGetType: (path, follows) {
          final uri = parent.run(() => File(path).absolute.uri);
          if (uri == selected) {
            followLinks.add(follows);
            if (hideType) {
              log.add('type:followLinks=$follows:notFound');
              return Future.value(FileSystemEntityType.notFound);
            }
          }
          return parent.run(() => FileSystemEntity.type(path, followLinks: follows));
        },
      );
    } finally {
      // Test cleanup cannot conceal a leaked product handle: count every
      // descriptor that only the test, rather than probe.close(), releases.
      for (final handle in handles) {
        if (!handle.released) {
          cleanupCloses++;
          await handle.release();
        }
      }
    }
  }
}

class _BookFile implements File {
  _BookFile(this.real, this.fault);
  final File real;
  final _DeleteFault fault;
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
  Future<bool> exists() async {
    fault.existsCalls++;
    final found = fault.hideExists ? false : await real.exists();
    fault.log.add('exists:$found');
    return found;
  }

  @override
  Future<String> readAsString({Encoding encoding = utf8}) => real.readAsString(encoding: encoding);
  @override
  Future<Uint8List> readAsBytes() async {
    fault.byteReads++;
    if (fault.openError case final error?) throw error;
    return real.readAsBytes();
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    fault.deletes++;
    fault.handlesAtDelete.add(fault.liveHandles);
    fault.log.add('delete:handles=${fault.liveHandles}:recursive=$recursive');
    if (recursive) throw StateError('A lorebook deletion must not recurse through a directory.');
    if (fault.deleteError case final error?) throw error;
    return real.delete(recursive: recursive);
  }

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async {
    fault.opens++;
    if (mode != FileMode.read) throw StateError('A lorebook probe must not create or truncate the source.');
    fault.log.add('open:read');
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ProbeHandle implements RandomAccessFile {
  _ProbeHandle(this.real, this.fault);
  final RandomAccessFile real;
  final _DeleteFault fault;
  var released = false;

  @override
  Future<RandomAccessFile> close() async {
    await release();
    fault.closedHandles++;
    fault.log.add('close:completed');
    if (fault.closeError case final error?) throw error;
    return this;
  }

  Future<void> release() async {
    if (released) return;
    await real.close();
    released = true;
    fault.liveHandles--;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
