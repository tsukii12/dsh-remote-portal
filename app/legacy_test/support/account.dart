// Fakes and rendering helpers for the account tests.

import 'dart:async';

import 'package:dsh_app/state/account_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/onboarding_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../support/test_fonts.dart';

// ── Views ────────────────────────────────────────────────────────────────────

const links = AccountLinks(
  usageUrl: 'https://platform.deepseek.com/usage',
  topUpUrl: 'https://platform.deepseek.com/top_up',
);

const authorizeUrl = 'https://platform.deepseek.com/dsh/authorize?authorize_id=a-1';

AccountView signedOutView({SignInAttempt? attempt}) =>
    AccountView(status: AccountStatus.signedOut, links: links, attempt: attempt);

AccountView signedInView({SignInAttempt? attempt}) =>
    AccountView(status: AccountStatus.credentialStored, links: links, attempt: attempt);

SignInAttempt attempt(SignInPhase phase, {String id = 'att-1', String? url, SignInErrorCode? error}) => SignInAttempt(
  id: id,
  phase: phase,
  authorizeUrl: url ?? (phase == SignInPhase.waitingBrowser ? authorizeUrl : null),
  expiresAt: DateTime.now().add(const Duration(minutes: 10)),
  errorCode: error,
);

const sampleProfile = AccountProfile(id: 'u-1001', name: '雾蓝', contact: '138****5678');

const sampleBalance = AccountBalance(
  recharge: [AccountWallet(currency: 'CNY', balance: '128.4567')],
  bonus: [AccountWallet(currency: 'CNY', balance: '10.0000000000000000')],
);

// ── Fake Host ────────────────────────────────────────────────────────────────

/// In-memory stand-in for the Host's `account/*` namespace. Unary calls answer
/// from [current]; [emit] pushes a snapshot to every open `watch()`.
class FakeAccountApi implements AccountApi {
  FakeAccountApi({AccountView? initial}) : current = initial ?? signedOutView();

  AccountView current;
  final calls = <String>[];
  final _watchers = <StreamController<AccountView>>[];

  /// Overrides the default startSignIn answer (initializing attempt `att-1`).
  Future<AccountView> Function()? onStart;
  Future<AccountView> Function(String id)? onCancel;
  AccountProfile? profile = sampleProfile;
  Object? profileError;
  AccountBalance? balance = sampleBalance;
  Object? balanceError;
  bool runningTasks = false;
  Object? getStateError;

  int get watcherCount => _watchers.where((c) => !c.isClosed && c.hasListener).length;

  void emit(AccountView view) {
    current = view;
    for (final c in [..._watchers]) {
      if (!c.isClosed) c.add(view);
    }
  }

  /// Fails every open watch stream.
  void failWatchers(Object error) {
    for (final c in [..._watchers]) {
      if (!c.isClosed) {
        c.addError(error);
        unawaited(c.close());
      }
    }
  }

  @override
  String get callbackOrigin => 'http://127.0.0.1:3080';

  @override
  Future<AccountView> getState() async {
    calls.add('getState');
    if (getStateError case final e?) throw e;
    return current;
  }

  @override
  Stream<AccountView> watch() {
    calls.add('watch');
    late final StreamController<AccountView> c;
    c = StreamController<AccountView>(onListen: () => c.add(current), onCancel: () => _watchers.remove(c));
    _watchers.add(c);
    return c.stream;
  }

  @override
  Future<AccountView> startSignIn({LoginSource source = LoginSource.web}) async {
    calls.add('startSignIn:${source.wire}');
    if (onStart case final start?) return start();
    final view = signedOutView(attempt: attempt(SignInPhase.initializing));
    current = view;
    return view;
  }

  @override
  Future<AccountView> cancelSignIn(String attemptId) async {
    calls.add('cancelSignIn:$attemptId');
    if (onCancel case final cancel?) return cancel(attemptId);
    final view = signedOutView(attempt: attempt(SignInPhase.cancelled, id: attemptId));
    emit(view);
    return view;
  }

  @override
  Future<AccountView> signOut() async {
    calls.add('signOut');
    final view = signedOutView();
    emit(view);
    return view;
  }

  @override
  Future<AccountProfile?> getProfile() async {
    calls.add('getProfile');
    if (profileError case final e?) throw e;
    return current.signedIn ? profile : null;
  }

