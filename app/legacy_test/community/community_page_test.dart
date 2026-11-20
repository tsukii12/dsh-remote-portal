// The 社区 hub: goldens (light + dark, with and without the forum hook, the
// group sheet), and its flows — a prompt opens a new conversation with the
// text in the composer, a group shows its QR code and copies its number, a
// picked plugin opens the market's install sheet.
//
//   flutter test --update-goldens test/community/community_page_test.dart

import 'package:dsh_app/state/community_state.dart';
import 'package:dsh_app/state/safe_mode_state.dart';
import 'package:dsh_app/ui/community/community_page.dart';
import 'package:dsh_app/ui/community/community_widgets.dart';
import 'package:dsh_app/ui/share/qr_code.dart';
import 'package:dsh_app/ui/shell/brand_mark.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderScope;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../plugins/support/fake_plugin_host.dart';
import 'support.dart';

void main() {
  late FakePluginCarrier carrier;
  late DshClient client;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    carrier = FakePluginCarrier();
    client = DshClient.withCarrier(carrier);
    carrier.handlers['pluginManager/listBundles'] = (_) => sampleBundles;
  });
  tearDown(() => client.close());

  Future<void> pump(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
    VoidCallback? onOpenForum,
    double height = 844,
  }) async {
    await tester.runAsync(loadTestFonts);
    usePhoneView(tester);
    tester.view.physicalSize = Size(780, height * 2);
    await tester.pumpWidget(
      testApp(
        Navigator(
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () =>
                      Navigator.of(context)
                          .push(MaterialPageRoute<void>(builder: (_) => CommunityPage(onOpenForum: onOpenForum))),
                  child: const Text('home'),
                ),
              ),
            ),
          ),
        ),
        brightness: brightness,
        overrides: [
          ...pluginOverrides(fakeHost(client)),
          communityHttpProvider.overrideWithValue(ScriptedHttp({})),
          communitySourcesProvider.overrideWithValue(const []),
          communityBundleProvider.overrideWithValue(() async => sampleFeed()),
        ],
      ),
    );
    await tester.tap(find.text('home'));
    await tester.pumpAndSettle();
  }

  for (final brightness in Brightness.values) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    testWidgets('hub golden ($mode)', (tester) async {
      await pump(tester, brightness: brightness, onOpenForum: () {}, height: 1400);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/community_$mode.png'));
    });

    testWidgets('group sheet golden ($mode)', (tester) async {
      await pump(tester, brightness: brightness);
      await tester.scrollUntilVisible(find.text('QQ 交流群'), 200);
      await tester.tap(find.text('QQ 交流群'));
      await tester.pumpAndSettle();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/community_group_$mode.png'));
    });
  }

  testWidgets('without the forum hook the lead card is the project', (tester) async {
    await pump(tester);
    expect(find.text('论坛'), findsNothing);
    expect(find.text('DSH Go'), findsOneWidget);
    expect(find.text('开源项目，欢迎点星'), findsOneWidget);
    // The brand glyph sits on its visual centre in the avatar circle.
    final mark = tester.getRect(find.byType(BrandMark));
    final circle = tester.getRect(find.ancestor(of: find.byType(BrandMark), matching: find.byType(DecoratedBox)).first);
    final centre =
        mark.topLeft + Offset(BrandMark.visualCentre.dx * mark.width, BrandMark.visualCentre.dy * mark.height);
    expect((centre - circle.center).distance, lessThan(0.01));
  });

  testWidgets('the forum card opens the forum', (tester) async {
    var opened = 0;
    await pump(tester, onOpenForum: () => opened++);
    await tester.tap(find.text('论坛'));
    expect(opened, 1);
  });

  testWidgets('a prompt opens a new conversation with the text, not sent', (tester) async {
    await pump(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(CommunityPage)));
    await tester.scrollUntilVisible(find.text('读懂报错'), 200);
    await tester.tap(find.text('读懂报错'));
    await tester.pumpAndSettle();
    expect(container.read(repairDraftProvider), '帮我解释这段报错：\n\n');
    expect(find.byType(CommunityPage), findsNothing, reason: 'back to the chat');
  });

  testWidgets('picked plugins come from the market index; missing ones are left out', (tester) async {
    await pump(tester);
    expect(find.text('五个子代理一起写长篇'), findsOneWidget);
    expect(find.text('危险命令先问一句'), findsOneWidget);
    expect(find.text('not-in-the-index'), findsNothing);
    await tester.tap(find.text('五个子代理一起写长篇'));
    await tester.pumpAndSettle();
    expect(find.text('插件详情'), findsOneWidget);
  });

  testWidgets('a group: its QR code, 复制群号 and 打开', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    await pump(tester);
    await tester.scrollUntilVisible(find.text('QQ 交流群'), 200);
    await tester.tap(find.text('QQ 交流群'));
    await tester.pumpAndSettle();
    expect(tester.widget<QrCodeView>(find.byType(QrCodeView)).data, 'https://qm.qq.com/q/example');
    await tester.tap(find.text('复制群号'));
    await tester.pump();
    expect(copied, '123456789');
    expect(find.text('已复制'), findsOneWidget);
    expect(find.byKey(const ValueKey('group-open')), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('group sheet buttons: equal halves on the 20 gutter', (tester) async {
    await pump(tester);
    await tester.scrollUntilVisible(find.text('QQ 交流群'), 200);
    await tester.tap(find.text('QQ 交流群'));
    await tester.pumpAndSettle();
    final copy = tester.getRect(find.byKey(const ValueKey('group-copy')));
    final open = tester.getRect(find.byKey(const ValueKey('group-open')));
    final sheet = tester.getRect(find.byType(CommunityGroupSheet));
    expect(copy.width, moreOrLessEquals(open.width));
    expect(copy.height, 48);
    expect(open.height, 48);
    expect(open.left - copy.right, moreOrLessEquals(12));
    expect(copy.left - sheet.left, moreOrLessEquals(20));
    expect(sheet.right - open.right, moreOrLessEquals(20));
    final qr = tester.getRect(find.byType(QrCodeView));
    expect(qr.center.dx, moreOrLessEquals(sheet.center.dx), reason: 'QR centred');
    final logo = tester.getRect(find.byKey(QrCodeView.logoKey));
    expect(logo.center.dx, moreOrLessEquals(qr.center.dx, epsilon: 1e-6), reason: 'the tile on the code\'s centre');
    expect(logo.center.dy, moreOrLessEquals(qr.center.dy, epsilon: 1e-6));
  });

  test('dates: this year short, other years with the year', () {
    final now = DateTime(2026, 10, 24);
    expect(communityDate(DateTime(2026, 3, 5), now: now), '3月5日');
    expect(communityDate(DateTime(2025, 12, 1), now: now), '2025年12月');
  });
}
