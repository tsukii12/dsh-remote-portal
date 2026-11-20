import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/share_code/settings_sanitizer.dart';
import 'package:dsh_app/share_code/share_codec.dart';
import 'package:dsh_app/share_code/share_link.dart';
import 'package:dsh_app/share_code/share_models.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

const _plugin = SharedPlugin(
  name: '@acme/dsh-notes',
  source: PluginSourceKind.npm,
  spec: '@acme/dsh-notes@1.4.2',
  version: '1.4.2',
  integrity:
      'sha512-Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4Zm9vYg==',
  title: '读书笔记',
  author: 'Acme',
  summary: '把对话整理成读书笔记',
);

ProfileShare _profile() => ProfileShare(
  name: '写作配置',
  created: DateTime.utc(2026, 10, 24, 9),
  settings: {
    'subagent': {'maxDepth': 3},
    'agent-preset-registry': {'selectedDefault': 'writer'},
  },
  plugins: const [
    _plugin,
    SharedPlugin(name: 'dsh-writer', source: PluginSourceKind.github, spec: 'github:acme/dsh-writer#v2.0.0'),
    SharedPlugin(name: '@deepseek-ai/dsh-experimental-session-titles-bundle', source: PluginSourceKind.official),
  ],
  presets: const [SharedPreset(id: 'writer', name: '写作', bundle: 'dsh-writer')],
  skills: const [
    SharedSkill(name: 'outline', files: {'SKILL.md': '---\nname: outline\ndescription: 列提纲\n---\n先列提纲。'}),
  ],
  agentsMd: '回答用中文。',
);

