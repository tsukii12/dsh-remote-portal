// Hosted links opened in the app (link router, shared text, `dshgo://`), the
// landing page on the share host (old github.io links still read), and the
// two entries to 「我的分享链接」.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/links/app_links.dart';
import 'package:dsh_app/links/share_intake.dart';
import 'package:dsh_app/share_code/share_link.dart';
import 'package:dsh_app/share_hosted/hosted_client.dart';
import 'package:dsh_app/share_hosted/hosted_config.dart';
import 'package:dsh_app/share_hosted/hosted_crypto.dart';
import 'package:dsh_app/share_hosted/hosted_link.dart';
import 'package:dsh_app/share_hosted/hosted_links_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/replay/conversation_out.dart' show ManageLinksButton;
import 'package:dsh_app/ui/replay/replay_page.dart';
import 'package:dsh_app/ui/share_hosted/hosted_links_page.dart';
import 'package:dsh_app/ui/share_hosted/hosted_links_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import 'hosted_client_test.dart' show FakeHost;
import 'hosted_links_state_test.dart' show MemoryStore, link;

/// The conversation file the app wrote (the replay timeline fixture).
final _fileText =
    (jsonDecode(File('${Directory.current.path}/test/replay/fixtures/timeline.json').readAsStringSync()) as Map)['file']
        as String;

