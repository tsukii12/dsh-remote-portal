// DSHDLT01 patches: built against synthetic APKs bigger than the applier's
// buffers, and refused for any patch that isn't exactly one from this base to
// this target.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dsh_app/update/delta.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('dsh_delta'));
  tearDown(() => dir.deleteSync(recursive: true));

  final random = Random(7);
  List<int> noise(int length) => [for (var i = 0; i < length; i++) random.nextInt(256)];

  // 300 KiB base; the target keeps most of it, moved around, plus new bytes.
  final base = noise(300 << 10);
  final fresh = noise(90 << 10);
  final target = [...base.sublist(0, 100 << 10), ...fresh, ...base.sublist(150 << 10), ...base.sublist(10, 20)];
  final ops = [deltaCopy(0, 100 << 10), deltaData(fresh), deltaCopy(150 << 10, 150 << 10), deltaCopy(10, 10), deltaEnd];

  File write(String name, List<int> bytes) => File('${dir.path}/$name')..writeAsBytesSync(bytes);
  File out() => File('${dir.path}/out.apk');

  void apply(List<int> patch, {String? baseSha, String? targetSha, int? size}) => DeltaPatch.apply(
    base: write('base.apk', base),
    patch: write('p.dshdlt', patch),
    out: out(),
    baseSha256: baseSha ?? sha256.convert(base).toString(),
    targetSha256: targetSha ?? sha256.convert(target).toString(),
    targetSize: size ?? target.length,
  );

  test('builds the target from the base, through more than one buffer of each', () {
    final patch = deltaPatch(base, target, ops);
    apply(patch);
    expect(out().readAsBytesSync(), target);
    expect(patch.length, lessThan(target.length ~/ 3));
  });

  test('off the UI isolate, the same', () async {
    await applyDeltaPatch(
      base: write('base.apk', base),
      patch: write('p.dshdlt', deltaPatch(base, target, ops)),
      out: out(),
      baseSha256: sha256.convert(base).toString(),
      targetSha256: sha256.convert(target).toString(),
    );
    expect(out().readAsBytesSync(), target);
  });

  test('a patch for another base APK is refused before anything is written', () {
    final other = noise(1000);
    expect(() => apply(deltaPatch(other, target, ops)), throwsFormatException);
    expect(out().existsSync(), isFalse);
    // The patch names this base, but the one installed is another.
    expect(
      () => apply(deltaPatch(base, target, ops), baseSha: sha256.convert(other).toString()),
      throwsFormatException,
    );
    expect(out().existsSync(), isFalse);
  });

  test('a patch cut short anywhere is refused, and what it wrote is gone', () {
    final patch = deltaPatch(base, target, ops);
    for (final cut in [0, 7, 79, 80, 85, patch.length ~/ 2, patch.length - 1]) {
      out().writeAsStringSync('stale');
      expect(() => apply(patch.sublist(0, cut)), throwsFormatException, reason: 'cut at $cut');
      expect(out().existsSync(), isFalse, reason: 'cut at $cut');
    }
    expect(() => apply([...utf8.encode('DSHDLT02'), ...patch.sublist(8)]), throwsFormatException);
  });

  test('a target other than the manifest\'s is refused: named so, or built so', () {
    // The header names another target.
    final wrong = [...target];
    wrong[5] ^= 1;
    expect(() => apply(deltaPatch(base, wrong, ops)), throwsFormatException);
    // The header names this target, but the ops build something else.
    final off = [deltaCopy(0, 100 << 10), deltaData(noise(90 << 10)), ...ops.skip(2)];
    expect(() => apply(deltaPatch(base, target, off)), throwsFormatException);
    expect(out().existsSync(), isFalse);
  });

  test('the target length: declared, never overrun, exactly reached', () {
    expect(() => apply(deltaPatch(base, target, ops), size: target.length + 1), throwsFormatException);
    expect(
      () => apply(
        deltaPatch(base, target, [
          ...ops.take(4),
          deltaData([1]),
          deltaEnd,
        ]),
      ),
      throwsFormatException,
    );
    expect(() => apply(deltaPatch(base, target, [...ops.take(3), deltaEnd])), throwsFormatException);
    expect(out().existsSync(), isFalse);
  });

  test('COPY past the base, unknown ops and lengths out of range are refused', () {
    expect(() => apply(deltaPatch(base, target, [deltaCopy(base.length - 4, 8), deltaEnd])), throwsFormatException);
    expect(
      () => apply(
        deltaPatch(base, target, [
          ...ops.take(1),
          [0x03],
          deltaEnd,
        ]),
      ),
      throwsFormatException,
    );
    final huge = [0x02, 0xff, 0, 0, 0, 0, 0, 0, 0];
    expect(() => apply(deltaPatch(base, target, [huge, deltaEnd])), throwsFormatException);
    expect(out().existsSync(), isFalse);
  });
}
