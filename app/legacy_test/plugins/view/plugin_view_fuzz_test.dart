// Fuzzing the plugin-view parser (and the dsh-ui fence parser it shares):
// random and hostile JSON must never throw, never hang, and never produce a
// view over its budget. A smaller batch is also drawn, to catch layout
// errors the parser cannot see.

import 'dart:collection';
import 'dart:math';

import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui.dart';
import 'package:dsh_app/ui/plugins/view/plugin_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';
import 'fixtures.dart';

// Wall-clock thresholds are useful on an idle benchmark worker, but include
// time the OS does not schedule this process. Keep the original gates opt-in:
// flutter test --dart-define=DSH_FUZZ_BENCHMARK=true <this file>
const _benchmark = bool.fromEnvironment('DSH_FUZZ_BENCHMARK');

// Count input work, not elapsed host time. Lazy wrappers retain shared/cyclic
// identity and never recursively copy the hostile 100000-level fixture.
class _InputWork {
  _InputWork(this.limit);
  final int limit;
  int reads = 0;
  final _wrapped = HashMap<Object, Object>.identity();

  void visit() {
    if (++reads > limit) fail('Parser exceeded $limit input accesses');
  }

  Object? wrap(Object? value) {
    if (value is Map<String, Object?>) {
      return _wrapped.putIfAbsent(value, () => _WorkMap(value, this));
    }
    if (value is List<Object?>) {
      return _wrapped.putIfAbsent(value, () => _WorkList(value, this));
    }
    return value;
  }
}

class _WorkMap extends MapBase<String, Object?> {
  _WorkMap(this.source, this.work);
  final Map<String, Object?> source;
  final _InputWork work;
  @override
  Object? operator [](Object? key) {
    work.visit();
    return work.wrap(source[key]);
  }

  @override
  int get length {
    work.visit();
    return source.length;
  }

  @override
  Iterable<String> get keys sync* {
    for (final key in source.keys) {
      work.visit();
      yield key;
    }
  }

  @override
  void operator []=(String key, Object? value) => throw UnsupportedError('read only');
  @override
  void clear() => throw UnsupportedError('read only');
  @override
  Object? remove(Object? key) => throw UnsupportedError('read only');
}

class _WorkList extends ListBase<Object?> {
  _WorkList(this.source, this.work);
  final List<Object?> source;
  final _InputWork work;
  @override
  int get length {
    work.visit();
    return source.length;
  }

  @override
  Object? operator [](int index) {
    work.visit();
    return work.wrap(source[index]);
  }

  @override
  set length(int value) => throw UnsupportedError('read only');
  @override
  void operator []=(int index, Object? value) => throw UnsupportedError('read only');
}

DshUiParse _boundedParse(Object? view, {Object? data, DshUiProfile profile = DshUiProfile.panel, int? limit}) {
  // Several passes over a byte-bounded template are allowed. Hostile data
  // gets an explicit linear cap, independent of host scheduling and GC.
  final work = _InputWork(limit ?? profile.bytes * 8);
  return parseDshUiPluginUncached(work.wrap(view), data: work.wrap(data), profile: profile);
}

const _types = [
  'stack', 'row', 'text', 'metric', 'chart', 'compare', 'steps', 'callout', //
  'options', 'confirm', 'list', 'keyValue', 'progress', 'table', 'actions', //
  'image', 'gauge', '', 'STACK',
];

const _keys = [
  'type', 'children', 'items', 'title', 'subtitle', 'trailing', 'label', //
  'value', 'values', 'max', 'tone', 'caption', 'kind', 'categories', //
  'series', 'name', 'rows', 'columns', 'align', 'options', 'selected', //
  'multi', 'id', 'action', 'args', 'style', 'icon', 'src', 'alt', //
  'aspect', 'text', 'status', 'detail', 'badge', r'$', 'item', '__proto__',
];

class _Gen {
  _Gen(int seed) : r = Random(seed);

  final Random r;

