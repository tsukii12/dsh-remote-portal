import 'dart:convert';

import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_model.dart';
import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_plugin_formula.dart';
import 'package:dsh_app/ui/plugins/view/plugin_view.dart';
import 'package:flutter_test/flutter_test.dart';

DshUiView view(Object source, {Object? data, PluginViewBudget budget = PluginViewBudget.panel}) {
  final result = parseDshUiPluginUncached(source, data: data, profile: budget.profile);
  expect(result, isA<DshUiParsed>());
  return (result as DshUiParsed).view;
}

Map<String, Object?> field(String type, String bind, [Map<String, Object?> props = const {}]) => {
  'type': type,
  'label': type,
  'bind': bind,
  ...props,
};

// F1 separately reports correction of its default accent; control assertions
// below inspect input diagnostics. The shared corpus retains every issue.
Iterable<DshUiIssue> controlIssues(DshUiView view) => view.issues.where((issue) => issue.path != 'view.accent');

void main() {
  test('v2 owns the new catalog; model and plugin v1 remain unchanged', () {
    final source = field('textField', 'data.name');
    expect(parseDshUiPluginUncached(source), isA<DshUiInvalid>());
    expect(parseDshUiUncached(jsonEncode({'v': 2, ...source})), isA<DshUiInvalid>());
    expect(view({'v': 2, ...source}).version, 2);
    expect(dshUiPluginComponents, hasLength(42));
  });

  test('all eleven inputs parse; binding wins over literal value', () {
    final source = {
      'v': 2,
      'type': 'stack',
      'children': [
        for (final type in dshUiPluginInputTypes)
          field(type, 'data.$type', {
            'value': 'ignored',
            if (['select', 'segmented', 'chips'].contains(type)) 'options': ['one', 'two'],
          }),
      ],
    };
    final parsed = view(source, data: {'textField': 'actual', 'number': 3, 'toggle': true});
    expect(parsed.nodes.whereType<DshUiInput>(), hasLength(11));
    expect(controlIssues(parsed), isEmpty);
    expect(parsed.nodes.whereType<DshUiInput>().first.value, 'actual');
  });

  test('read-only tool cards and strip rejection are profile decisions', () {
    final source = {'v': 2, ...field('textField', 'data.name')};
    final card = view(source, budget: PluginViewBudget.toolCard);
    expect((card.root as DshUiInput).readOnly, isTrue);
    expect(parseDshUiPluginUncached(source, profile: DshUiProfile.strip), isA<DshUiInvalid>());
    expect((view({'v': 2, 'type': 'textField', 'label': 'Fixed', 'value': 'x'}).root as DshUiInput).readOnly, isTrue);
  });

  test('an absent number stays empty and cannot satisfy required by a fabricated zero', () {
    final number =
        view({
              'v': 2,
              ...field('number', 'data.n', {'required': true}),
            }).root
            as DshUiInput;
    expect(number.value, '');
    expect(number.validate(number.value), isNotNull);
    final optional = view({'v': 2, ...field('number', 'data.n')}, data: {'n': null}).root as DshUiInput;
    expect(optional.submitted(optional.value), isNull);
  });

  test('no password, executable regex, duplicate or overlapping writes', () {
    for (final props in [
      {'obscureText': true},
      {'password': true},
      {'keyboardType': 'password'},
      {'inputType': 'password'},
      {'pattern': r'(a+)+$'},
      {'bind': 'data.rows[99999999]'},
      {'bind': 'data.constructor.name'},
    ]) {
      expect(parseDshUiPluginUncached({'v': 2, ...field('textField', 'data.name', props)}), isA<DshUiInvalid>());
    }
    for (final second in ['data.a', 'data.a.b']) {
      final parsed = view({
        'v': 2,
        'type': 'stack',
        'children': [field('textField', 'data.a'), field('textField', second)],
      });
      expect(parsed.nodes.whereType<DshUiPlaceholder>(), hasLength(1));
      expect(controlIssues(parsed).single.path, 'view.children[1].bind');
    }
  });

  test('input, option, section and tree budgets apply to hidden content too', () {
    final parsed = view({
      'v': 2,
      'type': 'stack',
      'children': [
        for (var group = 0; group < 2; group++)
          {
            'type': 'collapsible',
            'children': [for (var i = 0; i < 20; i++) field('textField', 'data.f${group}_$i')],
          },
      ],
    });
    expect(parsed.nodes.whereType<DshUiInput>(), hasLength(32));
    expect(parsed.nodes.whereType<DshUiPlaceholder>(), hasLength(8));
    final choices = view({
      'v': 2,
      ...field('select', 'data.selected', {'options': List.generate(30, (i) => '$i')}),
    });
    expect((choices.root as DshUiInput).options, hasLength(24));
    expect(controlIssues(choices).single.path, 'view.options');
    final sections = view({
      'v': 2,
      'type': 'tabs',
      'items': List.generate(12, (i) => {'label': '$i', 'children': []}),
    });
    expect((sections.root as DshUiControlContainer).sections, hasLength(8));
    final tree = view({
      'v': 2,
      'type': 'timeline',
      'items': List.generate(
        24,
        (i) => {
          'label': '$i',
          'children': List.generate(10, (j) => {'type': 'text', 'text': '$j'}),
        },
      ),
    });
    final container = tree.root as DshUiControlContainer;
    expect(tree.nodes.length + container.sections.length, lessThanOrEqualTo(120));
  });

  test('forms reject nesting and require an action', () {
    expect(parseDshUiPluginUncached({'v': 2, 'type': 'form', 'children': []}), isA<DshUiInvalid>());
    final parsed = view({
      'v': 2,
      'type': 'form',
      'submit': 'save',
      'children': [
        field('textField', 'data.name'),
        {'type': 'form', 'submit': 'inner', 'children': []},
      ],
    });
    expect((parsed.root as DshUiControlContainer).inputs, hasLength(1));
    expect(parsed.nodes.whereType<DshUiPlaceholder>(), hasLength(1));
  });

  test('finite validation covers value types, bounds, lengths and named patterns', () {
    final text =
        view({
              'v': 2,
              ...field('textField', 'data.name', {
                'required': true,
                'minLength': 2,
                'maxLength': 12,
                'pattern': 'slug',
              }),
            }).root
            as DshUiInput;
    expect(text.validate(''), isNotNull);
    expect(text.validate('A space'), isNotNull);
    expect(text.validate(true), isNotNull);
    expect(text.validate('valid-name'), isNull);
    final numeric =
        view({
              'v': 2,
              ...field('number', 'data.n', {'min': -2, 'max': 3}),
            }).root
            as DshUiInput;
    for (final bad in [double.nan, double.infinity, 'no', 4, -3]) {
      expect(numeric.validate(bad), isNotNull);
    }
    expect(numeric.validate('2.5'), isNull);
    expect(numeric.submitted('2.5'), 2.5);
    final range =
        view({
              'v': 2,
              ...field('slider', 'data.range', {'range': true}),
            }).root
            as DshUiInput;
    expect(range.validate([80, 20]), isNotNull);
    expect(range.validate([10, 20, 30]), isNotNull);
    expect(range.validate([10, 20]), isNull);
    final chips =
        view({
              'v': 2,
              ...field('chips', 'data.chips', {
                'multi': true,
                'options': ['a', 'b'],
              }),
            }).root
            as DshUiInput;
    expect(chips.validate('a'), isNotNull);
    expect(chips.validate(['unknown']), isNotNull);
    expect(chips.validate(['a']), isNull);
  });

  test('dates and times are strict and bounded', () {
    expect(dshUiInputDate('2024-02-29'), isNotNull);
    for (final bad in ['2023-02-29', '2024-13-01', '2024-01-32', '2024-1-1', '1899-12-31']) {
      expect(dshUiInputDate(bad), isNull);
    }
    expect(dshUiInputTime('23:59'), (23, 59));
    for (final bad in ['24:00', '12:60', '1:02', '12:03Z']) {
      expect(dshUiInputTime(bad), isNull);
    }
    expect(
      parseDshUiPluginUncached({
        'v': 2,
        ...field('date', 'data.date', {'minDate': '2025-01-01', 'maxDate': '2024-01-01'}),
      }),
      isA<DshUiInvalid>(),
    );
  });

  test('avatar reuses the image allowlist and code is bounded', () {
    final unsafe = view({'v': 2, 'type': 'avatar', 'src': 'https://tracker.example/a.png'});
    expect((unsafe.root as DshUiControlDisplay).image!.source, isNull);
    expect(controlIssues(unsafe).single.path, 'view.src');
    final image = view({'v': 2, 'type': 'avatar', 'src': 'asset:icons/a.png', 'alt': 'A'});
    expect((image.root as DshUiControlDisplay).image!.source, isA<DshUiAssetImage>());
    final code = view({'v': 2, 'type': 'codeBlock', 'code': 'x' * 9000, 'language': 'js'});
    expect((code.root as DshUiControlDisplay).text!.length, 8001);
    expect(controlIssues(code).single.path, 'view.code');
  });

  test('bounded formulas have precedence, finite results and no object execution', () {
    final data = {
      'a': '3',
      'b': 4,
      'rows': [2],
    };
    expect(evaluateDshUiFormula('data.a + data.b * data.rows[0]', data), 11);
    expect(evaluateDshUiFormula('data.b-data.a', data), 1);
    expect(evaluateDshUiFormula('clamp(abs(-8), 0, max(2, 5))', data), 5);
    expect(evaluateDshUiFormula('-5 % 3', data), 1);
    for (final invalid in [
      '1/0',
      '1e999',
      'data.missing',
      'Math.random()',
      'while(true){}',
      'data.a=4',
      'min(1)',
      'clamp(1,3,2)',
      '1' * 257,
      '${'(' * 20}1${')' * 20}',
    ]) {
      expect(evaluateDshUiFormula(invalid, data), isNull, reason: invalid);
    }
    final parsed = view({
      'v': 2,
      'type': 'metric',
      'label': 'Total',
      'value': {'=': 'data.a*2'},
    }, data: data);
    expect((parsed.root as DshUiMetric).value, '6');
    final unresolved = view({
      'v': 2,
      'type': 'metric',
      'label': 'Total',
      'value': {'=': '1/0'},
    });
    expect(controlIssues(unresolved).single.path, 'view.value');
    expect((unresolved.root as DshUiMetric).value, '—');
  });
}
