import 'dart:async';

import '../legacy_test/flutter_test_config.dart' as support;

Future<void> testExecutable(FutureOr<void> Function() testMain) => support.testExecutable(testMain);
