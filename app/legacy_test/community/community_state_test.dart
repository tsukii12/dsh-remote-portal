// community.json: parsing and its guards, and where the hub's content comes
// from — bundled, cached, network (newer revisions only), source order.

import 'dart:io';

import 'package:dsh_app/state/community_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

final _sources = [
  CommunitySource('github', Uri.parse('https://raw.example/community.json')),
  CommunitySource('jsdelivr', Uri.parse('https://cdn.example/community.json')),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CommunityFeed.parse', () {
    test('reads every section and drops what it cannot use', () {
      final feed = CommunityFeed.parse(sampleFeed());
      expect(feed.revision, 7);
      expect(feed.tagline, '开源项目，欢迎点星');
      expect(feed.plugins.map((p) => p.name), ['novel-writer', 'dsh-approval-gate', 'not-in-the-index']);
      expect(feed.prompts, hasLength(4));
      expect(feed.prompts[1].prompt, '帮我解释这段报错：\n\n', reason: 'trailing blank lines kept for the paste');
      expect(feed.groups.map((g) => g.title), ['QQ 交流群', '微信公众号', 'Telegram'], reason: 'empty and http links dropped');
      expect(feed.groups[0].copy, '123456789');
      expect(feed.groups[1].qrData, 'https://example.com/wechat');
      expect(feed.groups[2].qrData, 'https://t.me/example', reason: 'the link is the QR by default');
      expect(feed.updates.last.url, 'https://example.com/releases');
    });

    test('the shipped file parses, and its unfilled groups stay hidden', () {
      final feed = CommunityFeed.parse(File('assets/community/community.json').readAsStringSync());
      expect(feed.revision, greaterThanOrEqualTo(1));
      expect(feed.plugins, isNotEmpty);
      expect(feed.prompts, hasLength(6));
      expect(feed.groups.map((g) => g.title), ['问题反馈']);
    });

    test('wrong schema, missing revision or bad JSON are refused', () {
      expect(() => CommunityFeed.parse('{"schema": 2, "revision": 1}'), throwsFormatException);
      expect(() => CommunityFeed.parse('{"schema": 1}'), throwsFormatException);
      expect(() => CommunityFeed.parse('[1, 2]'), throwsFormatException);
      expect(() => CommunityFeed.parse('{'), throwsFormatException);
    });

    test('bad package names, javascript: links and link-like QR codes on http are dropped', () {
      final feed = CommunityFeed.parse('''{
        "schema": 1, "revision": 1,
        "plugins": [{"name": "../evil"}, {"name": "@scope/ok-name"}],
        "groups": [
          {"title": "A", "url": "javascript:alert(1)"},
          {"title": "B", "qr": "http://plain.example"},
          {"title": "C", "qr": "加群请搜 12345"}
        ],
        "updates": [{"date": "not a date", "title": "x"}]
      }''');
      expect(feed.plugins.map((p) => p.name), ['@scope/ok-name']);
      expect(feed.groups.map((g) => g.title), ['C']);
      expect(feed.updates, isEmpty);
    });
  });

  group('CommunityController', () {
    late DateTime now;

    ProviderContainer container(ScriptedHttp http, {String? bundled}) {
      final c = ProviderContainer(
        overrides: [
          communityHttpProvider.overrideWithValue(http),
          communitySourcesProvider.overrideWithValue(_sources),
          communityBundleProvider.overrideWithValue(() async => bundled ?? sampleFeed(revision: 1, tagline: '内置')),
          communityClockProvider.overrideWithValue(() => now),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    Future<CommunityState> settled(ProviderContainer c) async {
      await c.read(communityProvider.future);
      for (var i = 0; i < 20 && (c.read(communityProvider).value?.refreshing ?? true); i++) {
        await Future<void>.delayed(Duration.zero);
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return c.read(communityProvider).value!;
    }

    setUp(() {
      now = DateTime(2026, 10, 24, 12);
      SharedPreferences.setMockInitialValues({});
    });

    test('offline: the bundled copy, and nothing breaks', () async {
      final http = ScriptedHttp({});
      final c = container(http);
      final state = await settled(c);
      expect(state.origin, CommunityOrigin.bundled);
      expect(state.feed.tagline, '内置');
      expect(http.asked, hasLength(2), reason: 'every source tried once');
    });

    test('a newer revision from the network replaces it and is cached', () async {
      final c = container(ScriptedHttp({'https://cdn.example/community.json': sampleFeed(revision: 9, tagline: '网络')}));
      final state = await settled(c);
      expect(state.origin, CommunityOrigin.network);
      expect(state.feed.revision, 9);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('community.source'), 'jsdelivr');
      expect(CommunityFeed.parse(prefs.getString('community.feed')!).revision, 9);

      // Next launch: the cache wins over the bundle, the working source goes first.
      final http = ScriptedHttp({'https://cdn.example/community.json': sampleFeed(revision: 9)});
      now = now.add(const Duration(hours: 7));
      final again = await settled(container(http));
      expect(again.feed.revision, 9);
      expect(http.asked.first.host, 'cdn.example');
    });

    test('a stale copy (older revision) never replaces a newer one', () async {
      SharedPreferences.setMockInitialValues({'community.feed': sampleFeed(revision: 12, tagline: '缓存')});
      final c = container(ScriptedHttp({'https://raw.example/community.json': sampleFeed(revision: 10, tagline: '旧')}));
      final state = await settled(c);
      expect(state.feed.tagline, '缓存');
      expect(state.origin, CommunityOrigin.cached);
    });

    test('a broken answer falls through to the next source', () async {
      final c = container(
        ScriptedHttp({
          'https://raw.example/community.json': '<html>blocked</html>',
          'https://cdn.example/community.json': sampleFeed(revision: 3, tagline: '第二个源'),
        }),
      );
      expect((await settled(c)).feed.tagline, '第二个源');
    });

    test('asks at most every six hours', () async {
      SharedPreferences.setMockInitialValues({
        'community.fetchedAt': now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
      });
      final http = ScriptedHttp({'https://raw.example/community.json': sampleFeed(revision: 99)});
      final state = await settled(container(http));
      expect(http.asked, isEmpty);
      expect(state.feed.revision, 1);
    });
  });
}
