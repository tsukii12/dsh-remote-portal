// Media words: the metadata line that cuts the model's name first, costs,
// failures, and the reply lines a card makes redundant.

import 'package:dsh_app/ui/chat/media/media_card.dart' show fitMediaMetaLine;
import 'package:dsh_app/ui/chat/media/media_format.dart';
import 'package:dsh_app/ui/chat/media/media_paths.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);

  test('money and clip lengths', () {
    expect(formatMoney(0.3, 'CNY'), '¥0.30');
    expect(formatMoney(4, 'CNY'), '¥4');
    expect(formatMoney(0.05, 'USD'), r'$0.05');
    expect(mediaCostText(null), isNull);
    expect(mediaCostText(const MediaCost(0.6, 'CNY')), '约 ¥0.60');
    expect(formatClip(5), '0:05');
    expect(formatClip(80.4), '1:20');
  });

  test('failures in one sentence; the code stays out', () {
    expect(mediaErrorText(const MediaFailure('policy', 'input')), '描述未通过内容审核');
    expect(mediaErrorText(const MediaFailure('policy', 'output')), '生成结果未通过内容审核');
    expect(mediaErrorText(const MediaFailure('policy-output', null)), '生成结果未通过内容审核');
    expect(mediaErrorText(const MediaFailure('balance', null)), '余额不足');
    expect(mediaErrorText(const MediaFailure('E_WEIRD_42', 'stack…')), '没能生成');
    expect(mediaErrorText(null), '没能生成');
  });

  test('the metadata line keeps 「AI 生成」 and the tail; the model gives way', () {
    const style = TextStyle(fontSize: 13, fontFamily: sansFamily, fontFamilyFallback: [cjkFamily]);
    const tail = ['3:4', '约 ¥0.60'];
    final full = fitMediaMetaLine(
      lead: 'AI 生成',
      model: 'Seedream 5.0',
      tail: tail,
      style: style,
      textScaler: TextScaler.noScaling,
      maxWidth: 400,
    );
    expect(full, 'AI 生成 · Seedream 5.0 · 3:4 · 约 ¥0.60');
    final cut = fitMediaMetaLine(
      lead: 'AI 生成',
      model: 'Seedream 5.0 Pro 高像素版',
      tail: tail,
      style: style,
      textScaler: const TextScaler.linear(1.3),
      maxWidth: 260,
    );
    expect(cut, startsWith('AI 生成 · Seed'));
    expect(cut, contains('…'));
    expect(cut, endsWith(' · 3:4 · 约 ¥0.60'));
    final none = fitMediaMetaLine(
      lead: 'AI 生成',
      model: 'Seedream 5.0',
      tail: tail,
      style: style,
      textScaler: const TextScaler.linear(1.3),
      maxWidth: 150,
    );
    expect(none, 'AI 生成 · 3:4 · 约 ¥0.60');
  });

  test('a reply line that only shows a carded picture goes; others stay', () {
    const shown = {'/root/workspace/generated/2026-10-28/cat-1.png'};
    expect(
      withoutShownImages('画好了。\n\n![橘猫](/root/workspace/generated/2026-10-28/cat-1.png)\n\n要换光线吗？', shown),
      '画好了。\n\n要换光线吗？',
    );
    expect(withoutShownImages('![](generated/2026-10-28/cat-1.png)', shown), '');
    expect(withoutShownImages('看这张 ![](generated/2026-10-28/cat-1.png) 怎么样', shown), isNull);
    expect(withoutShownImages('![](other.png)', shown), isNull);
    expect(withoutShownImages('no pictures', shown), isNull);
    expect(shownInMediaCard(shown, './generated/2026-10-28/cat-1.png'), isTrue);
    expect(shownInMediaCard(shown, '/elsewhere/cat-1.png'), isFalse);
  });
}
