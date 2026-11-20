/// Engine-side speech recognition (`speech/*`), served only while the
/// optional voice-input bundle is enabled.
///
/// Verified against DSH 0.2.1-rc.2 (`@deepseek-ai/dsh-experimental-api-speech-to-text`
/// typings and Remote descriptors, `dsh-experimental-speech-to-text` wave
/// validator, and a throwaway `dsh web`, which answers HTTP 404 "not served"
/// while the bundle is off). Recognition is whole-recording only: the client
/// sends one canonical 16 kHz mono PCM16 WAV as base64 and gets the final text.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'errors.dart';
import 'json.dart';
import 'session_api.dart';

/// One recognizer and its resource state.
class SpeechProviderView {
  const SpeechProviderView({
    required this.id,
    required this.name,
    required this.location,
    required this.languages,
    required this.phase,
    this.preparation = const SpeechPreparation(phase: 'ready'),
    this.downloadSources = const [],
  });

  static SpeechProviderView? fromJson(Object? json) {
    final map = asMap(json);
    final id = asString(map?['id']);
    if (map == null || id == null || id.isEmpty) return null;
    // Providers without preparation controls are immediately usable.
    final preparation = SpeechPreparation.fromJson(map['preparation']);
    return SpeechProviderView(
      id: id,
      name: asString(map['name']) ?? id,
      location: asString(map['location']) ?? 'host-local',
      languages: asStringList(map['languages']),
      phase: preparation.phase,
      preparation: preparation,
      downloadSources: asStringList(map['downloadSources']),
    );
  }

  final String id;
  final String name;

  /// `host-local` or `cloud`.
  final String location;
  final List<String> languages;

  /// `unprepared`, `ready`, `standby`, `downloading`, `checking`, `loading`,
  /// `waking`, `cancelling`, `cancelled` or `failed`.
  final String phase;

  /// The Host-owned preparation state behind [phase].
  final SpeechPreparation preparation;

  /// Origins the provider downloads its resources from (empty: no choice).
  final List<String> downloadSources;

  /// Recording now works: ready, or prepared and woken on demand.
  bool get usable => phase == 'ready' || phase == 'standby' || phase == 'waking';
}

/// `SpeechPreparationState`: one provider's resource preparation.
class SpeechPreparation {
  const SpeechPreparation({
    required this.phase,
    this.step,
    this.resource,
    this.completedBytes,
    this.totalBytes,
    this.message,
    this.failure,
  });

  factory SpeechPreparation.fromJson(Object? json) {
    final map = asMap(json);
    return SpeechPreparation(
      phase: asString(map?['phase']) ?? 'ready',
      step: asString(map?['step']),
      resource: asString(map?['resource']),
      completedBytes: asInt(map?['completedBytes']),
      totalBytes: asInt(map?['totalBytes']),
      message: asString(map?['message']),
      failure: SpeechDownloadFailure.fromJson(map?['download']),
    );
  }

  final String phase;

  /// `check`, `model`, `vad`, `verify` or `load`.
  final String? step;

  /// The file being downloaded (`downloading` only).
  final String? resource;
  final int? completedBytes;
  final int? totalBytes;

  /// Untranslated reason of a `failed` preparation.
  final String? message;

  /// Why a download failed, when one did.
  final SpeechDownloadFailure? failure;
}

/// `SpeechDownloadFailure`: safe diagnostics of a failed resource download.
class SpeechDownloadFailure {
  const SpeechDownloadFailure({required this.resource, required this.source, required this.reason, this.code, this.status});

  static SpeechDownloadFailure? fromJson(Object? json) {
    final map = asMap(json);
    final reason = asString(map?['reason']);
    if (map == null || reason == null) return null;
    return SpeechDownloadFailure(
      resource: asString(map['resource']) ?? '',
      source: asString(map['source']) ?? '',
      reason: reason,
      code: asString(map['code']),
      status: asInt(map['status']),
    );
  }

  final String resource;

  /// Origin only, no credentials or query.
  final String source;

