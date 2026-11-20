// Behaviour and geometry of the share-code sheets.

import 'dart:io';

import 'package:dsh_app/share_code/profile_export.dart';
import 'package:dsh_app/share_code/share_codec.dart';
import 'package:dsh_app/share_code/share_link.dart';
import 'package:dsh_app/share_code/share_models.dart';
import 'package:dsh_app/share_code/share_net.dart';
import 'package:dsh_app/ui/common/app_sheet.dart' show SheetDragHandle;
import 'package:dsh_app/ui/share_code/import_sheet.dart';
import 'package:dsh_app/ui/share_code/plugin_share_sheet.dart';
import 'package:dsh_app/ui/share_code/profile_share_sheet.dart';
import 'package:dsh_app/ui/share_code/share_code_host.dart';
import 'package:dsh_app/ui/share_code/share_code_widgets.dart';
import 'package:dsh_app/ui/share/share_card.dart';
import 'package:dsh_app/ui/share/share_content.dart';
import 'package:dsh_app/ui/share/share_image_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';
import 'support/fake_engine.dart';
import 'support/sheet_support.dart';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

Future<void> _pump(WidgetTester tester, void Function(BuildContext) open, List<dynamic> overrides) async {
  usePhoneSurface(tester);
  await tester.pumpWidget(
    goldenApp(
      home: SheetHost(open: open),
      brightness: Brightness.light,
      overrides: overrides.cast(),
    ),
  );
  await tester.tap(find.text('open'));
  await _settle(tester);
}

/// A profile too large for a link: it goes out as a file, or a Gist link.
ProfileShare _bigProfile() => ProfileShare(
  skills: [
    for (var i = 0; i < 3; i++)
      SharedSkill(
        name: 'skill-$i',
        files: {
          'SKILL.md': [for (var j = 0; j < 200; j++) '第 $j 行 $i-$j ${j * 7919 % 1000}'].join('\n'),
        },
      ),
  ],
);

