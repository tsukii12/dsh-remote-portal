import 'package:dsh_app/share_code/guest_fs.dart';
import 'package:dsh_app/share_code/share_import.dart';
import 'package:dsh_app/share_code/share_models.dart';
import 'package:dsh_app/ui/settings/reply_prefs_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';
import 'support/fake_engine.dart';
import 'support/sheet_support.dart';

void main() {
  test('personal preferences round-trip, replace on import, and delete when cleared', () async {
    final fs = tempGuest();
    addTearDown(() => fs.root.parent.deleteSync(recursive: true));
    writeGuest(fs, '/root/.dsh/AGENTS.md', '$managedAgentsMarker -->\nmanaged');
    const text = '回答用中文。\n保留空行。\n';
    await fs.writeImportedAgentsMd(text);
    expect(await fs.readImportedAgentsMd(), text);
    expect(await fs.readUserAgentsMd(), text);
    final plan = await planImport(
      const ProfileShare(agentsMd: '另一份偏好'),
      localTarget(DshClient.withCarrier(FakeEngine())),
      net: FakeShareNet(),
      fs: fs,
    );
    expect(plan.changes.single.detail, '替换现有内容');
    expect(plan.defaultSelection, isEmpty);
    await fs.deleteImportedAgentsMd();
    expect(fs.file(GuestFs.importedAgentsMd).existsSync(), isFalse);
    expect(await fs.readUserAgentsMd(), isNull);
  });

  testWidgets('save is disabled until edited, saves exactly and returns', (tester) async {
    final fs = tempGuest();
    addTearDown(() => fs.root.parent.deleteSync(recursive: true));
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        overrides: [guestFsProvider.overrideWith((ref) async => fs)],
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ReplyPrefsPage())),
              child: const Text('打开偏好'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开偏好'));
    await tester.pumpAndSettle();
    final save = find.byKey(const ValueKey('reply-prefs-save'));
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    await tester.enterText(find.byKey(const ValueKey('reply-prefs-input')), '用中文回答。');
    await tester.pump();
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.byType(ReplyPrefsPage), findsNothing);
    expect(await fs.readImportedAgentsMd(), '用中文回答。');
    expect(find.text('已保存'), findsOneWidget);
  });

  for (final text in ['', '用中文回答。\n我主要写 Flutter。']) {
    GuestFs? fs;
    goldenBoth(
      'reply_prefs_${text.isEmpty ? 'empty' : 'filled'}',
      () => const ReplyPrefsPage(),
      overrides: () {
        fs = tempGuest();
        if (text.isNotEmpty) writeGuest(fs!, GuestFs.importedAgentsMd, text);
        addTearDown(() => fs!.root.parent.deleteSync(recursive: true));
        return [guestFsProvider.overrideWith((ref) async => fs)];
      },
    );
  }
}
