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

const _skillPath = '${GuestFs.skillsRoot}/outline';
const _backupPath = '/root/.dsh/backups/share-import-20261024-153012/skills/outline';

void main() {
  // Real files outside the text-only share wire budget are valid installed
  // skill contents. Hidden regular files also must not disappear unbacked.
  final cases = <String, (String, List<int>)>{
    'PNG asset': (
      'assets/icon.png',
      base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=='),
    ),
    'large text asset': ('references/long.txt', List<int>.filled(SharedSkill.maxFileChars + 1, 65)),
    'hidden regular file': ('.local-notes', utf8.encode('private local notes')),
  };

  for (final entry in cases.entries) {
    group(entry.key, () {
      late GuestFs fs;
      late DshClient client;
      late Map<String, List<int>> originals;

      setUp(() {
        fs = tempGuest();
        client = DshClient.withCarrier(FakeEngine());
        originals = {'SKILL.md': utf8.encode('old installed skill'), entry.value.$1: entry.value.$2};
        for (final file in originals.entries) {
          final target = fs.file('$_skillPath/${file.key}');
          target.parent.createSync(recursive: true);
          target.writeAsBytesSync(file.value, flush: true);
          expect(FileSystemEntity.typeSync(target.path, followLinks: false), FileSystemEntityType.file);
        }
        expect(FileSystemEntity.typeSync(fs.dir(_skillPath).path, followLinks: false), FileSystemEntityType.directory);
      });
      tearDown(() async {
        try {
          await client.close();
        } finally {
          fs.root.parent.deleteSync(recursive: true);
        }
      });

      Future<ImportPlan> plan() => planImport(
        ProfileShare.fromJson({
          'skills': [
            {
              'name': 'outline',
              'files': {'SKILL.md': 'new shared skill'},
            },
          ],
        }),
        ImportTarget(HostConnection(hostId: '', client: client, isLocal: true, kind: HostKind.portal), isActive: false),
        net: FakeShareNet(),
        fs: fs,
      );

      test('existing directory is not presented as a new skill', () async {
        final planned = await plan();
        final change = planned.changes.singleWhere((change) => change.id == 'skill:outline');
        expect(planned.defaultSelection, isNot(contains(change.id)));
        expect(change.kind, isNot(ChangeKind.add));
      });

      test('explicit import preserves original bytes or explicitly refuses replacement', () async {
        final planned = await plan();
        final change = planned.changes.singleWhere((change) => change.id == 'skill:outline');
        expect(planned.defaultSelection, isNot(contains(change.id)));
        // A visible, explained refusal is permitted; silent omission is not.
        if (!change.actionable) {
          expect(change.blocked, isNotNull);
          expect(change.blocked, isNotEmpty);
          for (final original in originals.entries) {
            expect(fs.file('$_skillPath/${original.key}').readAsBytesSync(), original.value);
          }
          return;
        }
        final result = await applyImport(
          planned,
          {change.id}, // The same explicit opt-in as the import sheet's toggle.
          runner: DirectPluginRunner(client, isLocal: true),
          fs: fs,
          now: () => DateTime(2026, 10, 24, 15, 30, 12),
        );
        final status = result.statuses[change.id]!;
        expect(status.state, anyOf(ImportStepState.done, ImportStepState.failed));
        if (status.state == ImportStepState.failed) {
          expect(status.message, isNotNull);
          expect(status.message, isNotEmpty);
          for (final original in originals.entries) {
            expect(fs.file('$_skillPath/${original.key}').readAsBytesSync(), original.value);
          }
        } else {
          expect(fs.file('$_skillPath/SKILL.md').readAsStringSync(), 'new shared skill');
          for (final original in originals.entries) {
            final backup = fs.file('$_backupPath/${original.key}');
            expect(backup.existsSync(), isTrue, reason: 'Successful replacement must back up ${original.key}');
            expect(backup.readAsBytesSync(), original.value);
          }
        }
      });
    });
  }
}
