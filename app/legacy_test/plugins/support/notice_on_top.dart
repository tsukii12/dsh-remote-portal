import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Whether a tap at the centre of [text] lands on the SnackBar showing it. A
/// notice left under a modal sheet is in the tree but can't be seen.
bool snackBarOnTop(WidgetTester tester, String text) {
  final result = HitTestResult();
  tester.binding.hitTestInView(result, tester.getCenter(find.text(text)), tester.view.viewId);
  final bar = tester.renderObject(find.byType(SnackBar));
  // The first entry can be the TextSpan under the point; take the topmost box.
  final first = result.path.map((entry) => entry.target).whereType<RenderObject>().firstOrNull;
  for (RenderObject? node = first; node != null; node = node.parent) {
    if (identical(node, bar)) return true;
  }
  return false;
}
