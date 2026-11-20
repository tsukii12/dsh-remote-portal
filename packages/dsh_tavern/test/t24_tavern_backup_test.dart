import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:dsh_tavern/src/backup.dart';
import 'package:dsh_tavern/src/io/tavern_backup.dart';
import 'package:test/test.dart';

final _createdAt = DateTime.utc(2026, 11, 10, 12, 13, 14);
final _databaseBytes = utf8.encode('independent database snapshot');

void main() {
  late Directory workspace;
  late Directory root;
  late File output;

  setUp(() async {
    final temporary = await Directory.systemTemp.createTemp('dsh-tavern-t24-backup-');
    workspace = Directory(await temporary.resolveSymbolicLinks());
    root = await Directory('${workspace.path}/library').create();
    output = File('${workspace.path}/library.zip');
  });

  tearDown(() async {
    await workspace.delete(recursive: true);
  });

  test('capture waits for the database callback and uses its bytes and actual version', () async {
    await _write(root, 'tavern.sqlite3', utf8.encode('live main database is not the snapshot'));
    await _write(root, 'tavern.sqlite3-wal', utf8.encode('committed WAL belongs to the callback'));
    final entered = Completer<void>();
    final release = Completer<void>();
    var completed = false;
    final capture =
        captureTavernBackup(
          root,
          createdAt: _createdAt,
          backupDatabase: (destination) async {
            expect(await destination.exists(), false);
            entered.complete();
            await release.future;
            await destination.writeAsBytes(_databaseBytes, flush: true);
            return 7;
          },
        ).then((snapshot) {
          completed = true;
          return snapshot;
        });
    await entered.future;
    expect(completed, false);
    release.complete();
    final snapshot = await capture;
    addTearDown(snapshot.dispose);
    final info = await snapshot.writeZip(output);
    expect(info.sqliteUserVersion, 7);
    expect(info.createdAt, _createdAt);
    expect(info.fileCount, 1);
    expect(info.totalBytes, _databaseBytes.length);
    final archive = await _readZip(output);
    expect(archive.findFile('data/tavern.sqlite3')!.content, orderedEquals(_databaseBytes));
    expect(archive.findFile('data/tavern.sqlite3-wal'), isNull);
  });

  test('snapshot keeps originals, opaque bytes, reports and empty directories', () async {
    final payload = <String, List<int>>{
      'settings.json': utf8.encode('{"version":1,"settings":{},"globalVariables":{"x":"值"}}'),
      'regex-library.json': utf8.encode('{"version":1,"scripts":[]}'),
      'personas/index.json': utf8.encode('{"version":1,"personas":[]}'),
      'lorebooks/book.json': utf8.encode('{"entries":{}}'),
      'characters/card/card.json': utf8.encode('{"name":"中文角色"}'),
      'characters/card/library.json': utf8.encode('{"version":1}'),
      'characters/card/import-report.json': utf8.encode('{"version":1,"unknown":"keep"}'),
      'characters/card/original.json': [0xef, 0xbb, 0xbf, ...utf8.encode('{ "name" : "原文" }\n')],
      'characters/card/resources/custom.writing': [0, 255, 1, 254, 13, 10],
      'characters/card/resources/nested/card.json.writing': [11, 12],
      'characters/card/resources/character-index/raw.json': utf8.encode('{"unknown":true}'),
      'themes/opaque.bin': [128, 0, 4],
    };
    for (final entry in payload.entries) {
      await _write(root, entry.key, entry.value);
    }
    await Directory('${root.path}/themes/empty').create(recursive: true);
    final info = await _save(root, output);
    expect(info.fileCount, payload.length + 1);
    expect(info.totalBytes, _databaseBytes.length + payload.values.fold<int>(0, (sum, bytes) => sum + bytes.length));
    final archive = await _readZip(output);
    for (final entry in payload.entries) {
      expect(archive.findFile('data/${entry.key}')!.content, orderedEquals(entry.value), reason: entry.key);
    }
    expect(archive.findFile('data/themes/empty/')!.isDirectory, true);
    final manifest = _manifest(archive);
    final paths = [for (final record in manifest['files']! as List<Object?>) (record! as Map<String, Object?>)['path']];
    expect(paths, containsAll(payload.keys));
    expect(utf8.decode(archive.findFile('manifest.json')!.content), isNot(contains(root.path)));
  });

  test('capture excludes store temporary paths and the entire derived summary index', () async {
    const omitted = [
      'tavern.sqlite3-wal',
      'tavern.sqlite3-shm',
      'tavern.sqlite3-journal',
      'settings.json.writing',
      'regex-library.json.writing',
      'personas/index.json.writing',
      'lorebooks/book.json.writing',
      'character-index/card.json.writing',
      'character-index/card.json',
      'characters/.staging-interrupted/card.json',
      'characters/.trash-deleted/card.json',
      'characters/card/card.json.writing',
      'characters/card/import-report.json.writing',
    ];
    for (final path in omitted) {
      await _write(root, path, [1]);
    }
    const retained = [
      'resources/custom.writing',
      'themes/.staging-user/file.bin',
      'characters/card/resources/card.json.writing',
      'lorebooks/resource.writing',
    ];
    for (final path in retained) {
      await _write(root, path, [2]);
    }
    await _save(root, output);
    final archive = await _readZip(output);
    for (final path in omitted) {
      expect(archive.findFile('data/$path'), isNull, reason: path);
    }
    expect(archive.findFile('data/character-index/'), isNull);
    for (final path in retained) {
      expect(archive.findFile('data/$path')!.content, [2], reason: path);
    }
  });

  test('live mutations after capture cannot mix with the detached snapshot', () async {
    await _write(root, 'settings.json', utf8.encode('first generation'));
    final snapshot = await _capture(root);
    addTearDown(snapshot.dispose);
    await _write(root, 'settings.json', utf8.encode('second generation'));
    await _write(root, 'later.bin', [2]);
    await snapshot.writeZip(output);
    final archive = await _readZip(output);
    expect(utf8.decode(archive.findFile('data/settings.json')!.content), 'first generation');
    expect(archive.findFile('data/later.bin'), isNull);
  });

  test('callback failure protects the live root and removes its incomplete snapshot', () async {
    await _write(root, 'identity.txt', utf8.encode('live'));
    await output.writeAsString('existing backup');
    await expectLater(
      captureTavernBackup(
        root,
        createdAt: _createdAt,
        backupDatabase: (file) async {
          await file.writeAsString('incomplete native target');
          throw StateError('database backup failed');
        },
      ),
      throwsStateError,
    );
    expect(await File('${root.path}/identity.txt').readAsString(), 'live');
    expect(await output.readAsString(), 'existing backup');
    expect(await _snapshotDirectories(workspace), isEmpty);
  });

  test('a callback that did not create a regular database cannot produce a snapshot', () async {
    await expectLater(
      captureTavernBackup(root, createdAt: _createdAt, backupDatabase: (_) async => 5),
      throwsFormatException,
    );
    expect(await _snapshotDirectories(workspace), isEmpty);
  });

  test('a callback with an invalid database version cannot produce a snapshot', () async {
    await expectLater(
      captureTavernBackup(
        root,
        createdAt: _createdAt,
        backupDatabase: (file) async {
          await file.writeAsString('database');
          return -1;
        },
      ),
      throwsFormatException,
    );
    expect(await _snapshotDirectories(workspace), isEmpty);
  });

  test('ZIP output inside the live source is rejected before any file is created', () async {
    final snapshot = await _capture(root);
    addTearDown(snapshot.dispose);
    final forbidden = File('${root.path}/new-folder/library.zip');
    await expectLater(snapshot.writeZip(forbidden), throwsArgumentError);
    expect(await forbidden.parent.exists(), false);
  });

  test('raw directory-like ZIP paths cannot overwrite markers or create a guessed destination', () async {
    final out = await Directory('${workspace.path}/out').create();
    final missing = Directory('${workspace.path}/missing-output');
    final parentName = workspace.uri.pathSegments.lastWhere((part) => part.isNotEmpty);
    final markers = <File>[File('${out.path}/out'), File('${out.path}/$parentName'), File('${out.path}/unrelated.bin')];
    for (final marker in markers) {
      await marker.writeAsBytes([19, 8, 7, 255]);
    }
    final snapshot = await _capture(root);
    addTearDown(snapshot.dispose);
    final before = await workspace.list(recursive: true, followLinks: false).map((entry) => entry.path).toList();
    final paths = <String>[
      for (final separator in ['/', if (Platform.isWindows) r'\']) ...[
        '${out.path}$separator.',
        '${out.path}$separator..',
        '${out.path}$separator',
        '${missing.path}$separator.',
        '${missing.path}$separator..',
        '${missing.path}$separator',
      ],
      '',
    ];
    for (final path in paths) {
      await expectLater(snapshot.writeZip(File(path)), throwsArgumentError, reason: jsonEncode(path));
      for (final marker in markers) {
        expect(await marker.readAsBytes(), [19, 8, 7, 255], reason: jsonEncode(path));
      }
      expect(await missing.exists(), false, reason: jsonEncode(path));
      expect(
        await workspace.list(recursive: true, followLinks: false).map((entry) => entry.path).toList(),
        unorderedEquals(before),
        reason: jsonEncode(path),
      );
    }
    await snapshot.writeZip(output);
    expect((await _readZip(output)).findFile('data/tavern.sqlite3'), isNotNull);
  });

  test('raw ZIP file names keep valid absolute relative and dot-file destinations', () async {
    final snapshot = await _capture(root);
    addTearDown(snapshot.dispose);
    for (final name in ['ordinary.zip', '.hidden.zip', '..literal.zip']) {
      final target = File('${workspace.path}/$name');
      await snapshot.writeZip(target);
      expect((await _readZip(target)).findFile('data/tavern.sqlite3'), isNotNull);
    }
    final relativeDirectory = await Directory.current.createTemp('.t24-backup-relative-');
    addTearDown(() => relativeDirectory.delete(recursive: true));
    final name = relativeDirectory.uri.pathSegments.lastWhere((part) => part.isNotEmpty);
    for (final separator in ['/', if (Platform.isWindows) r'\']) {
      final target = File('$name$separator.relative.zip');
      expect(target.isAbsolute, false);
      await snapshot.writeZip(target);
      expect((await _readZip(target)).findFile('data/tavern.sqlite3'), isNotNull);
    }
  });

  test('an existing directory with a normal ZIP name still raises a filesystem error', () async {
    final directory = await Directory('${workspace.path}/existing.zip').create();
    final marker = File('${directory.path}/keep.bin');
    await marker.writeAsBytes([4, 3, 2, 1]);
    final snapshot = await _capture(root);
    addTearDown(snapshot.dispose);
    await expectLater(snapshot.writeZip(File(directory.path)), throwsA(isA<FileSystemException>()));
    expect(await marker.readAsBytes(), [4, 3, 2, 1]);
    expect(await directory.list().map((entry) => entry.uri).toList(), [marker.uri]);
  });

  test('a complete ZIP replaces an existing destination without changing its source', () async {
    await output.writeAsString('previous archive');
    await _write(root, 'identity.txt', utf8.encode('source unchanged'));
    await _save(root, output);
    expect((await _readZip(output)).findFile('data/tavern.sqlite3'), isNotNull);
    expect(await File('${root.path}/identity.txt').readAsString(), 'source unchanged');
  });

  test('a detached input failure leaves an existing destination byte-for-byte intact', () async {
    await output.writeAsBytes([1, 9, 8, 4]);
    final snapshot = await _capture(root);
    addTearDown(snapshot.dispose);
    final capturedDirectory = (await _snapshotDirectories(workspace)).single;
    await File('${capturedDirectory.path}/data/tavern.sqlite3').delete();
    await expectLater(snapshot.writeZip(output), throwsA(isA<FileSystemException>()));
    expect(await output.readAsBytes(), [1, 9, 8, 4]);
  });

  test('dispose waits for an active encoder and prevents later writes', () async {
    await _write(root, 'opaque.bin', List<int>.generate(256 * 1024, (index) => index % 251));
    final snapshot = await _capture(root);
    final writing = snapshot.writeZip(output);
    final disposing = snapshot.dispose();
    await writing;
    await disposing;
    expect((await _readZip(output)).findFile('data/opaque.bin')!.size, 256 * 1024);
    expect(await _snapshotDirectories(workspace), isEmpty);
    await expectLater(snapshot.writeZip(output), throwsStateError);
  });

  test('source symbolic links fail without copying their target', () async {
    final outside = File('${workspace.path}/outside.txt');
    await outside.writeAsString('outside');
    await Link('${root.path}/linked.txt').create(outside.path);
    await expectLater(_capture(root), throwsA(isA<FileSystemException>()));
    expect(await outside.readAsString(), 'outside');
    expect(await _snapshotDirectories(workspace), isEmpty);
  }, skip: Platform.isWindows ? 'Windows symbolic-link creation depends on host privileges.' : false);

  test('directory identity preserves component boundaries without creating missing paths', () async {
    final identity = await tavernDirectoryIdentity(root);
    final child = Directory('${root.path}/missing/child');
    final sibling = Directory('${root.path}-sibling');
    expect(identity.endsWith('/'), true);
    expect((await tavernDirectoryIdentity(child)).startsWith(identity), true);
    expect((await tavernDirectoryIdentity(sibling)).startsWith(identity), false);
    expect(await child.parent.exists(), false);
    expect(await sibling.exists(), false);
  });

  test('relative root alias still finds its journal between the two directory renames', () async {
    await _identity(root, 'original');
    final aliases = await Directory('${workspace.path}/aliases').create();
    final alias = await Link('${aliases.path}/library').create('../library');
    final aliasDirectory = Directory('${alias.path}/');
    final before = await tavernDirectoryIdentity(aliasDirectory);
    expect(before, await tavernDirectoryIdentity(root));
    final fixture = await _journal(root, hadRoot: true, incoming: 'candidate');
    await root.rename('${fixture.work.path}/previous');
    expect(await aliasDirectory.exists(), false);
    expect(await tavernDirectoryIdentity(aliasDirectory), before);
    await recoverPendingTavernRestore(aliasDirectory);
    expect(await _readIdentity(root), 'original');
    expect(await _readIdentity(aliasDirectory), 'original');
    expect(await alias.target(), '../library');
    expect(await FileSystemEntity.type(alias.path, followLinks: false), FileSystemEntityType.link);
    expect(await fixture.work.exists(), false);
    expect(await fixture.file.exists(), false);
  }, skip: Platform.isWindows ? 'Windows symbolic-link creation depends on host privileges.' : false);

  test('alias followed by dot-dot keeps native path meaning for identity capture and restore', () async {
    final realParent = await Directory('${workspace.path}/real-parent').create();
    final deep = await Directory('${realParent.path}/deep').create();
    final actual = await Directory('${realParent.path}/library').create();
    await _identity(actual, 'actual target');
    await _identity(root, 'lexically collapsed unrelated directory');
    final alias = await Link('${workspace.path}/up-link').create(deep.path);
    final selected = Directory('${alias.path}/../library');
    expect(await tavernDirectoryIdentity(selected), await tavernDirectoryIdentity(actual));
    await _save(selected, output);
    final archive = await _readZip(output);
    expect(utf8.decode(archive.findFile('data/identity.txt')!.content), 'actual target');
    await _identity(actual, 'changed after capture');
    await restoreTavernBackup(output, selected, validateStaging: (_, _) async {});
    expect(await _readIdentity(actual), 'actual target');
    expect(await _readIdentity(root), 'lexically collapsed unrelated directory');
    final fixture = await _journal(actual, hadRoot: true, incoming: 'candidate');
    await actual.rename('${fixture.work.path}/previous');
    expect(await tavernDirectoryIdentity(selected), await tavernDirectoryIdentity(actual));
    await recoverPendingTavernRestore(selected);
    expect(await _readIdentity(actual), 'actual target');
    expect(await fixture.file.exists(), false);
  }, skip: Platform.isWindows ? 'POSIX resolves the link before the following dot-dot.' : false);

  test('cyclic root aliases fail without creating a directory or recovery artifacts', () async {
    final first = await Link('${workspace.path}/cycle-a').create('cycle-b');
    final second = await Link('${workspace.path}/cycle-b').create('cycle-a');
    await expectLater(tavernDirectoryIdentity(Directory(first.path)), throwsA(isA<FileSystemException>()));
    expect(await first.target(), 'cycle-b');
    expect(await second.target(), 'cycle-a');
    expect(await _restoreArtifacts(workspace), isEmpty);
  }, skip: Platform.isWindows ? 'Windows symbolic-link creation depends on host privileges.' : false);

  test('restore validates detached staging before moving the old root', () async {
    final bytes = [0, 255, 128, 13, 10];
    await _makeArchive(
      output,
      payload: {'tavern.sqlite3': _databaseBytes, 'characters/card/resources/opaque.bin': bytes},
      sqliteVersion: 3,
    );
    await _write(root, 'identity.txt', utf8.encode('old root'));
    var calls = 0;
    final info = await restoreTavernBackup(
      output,
      root,
      validateStaging: (staging, version) async {
        calls++;
        expect(version, 3);
        expect(staging.path, isNot(root.path));
        expect(await File('${root.path}/identity.txt').readAsString(), 'old root');
        expect(await File('${staging.path}/characters/card/resources/opaque.bin').readAsBytes(), bytes);
        await File('${staging.path}/tavern.sqlite3').writeAsString('migrated by the validator');
      },
    );
    expect(calls, 1);
    expect(info.sqliteUserVersion, 3);
    expect(info.totalBytes, _databaseBytes.length + bytes.length);
    expect(await File('${root.path}/identity.txt').exists(), false);
    expect(await File('${root.path}/tavern.sqlite3').readAsString(), 'migrated by the validator');
    expect(await File('${root.path}/characters/card/resources/opaque.bin').readAsBytes(), bytes);
    expect(await _restoreArtifacts(workspace), isEmpty);
  });

  test('a minimal backup restores into an absent target without creating optional stores', () async {
    await root.delete();
    await _makeArchive(output);
    await restoreTavernBackup(output, root, validateStaging: (_, version) async => expect(version, 5));
    expect(await File('${root.path}/tavern.sqlite3').readAsBytes(), _databaseBytes);
    expect(await File('${root.path}/settings.json').exists(), false);
    expect(await Directory('${root.path}/characters').exists(), false);
    expect(await _restoreArtifacts(workspace), isEmpty);
  });

  test('empty directories survive the ZIP and restore round trip', () async {
    await Directory('${root.path}/themes/empty').create(recursive: true);
    await _save(root, output);
    final other = Directory('${workspace.path}/other');
    await restoreTavernBackup(output, other, validateStaging: (_, _) async {});
    expect(await Directory('${other.path}/themes/empty').exists(), true);
    expect(await Directory('${other.path}/themes/empty').list().isEmpty, true);
  });

  test('validation failure preserves the old root and the input archive', () async {
    await _makeArchive(output);
    final archiveBefore = await output.readAsBytes();
    await _write(root, 'identity.txt', utf8.encode('old'));
    await expectLater(
      restoreTavernBackup(
        output,
        root,
        validateStaging: (staging, _) async {
          await File('${staging.path}/tavern.sqlite3').writeAsString('partially migrated');
          throw StateError('schema or loader validation failed');
        },
      ),
      throwsStateError,
    );
    expect(await File('${root.path}/identity.txt').readAsString(), 'old');
    expect(await output.readAsBytes(), archiveBefore);
    expect(await _restoreArtifacts(workspace), isEmpty);
  });

  for (final invalid in <String, Object?>{
    'format': 'another application',
    'version': 2,
    'createdAt': 'invalid date',
    'sqliteUserVersion': -1,
    'files': 'not a list',
    'directories': <Object?>[7],
  }.entries) {
    test('invalid manifest ${invalid.key} is rejected before validation or publication', () async {
      await _makeArchive(output, alterManifest: (manifest) => manifest[invalid.key] = invalid.value);
      await _write(root, 'identity.txt', utf8.encode('old'));
      var called = false;
      await expectLater(
        restoreTavernBackup(
          output,
          root,
          validateStaging: (_, _) async {
            called = true;
          },
        ),
        throwsFormatException,
      );
      expect(called, false);
      expect(await File('${root.path}/identity.txt').readAsString(), 'old');
      expect(await _restoreArtifacts(workspace), isEmpty);
    });
  }

  test('checksum mismatch is rejected without opening a staged database', () async {
    await _makeArchive(
      output,
      alterManifest: (manifest) {
        final record = (manifest['files']! as List<Object?>).single! as Map<String, Object?>;
        record['sha256'] = '0' * 64;
      },
    );
    var called = false;
    await expectLater(
      restoreTavernBackup(
        output,
        root,
        validateStaging: (_, _) async {
          called = true;
        },
      ),
      throwsFormatException,
    );
    expect(called, false);
    expect(await root.list().isEmpty, true);
  });

  test('size mismatch is rejected before the validator sees the candidate', () async {
    await _makeArchive(
      output,
      alterManifest: (manifest) {
        final record = (manifest['files']! as List<Object?>).single! as Map<String, Object?>;
        record['size'] = _databaseBytes.length - 1;
      },
    );
    await expectLater(
      restoreTavernBackup(output, root, validateStaging: (_, _) async => fail('validator must not run')),
      throwsFormatException,
    );
  });

  test('a database-free manifest is not a Tavern backup', () async {
    await _makeArchive(output, payload: {'settings.json': utf8.encode('{}')});
    await expectLater(
      restoreTavernBackup(output, root, validateStaging: (_, _) async => fail('validator must not run')),
      throwsFormatException,
    );
  });

  test('unlisted ZIP entries are rejected instead of being silently restored', () async {
    await _makeArchive(
      output,
      extraEntries: [
        ArchiveFile.bytes('data/extra.bin', [1]),
      ],
    );
    await expectLater(
      restoreTavernBackup(output, root, validateStaging: (_, _) async => fail('validator must not run')),
      throwsFormatException,
    );
  });

  test('duplicate ZIP members are detected before Archive replaces the earlier entry', () async {
    await _makeArchive(
      output,
      extraEntries: [
        ArchiveFile.bytes('data/tavern.sqlite3', [9]),
      ],
    );
    await expectLater(
      restoreTavernBackup(output, root, validateStaging: (_, _) async => fail('validator must not run')),
      throwsFormatException,
    );
  });

  test('a file cannot also be a parent directory in the manifest', () async {
    await _makeArchive(
      output,
      payload: {
        'tavern.sqlite3': _databaseBytes,
        'conflict': [1],
        'conflict/child': [2],
      },
    );
    await expectLater(
      restoreTavernBackup(output, root, validateStaging: (_, _) async => fail('validator must not run')),
      throwsFormatException,
    );
  });

  for (final path in [
    'data/../escape.txt',
    '/absolute.txt',
    r'C:\outside.txt',
    'data/./alias.txt',
    'data//alias.txt',
  ]) {
    test('unsafe ZIP path $path cannot write outside staging', () async {
      await _makeArchive(
        output,
        extraEntries: [
          ArchiveFile.bytes(path, [1]),
        ],
      );
      await expectLater(
        restoreTavernBackup(output, root, validateStaging: (_, _) async => fail('validator must not run')),
        throwsFormatException,
      );
      expect(await File('${workspace.path}/escape.txt').exists(), false);
      expect(await root.list().isEmpty, true);
    });
  }

  test('manifest backslashes are rejected even when the ZIP encoder normalizes its member name', () async {
    await _makeArchive(
      output,
      payload: {
        'tavern.sqlite3': _databaseBytes,
        r'folder\file.bin': [1],
      },
    );
    await expectLater(
      restoreTavernBackup(output, root, validateStaging: (_, _) async => fail('validator must not run')),
      throwsFormatException,
    );
    expect(await root.list().isEmpty, true);
  });

  test('ZIP symbolic links are rejected without materializing a link', () async {
    final link = ArchiveFile.symlink('data/link', '../outside');
    await _makeArchive(output, extraEntries: [link]);
    await expectLater(
      restoreTavernBackup(output, root, validateStaging: (_, _) async => fail('validator must not run')),
      throwsFormatException,
    );
    expect(await _restoreArtifacts(workspace), isEmpty);
  });

  test('store temporary paths in a manifest are rejected as uncommitted data', () async {
    await _makeArchive(
      output,
      payload: {
        'tavern.sqlite3': _databaseBytes,
        'settings.json.writing': [1],
      },
    );
    await expectLater(
      restoreTavernBackup(output, root, validateStaging: (_, _) async => fail('validator must not run')),
      throwsFormatException,
    );
  });

  test('case-colliding paths are rejected on case-folded path contracts', () async {
    await _makeArchive(
      output,
      payload: {
        'tavern.sqlite3': _databaseBytes,
        'Card': [1],
        'card': [2],
      },
    );
    await expectLater(
      restoreTavernBackup(output, root, validateStaging: (_, _) async => fail('validator must not run')),
      throwsFormatException,
    );
  }, skip: !Platform.isWindows && !Platform.isMacOS);

  test('the input backup cannot be removed by replacing its enclosing target root', () async {
    final input = File('${root.path}/inside.zip');
    await _makeArchive(input);
    final before = await input.readAsBytes();
    await expectLater(restoreTavernBackup(input, root, validateStaging: (_, _) async {}), throwsArgumentError);
    expect(await input.readAsBytes(), before);
  });

  test('an existing directory alias uses the canonical root without replacing the alias', () async {
    final alias = Link('${workspace.path}/alias');
    await alias.create(root.path);
    await _write(root, 'identity.txt', utf8.encode('source'));
    await recoverPendingTavernRestore(Directory(alias.path));
    await _save(Directory(alias.path), output);
    await _write(root, 'identity.txt', utf8.encode('changed after snapshot'));
    await restoreTavernBackup(output, Directory(alias.path), validateStaging: (_, _) async {});
    expect(await FileSystemEntity.type(alias.path, followLinks: false), FileSystemEntityType.link);
    expect(await _readIdentity(root), 'source');
  }, skip: Platform.isWindows ? 'Windows symbolic-link creation depends on host privileges.' : false);

  test('recovery cannot interrupt a restore owned by an active validation callback', () async {
    await _makeArchive(output);
    final entered = Completer<void>();
    final release = Completer<void>();
    final restoring = restoreTavernBackup(
      output,
      root,
      validateStaging: (_, _) async {
        entered.complete();
        await release.future;
      },
    );
    await entered.future;
    await expectLater(recoverPendingTavernRestore(root), throwsStateError);
    release.complete();
    await restoring;
    expect(await File('${root.path}/tavern.sqlite3').readAsBytes(), _databaseBytes);
  });

  test('only backed-up owned persona avatars relocate to the final destination', () async {
    final avatarPath = '${root.path}/personas/avatars/face.bin';
    final externalPath = '${workspace.path}/external-avatar.bin';
    final missingPath = '${root.path}/personas/avatars/missing.bin';
    await File(externalPath).writeAsBytes([4, 5, 6]);
    await _write(root, 'personas/avatars/face.bin', [0, 255, 8]);
    final source = jsonEncode({
      'version': 1,
      'personas': [
        {'id': 'inside', 'name': '内部', 'avatarPath': avatarPath, 'unknown': avatarPath},
        {'id': 'outside', 'avatarPath': externalPath},
        {'id': 'missing', 'avatarPath': missingPath},
        {'id': 'relative', 'avatarPath': 'personas/avatars/face.bin'},
      ],
      'unknownTopLevel': avatarPath,
    });
    await _write(root, 'personas/index.json', utf8.encode(source));
    await _save(root, output);
    final archive = await _readZip(output);
    expect(utf8.decode(archive.findFile('data/personas/index.json')!.content), source);
    expect(_manifest(archive)['personaAvatars'], [
      {'id': 'inside', 'sourcePath': avatarPath, 'path': 'personas/avatars/face.bin'},
    ]);
    expect(archive.findFile('data/external-avatar.bin'), isNull);
    final destination = Directory('${workspace.path}/relocated-library');
    await restoreTavernBackup(
      output,
      destination,
      validateStaging: (staging, _) async {
        final value =
            jsonDecode(await File('${staging.path}/personas/index.json').readAsString())! as Map<String, Object?>;
        final records = (value['personas']! as List<Object?>).cast<Map<String, Object?>>();
        expect(records[0]['avatarPath'], '${destination.path}/personas/avatars/face.bin');
        expect(records[0]['unknown'], avatarPath);
        expect(value['unknownTopLevel'], avatarPath);
        expect(records[1]['avatarPath'], externalPath);
        expect(records[2]['avatarPath'], missingPath);
        expect(records[3]['avatarPath'], 'personas/avatars/face.bin');
      },
    );
    expect(await File('${destination.path}/personas/avatars/face.bin').readAsBytes(), [0, 255, 8]);
    expect(await File('${root.path}/personas/index.json').readAsString(), source);
    expect(await File(externalPath).readAsBytes(), [4, 5, 6]);
  });

  for (final invalid in <String, Map<String, Object?>>{
    'wrong persona': {'id': 'other'},
    'changed source': {'sourcePath': '/different/avatar.png'},
    'outside path': {'path': '../outside.png'},
    'unbacked file': {'path': 'missing.png'},
  }.entries) {
    test('persona mapping ${invalid.key} fails before target publication', () async {
      await _makeArchive(
        output,
        payload: {
          'tavern.sqlite3': _databaseBytes,
          'avatar.png': [1, 2, 3],
          'personas/index.json': utf8.encode(
            jsonEncode({
              'version': 1,
              'personas': [
                {'id': 'inside', 'avatarPath': '/old-root/avatar.png'},
              ],
            }),
          ),
        },
        alterManifest: (manifest) {
          manifest['personaAvatars'] = [
            {'id': 'inside', 'sourcePath': '/old-root/avatar.png', 'path': 'avatar.png', ...invalid.value},
          ];
        },
      );
      await _identity(root, 'original');
      await expectLater(
        restoreTavernBackup(output, root, validateStaging: (_, _) async => fail('validator must not run')),
        throwsFormatException,
      );
      expect(await _readIdentity(root), 'original');
      expect(await _restoreArtifacts(workspace), isEmpty);
    });
  }

  test('duplicate persona mappings do not rewrite the same identity twice', () async {
    await _makeArchive(
      output,
      payload: {
        'tavern.sqlite3': _databaseBytes,
        'avatar.png': [1],
        'personas/index.json': utf8.encode(
          jsonEncode({
            'version': 1,
            'personas': [
              {'id': 'inside', 'avatarPath': '/old-root/avatar.png'},
            ],
          }),
        ),
      },
      alterManifest: (manifest) {
        manifest['personaAvatars'] = [
          {'id': 'inside', 'sourcePath': '/old-root/avatar.png', 'path': 'avatar.png'},
          {'id': 'inside', 'sourcePath': '/old-root/avatar.png', 'path': 'avatar.png'},
        ];
      },
    );
    await expectLater(
      restoreTavernBackup(output, root, validateStaging: (_, _) async => fail('validator must not run')),
      throwsFormatException,
    );
  });

  test('prepared journal before the first rename preserves the original root', () async {
    await _identity(root, 'original');
    final fixture = await _journal(root, hadRoot: true, incoming: 'candidate');
    await recoverPendingTavernRestore(root);
    expect(await _readIdentity(root), 'original');
    expect(await fixture.work.exists(), false);
    expect(await fixture.file.exists(), false);
  });

  test('prepared journal between renames restores the previous directory', () async {
    await root.delete();
    final fixture = await _journal(root, hadRoot: true, incoming: 'candidate', previous: 'original');
    await recoverPendingTavernRestore(root);
    expect(await _readIdentity(root), 'original');
    expect(await fixture.work.exists(), false);
    expect(await fixture.file.exists(), false);
  });

  test('prepared journal after the second rename rolls back an uncommitted candidate', () async {
    await _identity(root, 'candidate');
    final fixture = await _journal(root, hadRoot: true, previous: 'original');
    await recoverPendingTavernRestore(root);
    expect(await _readIdentity(root), 'original');
    expect(await fixture.work.exists(), false);
    expect(await fixture.file.exists(), false);
  });

  test('an uncommitted fresh-target restore returns to the absent-target state', () async {
    await _identity(root, 'candidate');
    final fixture = await _journal(root, hadRoot: false);
    await recoverPendingTavernRestore(root);
    expect(await root.exists(), false);
    expect(await fixture.work.exists(), false);
    expect(await fixture.file.exists(), false);
  });

  test('committed journal retains the new root and removes the previous directory', () async {
    await _identity(root, 'committed');
    final fixture = await _journal(root, hadRoot: true, phase: 'committed', previous: 'original');
    await recoverPendingTavernRestore(root);
    expect(await _readIdentity(root), 'committed');
    expect(await fixture.work.exists(), false);
    expect(await fixture.file.exists(), false);
  });

  test('rolled-back journal finishes interrupted cleanup without moving the root', () async {
    await _identity(root, 'original');
    final fixture = await _journal(root, hadRoot: true, phase: 'rolledBack', incoming: 'discarded candidate');
    await recoverPendingTavernRestore(root);
    expect(await _readIdentity(root), 'original');
    expect(await fixture.work.exists(), false);
    expect(await fixture.file.exists(), false);
  });

  test('a committed missing root never becomes a silently created empty library', () async {
    await root.delete();
    final fixture = await _journal(root, hadRoot: true, phase: 'committed', previous: 'original');
    await expectLater(recoverPendingTavernRestore(root), throwsStateError);
    expect(await root.exists(), false);
    expect(await _readIdentity(Directory('${fixture.work.path}/previous')), 'original');
    expect(await fixture.file.exists(), true);
  });

  test('ambiguous prepared state keeps all three directories for recovery', () async {
    await _identity(root, 'unknown current');
    final fixture = await _journal(root, hadRoot: true, incoming: 'candidate', previous: 'original');
    await expectLater(recoverPendingTavernRestore(root), throwsStateError);
    expect(await _readIdentity(root), 'unknown current');
    expect(await _readIdentity(Directory('${fixture.work.path}/incoming')), 'candidate');
    expect(await _readIdentity(Directory('${fixture.work.path}/previous')), 'original');
    expect(await fixture.file.exists(), true);
  });

  test('a damaged or future journal does not authorize deleting any directory', () async {
    await _identity(root, 'original');
    final fixture = await _journal(root, hadRoot: true, incoming: 'candidate');
    final content = jsonDecode(await fixture.file.readAsString())! as Map<String, Object?>;
    content['version'] = 2;
    await fixture.file.writeAsString(jsonEncode(content));
    await expectLater(recoverPendingTavernRestore(root), throwsFormatException);
    expect(await _readIdentity(root), 'original');
    expect(await _readIdentity(Directory('${fixture.work.path}/incoming')), 'candidate');
    expect(await fixture.file.exists(), true);
  });

  test('journal workspace traversal cannot touch its named unrelated directory', () async {
    await _identity(root, 'original');
    final fixture = await _journal(root, hadRoot: true, incoming: 'candidate');
    final unrelated = await Directory('${workspace.path}/unrelated').create();
    await _identity(unrelated, 'unrelated');
    final content = jsonDecode(await fixture.file.readAsString())! as Map<String, Object?>;
    content['workName'] = '../unrelated';
    await fixture.file.writeAsString(jsonEncode(content));
    await expectLater(recoverPendingTavernRestore(root), throwsFormatException);
    expect(await _readIdentity(root), 'original');
    expect(await _readIdentity(unrelated), 'unrelated');
    expect(await fixture.work.exists(), true);
  });

  test('committed cleanup after workspace deletion only removes its journal', () async {
    await _identity(root, 'committed');
    final fixture = await _journal(root, hadRoot: true, phase: 'committed');
    await fixture.work.delete();
    await recoverPendingTavernRestore(root);
    expect(await _readIdentity(root), 'committed');
    expect(await fixture.file.exists(), false);
  });

  test('fresh-target rollback cleanup remains recoverable after workspace deletion', () async {
    await root.delete();
    final fixture = await _journal(root, hadRoot: false, phase: 'rolledBack');
    await fixture.work.delete();
    await recoverPendingTavernRestore(root);
    expect(await root.exists(), false);
    expect(await fixture.file.exists(), false);
  });
}

Future<TavernBackupSnapshot> _capture(Directory root) => captureTavernBackup(
  root,
  createdAt: _createdAt,
  backupDatabase: (destination) async {
    await destination.writeAsBytes(_databaseBytes, flush: true);
    return 5;
  },
);

Future<TavernBackupInfo> _save(Directory root, File output) async {
  final snapshot = await _capture(root);
  try {
    return await snapshot.writeZip(output);
  } finally {
    await snapshot.dispose();
  }
}

Future<void> _write(Directory root, String relative, List<int> bytes) async {
  final file = File('${root.path}/$relative');
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes);
}

Future<Archive> _readZip(File file) async => ZipDecoder().decodeBytes(await file.readAsBytes(), verify: true);
Map<String, Object?> _manifest(Archive archive) =>
    jsonDecode(utf8.decode(archive.findFile('manifest.json')!.content))! as Map<String, Object?>;

Future<List<Directory>> _snapshotDirectories(Directory workspace) async {
  final entries = await workspace.list(followLinks: false).toList();
  return entries
      .whereType<Directory>()
      .where((entity) => entity.uri.pathSegments.any((part) => part.startsWith('.dshgo-tavern-backup-')))
      .toList();
}

Future<List<FileSystemEntity>> _restoreArtifacts(Directory workspace) async {
  final entries = await workspace.list(followLinks: false).toList();
  return entries.where((entity) => entity.uri.pathSegments.any((part) => part.startsWith('.dshgo-restore-'))).toList();
}

Future<void> _makeArchive(
  File output, {
  Map<String, List<int>>? payload,
  int sqliteVersion = 5,
  void Function(Map<String, Object?> manifest)? alterManifest,
  List<ArchiveFile> extraEntries = const [],
}) async {
  final contents = payload ?? {'tavern.sqlite3': _databaseBytes};
  final directories = <String>{};
  for (final path in contents.keys) {
    final parts = path.split('/');
    for (var length = 1; length < parts.length; length++) {
      directories.add(parts.take(length).join('/'));
    }
  }
  final orderedDirectories = directories.toList()..sort();
  final manifest = <String, Object?>{
    'format': 'dshgo-tavern-backup',
    'version': 1,
    'createdAt': _createdAt.toIso8601String(),
    'sqliteUserVersion': sqliteVersion,
    'directories': orderedDirectories,
    'files': <Object?>[
      for (final entry in contents.entries)
        <String, Object?>{
          'path': entry.key,
          'size': entry.value.length,
          'sha256': sha256.convert(entry.value).toString(),
        },
    ],
  };
  alterManifest?.call(manifest);
  await output.parent.create(recursive: true);
  final encoder = ZipFileEncoder()..create(output.path);
  try {
    encoder.addArchiveFile(ArchiveFile.bytes('manifest.json', utf8.encode(jsonEncode(manifest))));
    encoder.addArchiveFile(ArchiveFile.directory('data/'));
    for (final directory in orderedDirectories) {
      encoder.addArchiveFile(ArchiveFile.directory('data/$directory/'));
    }
    for (final entry in contents.entries) {
      encoder.addArchiveFile(ArchiveFile.bytes('data/${entry.key}', entry.value));
    }
    for (final entry in extraEntries) {
      encoder.addArchiveFile(entry);
    }
  } finally {
    await encoder.close();
  }
}

Future<void> _identity(Directory directory, String text) async {
  await directory.create(recursive: true);
  await File('${directory.path}/identity.txt').writeAsString(text);
}

Future<String> _readIdentity(Directory directory) => File('${directory.path}/identity.txt').readAsString();

Future<({File file, Directory work})> _journal(
  Directory root, {
  required bool hadRoot,
  String phase = 'prepared',
  String? incoming,
  String? previous,
}) async {
  var rootKey = root.absolute.uri.normalizePath().toString();
  if (Platform.isWindows || Platform.isMacOS) {
    rootKey = rootKey.toLowerCase();
  }
  final id = sha256.convert(utf8.encode(rootKey)).toString().substring(0, 16);
  final workName = '.dshgo-restore-$id-testrecord';
  final work = await Directory('${root.parent.path}/$workName').create();
  if (incoming != null) {
    await _identity(Directory('${work.path}/incoming'), incoming);
  }
  if (previous != null) {
    await _identity(Directory('${work.path}/previous'), previous);
  }
  final file = File('${root.parent.path}/.dshgo-restore-$id.json');
  await file.writeAsString(
    jsonEncode({
      'format': 'dshgo-tavern-restore',
      'version': 1,
      'root': rootKey,
      'workName': workName,
      'hadRoot': hadRoot,
      'phase': phase,
    }),
    flush: true,
  );
  return (file: file, work: work);
}
