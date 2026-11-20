// 「恢复默认」 for one ui.json setting. The app never rewrites ui.json — it is the
// person's and their agent's — so restoring the default only sets that setting
// aside: one record of host + setting + a fingerprint of the value it had. When
// the file says something else there, the record no longer matches and the new
// value applies; records of settings that changed or left the file are dropped
// on the next good read.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/hosts_state.dart';
import 'ui_config_model.dart';

/// Stable per-host key for preferences (`local:local`, `ssh:<id>`).
String uiHostKey(HostRef host) => '${host.kind.name}:${host.id}';

/// One setting set aside.
@immutable
class UiIgnore {
  const UiIgnore({required this.host, required this.key, required this.hash});

  final String host;
  final String key;
  final String hash;

  bool matches(HostRef host, UiConfigEntry entry) =>
      this.host == uiHostKey(host) && key == entry.key.id && hash == entry.hash;

  Map<String, Object?> toJson() => {'h': host, 'k': key, 'v': hash};

  static UiIgnore? fromJson(Object? json) {
    if (json is! Map) return null;
    final (h, k, v) = (json['h'], json['k'], json['v']);
    if (h is! String || k is! String || v is! String) return null;
    return UiIgnore(host: h, key: k, hash: v);
  }

  @override
  bool operator ==(Object other) => other is UiIgnore && other.host == host && other.key == key && other.hash == hash;

  @override
  int get hashCode => Object.hash(host, key, hash);
}

/// Every setting set aside, on every host. Persisted.
class UiIgnoresController extends Notifier<List<UiIgnore>> {
  static const prefsKey = 'ui_config.ignored';

  late Future<void> _loaded;

  @override
  List<UiIgnore> build() {
    _loaded = _load();
    return const [];
  }

  Future<void> get ready => _loaded;

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw == null) return;
      final list = jsonDecode(raw);
      if (list is! List) return;
      final restored = [for (final item in list) ?UiIgnore.fromJson(item)];
      // Changes made while loading come first.
      state = [...state, ...restored.where((r) => !state.any((s) => s.host == r.host && s.key == r.key))];
    } catch (_) {
      // No preferences backend (tests) or a corrupt value: none.
    }
  }

  Future<void> _save(List<UiIgnore> next) async {
    state = List.unmodifiable(next);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, jsonEncode([for (final i in next) i.toJson()]));
    } catch (_) {}
  }

  bool isIgnored(HostRef host, UiConfigEntry entry) => state.any((i) => i.matches(host, entry));

  /// 「恢复默认」: [entry] stops applying on [host] while the file keeps that
  /// value.
  Future<void> ignore(HostRef host, UiConfigEntry entry) async {
    await _loaded;
    final hostKey = uiHostKey(host);
    await _save([
      ...state.where((i) => !(i.host == hostKey && i.key == entry.key.id)),
      UiIgnore(host: hostKey, key: entry.key.id, hash: entry.hash),
    ]);
  }

  /// Applies [key] from the file again.
  Future<void> unignore(HostRef host, UiSettingKey key) async {
    await _loaded;
    final hostKey = uiHostKey(host);
    if (!state.any((i) => i.host == hostKey && i.key == key.id)) return;
    await _save([...state.where((i) => !(i.host == hostKey && i.key == key.id))]);
  }

  /// After a good read of [host]'s file: drops records whose setting is gone
  /// or holds another value now.
  Future<void> prune(HostRef host, UiConfig config) async {
    await _loaded;
    final hostKey = uiHostKey(host);
    final keep = [
      for (final i in state)
        if (i.host != hostKey || (config.entries[UiSettingKey.fromId(i.key)]?.hash == i.hash)) i,
    ];
    if (keep.length != state.length) await _save(keep);
  }
}

final uiIgnoresProvider = NotifierProvider<UiIgnoresController, List<UiIgnore>>(UiIgnoresController.new);
