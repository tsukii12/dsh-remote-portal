// Symmetry of the terminal page, measured: the key row is twelve equal cells
// with centred labels and equal side insets (scrolling, never uneven, when
// too narrow); the status row has the same height and
// its button is concentric with the card corner; the top bar's round keys
// mirror each other around a centred title; the tab capsules and 「+」 share
// one height and one centre line, flush with the card's edge.

import 'package:dsh_app/ui/terminal/terminal_keys.dart';
import 'package:dsh_app/ui/terminal/terminal_page.dart';
import 'package:dsh_app/ui/terminal/terminal_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import 'support.dart';

Rect _rect(WidgetTester tester, Finder finder) => tester.getRect(finder);

Rect _card(WidgetTester tester) => _rect(tester, find.byType(TerminalCardFrame));

Finder _cell(TerminalExtraKey key) => find.byKey(ValueKey('terminal-key-${key.name}'));

Rect _label(WidgetTester tester, TerminalExtraKey key) =>
    _rect(tester, find.descendant(of: _cell(key), matching: find.byKey(const ValueKey('terminal-key-label'))));

Rect _pill(WidgetTester tester, TerminalExtraKey key) =>
    _rect(tester, find.descendant(of: _cell(key), matching: find.byKey(const ValueKey('terminal-key-pill'))));