  String string() => switch (r.nextInt(9)) {
    0 => '',
    1 => 'data.${['a', 'b.c', 'list[0]', 'x.0.y', '', '..', 'z' * 40][r.nextInt(7)]}',
    2 => '🐳' * r.nextInt(6),
    3 => 'x' * r.nextInt(3000),
    4 => 'asset:${['a.png', '../x.png', '', '%2e%2e/b.gif', 'a/b/c.webp'][r.nextInt(5)]}',
    5 => 'data:image/png;base64,${['iVBORw0KGgo=', duskPng.substring(22), '!!', ''][r.nextInt(4)]}',
    6 => '${r.nextDouble() * 1e6}',
    7 => '¥${r.nextInt(99999)}.${r.nextInt(99)}%',
    _ => String.fromCharCodes([for (var i = 0; i < r.nextInt(12); i++) r.nextInt(0x3000)]),
  };

  Object? scalar() => switch (r.nextInt(10)) {
    0 => null,
    1 => r.nextBool(),
    2 => r.nextInt(1 << 31) - (1 << 30),
    3 => r.nextDouble() * pow(10, r.nextInt(20)),
    4 => [double.nan, double.infinity, -0.0, 1e308, -1e308][r.nextInt(5)],
    5 => _types[r.nextInt(_types.length)],
    _ => string(),
  };

  Object? value(int depth) {
    if (depth > 7 || r.nextInt(10) < 4) return scalar();
    if (r.nextInt(6) == 0) return {r'$': string()};
    if (r.nextBool()) {
      return [for (var i = 0; i < r.nextInt(depth < 3 ? 12 : 4); i++) value(depth + 1)];
    }
    return node(depth + 1);
  }

  Map<String, Object?> node(int depth) => {
    if (r.nextInt(12) > 0) 'type': _types[r.nextInt(_types.length)],
    for (var i = 0; i < r.nextInt(7); i++) _keys[r.nextInt(_keys.length)]: value(depth),
  };

  /// A fixture with a few values swapped for random ones.
  Object? mutate(Object? v, [int depth = 0]) {
    if (r.nextInt(8) == 0) return value(depth);
    if (v is Map) {
      return {
        for (final e in v.entries)
          if (r.nextInt(10) > 0) '${e.key}': mutate(e.value, depth + 1),
        if (r.nextInt(5) == 0) _keys[r.nextInt(_keys.length)]: value(depth),
      };
    }
    if (v is List) {
      return [
        for (final item in v) mutate(item, depth + 1),
        if (r.nextInt(4) == 0)
          for (var i = 0; i < r.nextInt(80); i++) value(depth + 1),
      ];
    }
    return v;
  }
}

final _fixtures = <Object?>[
  weatherCard,
  usagePanel,
  listView,
  keyValueView,
  tableView,
  progressView,
  actionsView,
  imageView,
  choiceView,
  textView,
  partlyBroken,
];

/// Every invariant a parsed view keeps, whatever went in.
void _checkBudget(DshUiView view, PluginViewBudget budget) {
  final p = budget.profile;
  expect(view.nodes.length, lessThanOrEqualTo(p.nodes));
  int depth(DshUiNode n) => n is DshUiLayout && n.children.isNotEmpty ? 1 + n.children.map(depth).reduce(max) : 1;
  expect(depth(view.root), lessThanOrEqualTo(p.depth));
  for (final node in view.nodes) {
    switch (node) {
      case DshUiLayout(:final children):
        expect(children.length, lessThanOrEqualTo(p.children));
      case DshUiList(:final items):
        expect(items.length, lessThanOrEqualTo(DshUiProfile.listItems));
      case DshUiTable(:final columns, :final rows):
        expect(columns.length, lessThanOrEqualTo(DshUiProfile.tableColumns));
        expect(rows.length, lessThanOrEqualTo(DshUiProfile.tableRows));
        expect(rows.every((r) => r.length == columns.length), isTrue);
      case DshUiKeyValue(:final items):
        expect(items.length, lessThanOrEqualTo(DshUiProfile.keyValues));
      case DshUiActions(:final items):
        expect(items.length, lessThanOrEqualTo(DshUiProfile.actions));
        expect(items.where((b) => b.primary).length, lessThanOrEqualTo(1));
      case DshUiText(:final text):
        expect(text.length, lessThanOrEqualTo(p.text + 1));
      case DshUiProgress(:final fraction):
        if (fraction != null) expect(fraction, inInclusiveRange(0, 1));
      case DshUiImage(:final source):
        if (source is DshUiDataImage) {
          expect(source.width * source.height, lessThanOrEqualTo(DshUiProfile.imagePixels));
        }
      default:
    }
  }
}