  @override
  Future<AccountBalance?> getBalance() async {
    calls.add('getBalance');
    if (balanceError case final e?) throw e;
    return current.signedIn ? balance : null;
  }

  @override
  Future<bool> hasRunningAccountTasks() async {
    calls.add('hasRunningAccountTasks');
    return runningTasks;
  }

  @override
  Future<void> initializeDefaultModel() async => calls.add('initializeDefaultModel');
}

class FakeBrowser implements AccountBrowser {
  FakeBrowser({this.succeeds = true});

  bool succeeds;
  final opened = <Uri>[];

  @override
  Future<bool> open(Uri url) async {
    opened.add(url);
    return succeeds;
  }
}

/// Lets a test swap the engine connection (null = engine stopped).
class ApiSwitch extends Notifier<AccountApi?> {
  ApiSwitch(this.initial);

  final AccountApi? initial;

  @override
  AccountApi? build() => initial;

  void set(AccountApi? api) => state = api;
}

final apiSwitchProvider = NotifierProvider<ApiSwitch, AccountApi?>(() => ApiSwitch(null));

class NoConnection extends AsyncNotifier<HostConnection?> {
  @override
  Future<HostConnection?> build() async => null;
}

class FakeOnboardingPrefs extends OnboardingPrefsController {
  @override
  OnboardingPrefs build() => const OnboardingPrefs(loaded: true, welcomeSeen: true);

  @override
  Future<void> markWelcomeSeen() async => state = state.copyWith(welcomeSeen: true);

  @override
  Future<void> setKeySkipped(bool skipped) async => state = state.copyWith(keySkipped: skipped);
}

class FakeSettings extends SettingsController {
  @override
  AppSettings build() => const AppSettings(loaded: true);

  @override
  Future<void> setApiKey(String key) async => state = state.copyWith(apiKey: key);
}

/// Controller frozen in [fixed] (goldens): no Host, no streams.
class FixedAccount extends AccountController {
  FixedAccount(this.fixed);

  final AccountState fixed;

  @override
  AccountState build() => fixed;
}

/// Overrides shared by every account test: the engine connection is [api]
/// (switchable through [apiSwitchProvider]), nothing touches the runtime.
List<Override> accountOverrides({AccountApi? api, AccountBrowser? browser, int? engineStarts}) => [
  apiSwitchProvider.overrideWith(() => ApiSwitch(api)),
  accountApiProvider.overrideWith((ref) => ref.watch(apiSwitchProvider)),
  accountBrowserProvider.overrideWithValue(browser ?? FakeBrowser()),
  accountEngineStarterProvider.overrideWithValue(() async {}),
  localConnectionProvider.overrideWithValue(const AsyncData<HostConnection?>(null)),
  onboardingPrefsProvider.overrideWith(FakeOnboardingPrefs.new),
  settingsProvider.overrideWith(FakeSettings.new),
];

// ── Rendering ────────────────────────────────────────────────────────────────

/// Real fonts (see `test/support/test_fonts.dart`).
Future<void> loadAccountFonts() => loadTestFonts();

/// 390×844 logical phone at DPR 2 with system bar insets.
void usePhoneSurface(WidgetTester tester) {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(390 * 2, 844 * 2);
  tester.view.padding = const FakeViewPadding(top: 32 * 2, bottom: 24 * 2);
  tester.view.viewPadding = const FakeViewPadding(top: 32 * 2, bottom: 24 * 2);
  addTearDown(tester.view.reset);
}

Widget accountApp({
  required Widget home,
  Brightness brightness = Brightness.light,
  List<Override> overrides = const [],
  bool freezeAnimations = true,
}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: withTestFonts(buildLightTheme()),
      darkTheme: withTestFonts(buildDarkTheme()),
      themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: freezeAnimations
          ? (context, child) =>
                MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!)
          : null,
      home: home,
    ),
  );
}

/// Renders [home] in light and dark against `goldens/<name>_<mode>.png`.
void goldenBoth(String name, Widget Function() home, {required List<Override> Function() overrides}) {
  for (final brightness in Brightness.values) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    testWidgets('$name ($mode)', (tester) async {
      await tester.runAsync(loadAccountFonts);
      usePhoneSurface(tester);
      await tester.pumpWidget(accountApp(home: home(), brightness: brightness, overrides: overrides()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/${name}_$mode.png'));
    });
  }
}
