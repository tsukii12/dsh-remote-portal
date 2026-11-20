// The voice settings page with its model card: goldens of each state, the
// card's symmetry measured, and the confirmations (mobile data, delete).
//
//   flutter test --update-goldens test/settings/voice_model_card_test.dart

import 'dart:async';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/streaming_asr_model_state.dart';
import 'package:dsh_app/state/voice_model_state.dart';
import 'package:dsh_app/ui/settings/voice_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../shell/golden_harness.dart';
import '../support/english_preview.dart';

/// A model state that stays put; actions are recorded.
class FixedVoiceModel extends VoiceModelController {
  FixedVoiceModel(this.fixed, {this.isMetered = false, this.deletes = true, this.stopping = false});
  final VoiceModelState fixed;
  final bool isMetered;

  /// What [delete] answers, and why it would not delete.
  final bool deletes;
  final bool stopping;
  final actions = <String>[];

  @override
  VoiceModelState build() => fixed;
  @override
  Future<void> refresh() async {}
  @override
  Future<bool> metered() async => isMetered;
  @override
  Future<void> download() async => actions.add('download');
  @override
  Future<void> cancel() async => actions.add('cancel');
  @override
  Future<bool> delete() async {
    actions.add('delete');
    return deletes;
  }

  @override
  bool get downloadStopping => stopping;

  @override
  Future<void> redownload() async => actions.add('redownload');
}

/// The streaming recognizer's card, not downloaded (the real one would look for files).
class _NoStreamingModel extends StreamingAsrModelController {
  @override
  StreamingAsrModelState build() => const StreamingAsrModelState(status: StreamingAsrModelStatus.absent);
}

final _noStreamingModel = streamingAsrModelProvider.overrideWith(_NoStreamingModel.new);

const _total = voiceModelDefaultBytes;

