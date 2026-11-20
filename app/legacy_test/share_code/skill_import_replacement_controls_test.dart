import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/share_code/guest_fs.dart';
import 'package:dsh_app/share_code/share_import.dart';
import 'package:dsh_app/share_code/share_models.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine.dart';

const _root = '${GuestFs.skillsRoot}/outline';
const _backup = '/root/.dsh/backups/share-import-20261024-153012/skills/outline';

void main() {
  late GuestFs fs;
  late DshClient client;
  setUp(() {
    fs = tempGuest();
    client = DshClient.withCarrier(FakeEngine());
  });
  tearDown(() async {
    try {
      await client.close();
    } finally {
      fs.root.parent.deleteSync(recursive: true);
    }
  });

  Future<ImportPlan> plan() => planImport(
    const ProfileShare(
      skills: [
        SharedSkill(name: 'outline', files: {'SKILL.md': 'new skill'}),
      ],
    ),
    ImportTarget(HostConnection(hostId: '', client: client, isLocal: true), isActive: false),
    net: FakeShareNet(),
    fs: fs,
  );
  Future<ImportResult> apply(ImportPlan planned) => applyImport(
    planned,
    {'skill:outline'},
    runner: DirectPluginRunner(client, isLocal: true),
    fs: fs,
    now: () => DateTime(2026, 10, 24, 15, 30, 12),
  );
  void bytes(String path, List<int> value) {
    final file = fs.file(path);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(value, flush: true);
  }

  for (final flat in [false, true]) {
    test('normal ${flat ? 'flat' : 'directory'} skill preserves BOM bytes before replacement', () async {
      final old = [0xef, 0xbb, 0xbf, ...utf8.encode('old skill')];
      bytes(flat ? '${GuestFs.skillsRoot}/outline.md' : '$_root/SKILL.md', old);
      final planned = await plan();
      expect(planned.changes.single.kind, ChangeKind.change);
      final result = await apply(planned);
      expect(result.statuses['skill:outline']!.state, ImportStepState.done);
      expect(fs.file('$_backup/SKILL.md').readAsBytesSync(), old);
      expect(fs.file('$_root/SKILL.md').readAsStringSync(), 'new skill');
    });
  }

  test('absent skill remains a normal explicit addition', () async {
    final planned = await plan();
    expect(planned.changes.single.kind, ChangeKind.add);
    final result = await apply(planned);
    expect(result.statuses['skill:outline']!.state, ImportStepState.done);
    expect(fs.file('$_root/SKILL.md').readAsStringSync(), 'new skill');
  });

  test('execution refuses content added after the confirmation plan', () async {
    writeGuest(fs, '$_root/SKILL.md', 'old skill');
    final planned = await plan();
    expect(planned.changes.single.actionable, isTrue);
    writeGuest(fs, '$_root/.private', 'keep this');
    final result = await apply(planned);
    expect(result.statuses['skill:outline']!.state, ImportStepState.failed);
    expect(fs.file('$_root/SKILL.md').readAsStringSync(), 'old skill');
    expect(fs.file('$_root/.private').readAsStringSync(), 'keep this');
  });

  test('existing backup slot is not overwritten and source stays intact', () async {
    writeGuest(fs, '$_root/SKILL.md', 'current skill');
    writeGuest(fs, '$_backup/SKILL.md', 'earlier backup');
    final result = await apply(await plan());
    expect(result.statuses['skill:outline']!.state, ImportStepState.failed);
    expect(fs.file('$_root/SKILL.md').readAsStringSync(), 'current skill');
    expect(fs.file('$_backup/SKILL.md').readAsStringSync(), 'earlier backup');
  });

  test('directory and legacy flat file together are explicitly rejected', () async {
    writeGuest(fs, '$_root/SKILL.md', 'directory skill');
    writeGuest(fs, '${GuestFs.skillsRoot}/outline.md', 'flat skill');
    final planned = await plan();
    expect(planned.changes.single.kind, ChangeKind.unavailable);
    expect(planned.changes.single.blocked, isNotEmpty);
    expect(fs.file('$_root/SKILL.md').readAsStringSync(), 'directory skill');
    expect(fs.file('${GuestFs.skillsRoot}/outline.md').readAsStringSync(), 'flat skill');
  });

  test('a link inside a skill is rejected without following or deleting it', () async {
    writeGuest(fs, '$_root/SKILL.md', 'old skill');
    writeGuest(fs, '/root/other.txt', 'outside');
    final link = Link('${fs.dir(_root).path}/reference.txt')..createSync(fs.file('/root/other.txt').path);
    final planned = await plan();
    expect(planned.changes.single.kind, ChangeKind.unavailable);
    expect(planned.changes.single.blocked, isNotEmpty);
    expect(FileSystemEntity.typeSync(link.path, followLinks: false), FileSystemEntityType.link);
    expect(fs.file('/root/other.txt').readAsStringSync(), 'outside');
    expect(fs.file('$_root/SKILL.md').readAsStringSync(), 'old skill');
  });

  test('a file replacing the skills root is an explicit read failure, not an addition', () async {
    writeGuest(fs, GuestFs.skillsRoot, 'not a directory');
    final planned = await plan();
    expect(planned.changes.single.kind, ChangeKind.unavailable);
    expect(planned.changes.single.blocked, isNotEmpty);
    expect(fs.file(GuestFs.skillsRoot).readAsStringSync(), 'not a directory');
  });
}
