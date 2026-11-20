import 'dart:async';
import 'dart:convert';

import 'package:dsh_tavern/src/regex/regex_worker.dart';
import 'package:dsh_tavern/src/worldinfo/world_info.dart';
import 'package:test/test.dart';

late RegexWorker _worker;

void main() {
  setUpAll(() {
    _worker = RegexWorker();
  });
  tearDownAll(() => _worker.close());

  test('a skipped primary preserves prior effects and other hits without recursive admission', () async {
    final executor = _InterceptExecutor(_worker, match: (pattern) => pattern == '/blocked/' ? _skipped() : null);
    final book = _native([
      {
        'key': ['{{before}}'],
        'content': 'before',
        'sticky': 3,
      },
      {
        'key': ['{{blocked}}'],
        'content': 'blocked-marker body',
        'sticky': 3,
        'cooldown': 2,
      },
      {
        'key': ['{{after}}'],
        'content': 'after',
        'sticky': 2,
      },
      {
        'key': ['blocked-marker'],
        'content': 'must not recurse',
      },
    ]);
    final original = jsonEncode(book.raw);
    final calls = <String>[];
    var effects = 0;
    final result = await _evaluate(
      [book],
      worker: executor,
      settings: const WorldInfoSettings(includeNames: false, recursive: true),
      expand: (text) {
        calls.add(text);
        if (text == '{{before}}') {
          effects++;
          return 'key';
        }
        if (text == '{{blocked}}') {
          effects += 10;
          return '/blocked/';
        }
        if (text == '{{after}}') {
          expect(effects, 11);
          return 'key';
        }
        return text;
      },
      timed: const {
        'sticky': {
          'expired.9': {'hash': 9, 'start': 0, 'end': 1, 'protected': false},
        },
      },
    );
    expect(result.activated.map((hit) => hit.uid), ['0', '2']);
    expect(effects, 11);
    expect(calls.where((value) => value == '{{blocked}}'), hasLength(1));
    expect(calls, isNot(contains('blocked-marker body')));
    expect((result.timedWorldInfo['sticky']! as Map<String, Object?>).keys, ['book.0', 'book.2']);
    expect((result.timedWorldInfo['cooldown']! as Map<String, Object?>), isEmpty);
    expect(result.decoratorState.keys, ['${book.entries[0].stHash}', '${book.entries[2].stHash}']);
    final diagnostic = result.regexDiagnostics.single;
    expect(diagnostic.toJson(), {
      'bookId': 'book',
      'uid': '1',
      'source': 'global',
      'keyPath': 'key[0]',
      'phase': 'initial',
      'round': 1,
      'code': 'timeout',
      'message': 'controlled skip',
    });
    final retained = result.withoutEntries({('book', '0')});
    expect(retained.activated.single.uid, '2');
    expect(retained.regexDiagnostics.single.toJson(), diagnostic.toJson());
    expect(() => retained.regexDiagnostics.clear(), throwsUnsupportedError);
    expect((retained.timedWorldInfo['sticky']! as Map<String, Object?>).keys, ['book.2']);
    expect(jsonEncode(book.raw), original);
  });

  for (final logic in [0, 1, 2, 3]) {
    test('secondary logic $logic never turns a skipped regex into activation', () async {
      final executor = _InterceptExecutor(_worker, match: (pattern) => pattern == '/blocked/' ? _skipped() : null);
      final result = await _evaluate([
        _native([
          {
            'keysecondary': ['/blocked/'],
            'selective': true,
            'selectiveLogic': logic,
          },
          {'constant': true, 'content': 'survivor'},
        ]),
      ], worker: executor);
      expect(result.activated.map((hit) => hit.uid), ['1']);
      expect(result.regexDiagnostics.single.keyPath, 'keysecondary[0]');
      expect(executor.events, ['match:/blocked/']);
    });
  }

  test('native primary and NOT_ALL short circuits do not run unused regex keys', () async {
    final executor = _InterceptExecutor(_worker, match: (pattern) => _skipped());
    final result = await _evaluate([
      _native([
        {
          'key': ['key', '/unused-primary/'],
        },
        {
          'keysecondary': ['absent', '/unused-secondary/'],
          'selective': true,
          'selectiveLogic': 1,
        },
      ]),
    ], worker: executor);
    expect(result.activated.map((hit) => hit.uid), ['0', '1']);
    expect(result.regexDiagnostics, isEmpty);
    expect(executor.events, isEmpty);
  });

  test('an indeterminate exclusion skips the candidate instead of permitting it', () async {
    final executor = _InterceptExecutor(_worker, match: (pattern) => _skipped());
    final result = await _evaluate([
      _native([
        {'constant': true, 'content': '@@exclude_keys /blocked/\nexcluded'},
        {'constant': true, 'content': 'survivor'},
      ]),
    ], worker: executor);
    expect(result.activated.map((hit) => hit.uid), ['1']);
    expect(result.regexDiagnostics.single.keyPath, 'content.@@exclude_keys[0]');
  });

  test('additional groups keep whole-group expansion order before a skipped match', () async {
    final executor = _InterceptExecutor(_worker, match: (pattern) => pattern == '/blocked/' ? _skipped() : null);
    final calls = <String>[];
    final result = await _evaluate(
      [
        _native([
          {
            'key': ['primary-must-not-expand'],
            'content': '@@additional_keys key\n@@additional_keys /blocked/,{{later}}\nbody',
          },
        ]),
      ],
      worker: executor,
      expand: (text) {
        calls.add(text);
        return text == '{{later}}' ? 'key' : text;
      },
    );
    expect(result.activated, isEmpty);
    expect(calls, ['key', '/blocked/', '{{later}}']);
    expect(result.regexDiagnostics.single.keyPath, 'content.@@additional_keys[1][0]');
  });

  test('V3 expands every primary before validation and never matches after a compile skip', () async {
    final executor = _InterceptExecutor(_worker, compile: (pattern) => pattern == 'blocked' ? _compileSkipped() : null);
    final calls = <String>[];
    final result = await _evaluate(
      [
        _v3([
          {
            'keys': ['{{first}}', '{{blocked}}', '{{last}}'],
            'use_regex': true,
          },
        ]),
      ],
      worker: executor,
      expand: (text) {
        calls.add(text);
        return const {'{{first}}': 'key', '{{blocked}}': 'blocked', '{{last}}': 'last'}[text] ?? text;
      },
    );
    expect(result.activated, isEmpty);
    expect(calls, ['{{first}}', '{{blocked}}', '{{last}}']);
    expect(executor.events, ['compile:key', 'compile:blocked']);
    expect(result.regexDiagnostics.single.keyPath, 'keys[1]');
  });

  test('V3 required first-match skip does not continue to a later matching primary', () async {
    final executor = _InterceptExecutor(_worker, match: (pattern) => pattern == 'blocked' ? _skipped() : null);
    final result = await _evaluate([
      _v3([
        {
          'keys': ['blocked', 'key'],
          'use_regex': true,
        },
      ]),
    ], worker: executor);
    expect(result.activated, isEmpty);
    expect(executor.events, ['compile:blocked', 'compile:key', 'match:blocked']);
  });

  test('V3 additional validation uses the worker and keeps exclude ignored', () async {
    final executor = _InterceptExecutor(_worker, compile: (pattern) => pattern == 'blocked' ? _compileSkipped() : null);
    final result = await _evaluate([
      _v3([
        {'use_regex': true, 'content': '@@additional_keys key,blocked\n@@exclude_keys key\nbody'},
      ]),
    ], worker: executor);
    expect(result.activated, isEmpty);
    expect(executor.events, ['compile:key', 'compile:blocked']);
    expect(result.regexDiagnostics.single.keyPath, 'content.@@additional_keys[0][1]');
  });

  test('V3 sticky validates primary syntax but does not add admission after a skip', () async {
    final executor = _InterceptExecutor(_worker, compile: (pattern) => _compileSkipped());
    final book = _v3([
      {
        'keys': ['blocked'],
        'use_regex': true,
        'extensions': {'sticky': 3},
      },
    ]);
    final sticky = {
      'v3.0': {'hash': book.entries.single.stHash, 'start': 0, 'end': 3, 'protected': false},
    };
    final result = await _evaluate([book], worker: executor, timed: {'sticky': sticky});
    expect(result.activated, isEmpty);
    expect(result.decoratorState, isEmpty);
    expect(result.timedWorldInfo['sticky'], sticky);
    expect(executor.events, ['compile:blocked']);
  });

  test('native sticky and constants plus V3 force bypass unused regex work', () async {
    final executor = _InterceptExecutor(
      _worker,
      limits: const RegexLimits(maxRules: 0),
      compile: (pattern) => _compileSkipped(),
      match: (pattern) => _skipped(),
    );
    final native = _native([
      {
        'key': ['/blocked/'],
        'sticky': 3,
      },
      {
        'key': ['/unused/'],
        'constant': true,
      },
    ]);
    final forced = _v3([
      {
        'keys': ['blocked'],
        'use_regex': true,
        'content': '@@activate\n@@additional_keys blocked\nforced',
      },
    ]);
    final result = await _evaluate(
      [native, forced],
      worker: executor,
      timed: {
        'sticky': {
          'book.0': {'hash': native.entries.first.stHash, 'start': 0, 'end': 3, 'protected': false},
        },
      },
    );
    expect(
      {for (final hit in result.activated) '${hit.bookId}.${hit.uid}': hit.reason},
      {'book.0': 'sticky', 'book.1': 'constant', 'v3.0': 'decorator-activate'},
    );
    expect(result.regexDiagnostics, isEmpty);
    expect(executor.events, isEmpty);
  });

  test('group scoring skips an undecidable primary and retains the other member', () async {
    final executor = _InterceptExecutor(_worker, match: (pattern) => pattern == '/blocked/' ? _skipped() : null);
    final result = await _evaluate(
      [
        _native([
          {
            'constant': true,
            'key': ['/blocked/'],
            'group': 'g',
            'sticky': 3,
          },
          {
            'constant': true,
            'key': ['/key/'],
            'group': 'g',
          },
        ]),
      ],
      worker: executor,
      settings: const WorldInfoSettings(includeNames: false, useGroupScoring: true),
    );
    expect(result.activated.map((hit) => hit.uid), ['1']);
    expect(result.regexDiagnostics.single.keyPath, 'key[0]');
    expect((result.timedWorldInfo['sticky']! as Map<String, Object?>), isEmpty);
  });

  test('group scoring also protects raw secondary keys of nonselective entries', () async {
    final executor = _InterceptExecutor(_worker, match: (pattern) => pattern == '/blocked/' ? _skipped() : null);
    final result = await _evaluate(
      [
        _native([
          {
            'constant': true,
            'key': ['/key/'],
            'keysecondary': ['/blocked/'],
            'group': 'g',
          },
          {
            'constant': true,
            'key': ['/key/'],
            'group': 'g',
          },
        ]),
      ],
      worker: executor,
      settings: const WorldInfoSettings(includeNames: false, useGroupScoring: true),
    );
    expect(result.activated.map((hit) => hit.uid), ['1']);
    expect(result.regexDiagnostics.single.keyPath, 'keysecondary[0]');
  });

  test('overlapping groups remove skipped entries without splice(-1) collateral removal', () async {
    final executor = _InterceptExecutor(_worker, match: (pattern) => pattern == '/blocked/' ? _skipped() : null);
    final result = await _evaluate(
      [
        _native([
          {
            'constant': true,
            'key': ['/blocked/'],
            'group': 'a,b',
          },
          {
            'constant': true,
            'key': ['/key/'],
            'group': 'a',
          },
          {
            'constant': true,
            'key': ['/key/'],
            'group': 'b',
          },
          {'constant': true, 'key': <String>[], 'content': 'unrelated-tail'},
        ]),
      ],
      worker: executor,
      settings: const WorldInfoSettings(includeNames: false, useGroupScoring: true),
    );
    expect(result.activated.map((hit) => hit.uid), ['1', '2', '3']);
    expect(result.regexDiagnostics, hasLength(1));
    expect(executor.events.where((event) => event == 'match:/blocked/'), hasLength(1));
  });

  test('one regex identity shares its quota across recursion and overlapping group scores', () async {
    final executor = _InterceptExecutor(_worker, limits: const RegexLimits(maxRules: 1));
    final result = await _evaluate(
      [
        _native([
          {'constant': true, 'key': <String>[], 'content': 'later'},
          {
            'key': ['/later/'],
            'group': 'a,b',
            'content': 'found',
          },
        ]),
      ],
      worker: executor,
      settings: const WorldInfoSettings(includeNames: false, recursive: true, useGroupScoring: true),
    );
    expect(result.activated.map((hit) => hit.uid), ['0', '1']);
    expect(result.activated.last.phase, WorldInfoScanPhase.recursion);
    expect(result.regexDiagnostics, isEmpty);
    expect(executor.events, ['match:/later/', 'match:/later/', 'match:/later/']);
  });

  test('V3 compile and match share one key slot while duplicate key positions are distinct', () async {
    final executor = _InterceptExecutor(_worker, limits: const RegexLimits(maxRules: 1));
    final accepted = await _evaluate([
      _v3([
        {
          'keys': ['key'],
          'use_regex': true,
        },
      ]),
    ], worker: executor);
    expect(accepted.activated, hasLength(1));
    expect(accepted.regexDiagnostics, isEmpty);
    expect(executor.events, ['compile:key', 'match:key']);
    executor.events.clear();
    final limited = await _evaluate([
      _v3([
        {
          'keys': ['key', 'key'],
          'use_regex': true,
        },
      ]),
    ], worker: executor);
    expect(limited.activated, isEmpty);
    expect(limited.regexDiagnostics.single.code, 'rule-limit');
    expect(limited.regexDiagnostics.single.keyPath, 'keys[1]');
    expect(executor.events, ['compile:key']);
  });

  test('ordinary and malformed literal fallback keys do not consume regex quota', () async {
    final executor = _InterceptExecutor(_worker, limits: const RegexLimits(maxRules: 0));
    final result = await _evaluate(
      [
        _native([
          {
            'key': ['key'],
          },
          {
            'key': ['/bad/ii'],
          },
          {
            'key': ['/key/'],
          },
        ]),
      ],
      worker: executor,
      text: 'key /bad/ii',
    );
    expect(result.activated.map((hit) => hit.uid), ['0', '1']);
    expect(result.regexDiagnostics.single.uid, '2');
    expect(result.regexDiagnostics.single.code, 'rule-limit');
    expect(executor.events, isEmpty);
  });

  test('each additional key group owns a stable distinct rule identity', () async {
    final executor = _InterceptExecutor(_worker, limits: const RegexLimits(maxRules: 1));
    final result = await _evaluate([
      _native([
        {'content': '@@additional_keys /key/\n@@additional_keys /key/\nbody'},
      ]),
    ], worker: executor);
    expect(result.activated, isEmpty);
    expect(result.regexDiagnostics.single.keyPath, 'content.@@additional_keys[1][0]');
    expect(result.regexDiagnostics.single.code, 'rule-limit');
    expect(executor.events, ['match:/key/']);
  });

  test('a recognized native literal compile failure no longer falls back to text', () async {
    // Explicit T21 protection difference from the original native fallback.
    // The malformed flag suffix remains ordinary ST text.
    final result = await _evaluate([
      _native([
        {
          'key': ['/[/'],
        },
        {
          'key': ['/bad/ii'],
        },
      ]),
    ], text: '/[/ /bad/ii');
    expect(result.activated.map((hit) => hit.uid), ['1']);
    expect(result.regexDiagnostics.single.uid, '0');
    expect(result.regexDiagnostics.single.code, 'incompatible-pattern');
  });

  for (final code in ['input-limit', 'worker-unavailable', 'queue-limit']) {
    test('$code remains indeterminate under a negative secondary condition', () async {
      final executor = _InterceptExecutor(_worker, match: (pattern) => _skipped(code));
      final result = await _evaluate([
        _native([
          {
            'keysecondary': ['/blocked/'],
            'selective': true,
            'selectiveLogic': 2,
          },
        ]),
      ], worker: executor);
      expect(result.activated, isEmpty);
      expect(result.regexDiagnostics.single.code, code);
    });
  }

  for (final compiling in [false, true]) {
    test('cancellation during ${compiling ? 'compile' : 'match'} prevents later owner effects', () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final executor = _InterceptExecutor(
        _worker,
        compile: compiling
            ? (pattern) async {
                started.complete();
                await release.future;
                return _compatible;
              }
            : null,
        match: compiling
            ? null
            : (pattern) async {
                started.complete();
                await release.future;
                return _matched;
              },
      );
      var cancelled = false;
      final failure = StateError('controlled cancellation');
      final calls = <String>[];
      var tokens = 0;
      var draws = 0;
      final book = compiling
          ? _v3([
              {
                'keys': ['key'],
                'use_regex': true,
              },
              {'constant': true},
            ])
          : _native([
              {
                'key': ['/key/'],
              },
              {'constant': true},
            ]);
      final running = _evaluate(
        [book],
        worker: executor,
        checkCancelled: () {
          if (cancelled) throw failure;
        },
        expand: (text) {
          calls.add(text);
          return text;
        },
        tokenCount: (text) {
          tokens++;
          return text.length;
        },
        random: () {
          draws++;
          return 0;
        },
      );
      final checked = expectLater(running, throwsA(same(failure)));
      await started.future;
      cancelled = true;
      release.complete();
      await checked;
      expect(calls, [compiling ? 'key' : '/key/']);
      expect(tokens, 0);
      expect(draws, 0);
      expect(executor.events, [compiling ? 'compile:key' : 'match:/key/']);
    });
  }

  test('owner callback failures propagate instead of becoming regex diagnostics', () async {
    final failure = StateError('owner macro failure');
    await expectLater(
      _evaluate([
        _native([{}]),
      ], expand: (text) => throw failure),
      throwsA(same(failure)),
    );
  });

  test('diagnostics locate original key indices even when nonstrings are ignored', () async {
    final executor = _InterceptExecutor(_worker, match: (pattern) => _skipped());
    final result = await _evaluate([
      _native([
        {
          'key': <Object?>[null, 17, '/blocked/'],
        },
      ]),
    ], worker: executor);
    expect(result.regexDiagnostics.single.keyPath, 'key[2]');
  });

  test('import inputs preserve native source paths and mark macro patterns without evaluation', () {
    final book = WorldInfoBook.fromJson(
      id: 'native',
      source: WorldInfoSource.global,
      json: {
        'entries': {
          'source-key': {
            'uid': 42,
            'key': <Object?>[null, '/key/', 'plain', '/bad/ii', '{{pattern}}', '<USER>'],
            'keysecondary': ['/secondary/'],
            'content': 'body',
            'future': {'kept': true},
          },
        },
      },
    );
    final before = jsonEncode(book.raw);
    final inputs = worldInfoRegexInputs(book);
    expect(inputs.map((value) => value.pattern), ['/key/', '{{pattern}}', '<USER>', '/secondary/']);
    expect(inputs.map((value) => value.path), [
      'entries["source-key"].key[1]',
      'entries["source-key"].key[4]',
      'entries["source-key"].key[5]',
      'entries["source-key"].keysecondary[0]',
    ]);
    expect(inputs.map((value) => value.uid).toSet(), {'42'});
    expect(inputs.map((value) => value.isDynamic), [false, true, true, false]);
    expect(inputs.every((value) => value.dialect == RegexDialect.nativeKeyword), isTrue);
    expect(inputs.last.conditional, isTrue);
    expect(jsonEncode(book.raw), before);
    expect(() => inputs.clear(), throwsUnsupportedError);
  });

  test('import header inputs include conditional fallbacks and exclude body lookalikes', () {
    final book = _native([
      {
        'key': <String>[],
        'content':
            '@@unknown\r\n'
            '@@@additional_keys /first/,{{future}}\r\n@@exclude_keys /stop/\r\n'
            '@@@exclude_keys /fallback/\r\nbody\r\n@@additional_keys /not-header/',
      },
    ]);
    final before = jsonEncode(book.raw);
    final inputs = worldInfoRegexInputs(book);
    expect(inputs.map((value) => value.pattern), ['/first/', '{{future}}', '/stop/', '/fallback/']);
    expect(inputs.map((value) => value.line), [2, 2, 3, 4]);
    expect(inputs.map((value) => value.keyIndex), [0, 1, 0, 0]);
    expect(inputs.map((value) => value.isFallback), [true, true, false, true]);
    expect(inputs.every((value) => value.conditional), isTrue);
    expect(inputs.every((value) => value.path == 'entries["0"].content'), isTrue);
    expect(inputs[1].toJson()['dynamic'], isTrue);
    expect(jsonEncode(book.raw), before);
  });

  test('native import checks the trimmed activation pattern and preserves stored whitespace', () async {
    final book = _native([
      {
        'key': ['  /[/\t'],
        'keysecondary': ['\n/side/  '],
      },
      {
        'key': ['key'],
        'keysecondary': ['  /[/\t'],
        'selective': true,
        'selectiveLogic': 2,
      },
    ]);
    final before = jsonEncode(book.raw);
    final inputs = worldInfoRegexInputs(book);
    expect(inputs.map((value) => value.pattern), ['/[/', '/side/', '/[/']);
    expect(inputs.map((value) => value.path), [
      'entries["0"].key[0]',
      'entries["0"].keysecondary[0]',
      'entries["1"].keysecondary[0]',
    ]);
    final compiled = await _worker.compile(inputs.first.pattern, dialect: inputs.first.dialect);
    expect(compiled.status, RegexCompileStatus.incompatible);
    final result = await _evaluate([book], text: 'key /[/');
    expect(result.activated, isEmpty);
    expect(result.regexDiagnostics.map((value) => value.keyPath), ['key[0]', 'keysecondary[0]']);
    expect(jsonEncode(book.raw), before);
  });

  test('V3 import patterns and native group scoring retain significant surrounding whitespace', () async {
    final v3 = _v3([
      {
        'use_regex': true,
        'keys': [' key '],
      },
    ]);
    expect(worldInfoRegexInputs(v3).single.pattern, ' key ');
    expect((await _evaluate([v3])).activated, isEmpty);
    final executor = _InterceptExecutor(_worker, match: (pattern) => _skipped());
    final scored = await _evaluate(
      [
        _native([
          {
            'constant': true,
            'key': [' /[/ '],
            'group': 'g',
          },
          {
            'constant': true,
            'key': ['key'],
            'group': 'g',
          },
        ]),
      ],
      worker: executor,
      settings: const WorldInfoSettings(includeNames: false, useGroupScoring: true),
    );
    expect(scored.activated.map((value) => value.uid), ['1']);
    expect(scored.regexDiagnostics, isEmpty);
    expect(executor.events, isEmpty);
  });

  test('V3 import inputs include bare primary secondary and additional but no exclude', () {
    final book = _v3([
      {
        'use_regex': true,
        'keys': ['bare', '['],
        'secondary_keys': ['side'],
        'case_sensitive': true,
        'content': '@@additional_keys /extra/i\n@@exclude_keys ignored\nbody',
      },
    ]);
    final inputs = worldInfoRegexInputs(book);
    expect(inputs.map((value) => value.pattern), ['bare', '[', 'side', '/extra/i']);
    expect(inputs.take(3).map((value) => value.path), [
      'entries[0].keys[0]',
      'entries[0].keys[1]',
      'entries[0].secondary_keys[0]',
    ]);
    expect(inputs.every((value) => value.dialect == RegexDialect.v3Keyword && value.caseSensitive), isTrue);
    expect(inputs.last.decorator, 'additional_keys');
  });

  test('import checks all stored V3 rows without changing duplicate-id execution priority', () {
    final book = _v3([
      {
        'id': 7,
        'keys': ['/earlier/'],
      },
      {
        'id': 7,
        'keys': ['/later/'],
      },
    ]);
    final inputs = worldInfoRegexInputs(book);
    expect(inputs.map((value) => value.pattern), ['/earlier/', '/later/']);
    expect(inputs.map((value) => value.path), ['entries[0].keys[0]', 'entries[1].keys[0]']);
    expect(inputs.map((value) => value.uid), ['7', '7']);
    expect(book.entries.single.keys, ['/later/']);
  });
}

