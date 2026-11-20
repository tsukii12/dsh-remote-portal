// Dart port of the finite Fuse.js 7.1.0 consumer used by ST /findentry.
// Upstream: https://github.com/krisk/Fuse
// Commit: 8119c18862f7df585688b1320ff307eb19f8ff89. Apache-2.0;
// full license is in FUSE-LICENSE.txt beside this file.
// Modified: one JSON field, ordinary string query, no mutable/public index,
// extended/logical search, highlights, or configurable Fuse options. The
// original get/index/norm/Bitap/chunk/score order and 32-bit masks are retained.
import 'dart:math' as math;

import '../js_string.dart';

final class StFuseMatch {
  const StFuseMatch(this.item, this.index, this.score);
  final Object? item;
  final int index;
  final double score;
}

/// JS Object.values enumeration for JSON own properties. Ordinary non-index
/// keys retain insertion order; only canonical uint32-minus-one keys sort.
List<Object?> stObjectValues(Map<String, Object?> object) {
  final indexed = <(int, String)>[];
  final ordinary = <String>[];
  for (final key in object.keys) {
    final index = _arrayIndex(key);
    if (index == null) {
      ordinary.add(key);
    } else {
      indexed.add((index, key));
    }
  }
  indexed.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final entry in indexed) object[entry.$2], for (final key in ordinary) object[key]];
}

int? _arrayIndex(String key) {
  if (!RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(key)) return null;
  final value = int.tryParse(key);
  return value != null && value <= 4294967294 ? value : null;
}

// The consumer supplies JavaScript default lowercase, without accent removal.
List<StFuseMatch> stFindEntries(
  Map<String, Object?> entries,
  String field,
  String query, {
  required String Function(Object?) jsString,
  required String Function(String) lowercase,
}) {
  final documents = stObjectValues(entries);
  final searcher = _BitapSearch(lowercase(query));
  final results = <StFuseMatch>[];
  final path = field.split('.');
  for (var index = 0; index < documents.length; index++) {
    final value = _get(documents[index], path, jsString);
    final values = <String>[];
    if (value is List) {
      final stack = <Object?>[value];
      while (stack.isNotEmpty) {
        final item = stack.removeLast();
        if (item is String && trimJsWhitespace(item).isNotEmpty) {
          values.add(item);
        } else if (item is List) {
          stack.addAll(item);
        }
      }
    } else if (value is String && trimJsWhitespace(value).isNotEmpty) {
      values.add(value);
    }
    var matched = false;
    var total = 1.0;
    for (final text in values) {
      final result = searcher.search(lowercase(text));
      if (!result.isMatch) continue;
      matched = true;
      final tokens = RegExp(r'[^ ]+').allMatches(text).length;
      final norm = (1000 / math.sqrt(tokens)).round() / 1000;
      total *= math.pow(result.score == 0 ? 2.220446049250313e-16 : result.score, norm);
    }
    if (matched) results.add(StFuseMatch(documents[index], index, total));
  }
  results.sort((a, b) => a.score == b.score ? a.index.compareTo(b.index) : a.score.compareTo(b.score));
  return results;
}

Object? _property(Object? value, String key) {
  if (value is Map) return value[key];
  if (value is List) {
    if (key == 'length') return value.length;
    final index = _arrayIndex(key);
    return index != null && index < value.length ? value[index] : null;
  }
  if (value is String) {
    if (key == 'length') return value.length;
    final index = _arrayIndex(key);
    return index != null && index < value.length ? value.substring(index, index + 1) : null;
  }
  return null;
}

Object? _get(Object? object, List<String> path, String Function(Object?) jsString) {
  final list = <Object?>[];
  var array = false;
  void visit(Object? current, int index) {
    if (current == null) return;
    if (index >= path.length || path[index].isEmpty) {
      list.add(current);
      return;
    }
    final value = _property(current, path[index]);
    if (value == null) return;
    if (index == path.length - 1 && (value is String || value is num || value is bool)) {
      list.add(value is num && value == 0 && value.isNegative ? '-0' : jsString(value));
    } else if (value is List) {
      array = true;
      for (final item in value) {
        visit(item, index + 1);
      }
    } else {
      visit(value, index + 1);
    }
  }

  visit(object, 0);
  return array ? list : (list.isEmpty ? null : list.first);
}