  /// `network`, `dns`, `timeout`, `certificate`, `http`, `integrity`, `storage` or `unknown`.
  final String reason;
  final String? code;
  final int? status;
}

/// `speech/catalog`: recognizers, the saved selection and the intake limits.
class SpeechCatalog {
  const SpeechCatalog({
    required this.providers,
    required this.providerId,
    required this.language,
    required this.maxAudioBytes,
    required this.maxDurationSeconds,
  });

  static SpeechCatalog? fromJson(Object? json) {
    final map = asMap(json);
    if (map == null) return null;
    final selection = asMap(map['selection']);
    return SpeechCatalog(
      providers: [for (final p in asListOrEmpty(map['providers'])) ?SpeechProviderView.fromJson(p)],
      providerId: asString(selection?['providerId']),
      language: asString(selection?['language']),
      maxAudioBytes: asInt(map['maxAudioBytes']) ?? 4 * 1024 * 1024,
      maxDurationSeconds: asNum(map['maxDurationSeconds'])?.toDouble() ?? 120,
    );
  }

  final List<SpeechProviderView> providers;
  final String? providerId;
  final String? language;
  final int maxAudioBytes;
  final double maxDurationSeconds;

  /// The saved recognizer, when it is registered.
  SpeechProviderView? get selected => providers.where((p) => p.id == providerId).firstOrNull;

  /// The longest recording the Host accepts, in whole seconds (WAV header
  /// included in the byte limit).
  int get maxSeconds {
    final byBytes = (maxAudioBytes - 44) ~/ 32000;
    final limit = maxDurationSeconds.floor();
    return byBytes < limit ? byBytes : limit;
  }
}

class SpeechTranscript {
  const SpeechTranscript(this.text, this.audioSeconds);

  /// Empty when nothing was recognized.
  final String text;
  final double audioSeconds;
}

extension SpeechApi on DshClient {
  /// Whether the carrier lets `speech/*` through (remote tunnels do not).
  bool get canTranscribe => supportsEndpoint('speech/catalog') && supportsEndpoint('speech/transcribe');

  /// `speech/catalog`; null when the Host does not serve speech (bundle off,
  /// older Host, tunnel).
  Future<SpeechCatalog?> speechCatalog() async {
    if (!canTranscribe) return null;
    try {
      return SpeechCatalog.fromJson(await rpc.call('speech/catalog'));
    } on DshHttpException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    } on DshRemoteException catch (e) {
      if (e.isGatewayError) return null;
      rethrow;
    }
  }

  /// `speech/prepare`: starts (or joins) the Host-owned preparation of
  /// [providerId] and returns at once; progress shows in [speechCatalog].
  /// [downloadSource] must be one of the provider's `downloadSources`.
  Future<void> prepareSpeech(String providerId, {String? downloadSource}) async {
    await rpc.call('speech/prepare', {
      'providerId': providerId,
      if (downloadSource != null) 'options': {'downloadSource': downloadSource},
    });
  }

  /// `speech/cancelPreparation`: returns after the preparation settled.
  /// Completed readiness stays.
  Future<void> cancelSpeechPreparation(String providerId, {Duration? timeout}) async {
    await rpc.call('speech/cancelPreparation', {'providerId': providerId}, timeout);
  }

  /// `speech/configure`: saves the default recognizer and language hint.
  Future<void> configureSpeech({String? providerId, String? language}) async {
    await rpc.call('speech/configure', {
      'patch': {'providerId': ?providerId, 'language': ?language},
    });
  }

  /// `speech/transcribe` for one canonical 16 kHz mono PCM16 WAV recording.
  Future<SpeechTranscript> transcribe(Uint8List wav, {String? providerId, String? language, Duration? timeout}) async {
    final value = asMapOrEmpty(
      await rpc.call('speech/transcribe', {
        'request': {'audioBase64': base64Encode(wav), 'providerId': ?providerId, 'language': ?language},
      }, timeout),
    );
    return SpeechTranscript((asString(value['text']) ?? '').trim(), asNum(value['audioSeconds'])?.toDouble() ?? 0);
  }
}