/// Every key: a cell of the same width, cells edge to edge, the label (and
/// its pill) centred in the cell, the touch height at least 44.
void _expectEqualCells(WidgetTester tester) {
  final cells = [for (final key in TerminalExtraKey.values) _rect(tester, _cell(key))];
  for (final (i, key) in TerminalExtraKey.values.indexed) {
    final cell = cells[i];
    expect(cell.width, moreOrLessEquals(cells.first.width), reason: '${key.name} is as wide as the others');
    expect(cell.height, greaterThanOrEqualTo(44));
    if (i > 0) expect(cell.left, moreOrLessEquals(cells[i - 1].right), reason: 'no uneven gaps');
    final label = _label(tester, key);
    expect(label.center.dx, moreOrLessEquals(cell.center.dx), reason: '${key.name} label centred');
    expect(label.center.dy, moreOrLessEquals(cell.center.dy), reason: '${key.name} label centred');
    final pill = _pill(tester, key);
    expect(pill.center.dx, moreOrLessEquals(cell.center.dx));
    expect(pill.center.dy, moreOrLessEquals(cell.center.dy));
    expect(pill.height, TerminalBar.pillHeight);
    expect(
      pill.width,
      lessThanOrEqualTo(cell.width - TerminalBar.pillGap + 0.01),
      reason: '${key.name} pill stays inside its cell, apart from its neighbours',
    );
    expect(label.left - cell.left, greaterThanOrEqualTo(TerminalBar.labelMargin - 0.01));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('key row: twelve equal cells across the card, labels centred, equal insets', (tester) async {
    await pumpTerminalPage(tester, FakeTerminalBackend(terminals: [infoJson('a')]));
    final card = _card(tester);
    final row = _rect(tester, find.byType(ExtraKeysRow));
    expect(row.height, TerminalBar.height);
    expect(row.bottom, moreOrLessEquals(card.bottom));
    expect(find.byKey(const ValueKey('terminal-keys-scroll')), findsNothing, reason: 'fits on a 390dp phone');
    _expectEqualCells(tester);
    final first = _rect(tester, _cell(TerminalExtraKey.esc));
    final last = _rect(tester, _cell(TerminalExtraKey.dash));
    expect(first.left - card.left, moreOrLessEquals(TerminalBar.inset));
    expect(card.right - last.right, moreOrLessEquals(TerminalBar.inset));
  });

  testWidgets('armed and locked modifiers: a pill behind the label, centred in the cell', (tester) async {
    await pumpTerminalPage(tester, FakeTerminalBackend(terminals: [infoJson('a')]));
    await tester.tap(_cell(TerminalExtraKey.ctrl));
    await tester.pump();
    final gesture = await tester.startGesture(tester.getCenter(_cell(TerminalExtraKey.alt)));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.up();
    await settleTerminal(tester);
    for (final key in [TerminalExtraKey.ctrl, TerminalExtraKey.alt]) {
      final cell = _rect(tester, _cell(key));
      final pill = _pill(tester, key);
      final label = _label(tester, key);
      expect(pill.center.dx, moreOrLessEquals(cell.center.dx));
      expect(pill.center.dy, moreOrLessEquals(cell.center.dy));
      expect(label.center.dx, moreOrLessEquals(pill.center.dx));
      expect(pill.left, lessThanOrEqualTo(label.left - TerminalBar.labelMargin + 0.01));
      expect(pill.right, greaterThanOrEqualTo(label.right + TerminalBar.labelMargin - 0.01));
    }
    _expectEqualCells(tester);
  });

  for (final (width, scale) in [(320.0, 1.0), (390.0, 1.3)]) {
    testWidgets('too narrow (${width.round()}dp, text ×$scale): equal cells that scroll', (tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = Size(width * 2, 700 * 2);
      addTearDown(tester.view.reset);
      await tester.runAsync(loadGoldenFonts);
      await tester.pumpWidget(
        goldenApp(
          brightness: Brightness.light,
          overrides: terminalOverrides(FakeTerminalBackend(terminals: [infoJson('a')])),
          home: MediaQuery.withClampedTextScaling(
            minScaleFactor: scale,
            maxScaleFactor: scale,
            child: const TerminalPage(sessionId: 's1'),
          ),
        ),
      );
      await settleTerminal(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('terminal-keys-scroll')), findsOneWidget);
      final minCell = ExtraKeysRow.minCellWidth(tester.element(find.byType(ExtraKeysRow)));
      expect(_rect(tester, _cell(TerminalExtraKey.esc)).width, moreOrLessEquals(minCell));
      _expectEqualCells(tester);
      final card = _card(tester);
      expect(
        _rect(tester, _cell(TerminalExtraKey.esc)).left - card.left,
        moreOrLessEquals(TerminalBar.inset, epsilon: 0.01),
      );
      await tester.drag(find.byKey(const ValueKey('terminal-keys-scroll')), const Offset(-600, 0));
      await settleTerminal(tester);
      expect(
        card.right - _rect(tester, _cell(TerminalExtraKey.dash)).right,
        moreOrLessEquals(TerminalBar.inset, epsilon: 0.01),
      );
    });
  }

  testWidgets('status row: same height as the key row; the button 8 from the corner', (tester) async {
    final backend = FakeTerminalBackend(terminals: [infoJson('a')]);
    await pumpTerminalPage(tester, backend);
    backend.attachOf('a').lose();
    await settleTerminal(tester);
    final card = _card(tester);
    final bar = _rect(tester, find.byType(TerminalStatusBar));
    expect(bar.height, TerminalBar.height);
    expect(bar.bottom, moreOrLessEquals(card.bottom));
    final button = _rect(tester, find.byKey(const ValueKey('terminal-status-action')));
    expect(button.height, TerminalBar.keyHeight);
    expect(card.right - button.right, moreOrLessEquals(8));
    expect(button.top - bar.top, moreOrLessEquals(8));
    expect(bar.bottom - button.bottom, moreOrLessEquals(8));
  });

  testWidgets('top bar: mirrored round keys, centred title', (tester) async {
    await pumpTerminalPage(tester, FakeTerminalBackend(terminals: [infoJson('a')]));
    final screen = tester.getSize(find.byType(Scaffold));
    final back = _rect(tester, find.byKey(const ValueKey('terminal-back')));
    final more = _rect(tester, find.byKey(const ValueKey('terminal-more')));
    expect(back.size, more.size);
    expect(back.width, 44);
    expect(back.left, moreOrLessEquals(screen.width - more.right));
    expect(back.center.dy, moreOrLessEquals(more.center.dy));
    final title = _rect(tester, find.text('终端'));
    expect(title.center.dx, moreOrLessEquals(screen.width / 2, epsilon: 0.5));
    // The card lines up with the round keys.
    final card = _card(tester);
    expect(card.left, moreOrLessEquals(back.left));
    expect(screen.width - card.right, moreOrLessEquals(screen.width - more.right));
  });

  testWidgets('tabs: capsules and 「+」 share a height and a centre line, flush with the card', (tester) async {
    await pumpTerminalPage(
      tester,
      FakeTerminalBackend(
        terminals: [
          infoJson('a', title: 'server'),
          infoJson('b', title: 'build'),
        ],
      ),
    );
    final a = _rect(tester, find.byKey(const ValueKey('terminal-tab-a')));
    final b = _rect(tester, find.byKey(const ValueKey('terminal-tab-b')));
    final plus = _rect(tester, find.byKey(const ValueKey('terminal-new')));
    expect(a.height, 32);
    expect(b.height, a.height);
    expect(plus.height, a.height);
    expect(plus.width, plus.height);
    expect(b.center.dy, moreOrLessEquals(a.center.dy));
    expect(plus.center.dy, moreOrLessEquals(a.center.dy));
    expect(b.left - a.right, moreOrLessEquals(plus.left - b.right));
    expect(a.left, moreOrLessEquals(_card(tester).left));
  });
}
