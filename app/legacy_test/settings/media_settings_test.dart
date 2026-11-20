// 设置 › 能力 › 图像与视频 (media-generation §5.8, M6 first version): indexed
// with its synonyms, a hub row, the plugin's own form when the host has it,
// 「在此主机上安装」 when it doesn't.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/media_generation.dart';
import 'package:dsh_app/ui/engine_settings/engine_settings_page.dart' show curatedNamespaces;
import 'package:dsh_app/ui/settings/index/spots.dart';
import 'package:dsh_app/ui/settings/media_settings_page.dart';
import 'package:dsh_app/ui/settings/search/settings_search.dart';
import 'package:flutter_test/flutter_test.dart';

import '../engine_settings/support.dart';

final _zh = lookupL10n(AppLocale.zhCN);
final _en = lookupL10n(AppLocale.en);

void main() {
  test('it sits in 能力, after 联网搜索, and opens from dshgo://open/media', () {
    final page = SettingsIndex.page(SettingsPageId.media);
    expect(page.title(_zh), '图像与视频');
    expect(page.group!(_zh), '能力');
    expect(SettingsIndex.pageForLink('media')?.id, SettingsPageId.media);
    final hub = SettingsIndex.on(SettingsPageId.hub).where((s) => s.group?.call(_zh) == '能力').map((s) => s.id).toList();
    expect(hub.indexOf('page:media'), hub.indexOf('page:webSearch') + 1);
  });

  for (final word in ['生图', '画图', '文生图', '视频生成', 'AI 绘画', 'image generation']) {
    test('search finds it by 「$word」', () {
      final hits = searchSettings(word, spots: SettingsIndex.spots, features: const [], zh: _zh, en: _en);
      expect(hits.first.spot?.id, 'page:media', reason: word);
    });
  }

  testWidgets('no plugin on the host: 在此主机上安装', (tester) async {
    final client = await fakeClient(FakeSettingsHost());
    await pumpPage(
      tester,
      const MediaSettingsPage(),
      overrides: [...engineOverrides(client), mediaPluginProvider.overrideWithValue(MediaPluginState.absent)],
    );
    expect(find.text('这台主机还没有图像与视频插件'), findsOneWidget);
    expect(find.text('在此主机上安装'), findsOneWidget);
  });

  testWidgets('with the plugin: the curated page, with a word for a missing catalogue', (tester) async {
    final describe = recordedDescribe();
    final namespaces = [
      ...(describe['namespaces']! as List),
      {
        'ns': 'dsh-media',
        'schema': {
          'type': 'object',
          'meta': {},
          'dict': {
            'defaultImageModel': {
              'type': 'string',
              'meta': {'description': 'Default image model', 'default': 'doubao-seedream-5-0-pro'},
            },
          },
        },
        'value': {'defaultImageModel': 'doubao-seedream-5-0-pro', 'catalog': <Object?>[]},
        'revision': 1,
      },
    ];
    final client = await fakeClient(FakeSettingsHost(describe: {...describe, 'namespaces': namespaces}));
    await pumpPage(
      tester,
      const MediaSettingsPage(),
      overrides: [...engineOverrides(client), mediaPluginProvider.overrideWithValue(MediaPluginState.ready)],
    );
    // The plugin's namespace is there but its schema carries no catalogue:
    // the curated page still renders and says why nothing can be added.
    expect(find.text('图像与视频'), findsWidgets);
    expect(find.text('在此主机上安装'), findsNothing);
    expect(find.text(_zh.mediaSettingsCatalogMissing), findsOneWidget);
  });

  testWidgets('an instance the host renamed: found by its catalogue, the curated page shown', (tester) async {
    final describe = recordedDescribe();
    final m0 = jsonDecode(File('test/media/fixtures/settings_describe_media_m0.json').readAsStringSync()) as Map;
    final media = Map<String, Object?>.of(((m0['namespaces'] as List).single as Map).cast<String, Object?>())
      ..['ns'] = 'media-lab';
    final client = await fakeClient(
      FakeSettingsHost(
        describe: {
          ...describe,
          'namespaces': [...(describe['namespaces']! as List), media],
        },
      ),
    );
    await pumpPage(
      tester,
      const MediaSettingsPage(),
      overrides: [...engineOverrides(client), mediaPluginProvider.overrideWithValue(MediaPluginState.ready)],
    );
    // The host renamed the namespace; the catalogue finds it and the page
    // shows the service that catalogue carries (0.2.1, no video models).
    expect(find.text('办公室'), findsOneWidget);
    expect(find.text('图像与视频'), findsWidgets);
    // The M0 schema has one general default pair, not the 0.3 image/video
    // pairs: the page offers the shape that host has.
    expect(find.text(_zh.mediaSettingsDefaultModel), findsOneWidget);
    expect(find.text(_zh.mediaSettingsDefaultFooterLegacy), findsOneWidget);
  });

  test('the plugin\'s namespace has this page, not a second generic one', () {
    expect(curatedNamespaces, containsAll(mediaSettingsNamespaces));
  });
}
