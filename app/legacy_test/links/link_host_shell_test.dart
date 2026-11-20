// A link that cold-starts the app reaches its feature through the real home
// shell (LinkHost lives in its stack), with the native side faked the way
// LinksPlugin.kt behaves: arrivals held until Dart says `ready`.

import 'dart:io';

import 'package:dsh_app/links/app_links.dart';
import 'package:dsh_app/share_code/guest_fs.dart';
import 'package:dsh_app/share_code/share_code_state.dart';
import 'package:dsh_app/share_code/share_codec.dart';
import 'package:dsh_app/share_code/share_import.dart';
import 'package:dsh_app/share_code/share_link.dart';
import 'package:dsh_app/share_code/share_models.dart';
import 'package:dsh_app/share_code/share_net.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../share_code/support/fake_engine.dart';
import '../shell/golden_harness.dart';

const _channel = MethodChannel('dsh/links');

const _plugin = SharedPlugin(
  name: 'dsh-notes',
  source: PluginSourceKind.npm,
  spec: 'dsh-notes@1.4.2',
  version: '1.4.2',
  title: '读书笔记',
  summary: '把对话整理成读书笔记',
);

List<Override> _shareOverrides(FakeEngine engine) => [
  importTargetsProvider.overrideWithValue([
    ImportTarget(HostConnection(hostId: '', client: DshClient.withCarrier(engine), label: '本机', isLocal: true), isActive: false),
  ]),
  shareNetProvider.overrideWithValue(FakeShareNet()),
  guestFsProvider.overrideWith((ref) async => null),
];

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 200 && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(finder, findsOneWidget);
  expect(tester.takeException(), isNull);
}

/// Holds arrivals until `ready`, then pushes them as `link` calls.
class _FakeLinksNative {
  _FakeLinksNative(this.tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      if (call.method != 'ready') return null;
      readyCalls++;
      _ready = true;
      final held = List.of(_held);
      _held.clear();
      Future<void>.microtask(() async {
        for (final event in held) {
          await _push(event);
        }
      });
      return true;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null));
  }

  final WidgetTester tester;
  final _held = <Map<String, Object?>>[];
  bool _ready = false;
  int readyCalls = 0;

  Future<void> arrive(String uri) async {
    final event = {'uri': uri};
    if (_ready) {
      await _push(event);
    } else {
      _held.add(event);
    }
  }

  Future<void> _push(Map<String, Object?> event) => tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    _channel.name,
    const StandardMethodCodec().encodeMethodCall(MethodCall('link', event)),
    (_) {},
  );
}

Widget _shell({List<Override> extra = const []}) => ProviderScope(
  overrides: [
    ...extra,
    networkKicksProvider.overrideWithValue(const Stream.empty()),
    localRuntimeProvider.overrideWith(() => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus))),
    sessionsProvider.overrideWith(() => FakeSessions(const [])),
  ],
  child: MaterialApp(
    theme: buildLightTheme(),
    home: HomeShell(chatBuilder: (_) => const SizedBox.expand()),
  ),
);

void main() {
  testWidgets('a cold-start dshgo:// link reaches a handler a feature registers at startup', (tester) async {
    final native = _FakeLinksNative(tester);
    // The intent that launched the app, before Flutter draws anything.
    await native.arrive('dshgo://demo/hello?payload=cold');

    await tester.pumpWidget(_shell());
    await tester.pump();
    expect(native.readyCalls, 1);

    // A feature registering a moment later, as a startup provider would.
    final container = ProviderScope.containerOf(tester.element(find.byType(HomeShell)));
    final got = <Uri>[];
    await tester.pump(const Duration(seconds: 1));
    container.read(linkRouterProvider).registerLinkHandler('demo/hello', (uri) async {
      got.add(uri);
      return true;
    });
    await tester.pump();
    expect(got.single.queryParameters['payload'], 'cold');

    // Later links while the app runs (onNewIntent) go straight through, once.
    await native.arrive('dshgo://demo/hello?payload=warm');
    await tester.pump();
    expect(got.map((u) => u.queryParameters['payload']), ['cold', 'warm']);
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('无法打开这个链接'), findsNothing);
  });

  testWidgets('a cold-start dshgo://share/plugin link opens the install sheet', (tester) async {
    final native = _FakeLinksNative(tester);
    final link = ShareLink.inline(ShareKind.plugin, encodeShareCode(const PluginShare(_plugin)));
    await native.arrive(link.appLink.toString());

    final engine = FakeEngine();
    await tester.pumpWidget(_shell(extra: _shareOverrides(engine)));
    await _waitFor(tester, find.text('安装插件'));
    expect(find.text('读书笔记'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('安装'), findsOneWidget);
    expect(find.text('无法打开这个链接'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('share-import-primary')));
    await tester.pumpAndSettle();
    expect(engine.argsOf('pluginManager/installBundle').single['spec'], 'dsh-notes@1.4.2');
    expect(find.text('已完成'), findsOneWidget);
  });

  testWidgets('a cold-start file with spaces and Unicode opens and installs', (tester) async {
    final dir = Directory.systemTemp.createTempSync('share-links-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/团队 配置.dshgo')..writeAsStringSync(encodeShareFile(const PluginShare(_plugin)));
    final native = _FakeLinksNative(tester);
    await native.arrive(file.uri.toString());
    final engine = FakeEngine();
    await tester.pumpWidget(_shell(extra: _shareOverrides(engine)));
    await _waitFor(tester, find.text('安装插件'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('share-import-primary')));
    await _waitFor(tester, find.text('已完成'));
    expect(engine.argsOf('pluginManager/installBundle').single['spec'], 'dsh-notes@1.4.2');
    expect(tester.takeException(), isNull);
  });

  for (final kind in ['oversize', 'damaged', 'missing']) {
    testWidgets('a running shell handles a $kind share file without a generic error', (tester) async {
      final dir = Directory.systemTemp.createTempSync('share-links-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/$kind.dshgo');
      if (kind != 'missing') {
        file.writeAsStringSync(kind == 'oversize' ? 'x' * (maxShareCodeChars * 2 + 1) : '{"code":"broken"}');
      }
      final native = _FakeLinksNative(tester);
      await tester.pumpWidget(_shell(extra: _shareOverrides(FakeEngine())));
      await tester.pump();
      await native.arrive(file.uri.toString());
      await _waitFor(tester, find.text(kind == 'missing' ? '没能读取这个文件' : '这个分享码不完整或已损坏'));
      expect(find.text('安装插件'), findsNothing);
      expect(find.text('导入配置'), findsNothing);
      expect(find.text('无法打开这个文件'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the landing web link opens through the registered router', (tester) async {
    final native = _FakeLinksNative(tester);
    final link = ShareLink.inline(ShareKind.plugin, encodeShareCode(const PluginShare(_plugin)));
    await native.arrive(link.webLink.toString());
    await tester.pumpWidget(_shell(extra: _shareOverrides(FakeEngine())));
    await _waitFor(tester, find.text('安装插件'));
  });

  testWidgets('the home shell without links leaves no timers or errors behind', (tester) async {
    await tester.pumpWidget(_shell());
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  });
}