final class _BitapResult {
  const _BitapResult(this.isMatch, this.score);
  final bool isMatch;
  final double score;
}

final class _BitapChunk {
  _BitapChunk(this.pattern, this.start) {
    for (var i = 0; i < pattern.length; i++) {
      final code = pattern.codeUnitAt(i);
      alphabet[code] = (alphabet[code] ?? 0) | (1 << (pattern.length - i - 1));
    }
  }
  final String pattern;
  final int start;
  final alphabet = <int, int>{};
}

final class _BitapSearch {
  _BitapSearch(this.pattern) {
    if (pattern.isEmpty) return;
    if (pattern.length <= 32) {
      chunks.add(_BitapChunk(pattern, 0));
    } else {
      final remainder = pattern.length % 32;
      final end = pattern.length - remainder;
      for (var i = 0; i < end; i += 32) {
        chunks.add(_BitapChunk(pattern.substring(i, i + 32), i));
      }
      if (remainder != 0) {
        final start = pattern.length - 32;
        chunks.add(_BitapChunk(pattern.substring(start), start));
      }
    }
  }
  final String pattern;
  final chunks = <_BitapChunk>[];

  _BitapResult search(String text) {
    if (text == pattern) return const _BitapResult(true, 0);
    var hasMatches = false;
    var score = 0.0;
    for (final chunk in chunks) {
      final result = _searchChunk(text, chunk);
      hasMatches = hasMatches || result.isMatch;
      score += result.score;
    }
    return _BitapResult(hasMatches, hasMatches ? score / chunks.length : 1);
  }
}

double _score(int length, int errors, int actual, int expected) => errors / length + (expected - actual).abs() / 100;

int _at(List<int> bits, int index) => index >= 0 && index < bits.length ? bits[index] : 0;

_BitapResult _searchChunk(String text, _BitapChunk chunk) {
  final pattern = chunk.pattern;
  final patternLength = pattern.length;
  final textLength = text.length;
  final expected = math.min(chunk.start, textLength);
  var threshold = 0.3;
  var best = expected;
  while (best <= textLength) {
    final index = text.indexOf(pattern, best);
    if (index < 0) break;
    threshold = math.min(threshold, _score(patternLength, 0, index, expected));
    best = index + patternLength;
  }
  best = -1;
  var previous = <int>[];
  var finalScore = 1.0;
  var binaryMax = patternLength + textLength;
  final mask = 1 << (patternLength - 1);
  for (var errors = 0; errors < patternLength; errors++) {
    var binaryMin = 0;
    var binaryMid = binaryMax;
    while (binaryMin < binaryMid) {
      if (_score(patternLength, errors, expected + binaryMid, expected) <= threshold) {
        binaryMin = binaryMid;
      } else {
        binaryMax = binaryMid;
      }
      binaryMid = ((binaryMax - binaryMin) / 2 + binaryMin).floor();
    }
    binaryMax = binaryMid;
    var start = math.max(1, expected - binaryMid + 1);
    final finish = math.min(expected + binaryMid, textLength) + patternLength;
    final bits = List<int>.filled(finish + 2, 0);
    bits[finish + 1] = ((1 << errors) - 1) & 0xffffffff;
    for (var j = finish; j >= start; j--) {
      final location = j - 1;
      final match = location < textLength ? chunk.alphabet[text.codeUnitAt(location)] ?? 0 : 0;
      bits[j] = (((bits[j + 1] << 1) | 1) & match) & 0xffffffff;
      if (errors != 0) {
        bits[j] =
            (bits[j] | (((_at(previous, j + 1) | _at(previous, j)) << 1) | 1 | _at(previous, j + 1))) & 0xffffffff;
      }
      if ((bits[j] & mask) == 0) continue;
      finalScore = _score(patternLength, errors, location, expected);
      if (finalScore <= threshold) {
        threshold = finalScore;
        best = location;
        if (best <= expected) break;
        start = math.max(1, 2 * expected - best);
      }
    }
    if (_score(patternLength, errors + 1, expected, expected) > threshold) break;
    previous = bits;
  }
  return _BitapResult(best >= 0, math.max(0.001, finalScore));
}
