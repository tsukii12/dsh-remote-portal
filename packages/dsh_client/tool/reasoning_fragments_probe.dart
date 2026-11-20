// Optional semantic oracle and paired component timing. Run from dsh_client:
//   dart run tool/reasoning_fragments_probe.dart oracle
//   dart compile exe tool/reasoning_fragments_probe.dart -o /tmp/fragments-probe
//   /tmp/fragments-probe cost
//   /tmp/fragments-probe small
// This measures splitting only, not an App frame, RPC, or device memory peak.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dsh_client/dsh_client.dart';

typedef _Split = List<ReasoningFragment> Function(String text, {required bool running, required int maxTextChars});

var _sink = 0;

void main(List<String> args) {
  switch (args.isEmpty ? 'oracle' : args.single) {
    case 'oracle':
      _oracle();
    case 'cost':
      _cost();
    case 'small':
      _small();
    default:
      throw ArgumentError('Expected oracle, cost or small');
  }
}

void _oracle() {
  final inputs = <String>[''];
  for (final source in [
    'First paragraph.\n\nSecond one is longer.\n \nTail still grows',
    '  lead\tword\u00A0word\r\nline\r\n \t\r\n\nend   ',
    'a😀b 👩‍💻 c e\u0301 中文\u2028\u2029',
    '\uD800x\uDC00\uD800\uD800y\uDC00\uDC00\u0000z',
  ]) {
    for (var end = 0; end <= source.length; end++) {
      inputs.add(source.substring(0, end));
    }
  }
  final random = Random(457);
  const pieces = ['word', ' ', '\t', '\r', '\n', '\r\n', '\u00A0', '\u2003', '😀', '中', '\uD800', '\uDC00'];
  for (var i = 0; i < 2048; i++) {
    final text = StringBuffer();
    final length = random.nextInt(160);
    for (var j = 0; j < length; j++) {
      text.write(pieces[random.nextInt(pieces.length)]);
    }
    inputs.add(text.toString());
  }
  var checked = 0;
  for (final source in inputs) {
    for (final limit in [2, 3, 4, 7, 16, 31, 4000]) {
      for (final running in [false, true]) {
        _compare(source, limit, running, checked++);
      }
    }
  }
  for (final source in [
    'Thinking through this step carefully. ' * 1024,
    '😀 word\t' * 1024,
    'prefix${' \t\u00A0' * 4096}tail',
    '${'paragraph.\r\n \r\n' * 1024}growing tail',
  ]) {
    for (final running in [false, true]) {
      _compare(source, 4000, running, checked++);
    }
  }
  // The original limit=1 + leading high surrogate can fail to advance.
  // It is not the default-budget performance problem and is not exercised.
  for (final limit in [-1, 0, 1]) {
    for (final running in [false, true]) {
      _compare('a b\n\nc', limit, running, checked++);
    }
  }
  print(jsonEncode({'mode': 'oracle', 'seed': 457, 'comparisons': checked, 'all_equal': true}));
}

void _compare(String source, int limit, bool running, int index) {
  final expected = _baseline(source, running: running, maxTextChars: limit);
  final actual = reasoningFragments(source, running: running, maxTextChars: limit);
  if (actual.length != expected.length) {
    throw StateError('Fragment count differs at $index, limit=$limit, running=$running');
  }
  for (var i = 0; i < actual.length; i++) {
    if (actual[i].text != expected[i].text ||
        actual[i].suffix != expected[i].suffix ||
        actual[i].complete != expected[i].complete) {
      throw StateError('Fragment $i differs at $index, limit=$limit, running=$running');
    }
  }
  if (actual.map((f) => f.text + f.suffix).join() != source) {
    throw StateError('Reconstruction differs at $index');
  }
}

