// Run with a repository package_config that resolves package:dsh_client.
// This is a JIT component observation, not a mobile frame-time benchmark.
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';

var _sink = 0;

void main(List<String> args) {
  final label = args.isEmpty ? 'baseline-jit' : args.first;
  const maxTextChars = 4000;
  const phrase = 'Thinking through this step carefully. ';
  String input(int length) => (phrase * ((length + phrase.length - 1) ~/ phrase.length)).substring(0, length);

  final warm = input(32768);
  for (var i = 0; i < 80; i++) {
    _sink += reasoningFragments(warm, running: false, maxTextChars: maxTextChars).length;
  }

  for (final length in [1024, 4096, 16384, 65536, 262144, 1048576, 4194304]) {
    final source = input(length);
    for (var sample = 0; sample < 5; sample++) {
      final clock = Stopwatch()..start();
      final fragments = reasoningFragments(source, running: false, maxTextChars: maxTextChars);
      clock.stop();
      final restored = StringBuffer();
      for (final fragment in fragments) {
        if (!fragment.complete || fragment.text.length > maxTextChars) {
          throw StateError('Fragment contract failed at $length / $sample');
        }
        restored
          ..write(fragment.text)
          ..write(fragment.suffix);
      }
      if (restored.toString() != source) {
        throw StateError('Source reconstruction failed at $length / $sample');
      }
      _sink += fragments.length;
      print(
        jsonEncode({
          'label': label,
          'units': length,
          'maxTextChars': maxTextChars,
          'sample': sample,
          'elapsed_us': clock.elapsedMicroseconds,
          'fragments': fragments.length,
          'current_rss': ProcessInfo.currentRss,
          // Process lifetime high-water mark, including earlier observations.
          'process_max_rss': ProcessInfo.maxRss,
        }),
      );
    }
  }
  print(jsonEncode({'label': label, 'done': true, 'sink': _sink}));
}
