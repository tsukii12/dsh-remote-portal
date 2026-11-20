import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The haptics asked for from here to the test's end, in order, by type
/// (`HapticFeedbackType.selectionClick` …). Other platform calls answer null.
List<String> recordHaptics(WidgetTester tester) {
  final felt = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'HapticFeedback.vibrate') felt.add('${call.arguments}');
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return felt;
}
