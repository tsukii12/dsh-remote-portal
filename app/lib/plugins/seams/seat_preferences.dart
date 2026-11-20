// Local, per-host choices for opt-in plugin overlays. ui.json takes precedence.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../state/hosts_state.dart';

typedef SeatPreferences = Map<String, Map<String, bool>>;

String seatPreferenceHostKey(HostRef host) => '${host.kind.name}:${host.id}';

class SeatPreferencesController extends Notifier<SeatPreferences> {
  static const prefsKey = 'plugins.seats.overlays';

  late Future<void> _loaded;
  Future<void> _writes = Future<void>.value();

  @override
  SeatPreferences build() {
    _loaded = _load();
    return const {};
  }

  Future<void> get ready => _loaded;

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw == null) return;
      final json = jsonDecode(raw);
      if (json is! Map) return;
      final restored = <String, Map<String, bool>>{};
      for (final entry in json.entries) {
        if (entry.key is! String || entry.value is! Map) continue;
        restored[entry.key as String] = Map<String, bool>.unmodifiable({
          for (final value in (entry.value as Map).entries)
            if (value.key is String && value.value is bool) value.key as String: value.value as bool,
        });
      }
      if (ref.mounted) state = Map.unmodifiable(restored);
    } catch (_) {
      // Missing preferences backend or corrupt data: overlays stay opt-in.
      // A subsequent user write still reports persistence failures to the UI.
    }
  }

  /// Completes only after persistence succeeds. Serial writes preserve choices
  /// when two plugin details change preferences before either write finishes.
  Future<void> setOverlay(HostRef host, String package, bool enabled) {
    final write = _writes.then((_) async {
      await _loaded;
      final prefs = await SharedPreferences.getInstance();
      final key = seatPreferenceHostKey(host);
      final next = Map<String, Map<String, bool>>.unmodifiable({
        ...state,
        key: Map<String, bool>.unmodifiable({...?state[key], package: enabled}),
      });
      if (!await prefs.setString(prefsKey, jsonEncode(next))) {
        throw StateError('seat_preferences_save_failed');
      }
      if (ref.mounted) state = next;
    });
    // The caller receives the failure; it must not poison later user retries.
    _writes = write.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return write;
  }
}

final seatPreferencesProvider = NotifierProvider<SeatPreferencesController, SeatPreferences>(
  SeatPreferencesController.new,
);
