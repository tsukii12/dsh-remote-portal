// A ui.json or native plugin `open` target that named a settings card of
// 全部功能 before the cards moved to 设置 still opens the same page: every
// such id resolves through the settings index.

import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/engine_settings/runtime_settings_pages.dart';
import 'package:dsh_app/ui/features/feature_catalog.dart';
import 'package:dsh_app/ui/plugins/native/native_taps.dart' show openNativePage;
import 'package:dsh_app/ui/settings/index/settings_pages.dart';
import 'package:dsh_app/ui_config/ui_config_schema.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../shell/golden_harness.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('every ui.json target is a 全部功能 card or a settings link', () {
    final cards = {
      for (final s in featureSections)
        for (final i in s.items) i.id,
    };
    for (final page in UiSchema.pages) {
      if (page == 'new-chat' || page == 'settings' || cards.contains(page)) continue;
      expect(settingsPageForLink(page), isNotNull, reason: page);
    }
  });

  testWidgets('an id that left 全部功能 opens its settings page', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: Consumer(
          builder: (context, ref, _) =>
              TextButton(onPressed: () => openNativePage(context, ref, 'agent-loop'), child: const Text('open')),
        ),
        brightness: Brightness.light,
        overrides: [
          localRuntimeProvider.overrideWith(
            () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
          ),
          settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
        ],
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(AgentLoopSettingsPage), findsOneWidget);
  });
}
