// The frame-source probe (DSH_FRAME_PROBE): off unless built with the define,
// and each 5-second report goes out as numbered lines short enough for
// logcat (about 4 KB per line), which join back into the report's JSON.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/dev/frame_probe.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('off by default: the app starts as is and nothing is logged', () async {
    final printed = <String>[];
    var started = 0;
    await runZoned(
      () => runWithFrameProbe(() async => started++),
      zoneSpecification: ZoneSpecification(print: (_, _, _, line) => printed.add(line)),
    );
    expect(started, 1);
    expect(printed, isEmpty);
  });

  test('a short report is one line', () {
    final lines = frameProbeLines(7, '{"elapsedMs":5000}');
    expect(lines, ['DSH_FRAME_PROBE 7 1/1 {"elapsedMs":5000}']);
  });

  test('a long report splits into lines under 3 KB that join back', () {
    final report = {
      'elapsedMs': 120000,
      'counts': {for (var i = 0; i < 40; i++) 'request.kind$i': i},
      'top': [
        for (var i = 0; i < 4; i++)
          {
            'site': 'package:dsh_app/ui/chat/chat_list.dart 812:7 <- 工作区/笔记 ${'x' * 900} $i',
            'samples': [i, 0, 1],
            'timer': [1, 2, 3, 4, 5, 6],
          },
      ],
      'activeTimerTop': [
        for (var i = 0; i < 2; i++)
          {
            'site': '宠物 ${'y' * 400} $i',
            'active': [1, 0],
          },
      ],
    };
    final json = jsonEncode(report);
    expect(utf8.encode(json).length, greaterThan(4096), reason: 'what logcat used to cut');

    final lines = frameProbeLines(42, json);
    expect(lines.length, greaterThan(1));
    final pattern = RegExp(r'^DSH_FRAME_PROBE 42 (\d+)/(\d+) (.*)$', dotAll: true);
    final parts = <String>[];
    for (var i = 0; i < lines.length; i++) {
      expect(utf8.encode(lines[i]).length, lessThan(3000), reason: 'line ${i + 1}');
      expect(lines[i], isNot(contains('\n')));
      final match = pattern.firstMatch(lines[i])!;
      expect(int.parse(match[1]!), i + 1);
      expect(int.parse(match[2]!), lines.length);
      parts.add(match[3]!);
    }
    expect(parts.join(), json);
    expect(jsonDecode(parts.join()), report);
  });

  test('multi-byte text never splits inside a character', () {
    final json = jsonEncode({'site': '帧' * 3000});
    final lines = frameProbeLines(1, json, maxBytes: 500);
    for (final line in lines) {
      expect(utf8.encode(line).length, lessThan(500));
    }
    final joined = lines.map((l) => l.replaceFirst(RegExp(r'^DSH_FRAME_PROBE 1 \d+/\d+ '), '')).join();
    expect(joined, json);
  });
}
