// The adaptive frame on its own, with stand-in columns: where each column
// sits, what window each one sees (size, system insets, place in the
// backdrop), the hairline on the panel's edge, the chat keeping its state
// across rotation, and the columns moving together. Measured, not eyeballed.
//
//   flutter test test/shell/adaptive/adaptive_scaffold_test.dart

import 'package:dsh_app/ui/shell/adaptive/adaptive_layout.dart';
import 'package:dsh_app/ui/shell/adaptive/adaptive_scaffold.dart';
import 'package:dsh_app/ui/theme/backdrop_frame.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../chat/support/harness.dart';

const _top = 24.0;
const _bottom = 16.0;

/// Records what its column looks like from inside.
class _Probe extends StatefulWidget {
  const _Probe(this.name);

  final String name;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  static final created = <String, int>{};
  late MediaQueryData media;
  BackdropFrame? frame;

  @override
  void initState() {
    super.initState();
    created[widget.name] = (created[widget.name] ?? 0) + 1;
  }

  @override
  Widget build(BuildContext context) {
    media = MediaQuery.of(context);
    frame = BackdropFrame.maybeOf(context);
    return SizedBox.expand(key: ValueKey('probe-${widget.name}'));
  }
}

_ProbeState _probe(WidgetTester tester, String name) =>
    tester.state<_ProbeState>(find.ancestor(of: find.byKey(ValueKey('probe-$name')), matching: find.byType(_Probe)));

void _window(WidgetTester tester, Size size, {EdgeInsets padding = const EdgeInsets.only(top: _top, bottom: _bottom)}) {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = size * 2;
  final fake = FakeViewPadding(
    left: padding.left * 2,
    top: padding.top * 2,
    right: padding.right * 2,
    bottom: padding.bottom * 2,
  );
  tester.view.padding = fake;
  tester.view.viewPadding = fake;
  addTearDown(tester.view.reset);
}

AdaptiveLayout _layoutFor(WidgetTester tester, {bool panelOpen = true, bool sidebarOpen = true, bool session = true}) {
  final view = tester.view;
  final size = view.physicalSize / view.devicePixelRatio;
  final p = view.padding;
  return AdaptiveLayout.resolve(
    window: size,
    padding: EdgeInsets.fromLTRB(
      p.left / view.devicePixelRatio,
      p.top / view.devicePixelRatio,
      p.right / view.devicePixelRatio,
      p.bottom / view.devicePixelRatio,
    ),
    hasSession: session,
    sidebarOpen: sidebarOpen,
    panelOpen: panelOpen,
  );
}

/// The frame with stand-ins; [layout] is read on every build so a test can
/// change it and pump.
class _Host extends StatefulWidget {
  const _Host({required this.layout, this.animate = false});

  final AdaptiveLayout Function() layout;
  final bool animate;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  void rebuild() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final layout = widget.layout();
    return AdaptiveScaffold(
      layout: layout,
      animate: widget.animate,
      body: const _Probe('chat'),
      rail: const _Probe('rail'),
      sidebar: const _Probe('sidebar'),
      panel: layout.panelAvailable ? const _Probe('panel') : null,
    );
  }
}

Future<void> _pump(WidgetTester tester, AdaptiveLayout Function() layout, {bool animate = false}) async {
  await tester.pumpWidget(testApp(_Host(layout: layout, animate: animate)));
  await tester.pump();
}

Rect _rect(WidgetTester tester, String name) => tester.getRect(find.byKey(ValueKey('probe-$name')));

