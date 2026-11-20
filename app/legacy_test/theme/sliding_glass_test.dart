import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

class _Motion extends AnimationController {
  _Motion({required super.vsync, super.value});

  final _clients = <VoidCallback>[];

  bool get hasClients => _clients.isNotEmpty;

  @override
  void addListener(VoidCallback listener) {
    _clients.add(listener);
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    _clients.remove(listener);
    super.removeListener(listener);
  }
}

class _Counts {
  var inits = 0;
  var builds = 0;
  var disposes = 0;
}

class _Counted extends StatefulWidget {
  const _Counted(this.counts);

  final _Counts counts;

  @override
  State<_Counted> createState() => _CountedState();
}

class _CountedState extends State<_Counted> {
  @override
  void initState() {
    super.initState();
    widget.counts.inits++;
  }

  @override
  Widget build(BuildContext context) {
    widget.counts.builds++;
    return const SizedBox(width: 240, height: 320, child: Text('Panel content'));
  }

  @override
  void dispose() {
    widget.counts.disposes++;
    super.dispose();
  }
}

Future<void> _mount(
  WidgetTester tester,
  Animation<double> motion, {
  Widget child = const SizedBox(width: 240, height: 320),
  ThemeData? theme,
  bool reduced = false,
  bool highContrast = false,
}) => tester.pumpWidget(
  MaterialApp(
    theme: theme ?? buildLightTheme(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduced, highContrast: highContrast),
      child: child!,
    ),
    home: Scaffold(
      body: Center(
        child: SlidingGlass(
          motion: motion,
          tier: GlassTier.sheet,
          borderRadius: const BorderRadius.all(Radius.circular(28)),
          child: child,
        ),
      ),
    ),
  ),
);

RenderBackdropFilter _filter(WidgetTester tester) => tester.renderObject(find.byType(BackdropFilter));

double _settled(WidgetTester tester) => tester.widget<GlassSurface>(find.byType(GlassSurface)).settled!;

Color _fill(WidgetTester tester) {
  final box = find.descendant(of: find.byType(GlassSurface), matching: find.byType(DecoratedBox)).first;
  return (tester.widget<DecoratedBox>(box).decoration as ShapeDecoration).color!;
}

void main() {
  for (final theme in [buildLightTheme(), buildDarkTheme()]) {
    testWidgets('closing immediately stops sampling behind an opaque fill: ${theme.brightness}', (tester) async {
      final motion = _Motion(vsync: tester, value: 1);
      addTearDown(motion.dispose);
      final counts = _Counts();
      await _mount(tester, motion, theme: theme, child: _Counted(counts));
      final filter = _filter(tester);
      final style = theme.extension<DshSurfaces>()!.sheet;
      final builds = counts.builds;
      expect(filter.enabled, isTrue);
      expect(_fill(tester), style.fill);

      motion.value = 0.99;
      await tester.pump();
      expect(_filter(tester), same(filter));
      expect(filter.enabled, isFalse, reason: 'the first moving frame must not sample the background');
      expect(_fill(tester), style.fallbackFill, reason: 'sharp background text must not show through the moving panel');
      await tester.pump(const Duration(milliseconds: 60));
      expect(filter.enabled, isFalse);
      expect(_settled(tester), 0);
      expect(_fill(tester), style.fallbackFill);
      await tester.pumpAndSettle();
      expect(_fill(tester), style.fallbackFill);
      expect(_filter(tester), same(filter));
      expect(counts.inits, 1);
      expect(counts.builds, builds);
      expect(counts.disposes, 0);
      await tester.pumpWidget(const SizedBox());
      expect(counts.disposes, 1);
      expect(motion.hasClients, isFalse);
    });
  }

  testWidgets('opening stays unsampled until it reaches rest and fades into glass', (tester) async {
    final motion = _Motion(vsync: tester, value: 0);
    addTearDown(motion.dispose);
    await _mount(tester, motion);
    final filter = _filter(tester);
    expect(filter.enabled, isFalse);
    motion.value = 0.6;
    await tester.pump(const Duration(milliseconds: 60));
    expect(filter.enabled, isFalse);
    expect(_settled(tester), 0);
    motion.value = 1;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(filter.enabled, isTrue);
    expect(_settled(tester), inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect(_settled(tester), 1);
    expect(_filter(tester), same(filter));
  });

  testWidgets('dragging interrupts clear-in and resumes it only at rest', (tester) async {
    final motion = _Motion(vsync: tester, value: 0);
    addTearDown(motion.dispose);
    await _mount(tester, motion);
    final filter = _filter(tester);
    motion.value = 1;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(filter.enabled, isTrue);
    expect(_settled(tester), inExclusiveRange(0, 1));
    motion.value = 0.6;
    await tester.pump();
    expect(filter.enabled, isFalse);
    expect(_settled(tester), 0);
    motion.value = 1;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(filter.enabled, isTrue);
    await tester.pumpAndSettle();
    expect(_settled(tester), 1);
    motion.value = 0.8;
    await tester.pump();
    expect(filter.enabled, isFalse);
    motion.value = 0;
    await tester.pump();
    expect(_settled(tester), 0);
    expect(filter.enabled, isFalse);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('replacing motion transfers the listener and sampling state', (tester) async {
    final old = _Motion(vsync: tester, value: 1);
    final next = _Motion(vsync: tester, value: 0.5);
    addTearDown(old.dispose);
    addTearDown(next.dispose);
    await _mount(tester, old);
    final filter = _filter(tester);
    expect(old.hasClients, isTrue);
    await _mount(tester, next);
    expect(old.hasClients, isFalse);
    expect(next.hasClients, isTrue);
    expect(_filter(tester), same(filter));
    expect(filter.enabled, isFalse);
    old.value = 0;
    await tester.pump();
    expect(filter.enabled, isFalse);
    next.value = 1;
    await tester.pumpAndSettle();
    expect(filter.enabled, isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(next.hasClients, isFalse);
    next.value = 0;
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion keeps immediate opaque and glass states', (tester) async {
    final motion = _Motion(vsync: tester, value: 1);
    addTearDown(motion.dispose);
    await _mount(tester, motion, reduced: true);
    expect(_filter(tester).enabled, isTrue);
    motion.value = 0.5;
    await tester.pump();
    expect(_filter(tester).enabled, isFalse);
    expect(_settled(tester), 0);
    motion.value = 1;
    await tester.pump();
    expect(_filter(tester).enabled, isTrue);
    expect(_settled(tester), 1);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  for (final highContrast in [false, true]) {
    testWidgets('disabled blur does not create a filter: highContrast=$highContrast', (tester) async {
      final motion = _Motion(vsync: tester, value: 1);
      addTearDown(motion.dispose);
      final theme = buildLightTheme();
      await _mount(
        tester,
        motion,
        highContrast: highContrast,
        theme: highContrast
            ? theme
            : theme.copyWith(extensions: [theme.extension<DshSurfaces>()!.copyWith(blurEnabled: false)]),
      );
      expect(find.byType(BackdropFilter), findsNothing);
      motion.value = 0.5;
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsNothing);
      expect(_settled(tester), 0);
    });
  }

  testWidgets('a permanently open panel retains its glass', (tester) async {
    await _mount(tester, const AlwaysStoppedAnimation(1));
    await tester.pumpAndSettle();
    expect(_filter(tester).enabled, isTrue);
    expect(_settled(tester), 1);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
