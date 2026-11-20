import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_model.dart';
import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_style.dart' show DshUiPalette;
import 'package:dsh_app/ui/plugins/view/plugin_view.dart';
import 'package:flutter_test/flutter_test.dart';

DshUiView parseStyle(Object view, {Object? data, PluginViewBudget budget = PluginViewBudget.panel}) {
  final parsed = parseDshUiPluginUncached(view, data: data, profile: budget.profile);
  expect(parsed, isA<DshUiParsed>());
  return (parsed as DshUiParsed).view;
}

Map<String, Object?> styledText(Map<String, Object?> style, {Object? spans}) => {
  'v': 2,
  'type': 'text',
  'text': 'Readable fallback',
  'style': style,
  'spans': ?spans,
};

// Independent reference formula used on the colours returned by the parser.
double referenceRatio(int a, int b) {
  double luminance(int rgb) {
    final channels = [rgb ~/ 65536 % 256, rgb ~/ 256 % 256, rgb % 256];
    final linear = channels.map((byte) {
      final value = byte / 255.0;
      return value > 0.04045 ? math.pow((value + 0.055) / 1.055, 2.4).toDouble() : value / 12.92;
    }).toList();
    return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722;
  }

  final light = [luminance(a), luminance(b)]..sort();
  return (light[1] + 0.05) / (light[0] + 0.05);
}

void expectReadable(DshUiPluginStyle style) {
  for (final dark in [false, true]) {
    final background = style.background.at(dark);
    for (final pair in [style.foreground, style.accent, style.muted]) {
      expect(referenceRatio(pair.at(dark), background), greaterThanOrEqualTo(4.5));
    }
    for (final span in style.spans) {
      expect(
        referenceRatio(span.color.at(dark), (span.background ?? style.background).at(dark)),
        greaterThanOrEqualTo(4.5),
      );
    }
    for (final pair in [...style.chartColors, ?style.chartOther]) {
      expect(referenceRatio(pair.at(dark), background), greaterThanOrEqualTo(3));
    }
  }
}

