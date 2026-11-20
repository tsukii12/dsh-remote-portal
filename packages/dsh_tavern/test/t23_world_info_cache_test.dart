import 'package:dsh_tavern/src/regex/regex_types.dart';
import 'package:dsh_tavern/src/worldinfo/world_info.dart';
import 'package:test/test.dart';

void main() {
  test('warm whole-word patterns keep literal metacharacters escaped', () async {
    expect(await _matches(['a.b'], 'a.b'), isTrue);
    expect(await _matches(['a.b'], 'aXb'), isFalse);
    expect(await _matches(['a.b'], 'xa.by'), isFalse);
    expect(await _matches(['a.b'], '[a.b]'), isTrue);
    expect(await _matches(['c++'], 'c++!'), isTrue);
    expect(await _matches(['c++'], 'c++word'), isFalse);
  });

  test('warm patterns respect each entry case mode and do not reuse match results', () async {
    expect(await _matches(['Alpha'], 'ALPHA'), isTrue);
    expect(await _matches(['Alpha'], 'ALPHA', caseSensitive: true), isFalse);
    expect(await _matches(['Alpha'], 'Alpha', caseSensitive: true), isTrue);
    expect(await _matches(['alpha'], 'ALPHA', caseSensitive: true), isFalse);
    expect(await _matches(['alpha'], 'ALPHA'), isTrue);
    expect(await _matches(['alpha'], 'different'), isFalse);
  });

  test('whole-word and multiword bypass choices remain per input after warming', () async {
    expect(await _matches(['cat'], 'a cat!'), isTrue);
    expect(await _matches(['cat'], 'concatenate'), isFalse);
    expect(await _matches(['cat'], 'concatenate', wholeWords: false), isTrue);
    expect(await _matches(['cat'], 'concatenate'), isFalse);
    expect(await _matches(['red fox'], 'red foxes'), isTrue);
    expect(await _matches(['red fox'], 'red  foxes'), isFalse);
  });

  test('macro-expanded plain keys expand again even when a compiled pattern is warm', () async {
    var key = 'alpha';
    var expansions = 0;
    String expand(String text) {
      if (text != '{{key}}') return text;
      expansions++;
      return key;
    }

    expect(await _matches(['{{key}}'], 'alpha', expand: expand), isTrue);
    key = 'beta';
    expect(await _matches(['{{key}}'], 'alpha', expand: expand), isFalse);
    key = 'alpha';
    expect(await _matches(['{{key}}'], 'alpha', expand: expand), isTrue);
    expect(expansions, 3);
  });

  test('more than one cache capacity of plain keys keeps semantics and consumes no worker rule allowance', () async {
    final keys = [for (var index = 0; index < 1100; index++) 'needle$index'];
    expect(await _matches(keys, 'needle1099'), isTrue);
    expect(await _matches(['needle0'], 'needle0'), isTrue);
    expect(await _matches(['needle0'], 'needle00'), isFalse);
    expect(await _matches(['needle1099'], 'needle1099'), isTrue);
  });
}

Future<bool> _matches(
  List<String> keys,
  String text, {
  bool caseSensitive = false,
  bool wholeWords = true,
  String Function(String)? expand,
}) async {
  final book = WorldInfoBook.fromJson(
    id: 'plain-cache',
    source: WorldInfoSource.global,
    json: {
      'entries': <String, Object?>{
        '0': <String, Object?>{
          'uid': 0,
          'key': keys,
          'content': 'kept',
          'position': 0,
          'order': 100,
          'caseSensitive': caseSensitive,
          'matchWholeWords': wholeWords,
          'useProbability': false,
        },
      },
    },
  );
  final result = await const WorldInfoEngine(worker: _RejectUserRegex()).evaluate(
    WorldInfoInput(
      books: [book],
      messages: [WorldInfoMessage(text)],
      maxContext: 10000,
      tokenCount: (value) => value.length,
      random: () => throw StateError('No probability/group random draw is expected'),
      settings: const WorldInfoSettings(includeNames: false),
      expand: expand ?? (value) => value,
    ),
  );
  expect(result.regexDiagnostics, isEmpty);
  return result.activated.isNotEmpty;
}

class _RejectUserRegex implements RegexExecutor {
  const _RejectUserRegex();

  @override
  RegexLimits get limits => const RegexLimits(maxRules: 0);

  @override
  Future<RegexCompileResult> compile(
    String pattern, {
    RegexDialect dialect = RegexDialect.script,
    bool caseSensitive = true,
  }) => throw StateError('Plain keywords must not compile through the worker');

  @override
  Future<RegexMatchResult> hasMatch(
    String pattern,
    String text, {
    RegexDialect dialect = RegexDialect.script,
    bool caseSensitive = true,
  }) => throw StateError('Plain keywords must not match through the worker');
}
