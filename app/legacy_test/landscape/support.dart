// The four review windows of the landscape / tablet layouts:
// a phone on its side, 600, 840 and 1280, each with its system insets.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// One window: [size] logical at DPR 2, with its system insets.
class Win {
  const Win(this.name, this.size, {this.left = 0, this.top = 24, this.right = 0, this.bottom = 16});

  final String name;
  final Size size;
  final double left, top, right, bottom;

  EdgeInsets get padding => EdgeInsets.fromLTRB(left, top, right, bottom);
}

/// A phone on its side, camera on the left, gesture navigation.
const phoneLeft = Win('phone', Size(915, 412), left: 36);

/// The same phone turned the other way, three-button navigation on the left
/// and the camera on the right.
const phoneRight = Win('phone_right', Size(915, 412), left: 48, right: 36, bottom: 0);

const w600 = Win('w600', Size(600, 900));
const w840 = Win('w840', Size(840, 700));
const w1280 = Win('w1280', Size(1280, 800));

/// The four review widths.
const wins = [phoneLeft, w600, w840, w1280];

/// Sets the view to [win]; [keyboard] dp of keyboard at the bottom.
void useWin(WidgetTester tester, Win win, {double keyboard = 0}) {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = win.size * 2;
  tester.view.viewPadding = FakeViewPadding(
    left: win.left * 2,
    top: win.top * 2,
    right: win.right * 2,
    bottom: win.bottom * 2,
  );
  setKeyboard(tester, win, keyboard);
  addTearDown(tester.view.reset);
}

/// Raises or drops the keyboard on [win]. As on a device, the keyboard
/// covers the gesture bar: padding = view padding − view insets.
void setKeyboard(WidgetTester tester, Win win, double keyboard) {
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard * 2);
  tester.view.padding = FakeViewPadding(
    left: win.left * 2,
    top: win.top * 2,
    right: win.right * 2,
    bottom: (win.bottom - keyboard).clamp(0, win.bottom) * 2,
  );
}
