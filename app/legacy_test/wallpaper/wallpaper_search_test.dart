// Settings search finds 壁纸 by its name and the words people use for it, in Chinese and English.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/ui/features/feature_catalog.dart';
import 'package:dsh_app/ui/settings/index/spots.dart';
import 'package:dsh_app/ui/settings/search/settings_search.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final zh = lookupL10n(AppLocale.zhCN);
  final en = lookupL10n(AppLocale.en);
  List<String> ids(String q) => [
    for (final h in searchSettings(q, spots: SettingsIndex.spots, features: featureSections, zh: zh, en: en))
      h.spot?.id ?? 'feature:${h.feature!.id}',
  ];

  test('壁纸, 背景, wallpaper and friends lead to it', () {
    for (final q in ['壁纸', '背景', '聊天背景', '背景图', '换背景', 'wallpaper', 'Wallpaper', 'chat background', 'backdrop']) {
      expect(ids(q).first, Spots.wallpaper.id, reason: '$q: ${ids(q).take(4)}');
    }
    // English "background" is first of all 后台运行 (Background running); the wallpaper is listed.
    expect(ids('background').take(5), contains(Spots.wallpaper.id));
  });

  test('it lives on 主题, after the launch screen', () {
    expect(Spots.wallpaper.page, SettingsPageId.appearance);
    final all = SettingsIndex.spots.toList();
    expect(all.indexOf(Spots.wallpaper), all.indexOf(Spots.launchScreen) + 1);
  });
}
