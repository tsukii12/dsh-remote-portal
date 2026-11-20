import 'package:dsh_app/dev/remote_benchmark.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final messages = <String>[];
  late DebugPrintCallback previous;
  setUp(() {
    messages.clear();
    previous = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) messages.add(message);
    };
  });
  tearDown(() => debugPrint = previous);

  test('successful first operation emits one numeric measurement when enabled', () {
    RemoteBenchmark.start('test_success');
    RemoteBenchmark.finish('test_success');
    RemoteBenchmark.start('test_success');
    RemoteBenchmark.finish('test_success');
    expect(messages.length, RemoteBenchmark.enabled ? 1 : 0);
    if (RemoteBenchmark.enabled) expect(messages.single, matches(r'^YUREMOTE_PERF test_success \d+ us$'));
  });

  test('finishing an empty timer emits nothing', () {
    RemoteBenchmark.finish('test_empty');
    expect(messages, isEmpty);
  });

  test('failed operation cancels without measuring a later user delay', () {
    RemoteBenchmark.start('test_failure');
    try {
      throw StateError('fixture');
    } on StateError {
      RemoteBenchmark.cancel('test_failure');
    }
    RemoteBenchmark.finish('test_failure');
    expect(messages, isEmpty);
    RemoteBenchmark.start('test_failure');
    RemoteBenchmark.finish('test_failure');
    expect(messages.length, RemoteBenchmark.enabled ? 1 : 0);
  });
}
