import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/share_code/conversation_share.dart';
import 'package:dsh_app/share_code/share_code_state.dart';
import 'package:dsh_app/share_code/share_codec.dart';
import 'package:dsh_app/share_code/share_link.dart';
import 'package:dsh_app/share_code/share_models.dart';
import 'package:dsh_app/share_hosted/hosted_client.dart';
import 'package:dsh_app/share_hosted/hosted_crypto.dart';
import 'package:dsh_app/share_hosted/hosted_links_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/replay/replay_page.dart';
import 'package:dsh_app/ui/share_code/import_sheet.dart';
import 'package:dsh_app/ui/share_code/share_code_host.dart';
import 'package:dsh_app/ui/share_hosted/hosted_link_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';

class _Download extends HostedShareClient {
  _Download(this.reply);
  final Future<Uint8List> reply;
  @override
  Future<Uint8List> download(String url) => reply;
}

final _hostedUri = Uri.parse('https://go.dshtui.com/c/M000000001#k=${encodeHostedKey(Uint8List(32))}');

Future<BuildContext> _pump(WidgetTester tester, {List<Override> overrides = const []}) async {
  usePhoneView(tester);
  late BuildContext opener;
  await tester.pumpWidget(
    testApp(
      Builder(
        builder: (context) {
          opener = context;
          return const Scaffold(body: Text('Home'));
        },
      ),
      overrides: [
        settingsProvider.overrideWith(() => TestSettings()),
        importTargetsProvider.overrideWithValue(const []),
        ...overrides,
      ],
    ),
  );
  return opener;
}

Future<void> _until(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 250 && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(finder, findsOneWidget);
}

Future<File> _file(WidgetTester tester, List<int> bytes) async {
  final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('share-decode-')))!;
  addTearDown(() => dir.deleteSync(recursive: true));
  return File('${dir.path}/share.dshgo')..writeAsBytesSync(bytes);
}

void main() {
  tearDown(() => AppLocale.use(AppLocale.zhCN));
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAEklEQVR4nGPwTt/yHxkzkC4AAAPnJlH/osXzAAAAAElFTkSuQmCC',
  );
  final asset = ConversationAsset.of(png, mediaType: 'image/png');
  final share = ConversationShare(
    title: '',
    start: DateTime.utc(2026, 11, 11),
    entries: [
      UserEntry(
        t: 0,
        text: '你好 👋',
        images: [
          ImageRef(id: asset.id),
          const ImageRef(id: 'AAAAAAAAAAAA'),
        ],
      ),
    ],
  );
  final envelope = jsonDecode(encodeConversationFile(share, [asset])) as Map<String, dynamic>;
  (envelope['assets'] as Map)['AAAAAAAAAAAA'] = asset.toJson(); // Wrong hash: must still be dropped.
  final bytes = utf8.encode(jsonEncode(envelope));

  for (final hosted in [false, true]) {
    testWidgets('${hosted ? 'hosted' : 'file'} decode preserves English fallback, Unicode and checked assets', (
      tester,
    ) async {
      AppLocale.use(AppLocale.en);
      final client = _Download(Future.value(bytes));
      addTearDown(client.close);
      final opener = await _pump(tester, overrides: [hostedShareClientProvider.overrideWithValue(client)]);
      if (hosted) {
        unawaited(openHostedLink(opener, _hostedUri));
      } else {
        unawaited(openShareFile(opener, await _file(tester, bytes)));
      }
      await _until(tester, find.byType(ReplayPage));
      final page = tester.widget<ReplayPage>(find.byType(ReplayPage));
      expect(page.share.title, appL10n.pluginsChat);
      expect(page.share.entries.single.toJson()['text'], '你好 👋');
      expect(page.assets.keys, [asset.id]);
      expect(page.assets[asset.id]!.bytes, png);
    });
  }

  testWidgets('a non-UTF8 file retains the file-read error', (tester) async {
    final opener = await _pump(tester);
    unawaited(openShareFile(opener, await _file(tester, [0xff, 0xfe, 0x00])));
    await _until(tester, find.text(appL10n.pluginsShareFileReadFailed));
    expect(find.byType(ReplayPage), findsNothing);
  });

  for (final payload in <SharePayload>[
    const PluginShare(SharedPlugin(name: 'test-bundle', source: PluginSourceKind.official)),
    const ProfileShare(
      name: 'Synthetic profile',
      settings: {
        'ui-chat': {'value': 1},
      },
    ),
  ]) {
    testWidgets('${payload.kind.name} still reaches its confirm sheet without an install', (tester) async {
      final opener = await _pump(tester);
      unawaited(openShareLink(opener, ShareLink.inline(payload.kind, encodeShareCode(payload))));
      await _until(tester, find.byType(ShareImportSheet));
      expect(tester.widget<ShareImportSheet>(find.byType(ShareImportSheet)).payload.toJson(), payload.toJson());
      expect(find.byType(ReplayPage), findsNothing);
    });
  }

  testWidgets('a file beyond the existing size cap is refused', (tester) async {
    final opener = await _pump(tester);
    unawaited(openShareFile(opener, await _file(tester, Uint8List(maxConversationFileBytes * 2 + 1))));
    await _until(tester, find.text(appL10n.pluginsShareDamaged));
    expect(find.byType(ReplayPage), findsNothing);
  });

  for (final fail in [false, true]) {
    testWidgets('a ${fail ? 'failed' : 'successful'} hosted download after owner disposal opens nothing', (
      tester,
    ) async {
      final reply = (await tester.runAsync(() async => Completer<Uint8List>()))!;
      final client = _Download(reply.future);
      addTearDown(client.close);
      final opener = await _pump(tester, overrides: [hostedShareClientProvider.overrideWithValue(client)]);
      late Future<bool> opening;
      await tester.runAsync(() async {
        opening = openHostedLink(opener, _hostedUri);
      });
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        if (fail) {
          reply.completeError(const HostedShareException(HostedShareError.gone));
        } else {
          reply.complete(bytes);
        }
        expect(await opening, isTrue);
      });
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(ReplayPage), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('leaving the opener clears its pending hint without posting a later error', (tester) async {
    usePhoneView(tester);
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    final reply = Completer<Uint8List>();
    final client = _Download(reply.future);
    addTearDown(client.close);
    late BuildContext opener;
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: visible,
            builder: (_, showing, _) => showing
                ? Builder(
                    builder: (context) {
                      opener = context;
                      return const Text('Opener');
                    },
                  )
                : const Text('Home'),
          ),
        ),
        overrides: [hostedShareClientProvider.overrideWithValue(client)],
      ),
    );
    unawaited(openHostedLink(opener, _hostedUri));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.text(appL10n.remoteOpening), findsOneWidget);
    visible.value = false;
    await tester.pump();
    expect(opener.mounted, isFalse);
    reply.completeError(const HostedShareException(HostedShareError.gone));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text(appL10n.remoteOpening), findsNothing);
    expect(find.text(appL10n.remoteHostedErrGone), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