const states = <String, VoiceModelState>{
  'absent': VoiceModelState(status: VoiceModelStatus.absent),
  'downloading': VoiceModelState(status: VoiceModelStatus.downloading, doneBytes: 108000000),
  'ready': VoiceModelState(status: VoiceModelStatus.ready, doneBytes: _total),
  'failed': VoiceModelState(status: VoiceModelStatus.failed, doneBytes: 41000000, failure: VoiceModelFailure.network),
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => AppLocale.use(AppLocale.zhCN));

  // The card sits below 朗读 and the recognition choices: in view before the picture.
  Future<void> toCard(WidgetTester tester) async {
    final card = find.byKey(const ValueKey('voice-model-card'));
    await tester.scrollUntilVisible(card, 200, scrollable: find.byType(Scrollable).first);
    unawaited(Scrollable.ensureVisible(tester.element(card), alignment: 0.3));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }

  for (final MapEntry(key: name, value: state) in states.entries) {
    goldenBoth(
      'voice_model_$name',
      () => const VoiceSettingsPage(),
      overrides: () => [voiceModelProvider.overrideWith(() => FixedVoiceModel(state)), _noStreamingModel],
      before: toCard,
    );
  }

  testWidgets('voice_model_ready (en)', (tester) async {
    useEnglish();
    await tester.runAsync(loadGoldenFonts);
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: inEnglish(const VoiceSettingsPage()),
        brightness: Brightness.light,
        overrides: [voiceModelProvider.overrideWith(() => FixedVoiceModel(states['ready']!)), _noStreamingModel],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await toCard(tester);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/en_voice_model_ready_light.png'));
  });

  Future<FixedVoiceModel> pumpCard(
    WidgetTester tester,
    VoiceModelState state, {
    double width = 390,
    double scale = 1,
    bool metered = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 900);
    addTearDown(tester.view.reset);
    final model = FixedVoiceModel(state, isMetered: metered);
    await tester.pumpWidget(
      testApp(
        Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
            child: const VoiceSettingsPage(),
          ),
        ),
        overrides: [voiceModelProvider.overrideWith(() => model)],
      ),
    );
    await tester.pumpAndSettle();
    final card = find.byKey(const ValueKey('voice-model-card'));
    // Below 朗读 and the recognition choices: not built until scrolled to.
    await tester.scrollUntilVisible(card, 200, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    return model;
  }

  for (final width in [320.0, 390.0]) {
    for (final scale in [1.0, 2.0]) {
      for (final MapEntry(key: name, value: state) in states.entries) {
        testWidgets('model card $name at ${width.toInt()}dp ×$scale is symmetric', (tester) async {
          if (scale == 2) AppLocale.use(AppLocale.en);
          await pumpCard(tester, state, width: width, scale: scale);
          final card = tester.getRect(find.byKey(const ValueKey('voice-model-card')));
          expect(card.left, greaterThanOrEqualTo(0));
          expect(card.right, lessThanOrEqualTo(width));
          final status = tester.getRect(find.byKey(const ValueKey('voice-model-status')));
          final title = tester.getRect(find.text(voiceModelName));
          final actions = tester.getRect(find.byKey(const ValueKey('voice-model-actions')));
          const inset = VoiceModelCard.padding;
          // Same distance from the card edge on both sides, for the text row and the buttons.
          expect(title.left - card.left, moreOrLessEquals(inset.left));
          expect(card.right - status.right, moreOrLessEquals(inset.right, epsilon: 0.5));
          expect(actions.left - card.left, moreOrLessEquals(inset.left));
          expect(card.right - actions.right, moreOrLessEquals(inset.right));
          expect(card.bottom - actions.bottom, moreOrLessEquals(inset.bottom));
          final buttons = find.descendant(
            of: find.byKey(const ValueKey('voice-model-actions')),
            matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
          );
          final rects = [for (final e in buttons.evaluate()) tester.getRect(find.byWidget(e.widget))];
          expect(rects, isNotEmpty);
          final stacked = rects.length == 2 && rects[1].top >= rects[0].bottom;
          for (final r in rects) {
            expect(r.height, greaterThanOrEqualTo(48), reason: 'tap target');
            expect(r.width, moreOrLessEquals(rects.first.width), reason: 'equal widths');
            if (stacked) {
              expect(r.left, moreOrLessEquals(actions.left));
              expect(r.right, moreOrLessEquals(actions.right));
            } else {
              expect(r.center.dy, moreOrLessEquals(rects.first.center.dy));
            }
          }
          if (rects.length == 2 && !stacked) {
            expect(rects[1].left - rects[0].right, moreOrLessEquals(VoiceModelCard.buttonGap));
          }
          // No label is cut short.
          for (final e
              in find
                  .descendant(of: find.byKey(const ValueKey('voice-model-actions')), matching: find.byType(Text))
                  .evaluate()) {
            final paragraph = e.renderObject! as RenderParagraph;
            expect(paragraph.didExceedMaxLines, isFalse, reason: (e.widget as Text).data);
          }
          final bar = find.byKey(const ValueKey('voice-model-progress'));
          if (state.busy) {
            final r = tester.getRect(bar);
            expect(r.left, moreOrLessEquals(actions.left));
            expect(r.right, moreOrLessEquals(actions.right));
          } else {
            expect(bar, findsNothing);
          }
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  testWidgets('download on mobile data shows the size first; cancel keeps it from starting', (tester) async {
    final model = await pumpCard(tester, states['absent']!, metered: true);
    await tester.tap(find.byKey(const ValueKey('voice-model-download')));
    await tester.pumpAndSettle();
    expect(find.text('用移动数据下载？'), findsOneWidget);
    expect(find.text('语音模型约 241 MB，会使用移动数据流量。'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(model.actions, isEmpty);
    await tester.tap(find.byKey(const ValueKey('voice-model-download')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('voice-model-metered-ok')));
    await tester.pumpAndSettle();
    expect(model.actions, ['download']);
  });

  testWidgets('on Wi-Fi the download starts at once', (tester) async {
    final model = await pumpCard(tester, states['absent']!);
    await tester.tap(find.byKey(const ValueKey('voice-model-download')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(model.actions, ['download']);
  });

  testWidgets('a partly downloaded model offers 继续下载 with what is left', (tester) async {
    final model = await pumpCard(
      tester,
      const VoiceModelState(status: VoiceModelStatus.absent, doneBytes: 141000000),
      metered: true,
    );
    expect(find.text('继续下载'), findsOneWidget);
    expect(find.text('141 MB / 241 MB'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('voice-model-download')));
    await tester.pumpAndSettle();
    expect(find.text('语音模型约 100 MB，会使用移动数据流量。'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('voice-model-metered-ok')));
    await tester.pumpAndSettle();
    expect(model.actions, ['download']);
  });

  testWidgets('delete asks first', (tester) async {
    final model = await pumpCard(tester, states['ready']!);
    await tester.tap(find.byKey(const ValueKey('voice-model-delete')));
    await tester.pumpAndSettle();
    expect(find.text('删除语音模型？'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('voice-model-delete-ok')));
    await tester.pumpAndSettle();
    expect(model.actions, ['delete']);
  });

  for (final stopping in [true, false]) {
    testWidgets('a delete that did not go through says why (download still stopping: $stopping)', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 900);
      addTearDown(tester.view.reset);
      final model = FixedVoiceModel(states['ready']!, deletes: false, stopping: stopping);
      await tester.pumpWidget(
        testApp(const VoiceSettingsPage(), overrides: [voiceModelProvider.overrideWith(() => model)]),
      );
      await tester.pumpAndSettle();
      // Below 朗读 and the recognition choices: built once scrolled to.
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('voice-model-delete')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.byKey(const ValueKey('voice-model-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('voice-model-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('voice-model-delete-ok')));
      await tester.pumpAndSettle();
      expect(model.actions, ['delete']);
      expect(find.text('下载还在停止，请稍后再删'), stopping ? findsOneWidget : findsNothing);
      expect(find.text('没能删除语音模型，请重试'), stopping ? findsNothing : findsOneWidget);
    });
  }

  testWidgets('cancel goes straight to the controller', (tester) async {
    final model = await pumpCard(tester, states['downloading']!);
    expect(find.text('44%'), findsOneWidget);
    expect(find.text('108 MB / 241 MB'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('voice-model-cancel')));
    expect(model.actions, ['cancel']);
  });

  testWidgets('a failure says why and retries in one tap', (tester) async {
    final model = await pumpCard(tester, states['failed']!, metered: false);
    expect(find.text('网络连接失败'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('voice-model-retry')));
    await tester.pumpAndSettle();
    expect(model.actions, ['download']);
  });

  testWidgets('waiting for the engine with a download asked for offers cancel', (tester) async {
    final model = await pumpCard(tester, const VoiceModelState(status: VoiceModelStatus.waiting, wanted: true));
    expect(find.text('下载会在引擎启动后开始'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('voice-model-cancel')));
    expect(model.actions, ['cancel']);
  });

  testWidgets('an engine without the voice bundle shows no actions', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      testApp(
        const VoiceSettingsPage(),
        overrides: [
          voiceModelProvider.overrideWith(
            () => FixedVoiceModel(const VoiceModelState(status: VoiceModelStatus.unsupported)),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('当前引擎不支持语音模型'), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-model-actions')), findsNothing);
  });
}