void main() {
  setUp(_ProbeState.created.clear);

  group('1280 × 800, panel shown', () {
    testWidgets('rail · chat · panel, edge to edge', (tester) async {
      _window(tester, const Size(1280, 800));
      await _pump(tester, () => _layoutFor(tester));

      expect(_rect(tester, 'rail'), const Rect.fromLTWH(0, 0, 68, 800));
      expect(_rect(tester, 'chat'), const Rect.fromLTWH(68, 0, 828, 800));
      expect(_rect(tester, 'panel'), const Rect.fromLTWH(896, 0, 384, 800));
      expect(find.byKey(const ValueKey('probe-sidebar')), findsNothing);

      // One physical pixel on the panel's edge, the full height.
      final line = tester.getRect(find.byKey(const ValueKey('adaptive-panel-hairline')));
      expect(line, const Rect.fromLTWH(896, 0, 0.5, 800));
    });

    testWidgets('each column sees itself as the window', (tester) async {
      _window(tester, const Size(1280, 800));
      await _pump(tester, () => _layoutFor(tester));

      final chat = _probe(tester, 'chat');
      expect(chat.media.size, const Size(828, 800));
      expect(chat.media.padding, const EdgeInsets.only(top: _top, bottom: _bottom));
      expect(chat.frame?.origin, const Offset(68, 0));
      expect(chat.frame?.area, const Size(1280, 800));

      final panel = _probe(tester, 'panel');
      expect(panel.media.size, const Size(384, 800));
      expect(panel.frame?.origin, const Offset(896, 0));
      expect(panel.frame?.area, const Size(1280, 800));

      final rail = _probe(tester, 'rail');
      expect(rail.media.size, const Size(68, 800));
      expect(rail.frame?.origin, Offset.zero);
    });

    testWidgets('side insets go to the edge columns only', (tester) async {
      // A cutout on the left, the navigation bar on the right: the app's
      // root mirrors the larger one (MirroredSideInsets), 48 on each side.
      const insets = EdgeInsets.fromLTRB(32, _top, 48, _bottom);
      _window(tester, const Size(1280, 800), padding: insets);
      await _pump(tester, () => _layoutFor(tester));

      final layout = _layoutFor(tester);
      final chat = _probe(tester, 'chat');
      expect(chat.media.padding.left, 0);
      expect(chat.media.padding.right, 0);
      expect(_probe(tester, 'rail').media.padding.left, 48);
      expect(_rect(tester, 'rail').width, 68 + 48);

      // The panel's content stops at the navigation bar; the bar's strip
      // shows the page.
      final panel = _rect(tester, 'panel');
      expect(panel.right, 1280 - 48);
      expect(panel.width, layout.panelWidth);
      expect(_probe(tester, 'panel').media.padding.right, 0);
      expect(_rect(tester, 'chat').right, panel.left);
    });
  });

  testWidgets('1280 × 800, panel folded: sidebar · chat', (tester) async {
    _window(tester, const Size(1280, 800));
    await _pump(tester, () => _layoutFor(tester, panelOpen: false));
    expect(_rect(tester, 'sidebar'), const Rect.fromLTWH(0, 0, 320, 800));
    expect(_rect(tester, 'chat'), const Rect.fromLTWH(320, 0, 960, 800));
    expect(find.byKey(const ValueKey('probe-panel')), findsNothing);
    expect(find.byKey(const ValueKey('probe-rail')), findsNothing);
    expect(find.byKey(const ValueKey('adaptive-panel-hairline')), findsNothing);
    expect(_probe(tester, 'chat').media.padding.right, 0);
  });

  for (final size in [const Size(390, 844), const Size(720, 900)]) {
    testWidgets('${size.width.round()} wide: only the chat, untouched', (tester) async {
      _window(tester, size);
      MediaQueryData? outer;
      await tester.pumpWidget(
        testApp(
          Builder(
            builder: (context) {
              outer = MediaQuery.of(context);
              return AdaptiveScaffold(
                layout: _layoutFor(tester),
                body: const _Probe('chat'),
                rail: const _Probe('rail'),
                sidebar: const _Probe('sidebar'),
                panel: const _Probe('panel'),
              );
            },
          ),
        ),
      );
      expect(_rect(tester, 'chat'), Offset.zero & size);
      expect(_probe(tester, 'chat').media, outer);
      for (final other in ['rail', 'sidebar', 'panel']) {
        expect(find.byKey(ValueKey('probe-$other')), findsNothing);
      }
    });
  }

  testWidgets('a phone on its side: the chat set in from both sides alike', (tester) async {
    // Camera on the left; the root mirrors it onto the right.
    const insets = EdgeInsets.fromLTRB(36, 24, 0, 16);
    _window(tester, const Size(915, 412), padding: insets);
    await _pump(tester, () => _layoutFor(tester));
    expect(_layoutFor(tester).windowClass, WindowClass.compact);
    expect(_rect(tester, 'chat'), const Rect.fromLTRB(36, 0, 915 - 36, 412));
    final chat = _probe(tester, 'chat');
    expect(chat.media.size, const Size(915 - 72, 412));
    expect(chat.media.padding, const EdgeInsets.only(top: 24, bottom: 16));
    expect(chat.frame?.origin, const Offset(36, 0));
    for (final other in ['rail', 'sidebar', 'panel']) {
      expect(find.byKey(ValueKey('probe-$other')), findsNothing);
    }
  });

  testWidgets('turning a phone keeps the chat (same state)', (tester) async {
    const upright = EdgeInsets.only(top: 24, bottom: 16);
    _window(tester, const Size(412, 915), padding: upright);
    await _pump(tester, () => _layoutFor(tester));
    final before = _probe(tester, 'chat');

    _window(tester, const Size(915, 412), padding: const EdgeInsets.fromLTRB(36, 24, 0, 16));
    tester.state<_HostState>(find.byType(_Host)).rebuild();
    await tester.pump();
    expect(_probe(tester, 'chat'), same(before));
    expect(_rect(tester, 'chat').width, 915 - 72);

    _window(tester, const Size(412, 915), padding: upright);
    tester.state<_HostState>(find.byType(_Host)).rebuild();
    await tester.pump();
    expect(_probe(tester, 'chat'), same(before));
    expect(_ProbeState.created['chat'], 1);
  });

  testWidgets('turning the tablet keeps the chat (same state)', (tester) async {
    _window(tester, const Size(1280, 800));
    await _pump(tester, () => _layoutFor(tester));
    final before = _probe(tester, 'chat');

    _window(tester, const Size(800, 1280));
    tester.state<_HostState>(find.byType(_Host)).rebuild();
    await tester.pump();
    expect(_probe(tester, 'chat'), same(before));
    expect(_rect(tester, 'chat'), const Rect.fromLTWH(0, 0, 800, 1280));

    _window(tester, const Size(1280, 800));
    tester.state<_HostState>(find.byType(_Host)).rebuild();
    await tester.pump();
    expect(_probe(tester, 'chat'), same(before));
    expect(_ProbeState.created['chat'], 1);
  });

  testWidgets('folding the panel: the chat edge travels with it', (tester) async {
    _window(tester, const Size(1280, 800));
    var open = true;
    await _pump(tester, () => _layoutFor(tester, panelOpen: open), animate: true);
    expect(_rect(tester, 'chat').right, 896);

    open = false;
    tester.state<_HostState>(find.byType(_Host)).rebuild();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final chat = _rect(tester, 'chat');
    final panel = _rect(tester, 'panel');
    // Mid-way: the panel slides out at full width, its edge on the chat's.
    expect(chat.right, greaterThan(896));
    expect(chat.right, lessThan(1280));
    expect(panel.left, moreOrLessEquals(chat.right, epsilon: 0.01));
    expect(panel.width, 384);

    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('probe-panel')), findsNothing);
    // With the panel gone the sidebar fits again.
    expect(_rect(tester, 'chat').left, 320);
    expect(_rect(tester, 'chat').right, 1280);
  });

  testWidgets('the chrome publishes the layout and the header rules', (tester) async {
    _window(tester, const Size(1280, 800));
    var open = true;
    await _pump(tester, () => _layoutFor(tester, panelOpen: open));
    AdaptiveChrome chrome() => tester.widget<AdaptiveChrome>(find.byType(AdaptiveChrome));
    // Rail: its own ≡ key, the header's goes; the panel shows.
    expect(chrome().showsMenuKey, isFalse);
    expect(chrome().showsPanelKey, isFalse);
    expect(chrome().menuTooltip, '对话列表');

    open = false;
    tester.state<_HostState>(find.byType(_Host)).rebuild();
    await tester.pump();
    // Sidebar: the header's ≡ folds it; the corner key brings the panel.
    expect(chrome().showsMenuKey, isTrue);
    expect(chrome().menuTooltip, '收起对话列表');
    expect(chrome().showsPanelKey, isTrue);
  });
}
