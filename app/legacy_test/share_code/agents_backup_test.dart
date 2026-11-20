import 'dart:convert';
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
  final now = DateTime(2026, 11, 3, 12);
  const incoming = '回答用中文。';

  setUp(() {
    fs = tempGuest();
    client = DshClient.withCarrier(FakeEngine());
  });
  tearDown(() async {
    await client.close();
    fs.root.parent.deleteSync(recursive: true);
  });

  Future<ImportResult> importAgents() async {
    final target = ImportTarget(
      HostConnection(hostId: '', client: client, label: '本机', isLocal: true, kind: HostKind.portal),
      isActive: true,
    );
    final plan = await planImport(
      const ProfileShare(agentsMd: incoming),
      target,
      net: FakeShareNet(),
      fs: fs,
    );
    expect(plan.defaultSelection, isNot(contains('agents-md')));
    expect(plan.changes.single.id, 'agents-md');
    return applyImport(plan, {'agents-md'}, runner: DirectPluginRunner(client, isLocal: true), fs: fs, now: () => now);
  }

  for (final sample in <String, List<int>?>{
    'invalid UTF-8 existing bytes': [0xff, 0xfe, 0x41, 0x00],
    'UTF-8 BOM existing bytes': [0xef, 0xbb, 0xbf, ...utf8.encode('旧习惯')],
    'plain UTF-8 existing bytes': utf8.encode('旧习惯'),
    'absent file': null,
  }.entries) {
    test('profile import backs up ${sample.key} without decoding', () async {
      final source = fs.file(GuestFs.importedAgentsMd);
      final original = sample.value;
      if (original != null) {
        source.parent.createSync(recursive: true);
        source.writeAsBytesSync(original);
      }
      final result = await importAgents();
      expect(result.statuses['agents-md']!.state, ImportStepState.done);
      expect(source.readAsStringSync(), incoming);
      final root = fs.dir('${GuestFs.dshHome}/backups');
      final backups = root.existsSync()
          ? root
                .listSync(recursive: true, followLinks: false)
                .whereType<File>()
                .where((file) => file.uri.pathSegments.last == 'AGENTS.md')
                .toList()
          : <File>[];
      if (original == null) {
        expect(backups, isEmpty);
      } else {
        expect(backups, hasLength(1), reason: 'successful replacement must retain the previous bytes');
        expect(backups.single.readAsBytesSync(), original);
      }
    });
  }

  test('a real backup destination error leaves the existing AGENTS.md unchanged', () async {
    final source = fs.file(GuestFs.importedAgentsMd);
    source.parent.createSync(recursive: true);
    final original = utf8.encode('旧习惯');
    source.writeAsBytesSync(original);
    final blocked = fs.file('${GuestFs.dshHome}/backups');
    blocked.parent.createSync(recursive: true);
    blocked.writeAsStringSync('a file occupies the required backup directory');
    final result = await importAgents();
    expect(result.statuses['agents-md']!.state, ImportStepState.failed);
    expect(source.readAsBytesSync(), original);
  });
}