void main() {
  group('landing page', () {
    test('lives on the share host; old github.io links still read', () {
      expect(shareLandingUrl, '$shareHostOrigin/share/');
      expect(shareLandingUrl, 'https://go.dshtui.com/share/');
      const code = 'abc123.ABCDEFGH';
      for (final base in [shareLandingUrl, ...legacyShareLandingUrls]) {
        final uri = Uri.parse('$base#p=$code');
        expect(isLandingUri(uri), isTrue, reason: base);
        expect(ShareLink.parse(uri)?.code, code, reason: base);
        expect(ShareLink.find('看看这个 $base#p=$code 很好用')?.code, code, reason: base);
      }
      expect(isLandingUri(Uri.parse('https://ccch1mneyyy.github.io/dsh-go/other/')), isFalse);
      expect(isLandingUri(Uri.parse('https://go.dshtui.com/c/')), isFalse);
      expect(
        ShareLink.inline(ShareLink.parse(Uri.parse('dshgo://share/plugin?p=$code'))!.kind!, code).webLink,
        startsWith('https://go.dshtui.com/share/#p='),
      );
    });
  });

  group('finding hosted links', () {
    final key = encodeHostedKey(newHostedKey());

    test('https and dshgo forms, on our host only', () {
      expect(parseHostedUrl('dshgo://go.dshtui.com/c/Ab3dE5gH9k#k=$key')?.origin, 'https://go.dshtui.com');
      expect(isHostedLink(Uri.parse('https://go.dshtui.com/c/Ab3dE5gH9k#k=$key')), isTrue);
      expect(isHostedLink(Uri.parse('dshgo://go.dshtui.com/c/Ab3dE5gH9k#k=$key')), isTrue);
      expect(isHostedLink(Uri.parse('https://evil.example/c/Ab3dE5gH9k#k=$key')), isFalse);
      expect(isHostedLink(Uri.parse('https://go.dshtui.com:8443/c/Ab3dE5gH9k#k=$key')), isFalse);
    });

    test('in forwarded text, punctuation and all', () {
      final url = 'https://go.dshtui.com/c/Ab3dE5gH9k#k=$key';
      expect(findHostedUrl('「修复登录」· dsh-go 对话\n$url'), Uri.parse(url));
      expect(findHostedUrl('看这个：$url。'), Uri.parse(url));
      expect(findHostedUrl('dshgo://go.dshtui.com/c/Ab3dE5gH9k#k=$key'), Uri.parse(url));
      expect(findHostedUrl('https://evil.example/c/Ab3dE5gH9k#k=$key'), isNull);
      expect(findHostedUrl('https://go.dshtui.com/c/Ab3dE5gH9k#k=short'), isNull);
      expect(findHostedUrl('https://go.dshtui.com/share/#p=a.b'), isNull);
    });

    test('a shared text with one goes to its replay, not the composer', () {
      final url = 'https://go.dshtui.com/c/Ab3dE5gH9k#k=$key';
      expect(IncomingShare(text: '「修复登录」· dsh-go 对话\n$url').hostedLink, Uri.parse(url));
      expect(
        IncomingShare(
          text: url,
          files: const [SharedFile(path: '/p', name: 'a.png')],
        ).hostedLink,
        isNull,
      );
      expect(IncomingShare(text: '随便聊聊').hostedLink, isNull);
    });
  });

  group('opening through the link router', () {
    late FakeHost host;
    late String key;

    Future<AppLinks> pumpHome(WidgetTester tester) async {
      usePhoneView(tester);
      host = FakeHost();
      final raw = newHostedKey();
      key = encodeHostedKey(raw);
      host.blobs['M000000001'] = sealHosted(utf8.encode(_fileText), raw);
      late AppLinks links;
      await tester.pumpWidget(
        testApp(
          Consumer(
            builder: (context, ref, _) {
              links = ref.read(appLinksProvider);
              return const Scaffold(body: LinkHost());
            },
          ),
          overrides: [
            settingsProvider.overrideWith(() => TestSettings()),
            hostedShareClientProvider.overrideWithValue(HostedShareClient(client: host.client)),
            hostedLinkStoreProvider.overrideWithValue(MemoryStore()),
          ],
        ),
      );
      await pumpFrames(tester, 2);
      return links;
    }

    for (final scheme in ['https', 'dshgo']) {
      testWidgets('$scheme link → replay', (tester) async {
        final links = await pumpHome(tester);
        links.add(Uri.parse('$scheme://go.dshtui.com/c/M000000001#k=$key'));
        for (var i = 0; i < 100 && find.byType(ReplayPage).evaluate().isEmpty; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump();
        }
        await pumpFrames(tester, 6);
        expect(find.byType(ReplayPage), findsOneWidget);
        expect(find.text('修复登录重复提交'), findsWidgets);
        expect(host.requests.single.url.toString(), 'https://go.dshtui.com/api/v1/c/M000000001');
      });
    }

    testWidgets('a deleted link or a wrong key says so', (tester) async {
      final links = await pumpHome(tester);
      links.add(Uri.parse('https://go.dshtui.com/c/M000000002#k=$key'));
      await pumpFrames(tester, 4);
      expect(find.text('链接已过期或被删除'), findsOneWidget);
      expect(find.byType(ReplayPage), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      links.add(Uri.parse('https://go.dshtui.com/c/M000000001#k=${encodeHostedKey(newHostedKey())}'));
      await pumpFrames(tester, 4);
      expect(find.text('链接不完整或已损坏'), findsOneWidget);
      expect(find.byType(ReplayPage), findsNothing);
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('entries to 「我的分享链接」', () {
    final saved = [link('M000000001'), link('M000000002')];

    testWidgets('settings row shows the count and opens the page', (tester) async {
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          const Scaffold(body: Column(children: [HostedLinksSettingsTile()])),
          overrides: [hostedLinkStoreProvider.overrideWithValue(MemoryStore(saved))],
        ),
      );
      await pumpFrames(tester, 2);
      expect(find.text('我的分享链接'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      await tester.tap(find.text('我的分享链接'));
      await tester.pumpAndSettle();
      expect(find.byType(HostedLinksPage), findsOneWidget);
      expect(find.text(saved.first.title), findsOneWidget);
    });

    testWidgets('no count when there are none', (tester) async {
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          const Scaffold(body: Column(children: [HostedLinksSettingsTile()])),
          overrides: [hostedLinkStoreProvider.overrideWithValue(MemoryStore())],
        ),
      );
      await pumpFrames(tester, 2);
      expect(find.text('0'), findsNothing);
    });

    testWidgets('「我的分享链接」 closes the sheet and opens the page', (tester) async {
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    builder: (_) => const SizedBox(height: 200, child: Center(child: ManageLinksButton())),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
          overrides: [hostedLinkStoreProvider.overrideWithValue(MemoryStore(saved))],
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('我的分享链接'));
      await tester.pumpAndSettle();
      expect(find.byType(HostedLinksPage), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      Navigator.of(tester.element(find.byType(HostedLinksPage))).pop();
      await tester.pumpAndSettle();
      expect(find.text('open'), findsOneWidget);
    });
  });

  test('a link this phone made reads back as hosted', () {
    final made = link('A000000003');
    expect(isHostedLink(Uri.parse(made.url.replaceFirst('https://go.example', shareHostOrigin))), isTrue);
  });
}