const _compatible = RegexCompileResult(status: RegexCompileStatus.compatible);
const _matched = RegexMatchResult(status: RegexMatchStatus.matched, compilation: _compatible);

RegexCompileResult _compileSkipped([String code = 'timeout']) =>
    RegexCompileResult(status: RegexCompileStatus.skipped, code: code, message: 'controlled skip');

RegexMatchResult _skipped([String code = 'timeout']) => RegexMatchResult(
  status: RegexMatchStatus.skipped,
  compilation: _compileSkipped(code),
  code: code,
  message: 'controlled skip',
);

class _InterceptExecutor implements RegexExecutor {
  _InterceptExecutor(
    this.delegate, {
    RegexLimits? limits,
    FutureOr<RegexCompileResult?> Function(String)? compile,
    FutureOr<RegexMatchResult?> Function(String)? match,
  }) : limits = limits ?? delegate.limits,
       onCompile = compile,
       onMatch = match;
  final RegexExecutor delegate;
  @override
  final RegexLimits limits;
  final FutureOr<RegexCompileResult?> Function(String)? onCompile;
  final FutureOr<RegexMatchResult?> Function(String)? onMatch;
  final events = <String>[];

  @override
  Future<RegexCompileResult> compile(
    String pattern, {
    RegexDialect dialect = RegexDialect.script,
    bool caseSensitive = true,
  }) async {
    events.add('compile:$pattern');
    final intercepted = await onCompile?.call(pattern);
    return intercepted ?? await delegate.compile(pattern, dialect: dialect, caseSensitive: caseSensitive);
  }