void main() {
  late Directory cache;
  setUp(() => cache = Directory.systemTemp.createTempSync('share-sheets-'));
  tearDown(() => cache.deleteSync(recursive: true));

  testWidgets('分享插件: copy the landing link, QR, share text; a link always fits, so no file', (tester) async {
    final out = RecordingShareOut(cache);
    await _pump(
      tester,
      (c) => showSharePluginSheet(c, plugin: notesPlugin),
      shareOverrides(net: sampleNet(), out: out),
    );

    await tester.tap(find.byKey(const ValueKey('share-code-copy')));
    await tester.pump();
    expect(find.text('已复制'), findsOneWidget);
    final link = out.copied.single;
    expect(link, startsWith('$shareLandingUrl#p='));
    final decoded = decodeShareCode(ShareLink.parse(Uri.parse(link))!.code!) as PluginShare;
    expect(decoded.plugin.spec, '@acme/dsh-notes@1.4.2');
    expect(decoded.plugin.integrity, notesIntegrity);
    await _settle(tester);
    expect(find.text('复制链接'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('share-code-share')));
    await _settle(tester);
    expect(out.sharedText.single, contains('「读书笔记」· DSH Go 插件'));
    expect(out.sharedText.single, contains(link));

    expect(find.byKey(const ValueKey('share-code-save')), findsNothing);
    expect(find.byKey(const ValueKey('share-code-image')), findsNothing, reason: 'no market card for it');
    expect(find.byTooltip('关闭'), findsNothing, reason: 'the sheet drags down to close');

    await tester.tap(find.byKey(const ValueKey('share-code-qr')));
    await _settle(tester);
    expect(find.text('二维码'), findsOneWidget);
    expect(find.bySemanticsLabel('分享码二维码'), findsOneWidget);
    expect(find.byTooltip('关闭'), findsNothing);
  });

  testWidgets('分享插件 with a market card: 图片 opens the share panel\'s image page in the same sheet', (tester) async {
    await _pump(
      tester,
      (c) => showSharePluginSheet(c, plugin: notesPlugin, card: notesEntry),
      shareOverrides(net: sampleNet(), out: RecordingShareOut(cache)),
    );
    final labels = [
      for (final k in ['share-code-copy', 'share-code-qr', 'share-code-image', 'share-code-share'])
        find.descendant(of: find.byKey(ValueKey(k)), matching: find.byType(Text)),
    ];
    expect([for (final l in labels) tester.widget<Text>(l).data], ['复制链接', '二维码', '图片', '分享']);
    await tester.tap(find.byKey(const ValueKey('share-code-image')));
    await _settle(tester);
    expect(find.byType(ShareImagePage), findsOneWidget);
    final card = tester.widget<ShareCard>(find.byType(ShareCard));
    expect((card.content.blocks.single as SharePlugin).name, '@acme/dsh-notes');
    expect(find.text('保存图片'), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await _settle(tester);
    expect(find.byType(PluginShareSheet), findsOneWidget);
  });

  testWidgets('分享配置: ticks change the share; too large goes out as a file or a Gist', (tester) async {
    final fs = await tester.runAsync(() async => sampleGuest());
    addTearDown(() => fs!.root.parent.deleteSync(recursive: true));
    final source = (await tester.runAsync(
      () => loadProfileExport(DshClient.withCarrier(exportEngine()), hostLabel: '本机', isLocal: true, fs: fs),
    ))!;
    final out = RecordingShareOut(cache);
    await _pump(tester, showShareProfileSheet, shareOverrides(net: sampleNet(), out: out, export: source));

    expect(find.text('已选 9 项 · 可生成二维码'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('share-item-settings:subagent')));
    await tester.pump();
    expect(find.text('已选 8 项 · 可生成二维码'), findsOneWidget);
    // A local install can't be ticked.
    await tester.tap(find.byKey(const ValueKey('share-item-plugin:my-tools')));
    await tester.pump();
    expect(find.text('已选 8 项 · 可生成二维码'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('share-profile-next')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('share-code-copy')));
    await tester.pump();
    final share = decodeShareCode(ShareLink.parse(Uri.parse(out.copied.single))!.code!) as ProfileShare;
    expect(share.settings.keys, isNot(contains('subagent')));
    expect(share.plugins.map((p) => p.name), contains('@acme/dsh-notes'));
    expect(share.plugins.first.integrity, notesIntegrity);
    expect(share.agentsMd, isNull);
    await _settle(tester);
  });

  testWidgets('a profile too large for a link: file share, then a Gist link with a token', (tester) async {
    final net = sampleNet();
    final out = RecordingShareOut(cache);
    await _pump(tester, (c) => showProfileSharePreview(c, _bigProfile()), shareOverrides(net: net, out: out));
    expect(find.text('内容较多，以文件分享'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('share-code-copy')));
    await tester.pump();
    expect(out.copied, isEmpty, reason: 'no link yet');

    await tester.tap(find.byKey(const ValueKey('share-code-share')));
    await _settle(tester);
    expect(out.sharedFiles.single, endsWith('.dshgo'));

    await tester.tap(find.byKey(const ValueKey('share-code-gist')));
    await _settle(tester);
    await tester.enterText(find.byKey(const ValueKey('share-code-gist-token')), 'bad');
    await tester.tap(find.byKey(const ValueKey('share-code-gist-make')));
    await _settle(tester);
    expect(find.text('GitHub 令牌无效或没有 Gist 权限'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('share-code-gist-token')), 'good');
    await tester.tap(find.byKey(const ValueKey('share-code-gist-make')));
    await _settle(tester);
    expect(find.text('已生成 Gist 链接'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('share-code-copy')));
    await tester.pump();
    final link = ShareLink.parse(Uri.parse(out.copied.single))!;
    expect(link.isGist, isTrue);
    expect(net.created.single.$2, 'dsh-go-profile-20261024.dshgo');
    await _settle(tester);
  });

  group('a GitHub token being typed holds the profile sheet', () {
    const gist = ValueKey('share-code-gist');
    const token = ValueKey('share-code-gist-token');
    final sheet = find.byType(ProfileSharePreview);
    final handle = find.byType(SheetDragHandle);
    final ask = find.text('放弃修改？');

    Future<void> openSheet(WidgetTester tester, FakeShareNet net) => _pump(
      tester,
      (c) => showProfileSharePreview(c, _bigProfile()),
      shareOverrides(net: net, out: RecordingShareOut(cache)),
    );

    Future<void> drag(WidgetTester tester) async {
      await tester.fling(handle, const Offset(0, 300), 1500);
      await _settle(tester);
    }

    testWidgets('drag, scrim and back ask first; keeping it keeps the token', (tester) async {
      await openSheet(tester, sampleNet());
      await tester.tap(find.byKey(gist));
      await _settle(tester);
      await tester.enterText(find.byKey(token), 'ghp_typed');
      await tester.pump();
      String typed() => tester.widget<TextField>(find.byKey(token)).controller!.text;
      final rest = tester.getTopLeft(handle);

      await drag(tester);
      expect(ask, findsOneWidget, reason: 'a drag would have closed it');
      await tester.tap(find.text('继续编辑'));
      await _settle(tester);
      expect(sheet, findsOneWidget);
      expect(typed(), 'ghp_typed');
      expect(tester.getTopLeft(handle), rest, reason: 'the sheet springs back');

      // A drag on the content, not only on the handle.
      await tester.fling(find.byType(ShareHero), const Offset(0, 300), 1500);
      await _settle(tester);
      expect(ask, findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await _settle(tester);
      expect(typed(), 'ghp_typed');

      // A short, slow drag springs back without asking, as on any sheet.
      await tester.timedDrag(handle, const Offset(0, 40), const Duration(milliseconds: 600));
      await _settle(tester);
      expect(ask, findsNothing);
      expect(tester.getTopLeft(handle), rest);

      await tester.tapAt(const Offset(195, 40));
      await _settle(tester);
      expect(ask, findsOneWidget, reason: 'the scrim');
      await tester.tap(find.text('继续编辑'));
      await _settle(tester);
      expect(typed(), 'ghp_typed');

      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(ask, findsOneWidget, reason: 'system back');
      await tester.tap(find.text('放弃'));
      await _settle(tester);
      expect(sheet, findsNothing);
      expect(ask, findsNothing);
    });

    testWidgets('empty, folded or already used: a drag closes it at once', (tester) async {
      final net = sampleNet();
      await openSheet(tester, net);

      // Open but empty.
      await tester.tap(find.byKey(gist));
      await _settle(tester);
      await drag(tester);
      expect(ask, findsNothing);
      expect(sheet, findsNothing);

      // Typed, then folded away.
      await tester.tap(find.text('open'));
      await _settle(tester);
      await tester.tap(find.byKey(gist));
      await _settle(tester);
      await tester.enterText(find.byKey(token), 'ghp_typed');
      await tester.tap(find.byKey(gist));
      await _settle(tester);
      await drag(tester);
      expect(ask, findsNothing);
      expect(sheet, findsNothing);

      // Used for a Gist: the link is made and the token kept for the session.
      await tester.tap(find.text('open'));
      await _settle(tester);
      await tester.tap(find.byKey(gist));
      await _settle(tester);
      await tester.enterText(find.byKey(token), 'good');
      await tester.tap(find.byKey(const ValueKey('share-code-gist-make')));
      await _settle(tester);
      expect(find.text('已生成 Gist 链接'), findsOneWidget);
      await drag(tester);
      expect(ask, findsNothing);
      expect(sheet, findsNothing);

      // Next time the kept token is already in the field: nothing to lose.
      await tester.tap(find.text('open'));
      await _settle(tester);
      await tester.tap(find.byKey(gist));
      await _settle(tester);
      expect(tester.widget<TextField>(find.byKey(token)).controller!.text, 'good');
      await drag(tester);
      expect(ask, findsNothing);
      expect(sheet, findsNothing);
    });
  });

  testWidgets('安装插件: a changed package can not be installed', (tester) async {
    final engine = FakeEngine();
    final net = FakeShareNet()..npm['@acme/dsh-notes@1.4.2'] = const NpmFacts(integrity: 'sha512-OTHER');
    await _pump(
      tester,
      (c) => showShareImportSheet(c, const PluginShare(notesPlugin)),
      shareOverrides(net: net, targets: [localTarget(DshClient.withCarrier(engine))]),
    );
    expect(find.text('校验不一致'), findsOneWidget);
    expect(find.text('与分享时的版本不一致'), findsOneWidget);
    final button = tester.widget<FilledButton>(find.byKey(const ValueKey('share-import-primary')));
    expect(button.onPressed, isNull);
  });

  testWidgets('导入配置: switches choose what runs; another engine replans', (tester) async {
    final local = FakeEngine()
      ..addSettings('subagent', base: {'maxDepth': 1})
      ..addBundle('@acme/dsh-notes', version: '1.4.2', source: '@acme/dsh-notes@1.4.2');
    final remote = FakeEngine()..addSettings('subagent', base: {'maxDepth': 1});
    const profile = ProfileShare(
      settings: {
        'subagent': {'maxDepth': 3},
      },
      plugins: [notesPlugin],
      skills: [
        SharedSkill(name: 'weekly', files: {'SKILL.md': 'x'}),
      ],
    );
    final fs = await tester.runAsync(() async => tempGuest());
    addTearDown(() => fs!.root.parent.deleteSync(recursive: true));
    await _pump(
      tester,
      (c) => showShareImportSheet(c, profile),
      shareOverrides(
        net: sampleNet(),
        targets: [localTarget(DshClient.withCarrier(local)), remoteTarget(DshClient.withCarrier(remote))],
        fs: fs,
      ),
    );
    // Same version already there: shown, nothing to do.
    expect(find.textContaining('无需改动'), findsOneWidget);
    expect(find.text('导入 1 项'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('share-change-skill:weekly')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('share-change-skill:weekly')));
    await tester.pump();
    expect(find.text('导入 2 项'), findsOneWidget);

    await tester.ensureVisible(find.text('书房的 Mac · SSH'));
    await tester.pump();
    await tester.tap(find.text('书房的 Mac · SSH'));
    await _settle(tester);
    expect(find.text('只能导入到本机'), findsOneWidget);
    expect(find.text('导入 2 项'), findsOneWidget, reason: 'install + setting on the Mac');

    await tester.tap(find.byKey(const ValueKey('share-import-primary')));
    await _settle(tester);
    expect(remote.argsOf('pluginManager/installBundle').single['spec'], '@acme/dsh-notes@1.4.2');
    expect(remote.settings['subagent']!['user'], {'maxDepth': 3});
    expect(local.argsOf('pluginManager/installBundle'), isEmpty);
    expect(find.text('已导入 2 项'), findsOneWidget);
  });

  testWidgets('a damaged link says so instead of opening', (tester) async {
    final code = encodeShareCode(const PluginShare(notesPlugin));
    final broken = ShareLink.inline(ShareKind.plugin, '${code.substring(0, code.length - 12)}.${code.split('.').last}');
    await _pump(tester, (c) => openShareLink(c, broken), shareOverrides(net: sampleNet()));
    for (var i = 0; i < 100 && find.text('这个分享码不完整或已损坏').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(find.text('这个分享码不完整或已损坏'), findsOneWidget);
    expect(find.text('安装插件'), findsNothing);
  });

  testWidgets('geometry: four equal action cells, keys centred, edges mirrored', (tester) async {
    await _pump(
      tester,
      (c) => showSharePluginSheet(c, plugin: notesPlugin, card: notesEntry),
      shareOverrides(net: sampleNet(), out: RecordingShareOut(cache)),
    );
    const order = ['share-code-copy', 'share-code-qr', 'share-code-image', 'share-code-share'];
    final keys = [
      for (final k in order)
        tester.getRect(find.descendant(of: find.byKey(ValueKey(k)), matching: find.byType(DecoratedBox)).first),
    ];
    final cells = [for (final k in order) tester.getRect(find.byKey(ValueKey(k)))];
    final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    for (final (i, cell) in cells.indexed) {
      expect(cell.width, moreOrLessEquals(cells.first.width, epsilon: 0.01));
      expect(keys[i].width, ShareActionRow.keySize);
      expect(keys[i].center.dx, moreOrLessEquals(cell.center.dx, epsilon: 0.01));
      expect(keys[i].top, moreOrLessEquals(keys.first.top, epsilon: 0.01));
    }
    // Row spans the gutters; the outer keys sit equally far from the edges.
    expect(cells.first.left, moreOrLessEquals(20, epsilon: 0.01));
    expect(width - cells.last.right, moreOrLessEquals(20, epsilon: 0.01));
    expect(keys.first.left, moreOrLessEquals(width - keys.last.right, epsilon: 0.01));
  });

  testWidgets('geometry: the done buttons are equal halves, 12 apart, on the gutters', (tester) async {
    final engine = FakeEngine()..restartRequired = true;
    const profile = ProfileShare(plugins: [notesPlugin]);
    await _pump(
      tester,
      (c) => showShareImportSheet(c, profile),
      shareOverrides(net: sampleNet(), targets: [localTarget(DshClient.withCarrier(engine))]),
    );
    await tester.tap(find.byKey(const ValueKey('share-import-primary')));
    await _settle(tester);
    final done = tester.getRect(find.byKey(const ValueKey('share-import-done')));
    final restart = tester.getRect(find.byKey(const ValueKey('share-import-restart')));
    final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    expect(done.width, moreOrLessEquals(restart.width, epsilon: 0.01));
    expect(done.height, restart.height);
    expect(done.top, restart.top);
    expect(restart.left - done.right, moreOrLessEquals(12, epsilon: 0.01));
    expect(done.left, moreOrLessEquals(width - restart.right, epsilon: 0.01));
    expect(done.left, moreOrLessEquals(20, epsilon: 0.01));
  });
}
