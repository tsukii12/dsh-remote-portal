// The update sheet's release notes in the app's language only: the beta
// channel's `notesByLocale` first, else that language's section of notes
// written as 「### 中文 … ### English …」, Chinese when the release has
// nothing in the app's language. The split survives the cached offer.

import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/update_state.dart';
import 'package:dsh_app/ui/update/update_sheet.dart';
import 'package:dsh_app/update/release.dart';
import 'package:dsh_app/update/version.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';
import '../support/english_preview.dart';

const _both = '### 中文\n\n- 插件可以直接显示在原生界面里\n\n### English\n\n- Plugins can show up natively';

ReleaseInfo _release({String notes = _both, Map<String, String>? byLocale}) => parseUpdateManifest({
  'schema': 1,
  'version': '0.9.2+10261200',
  'tag': 'v0.9.2',
  'notes': notes,
  'notesByLocale': ?byLocale,
  'assets': {
    'arm64': {
      'name': 'dsh-go-0.9.2-arm64.apk',
      'url': 'https://go.dshtui.com/beta/0.9.2/dsh-go-0.9.2-arm64.apk',
      'size': 1,
    },
  },
}, base: Uri.parse('https://go.dshtui.com/beta/'));

class _Offer extends AppUpdateController {
  _Offer(this.release);

  final ReleaseInfo release;

  @override
  AppUpdateState build() => AppUpdateState(
    loaded: true,
    current: AppVersion.tryParse('0.9.1+1')!,
    flavor: ApkFlavor.arm64,
    check: UpdateCheckPhase.available,
    latest: release,
    total: 1,
  );

  @override
  Future<void> get ready async {}
}

void main() {
  group('releaseNotesFor', () {
    test('the source\'s own split wins; English falls back to Chinese', () {
      final split = _release(byLocale: {'zh': '- 内测', 'en': '- Beta'});
      expect(releaseNotesFor(split, 'zh'), '- 内测');
      expect(releaseNotesFor(split, 'en'), '- Beta');
      expect(releaseNotesFor(_release(byLocale: {'zh': '- 内测'}), 'en'), '- 内测');
    });

    test('without a split: the language\'s section of the changelog\'s form', () {
      final release = _release();
      expect(releaseNotesFor(release, 'zh'), '- 插件可以直接显示在原生界面里');
      expect(releaseNotesFor(release, 'en'), '- Plugins can show up natively');
      expect(releaseNotesFor(_release(notes: '### 中文\n\n- 只有中文'), 'en'), '- 只有中文');
    });

    test('notes without language sections stay as they are', () {
      const plain = '## 新功能\n\n- 应用内更新';
      expect(releaseNotesFor(_release(notes: plain), 'en'), plain);
      expect(releaseNotesFor(_release(notes: ''), 'zh'), '');
    });

    test('the cached offer keeps the split', () {
      final release = _release(byLocale: {'zh': '- 内测', 'en': '- Beta'});
      final again = parseUpdateManifest(release.toManifestJson());
      expect(again.notesByLocale, {'zh': '- 内测', 'en': '- Beta'});
    });
  });

  group('the sheet', () {
    Future<void> pump(WidgetTester tester, ReleaseInfo release, {bool english = false}) async {
      if (english) useEnglish();
      usePhoneSurface(tester);
      const sheet = Scaffold(body: SingleChildScrollView(child: UpdateSheet()));
      await tester.pumpWidget(
        goldenApp(
          home: english ? inEnglish(sheet) : sheet,
          brightness: Brightness.light,
          overrides: [
            localRuntimeProvider.overrideWith(
              () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
            ),
            settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
            appUpdateProvider.overrideWith(() => _Offer(release)),
          ],
        ),
      );
      await tester.pump();
    }

    testWidgets('Chinese app: only the Chinese notes', (tester) async {
      await pump(tester, _release(byLocale: {'zh': '- 内测通道', 'en': '- Beta channel'}));
      expect(find.textContaining('内测通道'), findsOneWidget);
      expect(find.textContaining('Beta channel'), findsNothing);
      expect(find.textContaining('English'), findsNothing);
    });

    testWidgets('English app: only the English notes, also from the changelog\'s sections', (tester) async {
      await pump(tester, _release(), english: true);
      expect(find.textContaining('Plugins can show up natively'), findsOneWidget);
      expect(find.textContaining('插件可以直接显示'), findsNothing);
      expect(find.textContaining('中文'), findsNothing);
    });
  });
}