void main() {
  group('codec', () {
    test('plugin and profile round-trip', () {
      final code = encodeShareCode(const PluginShare(_plugin));
      expect(code, matches(RegExp(r'^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]{8}$')));
      final back = decodeShareCode(code) as PluginShare;
      expect(back.plugin.toJson(), _plugin.toJson());

      final profile = decodeShareCode(encodeShareCode(_profile())) as ProfileShare;
      expect(profile.toJson(), _profile().toJson());
      expect(profile.plugins[1].repository, 'acme/dsh-writer');
      expect(profile.plugins[1].gitRef, 'v2.0.0');
      expect(profile.skills.single.files['SKILL.md'], contains('先列提纲'));
    });

    test('reads a code made by another implementation (zlib raw deflate + SHA-256)', () {
      // Made with Python's zlib / hashlib, as the landing page's JS reads it.
      const code =
          'q1YqU7Iy1FHKzsxLUbJSKsgpTc_MU9KBMayqlfISc1OBMg6Jybmp-inFGbp5-SWpxUAlxfmlRckgqbyCXBC3IDUZU52DoZ6JnhFQuiy1qDgzH2iiEkwkM68kNb0os6QSKFackWhqaKRrYuicmZadbpZqEVKZE1yQUhJSkOoT5ltYFuzkGlYVUlLiUeYa5GJuYqhdkBdl4ehXZmBgYOIb5GNiHOgd4JLjbZnsXuZXYOYXFR4V6pST5B4RWVGRl25rC7StJLMkB-TYF-t3P9m57PmaKS_WbQAKJ5aWZOQXAcUdgc5WeLp96ZO9c56uWwLyT2lubmIRyHHPurqert_5Yv3cZ1O3PJ_Q9qxjArIh7_f0POvpfL56wYuupqd7Jz1buFipthYA.5oqXnV13';
      final plugin = (decodeShareCode(code) as PluginShare).plugin;
      expect(plugin.spec, '@acme/dsh-notes@1.4.2');
      expect(plugin.title, '读书笔记');
    });

    test('a damaged or truncated code is refused', () {
      final code = encodeShareCode(_profile());
      final dot = code.indexOf('.');
      final flipped = '${code.substring(0, 5)}${code[5] == 'A' ? 'B' : 'A'}${code.substring(6)}';
      expect(() => decodeShareCode(flipped), throwsA(isA<ShareDecodeException>()));
      expect(
        () => decodeShareCode(code.substring(0, dot - 3) + code.substring(dot)),
        throwsA(isA<ShareDecodeException>()),
      );
      expect(() => decodeShareCode(code.substring(0, dot)), throwsA(isA<ShareDecodeException>()));
      expect(() => decodeShareCode('不是分享码'), throwsA(isA<ShareDecodeException>()));
    });

    test('a decompression bomb stops at the limit', () {
      final body = utf8.encode('{"v":1,"kind":"plugin","x":"${'0' * (maxShareBodyBytes + 10)}"}');
      final deflated = ZLibEncoder(raw: true).convert(body);
      final code = '${base64Url.encode(deflated).replaceAll('=', '')}.${shareChecksum(body)}';
      expect(code.length, lessThan(20000));
      expect(() => decodeShareCode(code), throwsA(isA<ShareDecodeException>()));
    });

    test('bodies from a newer app or of an unknown kind are refused', () {
      String encode(Map<String, Object?> json) {
        final body = utf8.encode(jsonEncode(json));
        return '${base64Url.encode(ZLibEncoder(raw: true).convert(body)).replaceAll('=', '')}.${shareChecksum(body)}';
      }

      expect(() => decodeShareCode(encode({'v': 2, 'kind': 'plugin'})), throwsA(isA<ShareFormatException>()));
      expect(() => decodeShareCode(encode({'v': 1, 'kind': 'theme'})), throwsA(isA<ShareFormatException>()));
    });

    test('a .dshgo file holds the code in a readable envelope', () {
      final text = encodeShareFile(_profile());
      final json = jsonDecode(text) as Map<String, Object?>;
      expect(json['dshgo'], 1);
      expect(json['kind'], 'profile');
      expect(json['name'], '写作配置');
      expect((decodeShareFile(text) as ProfileShare).name, '写作配置');
      // A bare code saved as a file works too.
      expect(decodeShareFile(encodeShareCode(const PluginShare(_plugin))), isA<PluginShare>());
      expect(() => decodeShareFile('{"hello": 1}'), throwsA(isA<ShareDecodeException>()));
    });
  });

  group('what a link may install', () {
    test('npm needs an exact name@version and a well-formed integrity', () {
      expect(SharedPlugin.fromJson(_plugin.toJson()).spec, '@acme/dsh-notes@1.4.2');
      for (final bad in [
        {..._plugin.toJson(), 'version': '^1.4.2'},
        {..._plugin.toJson(), 'spec': '@acme/dsh-notes@latest'},
        {..._plugin.toJson(), 'spec': '/home/me/dsh-notes'},
        {..._plugin.toJson(), 'integrity': 'md5-abc'},
        {..._plugin.toJson(), 'name': '../evil'},
      ]) {
        expect(() => SharedPlugin.fromJson(bad), throwsA(isA<ShareFormatException>()), reason: '$bad');
      }
    });

    test('git specs must be GitHub or https git; official bundles carry no spec', () {
      expect(
        SharedPlugin.fromJson({'name': 'x', 'source': 'github', 'spec': 'github:o/r#v1&path:/packages/x'}).repository,
        'o/r',
      );
      expect(
        SharedPlugin.fromJson({
          'name': 'x',
          'source': 'github',
          'spec': 'git+https://github.com/o/r.git#0123456789abcdef0123456789abcdef01234567',
        }).repository,
        'o/r',
      );
      expect(
        SharedPlugin.fromJson({'name': 'x', 'source': 'git', 'spec': 'git+https://gitee.com/o/r.git#v1'}).repository,
        'gitee.com',
      );
      for (final bad in [
        {'name': 'x', 'source': 'github', 'spec': 'git+https://gitee.com/o/r.git#v1'},
        {'name': 'x', 'source': 'git', 'spec': 'git+ssh://git@github.com/o/r.git#v1'},
        {'name': 'x', 'source': 'git', 'spec': 'git+http://example.com/o/r.git#v1'},
        {'name': 'x', 'source': 'official', 'spec': 'x@1.0.0'},
        {'name': 'x', 'source': 'tarball', 'spec': 'https://x/y.tgz'},
      ]) {
        expect(() => SharedPlugin.fromJson(bad), throwsA(isA<ShareFormatException>()), reason: '$bad');
      }
    });

    test('installed sources map to shareable specs, local ones to nothing', () {
      SharedPlugin? from(String? source, [String? version = '1.2.3']) =>
          SharedPlugin.fromInstalledSource(name: 'foo', source: source, version: version);
      expect(from('foo@^1.2.0')?.spec, 'foo@1.2.3');
      expect(from('foo')?.spec, 'foo@1.2.3');
      expect(from('npm:foo@~1.2.0')?.source, PluginSourceKind.npm);
      expect(from('github:o/r#v1')?.source, PluginSourceKind.github);
      expect(from('git+https://github.com/o/r.git#abc1234')?.source, PluginSourceKind.github);
      expect(from('git+https://gitee.com/o/r.git#abc1234')?.source, PluginSourceKind.git);
      expect(from('/data/plugins/foo'), isNull);
      expect(from('file:../foo'), isNull);
      expect(from('link:../foo'), isNull);
      expect(from('https://example.com/foo.tgz'), isNull);
      expect(from('foo@^1.2.0', null), isNull);
      expect(from(null), isNull);
    });

    test('skills keep to their folder', () {
      expect(SharedSkill.isSafePath('SKILL.md'), isTrue);
      expect(SharedSkill.isSafePath('scripts/run.sh'), isTrue);
      for (final bad in ['../x', 'a/../../x', '/etc/passwd', '.hidden', 'a/.git/config', '']) {
        expect(SharedSkill.isSafePath(bad), isFalse, reason: bad);
      }
      expect(
        () => SharedSkill.fromJson({
          'name': 'x',
          'files': {'notes.md': 'no skill file'},
        }),
        throwsA(isA<ShareFormatException>()),
      );
    });
  });

  group('links', () {
    test('app link and landing link carry the same code', () {
      final code = encodeShareCode(const PluginShare(_plugin));
      final link = ShareLink.inline(ShareKind.plugin, code);
      expect(link.appLink.toString(), 'dshgo://share/plugin?p=$code');
      expect(link.webLink, '$shareLandingUrl#p=$code');

      final fromApp = ShareLink.parse(link.appLink)!;
      expect(fromApp.kind, ShareKind.plugin);
      expect(fromApp.code, code);
      final fromWeb = ShareLink.parse(Uri.parse(link.webLink))!;
      expect(fromWeb.kind, isNull);
      expect(fromWeb.code, code);
      expect(ShareLink.parse(Uri.parse(link.webLink.replaceFirst('share/#', 'share/index.html#')))?.code, code);
      expect(ShareLink.parse(Uri.parse(link.webLink.replaceFirst('share/#', 'share#')))?.code, code);
    });

    test('gist links', () {
      const link = ShareLink.gist('aa5a315d61ae9438b18d', 'AbCdEf12');
      expect(link.appLink.toString(), 'dshgo://share/profile?gist=aa5a315d61ae9438b18d&c=AbCdEf12');
      final back = ShareLink.parse(Uri.parse(link.webLink))!;
      expect(back.gistId, 'aa5a315d61ae9438b18d');
      expect(back.gistSum, 'AbCdEf12');
      expect(ShareLink.parse(Uri.parse('dshgo://share/profile?gist=../../x&c=AbCdEf12')), isNull);
    });

    test('other hosts and links are not share links', () {
      expect(ShareLink.parse(Uri.parse('dshgo://forum/auth?p=a.b')), isNull);
      expect(ShareLink.parse(Uri.parse('https://evil.example/dsh-go/share/#p=a.b')), isNull);
      expect(ShareLink.parse(Uri.parse('dshgo://share/plugin')), isNull);
      expect(isLandingUri(Uri.parse('https://ccch1mneyyy.github.io/dsh-go/sharer/')), isFalse);
    });

    test('finds the link in a pasted message', () {
      final code = encodeShareCode(const PluginShare(_plugin));
      final text = '试试这个插件：$shareLandingUrl#p=$code 很好用';
      expect(ShareLink.find(text)?.code, code);
      expect(ShareLink.find('dshgo://share/plugin?p=$code\n')?.kind, ShareKind.plugin);
      expect(ShareLink.find('没有链接'), isNull);
    });
  });

  group('settings sanitizer', () {
    SettingsNamespaceView view(
      String ns,
      Map<String, Object?> user, {
      Object? schema,
      List<List<String>> secrets = const [],
    }) => SettingsNamespaceView.fromJson({
      'ns': ns,
      'schema': schema,
      'value': user,
      'user': user,
      'revision': 1,
      'secrets': [
        for (final s in secrets) {'path': s, 'set': true},
      ],
    });

    test('keeps ordinary values and credential references', () {
      final s = sanitizeNamespace(
        view('llm-deepseek', {
          'maxTokens': 8192,
          'apiKeyEnv': 'DEEPSEEK_API_KEY',
          'baseURL': 'https://api.deepseek.com',
          'models': ['deepseek-v4-pro'],
          'tokenLimit': 2,
        }),
      )!;
      expect(s.values.keys, ['maxTokens', 'apiKeyEnv', 'baseURL', 'models', 'tokenLimit']);
    });

    test('drops secrets, tokens, credentials in URLs and local paths', () {
      final s = sanitizeNamespace(
        view(
          'web-search-deepseek',
          {
            'apiKey': 'abc',
            'accessToken': 'x',
            'model': 'sk-1234567890abcdef1234567890abcdef',
            'endpoint': 'https://user:pass@example.com/v1',
            'callback': 'https://example.com/hook?token=abc',
            'customSkillDirs': ['/home/me/skills', '~/more'],
            'cacheDir': '/data/data/x',
            'headers': {'Authorization': 'Bearer abc', 'X-Api-Key': 'k'},
            'opaque': 'a8F3kQ9zL2mN7pR4sT6vW1xY5bC0dE8gH3jK6nP9',
            'maxUses': 5,
            'region': 'cn',
            'private': {'password': 'p'},
          },
          secrets: [
            ['apiKey'],
          ],
        ),
      )!;
      expect(s.values, {'maxUses': 5, 'region': 'cn'});
      expect(s.dropped, greaterThanOrEqualTo(10));
    });

    test('a credential-ref field keeps its name', () {
      final schema = {
        'type': 'object',
        'dict': {
          'credential': {
            'type': 'string',
            'meta': {'role': 'credential-ref'},
          },
          'secretValue': {
            'type': 'string',
            'meta': {'role': 'secret'},
          },
        },
      };
      final s = sanitizeNamespace(
        view('providers', {'credential': 'my-openrouter', 'secretValue': 'x'}, schema: schema),
      )!;
      expect(s.values, {'credential': 'my-openrouter'});
    });

    test('account, telemetry and network namespaces are never offered', () {
      for (final ns in ['ui-settings-account', 'desktop-product-telemetry', 'remote-access', 'credentials-local']) {
        expect(isShareableNamespace(ns), isFalse, reason: ns);
        expect(sanitizeNamespace(view(ns, {'a': 1})), isNull);
      }
      expect(isShareableNamespace('subagent'), isTrue);
      expect(isSecretFieldName('maxTokens'), isFalse);
      expect(isSecretFieldName('keyId'), isFalse);
      expect(isSecretFieldName('client_secret'), isTrue);
      expect(isSecretFieldName('key'), isTrue);
    });
  });
}
