// Adapter for the published dsh-voice-scribe REST contract, not settings/mutate.
// Only language and polishPrompt are writable. Keys and provider arrays never
// enter an outgoing patch.
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';

import '../l10n/l10n.dart';

const voiceScribeModule = 'dsh-voice-scribe';

enum VoiceScribeField { language, polishPrompt }

class VoiceScribeProvider {
  const VoiceScribeProvider(this.url, this.model, this.hasKey);
  final String url;
  final String model;
  final bool hasKey;
}

class VoiceScribeSettings {
  const VoiceScribeSettings({
    required this.language,
    required this.polishPrompt,
    required this.providers,
    required this.hotwordsPath,
    required this.hotwordsRules,
    required this.hotwordsError,
  });
  final String language;
  final String polishPrompt;
  final List<VoiceScribeProvider> providers;
  final String hotwordsPath;
  final int hotwordsRules;
  final String hotwordsError;

  factory VoiceScribeSettings.fromJson(Object? json) {
    if (json is! Map ||
        json['language'] is! String ||
        json['polishPrompt'] is! String ||
        json['providers'] is! List ||
        json['hotwords'] is! Map) {
      throw const FormatException('unsupported voice settings response');
    }
    final providers = <VoiceScribeProvider>[];
    for (final row in json['providers'] as List) {
      if (row is! Map || row['url'] is! String || row['model'] is! String || row['hasKey'] is! bool) {
        throw const FormatException('unsupported voice provider response');
      }
      providers.add(VoiceScribeProvider(row['url'] as String, row['model'] as String, row['hasKey'] as bool));
    }
    final hotwords = json['hotwords'] as Map;
    if (hotwords['path'] is! String || hotwords['rules'] is! int || hotwords['error'] is! String) {
      throw const FormatException('unsupported hotword response');
    }
    return VoiceScribeSettings(
      language: json['language'] as String,
      polishPrompt: json['polishPrompt'] as String,
      providers: List.unmodifiable(providers),
      hotwordsPath: hotwords['path'] as String,
      hotwordsRules: hotwords['rules'] as int,
      hotwordsError: hotwords['error'] as String,
    );
  }

  String value(VoiceScribeField field) => field == VoiceScribeField.language ? language : polishPrompt;
  VoiceScribeSettings changed(VoiceScribeField field, String value) => VoiceScribeSettings(
    language: field == VoiceScribeField.language ? value : language,
    polishPrompt: field == VoiceScribeField.polishPrompt ? value : polishPrompt,
    providers: providers,
    hotwordsPath: hotwordsPath,
    hotwordsRules: hotwordsRules,
    hotwordsError: hotwordsError,
  );
}

abstract class VoiceScribeTransport {
  Future<VoiceScribeSettings> read({bool Function()? stillCurrent});
  Future<void> write(VoiceScribeField field, String value, {bool Function()? stillCurrent});
}

class VoiceScribeHttpTransport implements VoiceScribeTransport {
  VoiceScribeHttpTransport({required this.client, required this.entryId, required this.isCurrent});
  final DshClient client;
  final String entryId;
  final bool Function() isCurrent;

  // Client memory bound for a small settings response, not a claimed upstream
  // protocol limit. The upstream polish prompt limit is 8000 characters.
  static const maxResponseBytes = 256 * 1024;

  DshConnection _connection() {
    if (!isCurrent() || client.carrier is! DshHttpCarrier || client.mux.state != DshConnectionState.connected) {
      throw StateError('voice settings source is not ready');
    }
    final connection = client.connection;
    final cookie = connection.cookie;
    if (cookie == null || cookie.isExpiredAt(DateTime.now())) throw StateError('voice settings login required');
    return connection;
  }

  Future<Map> _request(Map<String, Object?> body, {bool Function()? stillCurrent}) async {
    void check() {
      _connection();
      if (stillCurrent?.call() == false) throw StateError('voice settings generation changed');
    }

    check();
    final inventory = await client.pluginInventory();
    if (!inventory.entries.any(
      (e) => e.entryId == entryId && e.moduleName == voiceScribeModule && e.enabled && e.fiberPhase == 'active',
    )) {
      throw StateError('voice plugin is not active');
    }
    check();
    final response = await _connection().postBytes(
      '/voice-input',
      utf8.encode(jsonEncode(body)),
      contentType: 'application/json',
      followRedirects: false,
      maxResponseBytes: maxResponseBytes,
    );
    check();
    if (response.statusCode != 200 || response.contentType != 'application/json') {
      throw StateError('voice settings request failed');
    }
    final decoded = jsonDecode(response.text);
    if (decoded is! Map || decoded['ok'] != true) throw StateError('voice settings request rejected');
    return decoded;
  }

  @override
  Future<VoiceScribeSettings> read({bool Function()? stillCurrent}) async =>
      VoiceScribeSettings.fromJson((await _request({'action': 'get-settings'}, stillCurrent: stillCurrent))['value']);

  @override
  Future<void> write(VoiceScribeField field, String value, {bool Function()? stillCurrent}) async {
    await _request({
      'action': 'set-settings',
      'patch': {field.name: value.trim()},
    }, stillCurrent: stillCurrent);
  }
}

/// A page-owned snapshot and write session. Each plugin/connection generation
/// invalidates old editors, including A→B→A and a plugin restart on one client.
class VoiceScribeSettingsController extends ChangeNotifier {
  VoiceScribeSettingsController(this.transport, this.isCurrent);
  final VoiceScribeTransport transport;
  final bool Function() isCurrent;
  VoiceScribeSettings? data;
  String? error;
  bool loading = false;
  bool saving = false;
  bool _disposed = false;
  int _generation = 0;
  int _read = 0;
  int get generation => _generation;
  bool accepts(int generation) => !_disposed && generation == _generation && isCurrent();

  void invalidate() {
    if (_disposed) return;
    _generation++;
    _read++;
    data = null;
    loading = false;
    saving = false;
    error = null;
    notifyListeners();
  }

  Future<void> refresh() async {
    final generation = _generation;
    if (!accepts(generation) || saving) return;
    final read = ++_read;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final next = await transport.read(stillCurrent: () => accepts(generation) && read == _read);
      if (!accepts(generation) || read != _read) return;
      data = next;
    } catch (_) {
      if (!accepts(generation) || read != _read) return;
      error = appL10n.voiceScribeReadFailed;
    } finally {
      if (accepts(generation) && read == _read) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<bool> save(int generation, VoiceScribeField field, String value) async {
    if (!accepts(generation) || saving || data == null) return false;
    final normalized = value.trim();
    if (field == VoiceScribeField.polishPrompt && normalized.length > 8000) return false;
    if (data!.value(field) == normalized) return true;
    saving = true;
    _read++; // A refresh started before this write cannot overwrite its ack.
    loading = false;
    error = null;
    notifyListeners();
    try {
      await transport.write(field, normalized, stillCurrent: () => accepts(generation));
      if (!accepts(generation)) return false;
      data = data!.changed(field, normalized);
      try {
        final next = await transport.read(stillCurrent: () => accepts(generation));
        if (!accepts(generation)) return false;
        data = next;
      } catch (_) {
        if (!accepts(generation)) return false;
        error = appL10n.voiceScribeSavedReadFailed;
      }
      return true;
    } catch (_) {
      if (accepts(generation)) error = appL10n.voiceScribeSaveUnconfirmed;
      return false;
    } finally {
      if (accepts(generation)) {
        saving = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
