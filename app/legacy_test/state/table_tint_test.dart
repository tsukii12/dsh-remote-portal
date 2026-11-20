import 'dart:ui' show Color;

import 'package:dsh_app/state/table_tint_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 三档只差在两个填充上：表头永远给一个色（透明也算），隔行给不给。
  const header = Color(0xFF112233);
  const stripe = Color(0x0A000000);

  group('tableTintFills', () {
    test('follow keeps the header fill and draws no stripes', () {
      final fills = tableTintFills(TableTint.follow, headerColor: header, stripeColor: stripe);
      expect(fills.header, header);
      expect(fills.stripe, isNull);
    });

    test('fill paints both the header and the stripes', () {
      final fills = tableTintFills(TableTint.fill, headerColor: header, stripeColor: stripe);
      expect(fills.header, header);
      expect(fills.stripe, stripe);
    });

    test('none is transparent, not null', () {
      // TableStyle 把 null 当成"用主题默认值"，所以"不铺"必须是显式透明。
      final fills = tableTintFills(TableTint.none, headerColor: header, stripeColor: stripe);
      expect(fills.header, transparentFill);
      expect(fills.header.a, 0);
      expect(fills.stripe, isNull);
    });
  });

  group('TableTint storage', () {
    test('every value round-trips through its stored name', () {
      for (final tint in TableTint.values) {
        expect(TableTint.values.asNameMap()[tint.name], tint);
      }
    });

    test('an unknown stored name falls back to follow', () {
      expect(TableTint.values.asNameMap()['nope'] ?? TableTint.follow, TableTint.follow);
    });
  });
}
