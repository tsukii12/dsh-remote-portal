import 'dart:ui' show Tristate;

import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every enabled button in the semantics tree has a tap action, so a screen
/// reader's double tap does something. Call after `ensureSemantics()` and a pump.
void expectAllButtonsTappable() {
  final silent = find.semantics.byPredicate((node) {
    final data = node.getSemanticsData();
    return data.flagsCollection.isButton &&
        data.flagsCollection.isEnabled != Tristate.isFalse &&
        !data.hasAction(SemanticsAction.tap);
  });
  expect(silent, findsNothing, reason: 'enabled buttons without a tap action');
}
