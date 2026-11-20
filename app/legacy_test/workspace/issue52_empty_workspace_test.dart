import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/common/empty_view.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/shell/sessions_drawer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import 'support.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => AppLocale.use(AppLocale.zhCN));

  for (final locale in AppLocale.supported) {
    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 1.3, 2.0]) {
        testWidgets('empty workspace keeps old chats reachable: $locale $brightness ${scale}x', (tester) async {
          AppLocale.use(locale);
          usePhoneSurface(tester);
          tester.view.physicalSize = const Size(320 * 2, 640 * 2);
          final host = FakeWorkspaceHost(folders: ['/root/workspace']);
          host.seedSession('old', 'Earlier conversation', DateTime.utc(2026, 10, 26));
          final workspace = host.seedWorkspace('/root/workspace');
          await tester.pumpWidget(
            goldenApp(
              brightness: brightness,
              overrides: workspaceOverrides(
                host,
                current: null,
                prefs: WorkspacePrefs(loaded: true, selected: workspace['workspaceId'] as String),
              ),
              home: Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
                  child: HomeShell(chatBuilder: (_) => const SizedBox.expand(), initiallyOpen: true),
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 800));

          expect(find.text(appL10n.shellWorkspaceNewChatsHint), findsOneWidget);
          expect(find.text('Earlier conversation'), findsNothing);
          final action = find.descendant(
            of: find.byType(EmptyView),
            matching: find.widgetWithText(OutlinedButton, appL10n.remoteWorkspaceAllChats),
          );
          expect(action, findsOneWidget);
          await tester.ensureVisible(action);
          final bounds = tester.getRect(action);
          expect(bounds.height, greaterThanOrEqualTo(48));
          expect(bounds.left, greaterThanOrEqualTo(0));
          expect(bounds.right, lessThanOrEqualTo(320));
          expect(tester.takeException(), isNull);
          await tester.tap(action);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));

          final container = ProviderScope.containerOf(tester.element(find.byType(SessionsDrawer)));
          expect(container.read(workspacePrefsProvider).selected, isNull);
          expect(find.text('Earlier conversation'), findsOneWidget);
          // Changing a view filter must not rewrite historical membership.
          expect(workspace['sessionIds'], isEmpty);
          expect(host.argsOf('session/create'), isEmpty);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
