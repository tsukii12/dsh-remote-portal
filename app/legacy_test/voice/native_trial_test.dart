import 'dart:io';

import 'package:dsh_app/voice/native_trial.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('native-trial-'));
  tearDown(() async => dir.delete(recursive: true));

  test('a run that decoded is proven and never marked again', () {
    final trial = NativeTrial(dir, 'ort-1.27.0');
    expect(trial.blocked(), isFalse);
    trial
      ..begin()
      ..passed();
    expect(trial.proven, isTrue);
    expect(NativeTrial(dir, 'ort-1.27.0').blocked(), isFalse);
    expect(trial.failed, isFalse);
  });

  test('a mark left behind (the app died in there) blocks that version, not the next', () {
    NativeTrial(dir, 'ort-1.27.0').begin();
    expect(NativeTrial(dir, 'ort-1.27.0').failed, isTrue);
    expect(NativeTrial(dir, 'ort-1.27.0').blocked(), isTrue);
    expect(NativeTrial(dir, 'ort-1.27.0').blocked(), isTrue);
    expect(NativeTrial(dir, 'ort-1.28.0').blocked(), isFalse);
  });

  test('stopped before it decoded: no verdict', () {
    final trial = NativeTrial(dir, 'ort-1.27.0')..begin();
    trial.dropped();
    expect(NativeTrial(dir, 'ort-1.27.0').blocked(), isFalse);
    expect(trial.proven, isFalse);
  });
}
