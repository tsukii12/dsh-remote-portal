import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

final _url = Uri.parse('https://api.dshfind.com/market/dsh-index.json');

const _commit = '0123456789abcdef0123456789abcdef01234567';

Map<String, Object?> _index(List<Object?> plugins, {Object? metadata}) => {
  'format': 1,
  'title': {'en': 'dshfind · DSH Plugin Directory', 'zh': 'dshfind · DSH 插件目录'},
  'description': {'en': 'Community plugins', 'zh': '社区插件'},
  'metadata':
      metadata ??
      {
        'categories': {
          'tools': {
            'title': {'en': 'Tools & Integrations', 'zh': '工具集成'},
          },
          'skin': {
            'title': {'en': 'Skins & Themes', 'zh': '皮肤主题'},
          },
        },
        'labels': {
          'featured': {
            'title': {'en': "Editor's pick", 'zh': '编辑推荐'},
          },
        },
        'sortKeys': {
          'stars': {
            'title': {'en': 'GitHub stars'},
            'order': 'desc',
          },
        },
      },
  'plugins': plugins,
};

Map<String, Object?> _npm(String version, {int ts = 1789469760, String? registry, String? engines}) => {
  'version': version,
  'publishTimestamp': ts,
  'source': {'type': 'npm', 'registry': ?registry},
  if (engines != null) 'engines': {'dsh': engines},
};

