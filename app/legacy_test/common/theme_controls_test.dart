import 'package:dsh_app/ui/common/capsule_chip.dart';
import 'package:dsh_app/ui/common/status_chip.dart';
import 'package:dsh_app/ui/common/streaming_cursor.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final theme in [buildLightTheme(), buildDarkTheme()]) {
    final scheme = theme.colorScheme;
    final surfaces = theme.extension<DshSurfaces>()!;
    // An opaque card as it sits on the page, and the opaque sheet.
    final card = Color.alphaBlend(surfaces.card.fill, surfaces.backdropTop);
    final sheet = surfaces.sheet.fallbackFill;

    test('switch: one light knob, accent track on, visible track off, faded when disabled: '
        '${theme.brightness}', () {
      final sw = theme.switchTheme;
      const on = {WidgetState.selected};
      const off = <WidgetState>{};
      const offDisabled = {WidgetState.disabled};
      const onDisabled = {WidgetState.selected, WidgetState.disabled};
      // Both states carry an icon, so the off knob is as big as the on one.
      expect(sw.thumbIcon!.resolve(off), isNotNull);
      expect(sw.thumbIcon!.resolve(on), isNotNull);
      expect(sw.thumbIcon!.resolve(off)!.color, Colors.transparent);
      for (final states in [on, off, onDisabled, offDisabled]) {
        expect(sw.trackOutlineColor!.resolve(states), Colors.transparent);
      }
      // Same light knob in both states.
      final knob = sw.thumbColor!.resolve(on)!;
      expect(sw.thumbColor!.resolve(off), knob);
      expect(knob.computeLuminance(), greaterThan(0.7));
      expect(contrastRatio(sw.thumbIcon!.resolve(on)!.color!, knob), greaterThan(3));
      // On: the accent; off: a neutral track that reads on the card.
      expect(sw.trackColor!.resolve(on), scheme.primary);
      final offTrack = Color.alphaBlend(sw.trackColor!.resolve(off)!, card);
      expect(contrastRatio(offTrack, card), greaterThan(1.4));
      expect(contrastRatio(knob, offTrack), greaterThan(1.4));
      expect(
        contrastRatio(scheme.primary, card),
        greaterThan(contrastRatio(offTrack, card)),
        reason: 'on reads stronger than off',
      );
      // Disabled is a fade of the same switch, well apart from enabled off.
      expect(sw.trackColor!.resolve(offDisabled)!.a, lessThan(sw.trackColor!.resolve(off)!.a / 2));
      expect(sw.trackColor!.resolve(onDisabled)!.a, lessThan(0.5));
      expect(sw.thumbColor!.resolve(offDisabled)!.a, lessThan(knob.a));
    });

    test('outlined button: border visible on cards and sheets, halved when disabled: '
        '${theme.brightness}', () {
      final side = theme.outlinedButtonTheme.style!.side!;
      final border = side.resolve({})!.color;
      for (final ground in [card, sheet]) {
        final ratio = contrastRatio(Color.alphaBlend(border, ground), ground);
        expect(ratio, greaterThan(1.35), reason: 'visible on $ground');
        expect(ratio, lessThan(2.2), reason: 'still quieter than a field outline');
      }
      expect(side.resolve({WidgetState.disabled})!.color.a, closeTo(border.a / 2, 0.01));
    });
  }

  testWidgets('dark capsule uses a transparent canvas inside its card', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        home: Scaffold(
          body: GlassSurface(
            tier: GlassTier.card,
            child: CapsuleChoiceChip(label: '选项', selected: false, onSelected: () {}),
          ),
        ),
      ),
    );
    final chip = tester.element(find.byType(ChoiceChip));
    expect(Theme.of(chip).canvasColor, Colors.transparent);
    final materials = find.descendant(of: find.byType(ChoiceChip), matching: find.byType(Material));
    expect(materials, findsWidgets);
    for (final element in materials.evaluate()) {
      expect(Theme.of(element).canvasColor, Colors.transparent);
    }
  });

  testWidgets('rebuilds reuse all three opacity animations', (tester) async {
    var rebuilds = 0;
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return Column(
                children: [
                  StreamingCursor(color: rebuilds.isEven ? Colors.blue : Colors.red),
                  StatusDot(tone: StatusTone.busy, size: rebuilds.isEven ? 8 : 9),
                  AnimatedStatusDot(tone: rebuilds.isEven ? StatusTone.busy : StatusTone.ok),
                ],
              );
            },
          ),
        ),
      ),
    );
    List<Animation<double>> animations() => [
      for (final type in [StreamingCursor, StatusDot, AnimatedStatusDot])
        tester
            .widget<FadeTransition>(find.descendant(of: find.byType(type), matching: find.byType(FadeTransition)).first)
            .opacity,
    ];
    final before = animations();
    for (var i = 0; i < 3; i++) {
      rebuild(() => rebuilds++);
      await tester.pump(const Duration(milliseconds: 1));
      expect(animations(), pairwiseCompare(before, identical, 'same animation'));
    }
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
    expect(tester.binding.transientCallbackCount, 0);
  });
}
