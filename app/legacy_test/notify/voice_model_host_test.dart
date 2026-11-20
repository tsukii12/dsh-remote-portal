// The voice model's failure notice (lib/ui/notify/voice_model_host.dart): its
// 重试 is a download the person asked for, so it asks about mobile data the
// same way the settings card does.

import 'dart:async';

import 'package:dsh_app/state/voice_model_state.dart';
import 'package:dsh_app/ui/notify/voice_model_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';

/// A failed model whose events the test sends; the network kind can change.
class _FailedModel extends VoiceModelController {
  final sent = StreamController<VoiceModelEvent>.broadcast();
  bool isMetered = false;
  final actions = <String>[];

  @override
  VoiceModelState build() =>
      const VoiceModelState(status: VoiceModelStatus.failed, doneBytes: 41000000, failure: VoiceModelFailure.network);
  @override
  Stream<VoiceModelEvent> get events => sent.stream;
  @override
  Future<void> refresh() async {}
  @override
  void setForeground(bool foreground) {}
  @override
  Future<bool> metered() async => isMetered;
  @override
  Future<void> download() async => actions.add('download');
  @override
  Future<void> redownload() async => actions.add('redownload');
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('重试 on the failure notice asks about mobile data first, like the settings card', (tester) async {
    final model = _FailedModel();
    await tester.pumpWidget(
      testApp(const Scaffold(body: VoiceModelHost()), overrides: [voiceModelProvider.overrideWith(() => model)]),
    );
    await tester.pump();

    Future<void> fail() async {
      model.sent.add(const VoiceModelEvent(VoiceModelEventKind.failed, failure: VoiceModelFailure.network));
      await tester.pumpAndSettle();
      expect(find.text('语音模型下载失败：网络连接失败'), findsOneWidget);
    }

    // Started on Wi-Fi and failed; by the time 重试 is tapped the phone is on mobile data.
    await fail();
    model.isMetered = true;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('用移动数据下载？'), findsOneWidget);
    expect(find.text('语音模型约 200 MB，会使用移动数据流量。'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(model.actions, isEmpty, reason: 'declined: nothing downloads');

    await fail();
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('voice-model-metered-ok')));
    await tester.pumpAndSettle();
    expect(model.actions, ['download'], reason: 'confirmed: one download');
  });

  testWidgets('on Wi-Fi 重试 on the failure notice starts at once', (tester) async {
    final model = _FailedModel();
    await tester.pumpWidget(
      testApp(const Scaffold(body: VoiceModelHost()), overrides: [voiceModelProvider.overrideWith(() => model)]),
    );
    await tester.pump();
    model.sent.add(const VoiceModelEvent(VoiceModelEventKind.failed, failure: VoiceModelFailure.network));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(model.actions, ['download']);
  });

  testWidgets('重试 after a failed 重新下载 asks for the whole model again', (tester) async {
    final model = _FailedModel();
    await tester.pumpWidget(
      testApp(const Scaffold(body: VoiceModelHost()), overrides: [voiceModelProvider.overrideWith(() => model)]),
    );
    await tester.pump();
    model.sent.add(const VoiceModelEvent(VoiceModelEventKind.failed, failure: VoiceModelFailure.network, again: true));
    await tester.pumpAndSettle();
    expect(find.text('语音模型下载失败：网络连接失败'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(model.actions, ['redownload']);
  });
}
