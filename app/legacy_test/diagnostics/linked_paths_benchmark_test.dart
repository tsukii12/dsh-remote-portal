import 'dart:convert';

import 'package:dsh_app/state/artifacts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('actual linkedPaths finite benchmark, output and growability', () {
    for (final n in [100, 1000, 4000]) {
      for (final mixed in [false, true]) {
        final markdown = StringBuffer();
        final expected = <String>[];
        for (var i = 0; i < n; i++) {
          markdown.write('[report $i](reports/item-$i.pdf) ');
          expected.add('/work/reports/item-$i.pdf');
          if (mixed) {
            markdown.write('[again](reports/item-$i.pdf) [web](https://example.invalid/$i.pdf) [anchor](#item-$i) ');
          }
        }
        final input = markdown.toString();
        var result = linkedPaths(input, cwd: '/work');
        expect(result, expected);
        result.add('/temporary-check');
        result.removeLast();
        expect(result, expected);
        for (var i = 0; i < 10; i++) {
          linkedPaths(input, cwd: '/work');
        }
        final micros = <int>[];
        for (var i = 0; i < 15; i++) {
          final timer = Stopwatch()..start();
          result = linkedPaths(input, cwd: '/work');
          timer.stop();
          micros.add(timer.elapsedMicroseconds);
          expect(result, expected);
        }
        micros.sort();
        // Benchmark-only JSON rows are the portable measurement output.
        // ignore: avoid_print
        print(
          jsonEncode({
            'n': n,
            'mixed': mixed,
            'inputChars': input.length,
            'returned': result.length,
            'warmup': 10,
            'samples': 15,
            'minMicros': micros.first,
            'medianMicros': micros[7],
            'maxMicros': micros.last,
          }),
        );
      }
    }
  });
}
