import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';

class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.chatSuggestions = true,
    this.hardwareEnterSends = false,
    this.chatTextScale = 1,
    this.foldCompletedTurns = true,
    this.loaded = false,
  });
  final ThemeMode themeMode;
  final bool chatSuggestions;
  final bool hardwareEnterSends;
  final double chatTextScale;
  final bool foldCompletedTurns;
  final bool loaded;

  AppSettings copyWith({
    ThemeMode? themeMode,
    bool? chatSuggestions,
    bool? hardwareEnterSends,
    double? chatTextScale,
    bool? foldCompletedTurns,
    bool? loaded,
  }) => AppSettings(
    themeMode: themeMode ?? this.themeMode,
    chatSuggestions: chatSuggestions ?? this.chatSuggestions,
    hardwareEnterSends: hardwareEnterSends ?? this.hardwareEnterSends,
    chatTextScale: chatTextScale ?? this.chatTextScale,
    foldCompletedTurns: foldCompletedTurns ?? this.foldCompletedTurns,
    loaded: loaded ?? this.loaded,
  );
}

List<(double, String)> get chatTextScales => [
  (0.9, appL10n.stateSizeSmall),
  (1.0, appL10n.stateSizeStandard),
  (1.15, appL10n.stateSizeLarge),
  (1.3, appL10n.stateSizeExtraLarge),
];

class SettingsController extends Notifier<AppSettings> {
  late Future<void> _loaded;
  @override
  AppSettings build() {
    _loaded = _load();
    return const AppSettings();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      final scale = prefs.getDouble('chat_text_scale');
      state = AppSettings(
        themeMode: ThemeMode.values.asNameMap()[prefs.getString('theme_mode')] ?? ThemeMode.system,
        chatSuggestions: prefs.getBool('chat_suggestions') ?? true,
        hardwareEnterSends: prefs.getBool('hardware_enter_sends') ?? false,
        chatTextScale: chatTextScales.any((item) => item.$1 == scale) ? scale! : 1,
        foldCompletedTurns: prefs.getBool('fold_completed_turns') ?? true,
        loaded: true,
      );
    } catch (_) {
      if (ref.mounted) state = state.copyWith(loaded: true);
    }
  }

  Future<void> _save(String key, Object value, AppSettings Function(AppSettings) update) async {
    await _loaded;
    if (!ref.mounted) return;
    final prefs = await SharedPreferences.getInstance();
    final saved = switch (value) {
      bool value => await prefs.setBool(key, value),
      double value => await prefs.setDouble(key, value),
      String value => await prefs.setString(key, value),
      _ => throw ArgumentError.value(value),
    };
    if (!saved) throw StateError('Could not save $key');
    if (ref.mounted) state = update(state);
  }

  Future<void> setThemeMode(ThemeMode value) => _save('theme_mode', value.name, (s) => s.copyWith(themeMode: value));
  Future<void> setChatTextScale(double value) {
    if (!chatTextScales.any((item) => item.$1 == value)) throw ArgumentError.value(value);
    return _save('chat_text_scale', value, (s) => s.copyWith(chatTextScale: value));
  }

  Future<void> setFoldCompletedTurns(bool value) =>
      _save('fold_completed_turns', value, (s) => s.copyWith(foldCompletedTurns: value));
  Future<void> setHardwareEnterSends(bool value) =>
      _save('hardware_enter_sends', value, (s) => s.copyWith(hardwareEnterSends: value));
  Future<void> setChatSuggestions(bool value) =>
      _save('chat_suggestions', value, (s) => s.copyWith(chatSuggestions: value));
}

final settingsProvider = NotifierProvider<SettingsController, AppSettings>(SettingsController.new);
