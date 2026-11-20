import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_chart.dart';
import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_skeleton.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('nice ticks', () {
    test('round steps of 1, 2, 2.5 and 5', () {
      expect(dshUiNiceTicks(0, 5920), [0, 2000, 4000, 6000]);
      expect(dshUiNiceTicks(0, 1), [0, 0.25, 0.5, 0.75, 1]);
      expect(dshUiNiceTicks(-30, 70), [-50, -25, 0, 25, 50, 75]);
      expect(dshUiNiceTicks(3600, 6000), [3000, 4000, 5000, 6000]);
    });

    test('a flat or empty range still gets an axis', () {
      expect(dshUiNiceTicks(5, 5), [0, 2, 4, 6]);
      expect(dshUiNiceTicks(0, 0), [0, 0.25, 0.5, 0.75, 1]);
      expect(dshUiNiceTicks(-3, -3), [-3, -2, -1, 0]);
    });

    test('bad numbers never hang or throw', () {
      expect(dshUiNiceTicks(double.nan, 1), [0, 1]);
      expect(dshUiNiceTicks(0, double.infinity), [0, 1]);
      final huge = dshUiNiceTicks(-1.7e308, 1.7e308);
      expect(huge.every((t) => t.isFinite), isTrue);
      final tiny = dshUiNiceTicks(1e-320, 2e-320);
      expect(tiny, isNotEmpty);
      expect(dshUiNiceTicks(1e300, 1e301).length, lessThanOrEqualTo(24));
      expect(dshUiNiceTicks(10, 0).first, 0);
    });
  });

  group('value axis', () {
    test('bars start at zero, lines get padding', () {
      expect(dshUiValueAxis([3800, 5920], zero: true).first, 0);
      final line = dshUiValueAxis([3800, 5920], zero: false);
      expect(line.first, greaterThan(0));
      expect(line.first, lessThanOrEqualTo(3800 - 212));
      expect(line.last, greaterThanOrEqualTo(5920 + 212));
      expect(dshUiValueAxis([7, 7], zero: false), [6, 6.5, 7, 7.5, 8]);
      expect(dshUiValueAxis([], zero: true), [0, 0.25, 0.5, 0.75, 1]);
    });
  });

  test('values with units', () {
    expect(dshUiWithUnit(3800, '元'), '3,800 元');
    expect(dshUiWithUnit(38, '%'), '38%');
    expect(dshUiWithUnit(null, '元'), '—');
    expect(dshUiWithUnit(1.25, null), '1.25');
  });

  group('skeleton shape from half a block', () {
    test('reads the root title and the component types so far', () {
      final shape = guessDshUiShape(
        '{"type":"stack","title":"近 6 个月\\"支出\\"","children":[\n'
        ' {"type":"row","children":[\n'
        '  {"type":"metric","label":"月均","value":"¥4,180"},\n'
        '  {"type":"metric","label":"最高"',
      );
      expect(shape.title, '近 6 个月"支出"');
      expect(shape.parts, [const DshUiGhostPart(DshUiGhost.metrics, 2)]);
    });

    test('charts, options and the rest', () {
      final shape = guessDshUiShape(
        '{"type":"stack","children":['
        '{"type":"chart","kind":"hbar","categories":["a","b","c"],"series":[]},'
        '{"type":"chart","kind":"donut"},{"type":"chart"},'
        '{"type":"compare","items":[{"title":"A"},{"title":"B"},{"title":"C"}]},'
        '{"type":"steps","items":[{"label":"1"},{"label":"2"},{"label":"3"}]},'
        '{"type":"options","options":[{"label":"x"},{"label":"y"},{"label":"z"}',
      );
      expect(shape.title, isNull);
      expect(shape.parts, const [
        DshUiGhostPart(DshUiGhost.hbar, 3),
        DshUiGhostPart(DshUiGhost.donut),
        DshUiGhostPart(DshUiGhost.chart),
        DshUiGhostPart(DshUiGhost.compare, 3),
        DshUiGhostPart(DshUiGhost.steps, 3),
        DshUiGhostPart(DshUiGhost.options, 3),
      ]);
    });

    test('nothing yet is one block; a child title is not the root title', () {
      expect(guessDshUiShape('{"ty').parts, const [DshUiGhostPart(DshUiGhost.block)]);
      final shape = guessDshUiShape('{"type":"stack","children":[{"type":"compare","items":[{"title":"方案 A"');
      expect(shape.title, isNull);
    });
  });
}
