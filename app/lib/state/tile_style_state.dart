import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';

/// How the big feature graphics (`FeatureTile`) are drawn. The name is the
/// persisted value.
enum TileStyle {
  /// Flat duotone: a light body with details in the accent. The default.
  duotone,

  /// Minimal geometric: a few solid shapes in three tones of the accent.
  geometric,

  /// Glass gradient: the painted glass set, turned to the accent's hue.
  glassy;

  /// Name in the picker.
  String get label => switch (this) {
    duotone => appL10n.stateTileDuotone,
    geometric => appL10n.stateTileGeometric,
    glassy => appL10n.stateTileGlassy,
  };

  static const fallback = TileStyle.duotone;

  /// Unknown or missing values fall back to [fallback].
  static TileStyle fromName(String? name) => TileStyle.values.asNameMap()[name] ?? fallback;
}

/// The user's [TileStyle], kept in SharedPreferences like the other appearance
/// settings. [TileStyle.fallback] until the stored value has loaded.
class TileStyleController extends Notifier<TileStyle> {
  static const _key = 'tile_style';

  /// Set by [select] before the stored value arrived: that value is then stale.
  bool _chosen = false;

  @override
  TileStyle build() {
    _load();
    return TileStyle.fallback;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted || _chosen) return;
      state = TileStyle.fromName(prefs.getString(_key));
    } catch (_) {
      // Preferences unavailable: keep the default.
    }
  }

  Future<void> select(TileStyle style) async {
    _chosen = true;
    state = style;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, style.name);
    } catch (_) {}
  }
}

final tileStyleProvider = NotifierProvider<TileStyleController, TileStyle>(TileStyleController.new);
