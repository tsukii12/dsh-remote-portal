import 'package:dsh_app/update/version.dart';
import 'package:flutter_test/flutter_test.dart';

AppVersion v(String s) => AppVersion.tryParse(s)!;

void main() {
  group('parse', () {
    test('release, tag prefix, missing patch, build, pre-release', () {
      expect(v('1.2.3').toString(), '1.2.3');
      expect(v('v1.2.3').name, '1.2.3');
      expect(v('1.2').name, '1.2.0');
      expect(v('1.2.0+7').build, 7);
      expect(v('1.2.0+7').name, '1.2.0');
      expect(v('1.3.0-beta.2').preRelease, ['beta', '2']);
      expect(v('1.3.0-beta.2+9').toString(), '1.3.0-beta.2+9');
      // Non-numeric build metadata is kept out of comparisons.
      expect(v('1.2.0+sha.abc').build, isNull);
    });

    test('rejects what is not a version', () {
      for (final bad in ['', '1', 'latest', 'v', '1.2.x', '1.2.0-', '1.2.0-beta..1', 'release-1.2.0']) {
        expect(AppVersion.tryParse(bad), isNull, reason: bad);
      }
      expect(AppVersion.tryParse(null), isNull);
    });
  });

  group('compare', () {
    test('numeric, not lexical', () {
      expect(v('1.10.0').isNewerThan(v('1.9.9')), isTrue);
      expect(v('2.0.0').isNewerThan(v('1.99.99')), isTrue);
      expect(v('1.0.10').isNewerThan(v('1.0.9')), isTrue);
      expect(v('1.0.0').isNewerThan(v('1.0.0')), isFalse);
    });

    test('a pre-release sorts before its release, semver identifier rules', () {
      final ordered = [
        '1.0.0-alpha',
        '1.0.0-alpha.1',
        '1.0.0-alpha.beta',
        '1.0.0-beta',
        '1.0.0-beta.2',
        '1.0.0-beta.11',
        '1.0.0-rc.1',
        '1.0.0',
        '1.0.1-beta.1',
      ].map(v).toList();
      for (var i = 0; i + 1 < ordered.length; i++) {
        expect(ordered[i + 1].isNewerThan(ordered[i]), isTrue, reason: '${ordered[i + 1]} > ${ordered[i]}');
        expect(ordered[i].isNewerThan(ordered[i + 1]), isFalse);
      }
    });

    test('build numbers break ties only when both sides have one', () {
      expect(v('1.2.0+8').isNewerThan(v('1.2.0+7')), isTrue);
      expect(v('1.2.0+7').isNewerThan(v('1.2.0+8')), isFalse);
      // A tag without a build is the same release as the installed 1.2.0+7.
      expect(v('v1.2.0').isNewerThan(v('1.2.0+7')), isFalse);
      expect(v('1.2.0+7').isNewerThan(v('1.2.0')), isFalse);
      // The version name still wins over the build number.
      expect(v('1.2.1+1').isNewerThan(v('1.2.0+99')), isTrue);
      expect(v('1.3.0-beta.1+50').isNewerThan(v('1.3.0+2')), isFalse);
    });

    test('withBuild attaches the native versionCode', () {
      expect(v('1.2.0').withBuild(7), v('1.2.0+7'));
      expect(v('1.2.0').withBuild(7).toString(), '1.2.0+7');
    });
  });

  // tooling/build-apk.sh stamps every build, dev or release, with the build
  // minute: (year - 2026) * 10^8 + MMDDhhmm. A dev build installed on the phone
  // is `X.Y.Z+<minute>` like any release.
  group('build-minute versionCodes', () {
    test('a release built after the installed dev build is offered, one built before is not', () {
      final dev = v('1.0.0').withBuild(10251234); // 2026-10-25 12:34
      expect(v('1.0.0+10301200').isNewerThan(dev), isTrue); // update.json carries the build
      expect(v('1.0.0+10201200').isNewerThan(dev), isFalse); // Android would refuse it as a downgrade
      expect(v('1.0.0+10251234').isNewerThan(dev), isFalse);
    });

    test('a big dev build number never hides a newer version name', () {
      final dev = v('1.0.0').withBuild(2012312359); // last minute of 2046
      expect(v('1.0.1+10251300').isNewerThan(dev), isTrue);
      expect(v('v1.1.0').isNewerThan(dev), isTrue);
      expect(v('1.1.0-beta.1').isNewerThan(dev), isTrue);
    });

    test('a GitHub tag without a build is the same release as any build of that name', () {
      expect(v('v1.0.0').isNewerThan(v('1.0.0').withBuild(10251234)), isFalse);
      expect(v('v1.0.0').isNewerThan(v('1.0.0').withBuild(1)), isFalse);
    });

    test('ordered across months and years, and above the old placeholder', () {
      final ordered = [
        '1.0.0+1', // every build before build-apk.sh
        '1.0.0+1010000', // 2026-01-01 00:00 (leading zero dropped)
        '1.0.0+9302359', // 2026-09-30 23:59
        '1.0.0+10251234', // 2026-10-25 12:34
        '1.0.0+12312359', // 2026-12-31 23:59
        '1.0.0+101010000', // 2027-01-01 00:00
        '1.0.0+2012312359', // 2046-12-31 23:59
      ].map(v).toList();
      for (var i = 0; i + 1 < ordered.length; i++) {
        expect(ordered[i + 1].isNewerThan(ordered[i]), isTrue, reason: '${ordered[i + 1]} > ${ordered[i]}');
      }
      expect(ordered.last.build, 2012312359);
      expect(ordered.last.toString(), '1.0.0+2012312359');
    });
  });
}
