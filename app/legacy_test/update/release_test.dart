import 'dart:convert';

import 'package:dsh_app/update/release.dart';
import 'package:dsh_app/update/version.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  group('GitHub releases/latest', () {
    final release = parseGithubRelease(jsonDecode(fixture('github_release.json')));

    test('version, notes, page, date', () {
      expect(release.version.name, '1.2.0');
      expect(release.tag, 'v1.2.0');
      expect(release.title, 'DSH 1.2.0');
      expect(release.notes, startsWith('## 新功能\n\n- 应用内更新'));
      expect(release.notes, isNot(contains('\r')));
      expect(release.publishedAt, DateTime.utc(2026, 11, 1, 8));
      expect(release.pageUrl.toString(), 'https://github.com/ccch1mneyyy/dsh-go/releases/tag/v1.2.0');
      expect(release.checksumsUrl.toString(), endsWith('/v1.2.0/SHA256SUMS'));
    });

    test('picks the APK for each flavor; digest becomes the checksum', () {
      final arm = release.apkFor(ApkFlavor.arm64)!;
      expect(arm.name, 'dsh-go-1.2.0-arm64.apk');
      expect(arm.size, 180107933);
      expect(arm.sha256, '3a8498bcf7d895bac5c9f2f02829c9ec7064cd8bc7ef9f1792f28277d44839f2');
      expect(
        arm.url.toString(),
        'https://github.com/ccch1mneyyy/dsh-go/releases/download/v1.2.0/dsh-go-1.2.0-arm64.apk',
      );
      final x64 = release.apkFor(ApkFlavor.x64)!;
      expect(x64.name, 'dsh-go-1.2.0-x64.apk');
      expect(x64.sha256, isNull, reason: 'no digest: resolved from SHA256SUMS at download time');
      expect(release.apkFor(null), isNull);
      // update.json and SHA256SUMS are not APKs.
      expect(release.apks, hasLength(2));
    });

    test('a release without this flavor has no asset for it', () {
      final json = jsonDecode(fixture('github_release.json')) as Map<String, Object?>;
      json['assets'] = (json['assets']! as List).where((a) => !(a as Map)['name'].toString().contains('x64')).toList();
      final armOnly = parseGithubRelease(json);
      expect(armOnly.apkFor(ApkFlavor.arm64), isNotNull);
      expect(armOnly.apkFor(ApkFlavor.x64), isNull);
    });

    test('drafts, odd tags and non-objects are refused', () {
      final json = jsonDecode(fixture('github_release.json')) as Map<String, Object?>;
      expect(() => parseGithubRelease({...json, 'draft': true}), throwsFormatException);
      expect(() => parseGithubRelease({...json, 'tag_name': 'nightly'}), throwsFormatException);
      expect(() => parseGithubRelease([]), throwsFormatException);
      expect(() => parseGithubRelease(null), throwsFormatException);
      // GitHub's 404 body.
      expect(() => parseGithubRelease({'message': 'Not Found', 'status': '404'}), throwsFormatException);
    });
  });

  group('update.json', () {
    test('reads the release script output; URLs default to the tag', () {
      final release = parseUpdateManifest(jsonDecode(fixture('update.json')));
      expect(release.version.toString(), '1.2.0+7');
      expect(release.tag, 'v1.2.0');
      expect(release.notes, contains('应用内更新'));
      final arm = release.apkFor(ApkFlavor.arm64)!;
      expect(
        arm.url.toString(),
        'https://github.com/ccch1mneyyy/dsh-go/releases/download/v1.2.0/dsh-go-1.2.0-arm64.apk',
      );
      expect(arm.sha256, hasLength(64));
      expect(arm.size, 14);
    });

    test('relative asset URLs resolve against the feed', () {
      final release = parseUpdateManifest({
        'version': '1.3.0',
        'assets': {
          'arm64': {'name': 'a.apk', 'url': 'files/a.apk', 'sha256': 'A' * 64},
          'x64': {'url': 'https://cdn.example.com/x.apk'},
          'riscv': {'name': 'r.apk'},
        },
      }, base: Uri.parse('https://update.example.com/dsh/update.json'));
      expect(release.tag, 'v1.3.0');
      expect(release.apkFor(ApkFlavor.arm64)!.url.toString(), 'https://update.example.com/dsh/files/a.apk');
      expect(release.apkFor(ApkFlavor.arm64)!.sha256, 'a' * 64);
      expect(release.apkFor(ApkFlavor.x64)!.name, 'dsh-go-1.3.0-x64.apk');
      expect(release.apkFor(ApkFlavor.x64)!.url.host, 'cdn.example.com');
      expect(release.apks, hasLength(2));
    });

    test('round-trips through toManifestJson (the cached offer)', () {
      final original = parseGithubRelease(jsonDecode(fixture('github_release.json')));
      final copy = parseUpdateManifest(jsonDecode(jsonEncode(original.toManifestJson())));
      expect(copy.version, original.version);
      expect(copy.tag, original.tag);
      expect(copy.notes, original.notes);
      expect(copy.publishedAt, original.publishedAt);
      expect(copy.pageUrl, original.pageUrl);
      for (final flavor in ApkFlavor.values) {
        expect(copy.apkFor(flavor)!.url, original.apkFor(flavor)!.url);
        expect(copy.apkFor(flavor)!.size, original.apkFor(flavor)!.size);
        expect(copy.apkFor(flavor)!.sha256, original.apkFor(flavor)!.sha256);
      }
    });

    test('assets named to climb out of the download directory are left out', () {
      final release = parseUpdateManifest({
        'version': '1.2.0',
        'assets': {
          'arm64': {'name': '../../shared_prefs/x.xml', 'url': 'https://dl.example.com/x', 'sha256': 'a' * 64},
          'x64': {'name': '.hidden', 'url': 'https://dl.example.com/x', 'sha256': 'a' * 64},
        },
      });
      expect(release.apks, isEmpty);
    });

    test('future schemas and bad versions are refused', () {
      expect(() => parseUpdateManifest({'schema': 2, 'version': '1.0.0'}), throwsFormatException);
      expect(() => parseUpdateManifest({'version': 'soon'}), throwsFormatException);
      expect(() => parseUpdateManifest('<html>'), throwsFormatException);
    });
  });

  group('names and checksums', () {
    test('asset name follows the convention, without the build number', () {
      final version = AppVersion.tryParse('1.3.0-beta.2+40')!;
      expect(apkAssetName(version, ApkFlavor.arm64), 'dsh-go-1.3.0-beta.2-arm64.apk');
      expect(apkAssetName(version, ApkFlavor.x64), 'dsh-go-1.3.0-beta.2-x64.apk');
    });

    test('flavor from appFlavor or the native ABI', () {
      expect(ApkFlavor.fromName('arm64'), ApkFlavor.arm64);
      expect(ApkFlavor.fromName('x64'), ApkFlavor.x64);
      expect(ApkFlavor.fromName(null), isNull);
      expect(ApkFlavor.fromAbi('arm64'), ApkFlavor.arm64);
      expect(ApkFlavor.fromAbi('arm64-v8a'), ApkFlavor.arm64);
      expect(ApkFlavor.fromAbi('x86_64'), ApkFlavor.x64);
      expect(ApkFlavor.fromAbi('armeabi-v7a'), isNull);
    });

    test('SHA256SUMS in text and binary mode; digest prefixes', () {
      final sums = parseSha256Sums(
        '${'A' * 64}  dsh-go-1.2.0-arm64.apk\n'
        '${'b' * 64} *dsh-go-1.2.0-x64.apk\r\n'
        'garbage line\n',
      );
      expect(sums, {'dsh-go-1.2.0-arm64.apk': 'a' * 64, 'dsh-go-1.2.0-x64.apk': 'b' * 64});
      expect(normalizeSha256('sha256:${'C' * 64}'), 'c' * 64);
      expect(normalizeSha256('sha1:abc'), isNull);
      expect(normalizeSha256(null), isNull);
    });
  });
}