void main() {
  test('schema is the source of the app typography, colours and bounds', () {
    final schema = jsonDecode(File('test/fixtures/plugin_view.schema.json').readAsStringSync()) as Map;
    final spec = schema['x-dsh-go']['v2Styles'] as Map;
    expect({for (final size in DshUiTextSize.values) size.name: size.pixels}, spec['fontPixels']);
    expect(DshUiTextWeight.values.map((weight) => weight.name).toList(), spec['weights']);
    expect({
      for (final color in DshUiPluginPalette.named.entries)
        color.key: '#${color.value.toRadixString(16).padLeft(6, '0').toUpperCase()}',
    }, spec['namedColors']);
    expect(spec['contrast']['enforcedText'], 4.5);
    expect(
      DshUiPluginPalette.chart.map((pair) => pair.light).toList(),
      DshUiPalette.light.map((color) => color.toARGB32() & 0xFFFFFF).toList(),
    );
    expect(
      DshUiPluginPalette.chart.map((pair) => pair.dark).toList(),
      DshUiPalette.dark.map((color) => color.toARGB32() & 0xFFFFFF).toList(),
    );
  });

  test('only explicit view v2 enters the new language', () {
    for (final v in [null, 1, 3, '2']) {
      final view = parseStyle({
        'type': 'text',
        'text': 'fallback',
        'v': ?v,
        'style': {'color': '#FFFFFF', 'size': 'display'},
        'spans': [
          {'text': 'new'},
        ],
      });
      expect(view.version, 1);
      expect(view.styles, isEmpty);
      expect((view.root as DshUiText).text, 'fallback');
    }
    final model = dshUiFromJson(styledText({'color': 'red'}));
    expect((model as DshUiParsed).view.styles, isEmpty, reason: 'model cards cannot opt into plugin styles');
  });

  test('every semantic font and weight is bounded; scale-independent floor is 4.5', () {
    for (final size in DshUiTextSize.values) {
      for (final weight in DshUiTextWeight.values) {
        final view = parseStyle(
          styledText({
            'size': size.name,
            'weight': weight.name,
            'color': '#FFFFFF',
            'italic': true,
            'underline': true,
            'strike': true,
            'align': 'end',
            'maxLines': 2,
          }),
        );
        final style = view.styles['view']!;
        expect(style.size, size);
        expect(style.weight, weight);
        expect(style.minimumContrast, 4.5);
        expect(style.italic && style.underline && style.strike, isTrue);
        expect(style.align, DshUiStyleAlign.end);
        expect(style.maxLines, 2);
        expectReadable(style);
      }
    }
  });

  test('contrast reference points and quantised correction never round 4.499 up', () {
    expect(dshUiContrast(0, 0xFFFFFF), 21);
    expect(dshUiContrast(0x777777, 0xFFFFFF), lessThan(4.5));
    expect(dshUiContrast(0x767676, 0xFFFFFF), greaterThan(4.5));
    expect(dshUiReadableColor(0x767676, 0xFFFFFF), 0x767676);
    final backgrounds = [
      0,
      0xFFFFFF,
      0x777777,
      0x808080,
      DshUiPluginPalette.surface.light,
      DshUiPluginPalette.surface.dark,
      DshUiPluginPalette.elevated.light,
      DshUiPluginPalette.elevated.dark,
    ];
    var seed = 0x125678;
    for (var i = 0; i < 512; i++) {
      seed = (seed * 1664525 + 1013904223) & 0xFFFFFF;
      for (final background in backgrounds) {
        final corrected = dshUiReadableColor(seed, background);
        expect(referenceRatio(corrected, background), greaterThanOrEqualTo(4.5), reason: '$seed / $background');
        if (referenceRatio(seed, background) >= 4.5) expect(corrected, seed);
      }
    }
  });

  test('all ten named colours, accent and hex are corrected on nested painted backgrounds', () {
    for (final background in [...DshUiPluginPalette.named.keys, '#000000', '#FFFFFF']) {
      for (final foreground in [...DshUiPluginPalette.named.keys, 'accent', '#000000', '#FFFFFF']) {
        final view = parseStyle({
          'v': 2,
          'accent': '#FFFF00',
          'type': 'stack',
          'style': {'card': 'outlined', 'background': background, 'padding': 'L', 'gap': 'S'},
          'children': [
            {
              'type': 'text',
              'text': 'fallback',
              'style': {'color': foreground},
              'spans': [
                {'text': 'highlight', 'background': foreground, 'color': background, 'weight': 'bold'},
              ],
            },
          ],
        });
        for (final style in view.styles.values) {
          expectReadable(style);
        }
        final root = view.styles['view']!;
        expect(root.padding, 16);
        expect(root.gap, 8);
        expect(view.styles['view.children[0]']!.background, same(root.background));
      }
    }
    final view = parseStyle(styledText({'color': '#FFFFFF'}));
    expect(view.issues.any((issue) => issue.path == 'view.style.color' && issue.message.contains('#737373')), isTrue);
  });

  test('sibling colours are checked against their own inherited background', () {
    final view = parseStyle({
      'v': 2,
      'type': 'stack',
      'children': [
        {
          'type': 'stack',
          'style': {'card': 'surface'},
          'children': [
            {'type': 'text', 'text': 'inside'},
          ],
        },
        {'type': 'text', 'text': 'outside'},
      ],
    });
    expect(view.styles['view.children[0].children[0]']!.background, same(DshUiPluginPalette.elevated));
    expect(view.styles['view.children[1]']!.background, same(DshUiPluginPalette.surface));
  });

  test('chart categories and the other segment remain visible against new backgrounds', () {
    for (final background in [...DshUiPluginPalette.named.keys, '#000000', '#FFFFFF']) {
      final view = parseStyle({
        'v': 2,
        'type': 'stack',
        'style': {'background': background},
        'children': [
          {
            'type': 'chart',
            'kind': 'bar',
            'categories': ['a', 'b'],
            'series': [
              {
                'values': [1, 2],
              },
            ],
          },
        ],
      });
      final style = view.styles['view.children[0]']!;
      expect(style.chartColors, hasLength(6));
      expect(style.chartOther, isNotNull);
      expectReadable(style);
      expect(view.issues.any((issue) => issue.path.contains('.palette')), isTrue);
    }
  });

  test('invalid style values, arbitrary geometry and links are diagnosed and cannot execute', () {
    final view = parseStyle(
      styledText(
        {
          'size': 500,
          'weight': 200,
          'maxLines': 21,
          'color': '#FFFFFF00',
          'opacity': 0,
          'position': 'fixed',
          'radius': 999,
          'fontFamily': 'System',
          'anythingElse': true,
        },
        spans: [
          {'text': 'click', 'href': 'https://example.com', 'action': 'grant', 'mono': 'yes'},
        ],
      ),
    );
    final style = view.styles['view']!;
    expect(style.size, DshUiTextSize.body);
    expect(style.weight, DshUiTextWeight.regular);
    expect(style.maxLines, isNull);
    expect(style.spans.single.text, 'click');
    expect(style.spans.single.mono, isFalse);
    expect(
      view.issues.map((issue) => issue.path),
      containsAll([
        'view.style.size',
        'view.style.weight',
        'view.style.maxLines',
        'view.style.color',
        'view.style.opacity',
        'view.style.position',
        'view.style.radius',
        'view.style.fontFamily',
        'view.style.anythingElse',
        'view.spans[0].href',
        'view.spans[0].action',
      ]),
    );
    expectReadable(style);
  });

  test('system roles are rejected; v2 cannot request the system solid grant treatment', () {
    for (final role in ['system', 'approval', 'authorization', 'dialog', 'permission']) {
      final result = parsePluginView({'v': 2, 'type': 'text', 'text': 'x', 'role': role});
      expect(result, isA<DshUiInvalid>());
    }
    final view = parseStyle({
      'v': 2,
      'type': 'actions',
      'items': [
        {'label': 'Grant', 'style': 'primary', 'action': 'go'},
      ],
    });
    expect((view.root as DshUiActions).items.single.primary, isFalse);
    expect(view.issues.map((issue) => issue.path), contains('view.items[0].style'));
  });

  test('spans share per-node text and per-view item budgets after binding resolution', () {
    final text = parseStyle(
      styledText({}, spans: {r'$': 'data.spans'}),
      data: {
        'spans': [
          {'text': 'x' * 5000},
          {'text': 'unreachable'},
        ],
      },
    );
    expect(text.styles['view']!.spans.single.text, '${'x' * 2000}…');
    for (final (budget, total, count) in [
      (PluginViewBudget.panel, 256, 10),
      (PluginViewBudget.toolCard, 64, 4),
      (PluginViewBudget.strip, 16, 1),
    ]) {
      final view = parseStyle({
        'v': 2,
        'type': 'stack',
        'children': [
          for (var i = 0; i < count; i++)
            {
              'type': 'text',
              'text': 'fallback',
              'spans': [
                for (var j = 0; j < 33; j++) {'text': 'x'},
              ],
            },
        ],
      }, budget: budget);
      expect(view.styles.values.fold(0, (sum, style) => sum + style.spans.length), total);
      expect(view.issues.any((issue) => issue.path.endsWith('.spans')), isTrue);
    }
  });

  test('text remains required so old apps retain a useful fallback', () {
    expect(
      parsePluginView({
        'v': 2,
        'type': 'text',
        'spans': [
          {'text': 'only new'},
        ],
      }),
      isA<DshUiInvalid>(),
    );
    final view = parseStyle({
      'v': 2,
      'type': 'stack',
      'children': [
        {'type': 'future-component'},
        {
          'type': 'text',
          'text': 'fallback',
          'spans': [
            {'text': 'rich'},
          ],
        },
      ],
    });
    expect(view.nodes.whereType<DshUiText>().single.text, 'fallback');
  });
}
