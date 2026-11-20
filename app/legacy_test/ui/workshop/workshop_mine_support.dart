// The 我的投稿 and 举报 widget tests run the real workshop controllers over a
// client that never opens a socket (test/state/workshop_personal_test_support):
// what the page shows is what the state layer really does with each answer.

import 'package:dsh_app/state/workshop_account_state.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/workshop_dependencies.dart';
import 'package:dsh_app/state/workshop_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../../chat/support/harness.dart' show testApp;
import '../../state/workshop_auth_test_support.dart';
import '../../state/workshop_personal_test_support.dart';

export '../../state/workshop_auth_test_support.dart' show authAccount, authSignedIn, authSignedOut, authWorker;
export '../../state/workshop_personal_test_support.dart';

/// The GitHub account, the workshop client and the stored agreement a test
/// page runs on.
class WorkshopPageWorld {
  WorkshopPageWorld({WorkshopAccountState? account, bool consent = true, PersonalClient? client})
    : client = client ?? PersonalClient(),
      accountController = AuthAccountController(account ?? authSignedIn()) {
    if (consent) preferences.accepted.add(preferences.pair(this.client.origin, authAccount));
  }

  final PersonalClient client;
  final AuthAccountController accountController;
  final preferences = AuthPreferences();

  List<Override> get overrides => [
    workshopAccountProvider.overrideWith(() => accountController),
    workshopClientProvider.overrideWith((ref) async => client),
    workshopPreferencesProvider.overrideWithValue(preferences),
  ];

  Widget app(Widget home) => testApp(home, overrides: overrides);
}

/// 360dp wide with the system font at 1.3: the narrowest phone the pages
/// must fit.
void useNarrowLargeText(WidgetTester tester) {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(720, 1560);
  tester.platformDispatcher.textScaleFactorTestValue = 1.3;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// Lets futures land and short animations run; never waits on a spinner.
Future<void> settle(WidgetTester tester, [int frames = 10]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// No stable code, exception name or raw server word is on screen.
void expectNoCodes(WidgetTester tester) {
  for (final text in tester.widgetList<Text>(find.byType(Text))) {
    final shown = text.data ?? text.textSpan?.toPlainText() ?? '';
    expect(shown, isNot(contains('workshop_')));
    expect(shown, isNot(contains('Exception')));
  }
}

/// The app's Chinese strings (tests run in Chinese).
L10n get zh => lookupL10n(AppLocale.zhCN);
