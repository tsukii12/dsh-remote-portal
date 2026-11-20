// The reasoning translation controller: one fragment at a time, cached by
// text, the streaming tail left alone, failures keep the original.

import 'dart:async';

import 'package:dsh_app/state/cot_translation_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('translates complete paragraphs in order, reuses the cache', () async {
    final asked = <String>[];
    final translation = ReasoningTranslation(
      maxTextChars: 4000,
      translate: (text) async {
        asked.add(text);
        return '【$text】';
      },
    );
    addTearDown(translation.dispose);
    translation.update('One.\n\nTwo.\n\nThr', running: true);
    await pumpEventQueue();
    expect(asked, ['One.', 'Two.']);
    expect(translation.text, '【One.】\n\n【Two.】\n\nThr');
    expect(translation.pending, isFalse);
    // The tail completes: only it goes out.
    translation.update('One.\n\nTwo.\n\nThree.', running: false);
    await pumpEventQueue();
    expect(asked, ['One.', 'Two.', 'Three.']);
    expect(translation.text, '【One.】\n\n【Two.】\n\n【Three.】');
    expect(translation.hasTranslation, isTrue);
  });

  test('a failure keeps the original until retry', () async {
    var fail = true;
    final translation = ReasoningTranslation(
      maxTextChars: 4000,
      translate: (text) async {
        if (fail) throw StateError('offline');
        return 'ok:$text';
      },
    );
    addTearDown(translation.dispose);
    translation.update('Alpha.\n\nBeta.', running: false);
    await pumpEventQueue();
    expect(translation.failed, isTrue);
    expect(translation.text, 'Alpha.\n\nBeta.');
    // Updates don't hammer a failing service.
    translation.update('Alpha.\n\nBeta.', running: false);
    await pumpEventQueue();
    expect(translation.failed, isTrue);
    fail = false;
    translation.retry();
    await pumpEventQueue();
    expect(translation.failed, isFalse);
    expect(translation.text, 'ok:Alpha.\n\nok:Beta.');
  });

  test('dispose stops publishing', () async {
    final gate = Completer<String>();
    final translation = ReasoningTranslation(maxTextChars: 4000, translate: (_) => gate.future);
    var notified = 0;
    translation.addListener(() => notified++);
    translation.update('Gamma.', running: false);
    final before = notified;
    translation.dispose();
    gate.complete('done');
    await pumpEventQueue();
    expect(notified, before);
  });

  test('only reasoning outside the target script is worth translating', () {
    expect(reasoningNeedsTranslation('Let me check the pubspec first.', 'zh'), isTrue);
    expect(reasoningNeedsTranslation('先看一下 pubspec 里锁的版本，再决定怎么改。', 'zh'), isFalse);
    expect(reasoningNeedsTranslation('看 `flutter_riverpod` 的 `ProviderScope.containerOf` 实现', 'zh-CN'), isFalse);
    expect(reasoningNeedsTranslation('先看一下版本。', 'en'), isTrue);
    expect(reasoningNeedsTranslation('Let me check the pubspec first.', 'en'), isFalse);
    expect(reasoningNeedsTranslation('The button says 登录 here.', 'en'), isFalse);
  });

  test('math notation in Chinese reasoning is not a foreign script', () {
    for (final text in ['设 θ 为入射角，先算 sin θ 的值。', '学习率 α 取 0.001，耗时 300µs。', '在 ℝ 上取连续函数。']) {
      expect(reasoningNeedsTranslation(text, 'zh'), isFalse, reason: text);
    }
    expect(reasoningNeedsTranslation('Θα ελέγξω πρώτα τις ρυθμίσεις.', 'zh'), isTrue);
    expect(reasoningNeedsTranslation('Θα ελέγξω πρώτα τις ρυθμίσεις.', 'en'), isTrue);
  });

  test('offers Chinese translation for non-Latin source scripts', () {
    for (final text in [
      'Сначала проверю настройки.',
      'まず設定を確認します。',
      '먼저 설정을 확인하겠습니다.',
      'سأتحقق من الإعدادات أولاً.',
      'ตรวจสอบการตั้งค่าก่อน',
    ]) {
      expect(reasoningNeedsTranslation(text, 'zh'), isTrue, reason: text);
      expect(reasoningNeedsTranslation(text, 'zh-CN'), isTrue, reason: text);
    }
  });

  test('foreign script is not hidden by nearby Han characters', () {
    expect(reasoningNeedsTranslation('設定を確認してから修正します。', 'zh'), isTrue);
    expect(reasoningNeedsTranslation('Проверю настройки 配置', 'zh'), isTrue);
    expect(reasoningNeedsTranslation('설정을 확인합니다 設定', 'zh'), isTrue);
  });

  test('preserves Chinese with technical identifiers and neutral text', () {
    expect(reasoningNeedsTranslation('看 flutter_riverpod 的 ProviderScope 实现。', 'zh'), isFalse);
    expect(reasoningNeedsTranslation('請先確認目前設定，再開始修改。', 'zh'), isFalse);
    for (final text in ['', '  ', '123 + 456', '… ✅']) {
      expect(reasoningNeedsTranslation(text, 'zh'), isFalse, reason: text);
    }
  });

  test('counts accented Latin words and supplementary Han by Unicode script', () {
    expect(reasoningNeedsTranslation('Sí, revisaré la configuración.', 'zh'), isTrue);
    expect(reasoningNeedsTranslation('é', 'zh'), isTrue);
    expect(reasoningNeedsTranslation('𠀀𠀁𠀂 id', 'zh'), isFalse);
  });

  test('non-Chinese targets retain the existing offer policy', () {
    for (final target in ['en', 'ru', 'ja', 'ko', 'es']) {
      expect(reasoningNeedsTranslation('先检查设置。', target), isTrue);
    }
  });
}