  @override
  Future<RegexMatchResult> hasMatch(
    String pattern,
    String text, {
    RegexDialect dialect = RegexDialect.script,
    bool caseSensitive = true,
  }) async {
    events.add('match:$pattern');
    final intercepted = await onMatch?.call(pattern);
    return intercepted ?? await delegate.hasMatch(pattern, text, dialect: dialect, caseSensitive: caseSensitive);
  }
}

WorldInfoBook _native(List<Map<String, Object?>> entries) => WorldInfoBook.fromJson(
  id: 'book',
  source: WorldInfoSource.global,
  json: {
    'entries': {
      for (var index = 0; index < entries.length; index++)
        '$index': {
          'uid': index,
          'key': ['key'],
          'content': 'entry-$index',
          'position': 0,
          'order': 100 - index,
          'probability': 100,
          'useProbability': true,
          ...entries[index],
        },
    },
  },
);

WorldInfoBook _v3(List<Map<String, Object?>> entries) => WorldInfoBook.fromJson(
  id: 'v3',
  source: WorldInfoSource.character,
  json: {
    'entries': [
      for (var index = 0; index < entries.length; index++)
        {
          'id': index,
          'keys': ['key'],
          'content': 'entry-$index',
          'enabled': true,
          'position': 'before_char',
          'insertion_order': 100 - index,
          ...entries[index],
        },
    ],
  },
);

Future<WorldInfoResult> _evaluate(
  List<WorldInfoBook> books, {
  RegexExecutor? worker,
  String text = 'key',
  WorldInfoSettings settings = const WorldInfoSettings(includeNames: false),
  String Function(String)? expand,
  int Function(String)? tokenCount,
  double Function()? random,
  void Function()? checkCancelled,
  Map<String, Object?> timed = const {},
}) => WorldInfoEngine(worker: worker ?? _worker).evaluate(
  WorldInfoInput(
    books: books,
    messages: [WorldInfoMessage(text)],
    maxContext: 10000,
    tokenCount: tokenCount ?? (text) => text.length,
    random: random ?? () => throw StateError('Unexpected random draw'),
    expand: expand ?? (text) => text,
    settings: settings,
    timedWorldInfo: timed,
    checkCancelled: checkCancelled,
  ),
);
