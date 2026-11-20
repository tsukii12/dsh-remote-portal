/// An ST theme (docs/design/roleplay-ui.md §10): what a SillyTavern theme
/// file says quotes and italics are drawn in — the two colours an ST theme
/// sets that the story here can wear (tavern_ink.dart) — and its custom CSS,
/// which the whole-story canvas takes as ST would (its DOM is ST's). The rest
/// of its look (blur, tints, chat width) stays ST's; the page here is the
/// app's. Kept as written, made readable where it is drawn.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TavernStTheme {
  const TavernStTheme({required this.name, this.quote, this.italics, this.customCss, this.useCss = true});

  final String name;

  /// 0xRRGGBB; null where the theme gives none.
  final int? quote;
  final int? italics;

  /// Its custom CSS as written; null where it has none.
  final String? customCss;

  /// Whether the canvas takes [customCss] (with ST's colours chosen): one
  /// that unsettles the page can be let go, the colours kept.
  final bool useCss;

  /// What the canvas adds after its own styles: [customCss] when it is used.
  String get canvasCss => useCss ? customCss ?? '' : '';

  TavernStTheme withUseCss(bool use) =>
      TavernStTheme(name: name, quote: quote, italics: italics, customCss: customCss, useCss: use);

  Map<String, Object?> toJson() => {
    'name': name,
    'quote': quote,
    'italics': italics,
    if (customCss != null) 'customCss': customCss,
    if (!useCss) 'useCss': false,
  };

  static TavernStTheme? fromJson(Object? json) {
    if (json case {'name': final String name, 'quote': final int? quote, 'italics': final int? italics}) {
      final css = switch (json['customCss']) {
        final String s when s.trim().isNotEmpty => s,
        _ => null,
      };
      if (quote == null && italics == null && css == null) return null;
      return TavernStTheme(name: name, quote: quote, italics: italics, customCss: css, useCss: json['useCss'] != false);
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is TavernStTheme &&
      other.name == name &&
      other.quote == quote &&
      other.italics == italics &&
      other.customCss == customCss &&
      other.useCss == useCss;

  @override
  int get hashCode => Object.hash(name, quote, italics, customCss, useCss);
}

/// [map] is an ST theme: ST's own text colour keys are there.
bool tavernIsStTheme(Map<String, Object?> map) =>
    map.containsKey('main_text_color') &&
    (map.containsKey('quote_text_color') || map.containsKey('italics_text_color'));

/// [map]'s story colours and custom CSS, named by its own `name` or else
/// [fileName] without `.json`; null when it gives neither colour in a form
/// read here, nor any CSS.
TavernStTheme? tavernStThemeOf(Map<String, Object?> map, {required String fileName}) {
  final quote = tavernCssColor(map['quote_text_color']);
  final italics = tavernCssColor(map['italics_text_color']);
  final css = switch (map['custom_css']) {
    final String s when s.trim().isNotEmpty => s,
    _ => null,
  };
  if (quote == null && italics == null && css == null) return null;
  final name = switch (map['name']) {
    final String own when own.trim().isNotEmpty => own.trim(),
    _ => fileName.replaceFirst(RegExp(r'\.json$', caseSensitive: false), ''),
  };
  return TavernStTheme(name: name, quote: quote, italics: italics, customCss: css);
}

final _rgb = RegExp(
  r'^rgba?\(\s*([\d.]+%?)\s*[,\s]\s*([\d.]+%?)\s*[,\s]\s*([\d.]+%?)\s*(?:[,/]\s*([\d.]+%?)\s*)?\)$',
  caseSensitive: false,
);
final _hex = RegExp(r'^#([0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})$', caseSensitive: false);

/// A CSS colour as ST writes one — `rgb()`/`rgba()` with numbers or
/// percentages, or `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa` — as 0xRRGGBB. Its
/// transparency is dropped, except that a fully transparent one is none.
int? tavernCssColor(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  if (_rgb.firstMatch(text) case final m?) {
    int channel(String raw) {
      final n = double.tryParse(raw.replaceAll('%', '')) ?? 0;
      return (raw.endsWith('%') ? n * 255 / 100 : n).round().clamp(0, 255);
    }

    if (m[4] case final alpha? when (double.tryParse(alpha.replaceAll('%', '')) ?? 1) == 0) return null;
    return (channel(m[1]!) << 16) | (channel(m[2]!) << 8) | channel(m[3]!);
  }
  if (_hex.firstMatch(text) case final m?) {
    var hex = m[1]!;
    if (hex.length <= 4) hex = hex.split('').map((c) => '$c$c').join();
    if (hex.length == 8 && hex.endsWith('00')) return null;
    return int.parse(hex.substring(0, 6), radix: 16);
  }
  return null;
}

/// The ST theme taken in, kept on this device; null for none.
class TavernStThemeController extends Notifier<TavernStTheme?> {
  static const key = 'tavern.stTheme';

  @override
  TavernStTheme? build() {
    unawaited(_load());
    return null;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(key);
      if (saved != null && state == null) state = TavernStTheme.fromJson(jsonDecode(saved));
    } catch (_) {
      // No preferences backend (tests), or a broken entry: none.
    }
  }

  Future<void> set(TavernStTheme theme) async {
    state = theme;
    await _save((prefs) => prefs.setString(key, jsonEncode(theme.toJson())));
  }

  /// Whether the canvas takes the theme's custom CSS.
  Future<void> setUseCss(bool use) async {
    if (state case final theme?) await set(theme.withUseCss(use));
  }

  Future<void> clear() async {
    state = null;
    await _save((prefs) => prefs.remove(key));
  }

  Future<void> _save(Future<bool> Function(SharedPreferences prefs) write) async {
    try {
      await write(await SharedPreferences.getInstance());
    } catch (_) {
      // Kept for this run only.
    }
  }
}

final tavernStThemeProvider = NotifierProvider<TavernStThemeController, TavernStTheme?>(TavernStThemeController.new);
