import 'dart:io';

import 'package:dsh_app/share_code/guest_fs.dart';
import 'package:dsh_app/share_code/share_import.dart';
import 'package:dsh_app/share_code/share_models.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine.dart';

void main() {
  late GuestFs fs;
  late DshClient client;
  late ImportTarget target;

  setUp(() {
    fs = tempGuest();
    client = DshClient.withCarrier(FakeEngine());
    target = ImportTarget(
      HostConnection(hostId: '', client: client, label: '本机', isLocal: true, kind: HostKind.portal),
      isActive: false,
    );
  });

  tearDown(() async {
    await client.close();
    fs.root.parent.deleteSync(recursive: true);
  });

  Future<ImportPlan> plan(String text) => planImport(
    ProfileShare(agentsMd: text),
    target,
    net: FakeShareNet(),
    fs: fs,
  );

  Future<ImportResult> applyText(String text, DateTime at, {bool cancel = false}) async {
    final changes = await plan(text);
    expect(changes.defaultSelection, isNot(contains('agents-md')));
    return applyImport(
      changes,
      {'agents-md'},
      runner: DirectPluginRunner(client, isLocal: true),
      fs: fs,
      now: () => at,
      cancelled: () => cancel,
    );
  }

  List<File> backups() {
    final root = fs.dir('${GuestFs.dshHome}/backups');
    if (!root.existsSync()) return [];
    return root
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((file) => file.uri.pathSegments.last == 'AGENTS.md')
        .toList();
  }

  test('two sequential imports within one second preserve both replaced AGENTS files', () async {
    writeGuest(fs, GuestFs.importedAgentsMd, 'before the first import');
    final first = await applyText('after the first import', DateTime.utc(2026, 11, 3, 12, 0, 0, 100));
    expect(first.statuses['agents-md']?.state, ImportStepState.done);
    final firstBackup = backups().single;
    expect(firstBackup.readAsStringSync(), 'before the first import');

    // Different real clock values in the same calendar second, no racing
    // futures: the second import starts only after the first has finished.
    final second = await applyText('after the second import', DateTime.utc(2026, 11, 3, 12, 0, 0, 800));
    expect(second.statuses['agents-md']?.state, ImportStepState.done);
    expect(fs.file(GuestFs.importedAgentsMd).readAsStringSync(), 'after the second import');
    expect(firstBackup.readAsStringSync(), 'before the first import');
    expect(
      backups().map((file) => file.readAsStringSync()),
      unorderedEquals(['before the first import', 'after the first import']),
    );
  });

  test('an existing legacy backup with the same timestamp is never overwritten', () async {
    const legacy = '${GuestFs.dshHome}/backups/share-import-20261103-120000/AGENTS.md';
    writeGuest(fs, legacy, 'earlier retained backup');
    writeGuest(fs, GuestFs.importedAgentsMd, 'current file');

    final result = await applyText('new file', DateTime.utc(2026, 11, 3, 12, 0, 0, 300));

    expect(result.statuses['agents-md']?.state, ImportStepState.done);
    expect(fs.file(legacy).readAsStringSync(), 'earlier retained backup');
    expect(
      backups().map((file) => file.readAsStringSync()),
      unorderedEquals(['earlier retained backup', 'current file']),
    );
    expect(fs.file(GuestFs.importedAgentsMd).readAsStringSync(), 'new file');
  });

  test('a new AGENTS file needs no directory for nonexistent old content', () async {
    final result = await applyText('first file', DateTime.utc(2026, 11, 3, 12));

    expect(result.statuses['agents-md']?.state, ImportStepState.done);
    expect(fs.file(GuestFs.importedAgentsMd).readAsStringSync(), 'first file');
    expect(fs.dir('${GuestFs.dshHome}/backups').existsSync(), isFalse);
  });

  test('an actual backup parent creation failure keeps the original file', () async {
    writeGuest(fs, GuestFs.importedAgentsMd, 'keep this original');
    writeGuest(fs, '${GuestFs.dshHome}/backups', 'a regular file blocks the directory');

    final result = await applyText('must not be written', DateTime.utc(2026, 11, 3, 12));

    expect(result.statuses['agents-md']?.state, ImportStepState.failed);
    expect(fs.file(GuestFs.importedAgentsMd).readAsStringSync(), 'keep this original');
    expect(fs.file('${GuestFs.dshHome}/backups').readAsStringSync(), 'a regular file blocks the directory');
  });

  test('cancelling before the file step creates no backup and leaves the old file', () async {
    writeGuest(fs, GuestFs.importedAgentsMd, 'unchanged');

    final result = await applyText('not applied', DateTime.utc(2026, 11, 3, 12), cancel: true);

    expect(result.statuses['agents-md']?.state, ImportStepState.skipped);
    expect(fs.file(GuestFs.importedAgentsMd).readAsStringSync(), 'unchanged');
    expect(backups(), isEmpty);
  });

  test('the default selection still does not import or back up AGENTS content', () async {
    writeGuest(fs, GuestFs.importedAgentsMd, 'user choice still required');
    final changes = await plan('not explicitly selected');
    expect(changes.defaultSelection, isNot(contains('agents-md')));

    final result = await applyImport(
      changes,
      changes.defaultSelection,
      runner: DirectPluginRunner(client, isLocal: true),
      fs: fs,
      now: () => DateTime.utc(2026, 11, 3, 12),
    );

    expect(result.done, 0);
    expect(fs.file(GuestFs.importedAgentsMd).readAsStringSync(), 'user choice still required');
    expect(backups(), isEmpty);
  });
}
