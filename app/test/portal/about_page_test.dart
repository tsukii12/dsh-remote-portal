import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/app_info.dart';
import 'package:dsh_app/ui/settings/about_page.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const channel = MethodChannel('plugins.flutter.io/url_launcher');
  final launched = <String>[];
  var accepted = true;
  var throws = false;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLocale.use(AppLocale.en);
    launched.clear();
    accepted = true;
    throws = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'launch') return null;
      launched.add((call.arguments as Map)['url'] as String);
      if (throws) throw PlatformException(code: 'unavailable');
      return accepted;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    AppLocale.use(AppLocale.zhCN);
  });

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(theme: buildLightTheme(), home: const AboutPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows YuRemote version, source and upstream credit without account data', (tester) async {
    await show(tester);
    expect(find.text('YuRemote'), findsOneWidget);
    expect(find.text(AppInfo.displayVersion), findsOneWidget);
    expect(find.text(AppInfo.repositoryUrl), findsOneWidget);
    expect(find.text('dsh-Go v1.2.0 · ccch1mneyyy'), findsOneWidget);
    await tester.tap(find.text('Project repository'));
    await tester.pumpAndSettle();
    expect(launched, [AppInfo.repositoryUrl]);
  });

  for (final failsWithException in [false, true]) {
    testWidgets('reports browser ${failsWithException ? 'exception' : 'refusal'} without leaving About', (
      tester,
    ) async {
      accepted = false;
      throws = failsWithException;
      await show(tester);
      await tester.tap(find.text('Project repository'));
      await tester.pumpAndSettle();
      expect(find.text(appL10n.stateBrowserOpenFailed), findsOneWidget);
      expect(find.byType(AboutPage), findsOneWidget);
    });
  }
}