void main() {
  test('input work guard is lazy, preserves cycles and fails at its limit', () {
    final source = <String, Object?>{};
    source['self'] = source;
    final work = _InputWork(2);
    final wrapped = work.wrap(source) as Map<String, Object?>;
    expect(work.reads, 0);
    expect(identical(wrapped['self'], wrapped), isTrue);
    expect(wrapped.length, 1);
    expect(() => wrapped.length, throwsA(isA<TestFailure>()));
    final listWork = _InputWork(2);
    final list = listWork.wrap([1, 2]) as List<Object?>;
    expect(list.length, 2);
    expect(list[0], 1);
    expect(() => list[1], throwsA(isA<TestFailure>()));
  });

  test('random and mutated views: no throw, within budget and bounded input work', () {
    var slowest = Duration.zero;
    var drawn = 0;
    for (var seed = 0; seed < 1500; seed++) {
      final gen = _Gen(seed);
      final view = seed.isEven ? gen.node(0) : gen.mutate(_fixtures[seed % _fixtures.length]);
      final data = gen.value(0);
      for (final budget in PluginViewBudget.values) {
        final watch = Stopwatch()..start();
        final result = parseDshUiPluginUncached(view, data: data, profile: budget.profile);
        watch.stop();
        if (watch.elapsed > slowest) slowest = watch.elapsed;
        final bounded = _boundedParse(view, data: data, profile: budget.profile);
        expect(bounded.runtimeType, result.runtimeType, reason: 'seed $seed, ${budget.name}');
        if (bounded case DshUiParsed(:final view)) _checkBudget(view, budget);
        if (result case DshUiParsed(:final view)) {
          drawn++;
          _checkBudget(view, budget);
        }
      }
    }
    expect(drawn, greaterThan(500));
    if (_benchmark) expect(slowest, lessThan(const Duration(milliseconds: 250)));
  });

  test('random fence text (model cards) never throws', () {
    final r = Random(7);
    const pieces = [
      '{',
      '}',
      '[',
      ']',
      '"type"',
      ':',
      ',',
      '"stack"',
      '"children"',
      '//',
      '/*',
      '*/',
      '"',
      r'\',
      '1e999',
      'null',
      'NaN',
      ' ',
      '\n',
      '"item"',
    ];
    for (var i = 0; i < 3000; i++) {
      final text = [for (var k = 0; k < r.nextInt(80); k++) pieces[r.nextInt(pieces.length)]].join();
      expect(() => parseDshUiUncached(text), returnsNormally);
    }
  });

  group('hostile input', () {
    Duration timed(void Function() body) {
      final watch = Stopwatch()..start();
      body();
      return watch.elapsed;
    }

    test('very deep nesting', () {
      Object deep = {'type': 'text', 'text': 'x'};
      for (var i = 0; i < 100000; i++) {
        deep = {
          'type': 'stack',
          'children': [deep],
        };
      }
      late DshUiParse result;
      final took = timed(() => result = parseDshUiPluginUncached(deep));
      expect(result, isA<DshUiInvalid>());
      expect(_boundedParse(deep, limit: 4096), isA<DshUiInvalid>());
      if (_benchmark) expect(took, lessThan(const Duration(milliseconds: 200)));
      // As fence text too (the model path).
      final text = '${'[' * 6000}${']' * 6000}';
      expect(() => parseDshUiUncached(text), returnsNormally);
    });

    test('huge arrays and strings in data', () {
      final data = {
        'rows': [
          for (var i = 0; i < 200000; i++) ['$i', i],
        ],
        'text': 'x' * 5000000,
        'cats': [for (var i = 0; i < 200000; i++) '$i'],
      };
      final view = {
        'type': 'stack',
        'children': [
          {
            'type': 'table',
            'columns': ['a', 'b'],
            'rows': {r'$': 'data.rows'},
          },
          {
            'type': 'text',
            'text': {r'$': 'data.text'},
          },
          {
            'type': 'list',
            'items': {r'$': 'data.rows'},
          },
          {
            'type': 'chart',
            'categories': {r'$': 'data.cats'},
            'series': [
              {
                'values': {r'$': 'data.cats'},
              },
            ],
          },
          {
            'type': 'stack',
            'children': {r'$': 'data.rows'},
          },
        ],
      };
      late DshUiParse result;
      final took = timed(() => result = parseDshUiPluginUncached(view, data: data));
      expect(result, isA<DshUiParsed>());
      _checkBudget((result as DshUiParsed).view, PluginViewBudget.panel);
      // Invalid list rows are currently scanned until a valid item limit is
      // reached: retain that linear behavior, but reject repeated full walks.
      final bounded = _boundedParse(view, data: data, limit: 4 * 200000 + 32768);
      expect(bounded, isA<DshUiParsed>());
      _checkBudget((bounded as DshUiParsed).view, PluginViewBudget.panel);
      if (_benchmark) expect(took, lessThan(const Duration(milliseconds: 500)));
    });

    test('cyclic data and a cyclic view object', () {
      final data = <String, Object?>{'name': 'loop'};
      data['self'] = data;
      final view = {
        'type': 'stack',
        'children': [
          {
            'type': 'metric',
            'label': 'a',
            'value': {r'$': 'data.self.self.self.name'},
          },
          {
            'type': 'stack',
            'children': {r'$': 'data.self'},
          },
          {
            'type': 'keyValue',
            'items': {r'$': 'data'},
          },
          {
            'type': 'actions',
            'items': [
              {
                'label': 'x',
                'action': {
                  'id': 'a',
                  'args': {r'$': 'data'},
                },
              },
            ],
          },
        ],
      };
      final result = parseDshUiPluginUncached(view, data: data);
      expect(result, isA<DshUiParsed>());
      final cyclic = <String, Object?>{'type': 'stack'};
      cyclic['children'] = [cyclic];
      expect(parseDshUiPluginUncached(cyclic), isA<DshUiInvalid>());
      expect(_boundedParse(cyclic, limit: 4096), isA<DshUiInvalid>());
      expect(_boundedParse(view, data: data, limit: 4096), isA<DshUiParsed>());
    });

    test('many bindings', () {
      final view = {
        'type': 'stack',
        'children': [
          for (var i = 0; i < 32; i++)
            {
              'type': 'keyValue',
              'items': [
                for (var k = 0; k < 24; k++)
                  [
                    {r'$': 'data.k$k'},
                    {r'$': 'data.v.$i.$k'},
                  ],
              ],
            },
        ],
      };
      final took = timed(() => parseDshUiPluginUncached(view, data: const {}));
      expect(_boundedParse(view, data: const {}, limit: 32768), isA<DshUiParsed>());
      if (_benchmark) expect(took, lessThan(const Duration(milliseconds: 200)));
    });
  });

  // Ten new seeds per test: a failure reports its bounded batch and exact seed.
  // Replay the preceding seed so every original adjacent update is still tested.
  // This retains all 120 seeds, profiles, actions and 50 ms virtual pumps.
  for (var start = 0; start < 120; start += 10) {
    testWidgets('random views draw without errors: seeds $start..${start + 9}', (tester) async {
      await loadTestFonts();
      usePhoneView(tester);
      for (var seed = max(0, start - 1); seed < start + 10; seed++) {
        final gen = _Gen(10000 + seed);
        final view = seed.isEven ? gen.node(0) : gen.mutate(_fixtures[seed % _fixtures.length]);
        final data = gen.value(0);
        final budget = PluginViewBudget.values[seed % 3];
        await tester.pumpWidget(
          testApp(
            Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: PluginFrame(
                  pluginName: 'fuzz',
                  child: PluginView(
                    view: view,
                    data: data,
                    budget: budget,
                    onAction: seed % 4 == 0 ? null : (_) async => true,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 50));
        expect(tester.takeException(), isNull, reason: 'seed $seed');
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  }
}