void _cost() {
  const limit = 4000;
  final functions = <String, _Split>{'baseline': _baseline, 'candidate': reasoningFragments};
  for (final split in functions.values) {
    for (var i = 0; i < 80; i++) {
      _sink += split(_input('words', 32768), running: false, maxTextChars: limit).length;
    }
  }
  for (final shape in ['words', 'token', 'paragraphs', 'space-run', 'supplementary']) {
    final lengths = shape == 'words'
        ? [1024, 4096, 16384, 65536, 262144, 1048576, 4194304]
        : [1024, 16384, 262144, 1048576];
    for (final length in lengths) {
      final source = _input(shape, length);
      _compare(source, limit, false, length);
      for (var sample = 0; sample < 7; sample++) {
        final order = sample.isEven ? ['baseline', 'candidate'] : ['candidate', 'baseline'];
        for (final label in order) {
          final clock = Stopwatch()..start();
          final fragments = functions[label]!(source, running: false, maxTextChars: limit);
          clock.stop();
          _sink += fragments.length;
          print(
            jsonEncode({
              'mode': 'cost',
              'shape': shape,
              'units': source.length,
              'maxTextChars': limit,
              'sample': sample,
              'first': order.first,
              'label': label,
              'elapsed_us': clock.elapsedMicroseconds,
              'fragments': fragments.length,
              'current_rss': ProcessInfo.currentRss,
              // Both variants share one process; this cannot attribute a peak.
              'process_max_rss': ProcessInfo.maxRss,
            }),
          );
        }
      }
    }
  }
  print(jsonEncode({'mode': 'cost', 'done': true, 'sink': _sink}));
}

String _input(String shape, int length) {
  final phrase = switch (shape) {
    'words' => 'Thinking through this step carefully. ',
    'token' => 'x',
    'paragraphs' => 'One short reasoning paragraph.\r\n \r\n',
    'space-run' => ' ',
    'supplementary' => 'Thinking 😀 through each step. ',
    _ => throw ArgumentError.value(shape),
  };
  if (shape == 'space-run') return 'prefix${' ' * (length - 10)}tail';
  return (phrase * ((length + phrase.length - 1) ~/ phrase.length)).substring(0, length);
}

// A batched control for the first matrix's small-call negative observation.
// Both variants include the same call loop and result consumption in timing.
void _small() {
  const iterations = 32;
  final functions = <String, _Split>{'baseline': _baseline, 'candidate': reasoningFragments};
  for (final length in [1024, 4096, 16384]) {
    final source = _input('words', length);
    for (var i = 0; i < 200; i++) {
      for (final split in functions.values) {
        _sink += split(source, running: false, maxTextChars: 4000).length;
      }
    }
    for (var sample = 0; sample < 9; sample++) {
      final order = sample.isEven ? ['baseline', 'candidate'] : ['candidate', 'baseline'];
      for (final label in order) {
        final split = functions[label]!;
        final clock = Stopwatch()..start();
        for (var i = 0; i < iterations; i++) {
          _sink += split(source, running: false, maxTextChars: 4000).length;
        }
        clock.stop();
        print(
          jsonEncode({
            'mode': 'small',
            'units': length,
            'maxTextChars': 4000,
            'iterations': iterations,
            'sample': sample,
            'first': order.first,
            'label': label,
            'elapsed_us': clock.elapsedMicroseconds,
          }),
        );
      }
    }
  }
  print(jsonEncode({'mode': 'small', 'done': true, 'sink': _sink}));
}

// Pinned b4f2d24 reference: only the function name differs from the original.
final RegExp _paragraphBreak = RegExp(r'\r?\n(?:[\t ]*\r?\n)+');

List<ReasoningFragment> _baseline(String text, {required bool running, required int maxTextChars}) {
  final out = <ReasoningFragment>[];
  final limit = maxTextChars < 1 ? 1 : maxTextChars;
  var start = 0;
  final matches = _paragraphBreak.allMatches(text).toList();
  for (var i = 0; ; i++) {
    final match = i < matches.length ? matches[i] : null;
    var remaining = text.substring(start, match?.start ?? text.length);
    while (remaining.length > limit) {
      var cut = limit;
      final unit = remaining.codeUnitAt(cut - 1);
      if (unit >= 0xD800 && unit <= 0xDBFF) cut -= 1;
      final head = remaining.substring(0, cut);
      final ws = RegExp(r'\s+\S*$').firstMatch(head);
      if (ws != null && ws.start > 0) cut = ws.start;
      final source = remaining.substring(0, cut);
      remaining = remaining.substring(cut);
      final lead = RegExp(r'^\s+').firstMatch(remaining);
      final suffix = lead?.group(0) ?? '';
      remaining = remaining.substring(suffix.length);
      out.add(ReasoningFragment(source, suffix, complete: true));
    }
    out.add(ReasoningFragment(remaining, match?.group(0) ?? '', complete: match != null || !running));
    if (match == null) return out;
    start = match.end;
  }
}