void main() {
  group('parseMarketIndex', () {
    test('reads a dshfind-shaped entry', () {
      final index = parseMarketIndex(
        _index([
          {
            'name': 'novel-writer',
            'title': 'novel-writer',
            'description': '小说创作模式：一个统筹队长统领全局',
            'icon': 'https://avatars.githubusercontent.com/sailoumili?s=96',
            'author': 'sailoumili',
            'homepage': 'https://dshfind.com/en/plugins/sailoumili/novel-writer',
            'repository': {'url': 'https://github.com/sailoumili/novel-writer'},
            'metadata': {
              'category': 'tools',
              'labels': ['featured'],
              'keywords': ['写作', 'novel'],
              'sortKeys': {'stars': 31},
            },
            'versions': [_npm('1.0.2')],
          },
        ]),
        _url,
      );
      expect(index.title.resolve('zh'), 'dshfind · DSH 插件目录');
      expect(index.description!.resolve(), '社区插件');
      expect(index.categories.keys, ['tools', 'skin']);
      expect(index.categories['tools']!.title.resolve(), '工具集成');
      expect(index.labels['featured']!.title.resolve(), '编辑推荐');
      expect(index.sortKeys['stars']!.descending, isTrue);
      expect(index.issues, isEmpty);

      final plugin = index.plugins.single;
      expect(plugin.name, 'novel-writer');
      expect(plugin.displayTitle(), 'novel-writer');
      expect(plugin.displayDescription(), startsWith('小说创作模式'));
      expect(plugin.icon, 'https://avatars.githubusercontent.com/sailoumili?s=96');
      expect(plugin.author, 'sailoumili');
      expect(plugin.repositoryUrl, 'https://github.com/sailoumili/novel-writer');
      expect(plugin.category, 'tools');
      expect(plugin.labels, ['featured']);
      expect(plugin.keywords, ['写作', 'novel']);
      expect(plugin.sortKeys, {'stars': 31});
      expect(plugin.latest.version, '1.0.2');
      expect(plugin.latest.published, DateTime.utc(2026, 9, 15, 10, 56));
      final target = plugin.latest.installTarget(plugin.name);
      expect(target.spec, 'novel-writer@1.0.2');
      expect(target.registry, isNull);
    });

    test('versions sort by SemVer precedence; install targets for npm registry and git', () {
      final index = parseMarketIndex(
        _index([
          {
            'name': '@scope/pkg',
            'title': {'en': 'Pkg', 'zh': '包'},
            'versions': [
              _npm('1.0.0-rc.1'),
              _npm('1.0.0', registry: 'https://registry.npmmirror.com/', engines: '>=0.2.1'),
              _npm('0.9.10'),
              _npm('1.0.0-rc.10'),
            ],
          },
          {
            'name': 'git-plugin',
            'versions': [
              {
                'version': '2.0.0',
                'publishTimestamp': 1,
                'source': {'type': 'git', 'url': 'https://github.com/a/b', 'commit': _commit, 'path': 'packages/p'},
              },
            ],
          },
        ]),
        _url,
      );
      final scoped = index.plugins[0];
      expect(scoped.versions.map((v) => v.version), ['1.0.0', '1.0.0-rc.10', '1.0.0-rc.1', '0.9.10']);
      expect(scoped.displayTitle('zh'), '包');
      expect(scoped.latest.enginesDsh, '>=0.2.1');
      final npm = scoped.latest.installTarget(scoped.name);
      expect(npm.spec, '@scope/pkg@1.0.0');
      expect(npm.registry, 'https://registry.npmmirror.com/');

      final git = index.plugins[1].latest.installTarget('git-plugin');
      expect(git.spec, 'git+https://github.com/a/b.git#$_commit&path:/packages/p');
      expect(git.registry, isNull);
      expect(index.plugins[1].latest.source, isA<MarketGitSource>());
    });

    test('bad entries are skipped, not fatal', () {
      final index = parseMarketIndex(
        _index([
          'not an object',
          {
            'name': 'Bad Name',
            'versions': [_npm('1.0.0')],
          },
          {'name': 'no-versions', 'versions': <Object?>[]},
          {
            'name': 'only-bad-versions',
            'versions': [
              _npm('^1.0.0'),
              {
                'version': '1.0.0',
                'publishTimestamp': -1,
                'source': {'type': 'npm'},
              },
              {
                'version': '1.0.1',
                'publishTimestamp': 1,
                'source': {'type': 'svn'},
              },
            ],
          },
          {
            'name': 'good',
            'icon': 'http://evil.example/icon.png',
            'homepage': 'ftp://x',
            'author': '   ',
            'title': {'zh': '只有中文'},
            'metadata': {
              'category': 'undeclared',
              'labels': ['featured', 'featured', 'nope'],
              'sortKeys': {'stars': 'many', 'unknown': 3},
              'keywords': ['ok', 3],
            },
            'versions': [_npm('not-semver'), _npm('1.2.3'), _npm('1.2.3')],
          },
          {
            'name': 'good',
            'versions': [_npm('9.9.9')],
          },
        ]),
        _url,
      );
      expect(index.plugins.map((p) => p.name), ['good']);
      final good = index.plugins.single;
      expect(good.icon, isNull, reason: 'cross-origin icons must be https');
      expect(good.homepage, isNull);
      expect(good.author, isNull);
      expect(good.title!.resolve('zh'), '只有中文', reason: 'plugin text is read leniently');
      expect(good.category, isNull);
      expect(good.labels, ['featured']);
      expect(good.sortKeys, isEmpty);
      expect(good.keywords, ['ok']);
      expect(good.versions.map((v) => v.version), ['1.2.3']);
      expect(index.issues.map((i) => i.path), contains(r'$.plugins[0]'));
      expect(index.issues.map((i) => i.path), contains(r'$.plugins[5].name'));
    });

    test('icons: relative same-origin, data URLs and size limit', () {
      final small = base64Encode(List<int>.filled(30, 1));
      final big = base64Encode(List<int>.filled(maxInlineIconBytes + 3, 1));
      final index = parseMarketIndex(
        _index([
          for (final (i, icon) in [
            'icons/a.png',
            'data:image/png;base64,$small',
            'data:image/png;base64,$big',
            'data:text/html;base64,$small',
            'javascript:alert(1)',
          ].indexed)
            {
              'name': 'p$i',
              'icon': icon,
              'versions': [_npm('1.0.0')],
            },
        ]),
        _url,
      );
      expect(index.plugins.map((p) => p.icon), [
        'https://api.dshfind.com/market/icons/a.png',
        'data:image/png;base64,$small',
        null,
        null,
        null,
      ]);
    });

    test('invalid metadata declarations are dropped individually', () {
      final index = parseMarketIndex(
        _index(
          [
            {
              'name': 'x',
              'metadata': {'category': 'b'},
              'versions': [_npm('1.0.0')],
            },
          ],
          metadata: {
            'categories': {
              'a': {
                'title': {'zh': 'no english'},
              },
              'b': {'title': 'B'},
            },
            'sortKeys': {
              's': {'title': 'S', 'order': 'sideways'},
            },
            'labels': 'nope',
          },
        ),
        _url,
      );
      expect(index.categories.keys, ['b']);
      expect(index.sortKeys, isEmpty);
      expect(index.labels, isEmpty);
      expect(index.plugins.single.category, 'b');
      expect(index.issues, hasLength(3));
    });

    test('only a non-index document is fatal', () {
      expect(() => parseMarketIndex([], _url), throwsA(isA<MarketIndexException>()));
      expect(() => parseMarketIndex({'format': 2, 'plugins': <Object?>[]}, _url), throwsA(isA<MarketIndexException>()));
      expect(() => parseMarketIndex({'format': 1}, _url), throwsA(isA<MarketIndexException>()));
      expect(() => parseMarketIndexText('<html>', _url), throwsA(isA<MarketIndexException>()));
      final untitled = parseMarketIndex({'format': 1, 'plugins': <Object?>[]}, _url);
      expect(untitled.title.resolve(), 'api.dshfind.com');
    });

    // A snapshot of the real dshfind index, when one was downloaded locally.
    final snapshot = Platform.environment['DSH_MARKET_INDEX_FILE'];
    test(
      'real index snapshot parses without dropping entries',
      skip: snapshot == null ? 'set DSH_MARKET_INDEX_FILE to a downloaded dsh-index.json' : null,
      () {
        final index = parseMarketIndexText(File(snapshot!).readAsStringSync(), _url);
        expect(index.issues, isEmpty);
        expect(index.plugins.length, greaterThan(1000));
      },
    );
  });

  group('compareSemver', () {
    test('follows SemVer 2.0.0 precedence', () {
      const ordered = [
        '1.0.0-alpha',
        '1.0.0-alpha.1',
        '1.0.0-alpha.beta',
        '1.0.0-beta',
        '1.0.0-beta.2',
        '1.0.0-beta.11',
        '1.0.0-rc.1',
        '1.0.0',
        '1.0.1',
        '1.10.0',
        '2.0.0',
      ];
      for (var i = 0; i < ordered.length - 1; i++) {
        expect(compareSemver(ordered[i], ordered[i + 1]), lessThan(0), reason: '${ordered[i]} < ${ordered[i + 1]}');
        expect(compareSemver(ordered[i + 1], ordered[i]), greaterThan(0));
      }
      expect(compareSemver('1.0.0+build.1', '1.0.0'), 0);
      expect(compareSemver('garbage', '0.0.1'), lessThan(0));
      expect(isExactSemver('1.2.3-rc.1+b'), isTrue);
      expect(isExactSemver('01.2.3'), isFalse);
    });
  });
}
