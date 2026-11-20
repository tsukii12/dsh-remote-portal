import 'package:dsh_app/links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('dsh/links');

/// The native side pushing one arrival, as LinksPlugin.kt does.
Future<void> _nativeSends(WidgetTester tester, Map<String, Object?> args) async {
  final data = const StandardMethodCodec().encodeMethodCall(MethodCall('link', args));
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(_channel.name, data, (_) {});
}

void _fakeNative(WidgetTester tester, List<String> calls) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
    calls.add(call.method);
    return true;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null));
}

/// A router attached to a fake host context, collecting toasts.
class _Harness {
  _Harness(this.tester) : links = AppLinks() {
    router = LinkRouter(links.links);
  }

  final WidgetTester tester;
  final AppLinks links;
  late final LinkRouter router;
  final toasts = <String>[];

  Future<void> attach() async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    router.attach(tester.element(find.byType(SizedBox)), toast: toasts.add);
  }

  void dispose() {
    router.dispose();
    links.dispose();
  }
}

void main() {
  group('AppLinks', () {
    testWidgets('says ready and holds the cold-start link for the first listener, once', (tester) async {
      final calls = <String>[];
      _fakeNative(tester, calls);
      final links = AppLinks();
      addTearDown(links.dispose);
      await tester.pump();
      expect(calls, ['ready']);

      await _nativeSends(tester, {'uri': 'dshgo://share/plugin?p=abc'});
      final first = <Uri>[];
      final second = <Uri>[];
      links.links.listen(first.add);
      await tester.pump();
      links.links.listen(second.add);
      await tester.pump();
      expect(first, [Uri.parse('dshgo://share/plugin?p=abc')]);
      expect(second, isEmpty);

      await _nativeSends(tester, {'uri': 'dshgo://forum/auth?payload=x'});
      await tester.pump();
      expect(first.last.host, 'forum');
      expect(second.single.path, '/auth');
    });

    testWidgets('maps files and unreadable files', (tester) async {
      _fakeNative(tester, []);
      final links = AppLinks();
      addTearDown(links.dispose);
      final got = <Uri>[];
      links.links.listen(got.add);
      await _nativeSends(tester, {'uri': 'file:///cache/links/k1/团队配置.dshgo', 'name': '团队配置.dshgo'});
      await _nativeSends(tester, {'error': 'too_large', 'name': 'big.dshgo'});
      await _nativeSends(tester, {'nonsense': 1});
      await tester.pump();
      expect(got, hasLength(2));
      expect(got[0].pathSegments.last, '团队配置.dshgo');
      expect(got[1].scheme, AppLinks.unreadableScheme);
      expect(got[1].path, 'big.dshgo');
    });

    testWidgets('no native side is not an error', (tester) async {
      final links = AppLinks();
      addTearDown(links.dispose);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('LinkRouter', () {
    testWidgets('waits for the home shell, then routes by host and longest path prefix', (tester) async {
      final h = _Harness(tester);
      addTearDown(h.dispose);
      final seen = <String>[];
      h.router.registerLinkHandler('forum', (uri) async {
        seen.add('forum ${uri.path}');
        return true;
      });
      h.router.registerLinkHandler('forum/auth', (uri) async {
        seen.add('auth ${uri.queryParameters['payload']}');
        return true;
      });
      h.router.registerLinkHandler('Example.com/s', (uri) async {
        seen.add('web ${uri.fragment}');
        return true;
      });
      h.links.add(Uri.parse('dshgo://forum/auth?payload=p1'));
      h.links.add(Uri.parse('dshgo://forum/t/42'));
      h.links.add(Uri.parse('https://example.com/s#abc'));
      h.links.add(Uri.parse('dshgo://forum/authors'));
      await tester.pump();
      expect(seen, isEmpty, reason: 'nothing before LinkHost attaches');

      await h.attach();
      await tester.pump();
      expect(seen, ['auth p1', 'forum /t/42', 'web abc', 'forum /authors']);
      expect(h.toasts, isEmpty);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a cold-start link waits for a handler registered after attach', (tester) async {
      final h = _Harness(tester);
      addTearDown(h.dispose);
      h.links.add(Uri.parse('dshgo://forum/auth?payload=late'));
      await h.attach();
      await tester.pump(const Duration(seconds: 2));
      expect(h.toasts, isEmpty);
      Uri? got;
      h.router.registerLinkHandler('forum', (uri) async {
        got = uri;
        return true;
      });
      await tester.pump();
      expect(got?.queryParameters['payload'], 'late');
      await tester.pump(const Duration(seconds: 5));
      expect(h.toasts, isEmpty);
    });

    testWidgets('unhandled links get the toast after the grace window, then right away', (tester) async {
      final h = _Harness(tester);
      addTearDown(h.dispose);
      h.links.add(Uri.parse('dshgo://nobody/here'));
      await h.attach();
      await tester.pump(const Duration(seconds: 3));
      expect(h.toasts, isEmpty);
      await tester.pump(const Duration(seconds: 2));
      expect(h.toasts, ['无法打开这个链接']);

      h.links.add(Uri.parse('dshgo://nobody/again'));
      h.links.add(Uri.parse('mailto:a@b.c'));
      await tester.pump();
      expect(h.toasts, hasLength(3));
    });

    testWidgets('files go by extension; refused, throwing and unreadable count as unhandled', (tester) async {
      final h = _Harness(tester);
      addTearDown(h.dispose);
      final files = <String>[];
      h.router.registerFileHandler('.DSHGO', (uri) async {
        files.add(uri.pathSegments.last);
        return true;
      });
      h.router.registerLinkHandler('share', (uri) async => uri.path != '/refuse');
      final off = h.router.registerLinkHandler('share/boom', (uri) async => throw StateError('boom'));
      await h.attach();
      await tester.pump(const Duration(seconds: 5));

      h.links.add(Uri.parse('file:///c/links/k/Team.dshgo'));
      h.links.add(Uri(scheme: AppLinks.unreadableScheme, path: 'big.dshgo'));
      h.links.add(Uri.parse('file:///c/links/k/photo.png'));
      h.links.add(Uri.parse('dshgo://share/refuse'));
      h.links.add(Uri.parse('dshgo://share/boom'));
      // The unknown file type waits out the grace window (real time since attach is ~0 here).
      await tester.pump(const Duration(seconds: 5));
      expect(files, ['Team.dshgo']);
      expect(h.toasts, ['无法打开这个文件', '无法打开这个链接', '无法打开这个链接', '无法打开这个文件']);

      off();
      h.toasts.clear();
      expect(await h.router.open(Uri.parse('dshgo://share/boom')), isTrue);
      expect(h.toasts, isEmpty);
    });
  });

  testWidgets('LinkHost attaches under the home route and shows the toast', (tester) async {
    final links = AppLinks();
    final router = LinkRouter(links.links, grace: Duration.zero);
    addTearDown(() {
      router.dispose();
      links.dispose();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [linkRouterProvider.overrideWithValue(router)],
        child: const MaterialApp(home: Scaffold(body: LinkHost())),
      ),
    );
    await tester.pump();
    expect(router.context, isNotNull);
    links.add(Uri.parse('dshgo://unknown'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('无法打开这个链接'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    expect(router.context, isNull);
  });
}
