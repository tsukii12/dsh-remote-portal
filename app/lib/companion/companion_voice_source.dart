// Where her voice comes from: the phone's own text-to-speech, an OpenAI-
// compatible speech API (OpenAI, SiliconFlow, and most self-hosted GPT-SoVITS /
// CosyVoice / Fish-Speech / edge-tts servers), or any HTTP API the person
// describes. Settings, fetching one sentence's audio, and the audio's loudness
// for her mouth. Playback and the queue are companion_voice.dart's.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../speech/deepseek_speech.dart';

/// The order the voice page lists them in. [deepseek] is DeepSeek's own speech
/// API, paid by the signed-in account or the API key (deepseek_speech.dart).
enum CompanionVoiceSource { deepseek, system, preset, openai, custom }

/// Her style, for services that take one, when the person hasn't written their own.
const companionVoiceStyleDefault = '用自然、温柔、带一点俏皮的少女语气说，像在陪朋友聊天。';

/// A voice a preset offers: its id at the service, and what kind it is.
typedef CompanionPresetVoice = ({String id, String? kind});

/// A service the person only needs a key for. [build] turns the key, voice and
/// style into an ordinary OpenAI-compatible or custom request; nothing of it is
/// stored, so a change to a preset reaches everyone who uses it.
@immutable
class CompanionVoicePreset {
  const CompanionVoicePreset({
    required this.id,
    required this.name,
    required this.site,
    required this.voices,
    required this.build,
    this.styled = false,
    this.clones = false,
  });

  final String id;
  final String name;

  /// Where to get a key.
  final String site;
  final List<CompanionPresetVoice> voices;

  /// Whether the service takes a speaking style.
  final bool styled;

  /// Whether it can speak in a voice cloned from the person's own recording
  /// (sent as a `data:` URI in place of a voice id).
  final bool clones;
  final CompanionVoiceSettings Function(CompanionVoiceSettings base, String key, String voice, String style) build;
}

String _jsonText(Object value) => jsonEncode(value);

/// The services she knows how to ask. Formats checked against each one's docs
/// (2026-11-07); MiMo's against its docs and a working client's report.
final companionVoicePresets = <CompanionVoicePreset>[
  CompanionVoicePreset(
    id: 'mimo',
    name: '小米 MiMo',
    site: 'platform.xiaomimimo.com',
    styled: true,
    clones: true,
    voices: const [
      (id: '冰糖', kind: 'f'),
      (id: '茉莉', kind: 'f'),
      (id: '苏打', kind: 'm'),
      (id: '白桦', kind: 'm'),
      (id: 'mimo_default', kind: null),
      (id: 'Mia', kind: 'f'),
      (id: 'Chloe', kind: 'f'),
      (id: 'Milo', kind: 'm'),
      (id: 'Dean', kind: 'm'),
    ],
    // Chat completions, not /audio/speech: the line is the assistant's message,
    // the style the user's; the audio comes back as base64 WAV (24 kHz PCM16).
    // A recording in place of the voice id means the cloning model.
    build: (base, key, voice, style) => base.copyWith(
      source: CompanionVoiceSource.custom,
      customUrl: 'https://api.xiaomimimo.com/v1/chat/completions',
      customPost: true,
      customHeaders: 'api-key: $key\nAuthorization: Bearer $key',
      customBody: _jsonText({
        'model': voice.startsWith('data:') ? 'mimo-v2.5-tts-voiceclone' : 'mimo-v2.5-tts',
        'messages': [
          {'role': 'user', 'content': style},
          {'role': 'assistant', 'content': '{text}'},
        ],
        'audio': {'format': 'wav', 'voice': voice},
      }),
      customField: 'choices.0.message.audio.data',
    ),
  ),
  CompanionVoicePreset(
    id: 'openai',
    name: 'OpenAI',
    site: 'platform.openai.com',
    styled: true,
    voices: const [
      (id: 'coral', kind: null),
      (id: 'nova', kind: null),
      (id: 'shimmer', kind: null),
      (id: 'sage', kind: null),
      (id: 'alloy', kind: null),
      (id: 'ash', kind: null),
      (id: 'ballad', kind: null),
      (id: 'echo', kind: null),
      (id: 'fable', kind: null),
      (id: 'onyx', kind: null),
      (id: 'verse', kind: null),
    ],
    build: (base, key, voice, style) => base.copyWith(
      source: CompanionVoiceSource.openai,
      openaiBase: 'https://api.openai.com/v1',
      openaiKey: key,
      openaiModel: 'gpt-4o-mini-tts',
      openaiVoice: voice,
      openaiInstructions: style,
    ),
  ),
  CompanionVoicePreset(
    id: 'siliconflow',
    name: '硅基流动',
    site: 'cloud.siliconflow.cn',
    voices: const [
      (id: 'claire', kind: 'f'),
      (id: 'diana', kind: 'f'),
      (id: 'anna', kind: 'f'),
      (id: 'bella', kind: 'f'),
      (id: 'alex', kind: 'm'),
      (id: 'benjamin', kind: 'm'),
      (id: 'charles', kind: 'm'),
      (id: 'david', kind: 'm'),
    ],
    build: (base, key, voice, style) => base.copyWith(
      source: CompanionVoiceSource.openai,
      openaiBase: 'https://api.siliconflow.cn/v1',
      openaiKey: key,
      openaiModel: 'FunAudioLLM/CosyVoice2-0.5B',
      // A voice of its own (speech:…) is sent as it is.
      openaiVoice: voice.contains(':') ? voice : 'FunAudioLLM/CosyVoice2-0.5B:$voice',
      openaiInstructions: '',
    ),
  ),
  CompanionVoicePreset(
    id: 'bailian',
    name: '阿里云百炼',
    site: 'bailian.console.aliyun.com',
    voices: const [
      (id: 'Cherry', kind: 'f'),
      (id: 'Ethan', kind: 'm'),
      (id: 'Jennifer', kind: 'f'),
      (id: 'Ryan', kind: 'm'),
    ],
    // Qwen-TTS (Beijing region): the reply links to a WAV for 24 hours.
    build: (base, key, voice, style) => base.copyWith(
      source: CompanionVoiceSource.custom,
      customUrl: 'https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation',
      customPost: true,
      customHeaders: 'Authorization: Bearer $key',
      customBody: _jsonText({
        'model': 'qwen3-tts-flash',
        'input': {'text': '{text}', 'voice': voice},
      }),
      customField: 'output.audio.url',
    ),
  ),
];

CompanionVoicePreset companionVoicePreset(String id) =>
    companionVoicePresets.firstWhere((p) => p.id == id, orElse: () => companionVoicePresets.first);

@immutable
class CompanionVoiceSettings {
  const CompanionVoiceSettings({
    this.on = false,
    this.follow = false,
    this.source = CompanionVoiceSource.system,
    this.deepseekVoice = 'stella',
    this.preset = 'mimo',
    this.presetKeys = const {},
    this.presetVoices = const {},
    this.presetStyle = '',
    this.cloneOn = false,
    this.cloneSample = '',
    this.openaiBase = 'https://api.openai.com/v1',
    this.openaiKey = '',
    this.openaiModel = 'gpt-4o-mini-tts',
    this.openaiVoice = 'alloy',
    this.openaiInstructions = '',
    this.customUrl = '',
    this.customPost = true,
    this.customHeaders = '',
    this.customBody = '{"text": "{text}"}',
    this.customField = '',
  });

  final bool on;

  /// Her voice is whatever 设置 › 语音 › 朗读 uses (speech_settings.dart);
  /// the rest of these settings wait for when she has her own again.
  final bool follow;
  final CompanionVoiceSource source;

  /// [deepSeekVoices]: stella (海星) or tide (暗潮).
  final String deepseekVoice;

  /// The chosen [companionVoicePresets] id, and per preset its key (secure
  /// storage) and voice; one style for all that take one ('' for the default).
  final String preset;
  final Map<String, String> presetKeys;
  final Map<String, String> presetVoices;
  final String presetStyle;

  /// Speak in a voice cloned from [cloneSample] (a file this app keeps), for
  /// presets that can.
  final bool cloneOn;
  final String cloneSample;

  /// Whether the current preset speaks in the cloned voice.
  bool get cloning => source == CompanionVoiceSource.preset && presetInfo.clones && cloneOn;

  final String openaiBase;
  final String openaiKey;
  final String openaiModel;
  final String openaiVoice;

  /// How to speak, for models that take it (gpt-4o-mini-tts). Not stored: presets set it.
  final String openaiInstructions;
  final String customUrl;
  final bool customPost;

  /// One `Name: value` per line. Kept in secure storage: it often carries a key.
  final String customHeaders;
  final String customBody;

  /// Where the audio is in a JSON reply (`data.audio`, `items.0.url`); empty
  /// when the reply is the audio itself.
  final String customField;

  CompanionVoicePreset get presetInfo => companionVoicePreset(preset);

  /// The voice chosen for the current preset (its first until one is picked).
  String get presetVoice => presetVoices[presetInfo.id] ?? presetInfo.voices.first.id;

  String get presetKey => presetKeys[presetInfo.id] ?? '';

  /// What is actually asked: a preset becomes its OpenAI-compatible or custom request.
  CompanionVoiceSettings resolved() {
    if (source != CompanionVoiceSource.preset) return this;
    final style = presetStyle.trim().isEmpty ? companionVoiceStyleDefault : presetStyle.trim();
    return presetInfo.build(this, presetKey.trim(), presetVoice.trim(), style);
  }

  /// Whether the chosen source has what it needs to be asked at all.
  bool get configured => switch (source) {
    // Who pays is only known when asking (deepseek_speech.dart).
    CompanionVoiceSource.deepseek || CompanionVoiceSource.system => true,
    CompanionVoiceSource.preset =>
      presetKey.trim().isNotEmpty && (cloning ? cloneSample.isNotEmpty : presetVoice.trim().isNotEmpty),
    CompanionVoiceSource.openai => openaiBase.trim().isNotEmpty && openaiVoice.trim().isNotEmpty,
    CompanionVoiceSource.custom => customUrl.trim().isNotEmpty,
  };

  CompanionVoiceSettings copyWith({
    bool? on,
    bool? follow,
    CompanionVoiceSource? source,
    String? deepseekVoice,
    String? preset,
    Map<String, String>? presetKeys,
    Map<String, String>? presetVoices,
    String? presetStyle,
    bool? cloneOn,
    String? cloneSample,
    String? openaiBase,
    String? openaiKey,
    String? openaiModel,
    String? openaiVoice,
    String? openaiInstructions,
    String? customUrl,
    bool? customPost,
    String? customHeaders,
    String? customBody,
    String? customField,
  }) => CompanionVoiceSettings(
    on: on ?? this.on,
    follow: follow ?? this.follow,
    source: source ?? this.source,
    deepseekVoice: deepseekVoice ?? this.deepseekVoice,
    preset: preset ?? this.preset,
    presetKeys: presetKeys ?? this.presetKeys,
    presetVoices: presetVoices ?? this.presetVoices,
    presetStyle: presetStyle ?? this.presetStyle,
    cloneOn: cloneOn ?? this.cloneOn,
    cloneSample: cloneSample ?? this.cloneSample,
    openaiBase: openaiBase ?? this.openaiBase,
    openaiKey: openaiKey ?? this.openaiKey,
    openaiModel: openaiModel ?? this.openaiModel,
    openaiVoice: openaiVoice ?? this.openaiVoice,
    openaiInstructions: openaiInstructions ?? this.openaiInstructions,
    customUrl: customUrl ?? this.customUrl,
    customPost: customPost ?? this.customPost,
    customHeaders: customHeaders ?? this.customHeaders,
    customBody: customBody ?? this.customBody,
    customField: customField ?? this.customField,
  );

  /// The part kept in plain preferences: no keys, no headers.
  Map<String, Object?> plain() => {
    'follow': follow,
    'source': source.name,
    'deepseekVoice': deepseekVoice,
    'preset': preset,
    'presetVoices': presetVoices,
    'presetStyle': presetStyle,
    'cloneOn': cloneOn,
    'cloneSample': cloneSample,
    'openaiBase': openaiBase,
    'openaiModel': openaiModel,
    'openaiVoice': openaiVoice,
    'customUrl': customUrl,
    'customPost': customPost,
    'customBody': customBody,
    'customField': customField,
  };

  /// Settings as kept; [defaults] for what was never saved. Settings saved
  /// before [follow] existed keep their own voice.
  static CompanionVoiceSettings fromPlain(
    Object? json, {
    bool on = false,
    CompanionVoiceSettings defaults = const CompanionVoiceSettings(),
  }) {
    if (json is! Map) return defaults.copyWith(on: on);
    final map = json;
    String text(String key, String fallback) => map[key] is String ? map[key] as String : fallback;
    final voices = map['presetVoices'];
    final d = defaults;
    return CompanionVoiceSettings(
      on: on,
      follow: map['follow'] == true,
      source: CompanionVoiceSource.values.asNameMap()[map['source']] ?? d.source,
      deepseekVoice: deepSeekVoices.contains(map['deepseekVoice']) ? map['deepseekVoice'] as String : d.deepseekVoice,
      preset: text('preset', d.preset),
      presetVoices: {
        if (voices is Map)
          for (final MapEntry(:key, :value) in voices.entries)
            if (key is String && value is String) key: value,
      },
      presetStyle: text('presetStyle', d.presetStyle),
      cloneOn: map['cloneOn'] == true,
      cloneSample: text('cloneSample', d.cloneSample),
      openaiBase: text('openaiBase', d.openaiBase),
      openaiModel: text('openaiModel', d.openaiModel),
      openaiVoice: text('openaiVoice', d.openaiVoice),
      customUrl: text('customUrl', d.customUrl),
      customPost: map['customPost'] is bool ? map['customPost'] as bool : d.customPost,
      customBody: text('customBody', d.customBody),
      customField: text('customField', d.customField),
    );
  }
}

/// Where one set of voice settings is kept: her voice (伙伴小屋) and the
/// app's 朗读 voice (speech_settings.dart) each have their own.
class VoiceSettingsKeys {
  const VoiceSettingsKeys({
    required this.on,
    required this.plain,
    required this.openaiKey,
    required this.headers,
    required this.presetKeys,
  });

  final String on;
  final String plain;
  final String openaiKey;
  final String headers;
  final String presetKeys;
}

const companionVoiceKeys = VoiceSettingsKeys(
  on: 'companion_voice_enabled',
  plain: 'companion_voice_v1',
  openaiKey: 'companion_voice_openai_key',
  headers: 'companion_voice_custom_headers',
  presetKeys: 'companion_voice_preset_keys',
);

/// One set of voice settings; null until read (then nothing speaks).
abstract class VoiceOutputSettingsController extends Notifier<CompanionVoiceSettings?> {
  static const _secure = FlutterSecureStorage();

  VoiceSettingsKeys get keys;

  /// What a person who never saved anything gets.
  CompanionVoiceSettings get defaults;

  String get _onKey => keys.on;
  String get _plainKey => keys.plain;
  String get _openaiKeyKey => keys.openaiKey;
  String get _headersKey => keys.headers;
  String get _presetKeysKey => keys.presetKeys;

  @override
  CompanionVoiceSettings? build() {
    _loaded = _load();
    return null;
  }

  late Future<void> _loaded;

  /// The settings once they have been read (the defaults when nothing could be).
  Future<CompanionVoiceSettings> ready() async {
    await _loaded;
    return state ?? defaults;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_plainKey);
      var settings = CompanionVoiceSettings.fromPlain(
        raw == null ? null : jsonDecode(raw),
        on: prefs.getBool(_onKey) ?? defaults.on,
        defaults: defaults,
      );
      try {
        final keys = await _secure.read(key: _presetKeysKey);
        final decoded = keys == null ? null : jsonDecode(keys);
        settings = settings.copyWith(
          openaiKey: await _secure.read(key: _openaiKeyKey) ?? '',
          customHeaders: await _secure.read(key: _headersKey) ?? '',
          presetKeys: {
            if (decoded is Map)
              for (final MapEntry(:key, :value) in decoded.entries)
                if (key is String && value is String) key: value,
          },
        );
      } on Object {
        // No secure storage (tests, a broken keystore): no keys, nothing else lost.
      }
      if (ref.mounted && state == null) state = settings;
    } on Object {
      if (ref.mounted && state == null) state = defaults;
    }
  }

  Future<void> update(CompanionVoiceSettings next) async {
    final before = state;
    state = next;
    final prefs = await SharedPreferences.getInstance();
    if (before?.on != next.on) await prefs.setBool(_onKey, next.on);
    await prefs.setString(_plainKey, jsonEncode(next.plain()));
    try {
      if (before?.openaiKey != next.openaiKey) await _secure.write(key: _openaiKeyKey, value: next.openaiKey);
      if (before?.customHeaders != next.customHeaders) await _secure.write(key: _headersKey, value: next.customHeaders);
      if (!mapEquals(before?.presetKeys, next.presetKeys)) {
        await _secure.write(key: _presetKeysKey, value: jsonEncode(next.presetKeys));
      }
    } on Object {
      // Kept for this run only.
    }
  }
}

/// Her voice: off, and the same as 朗读's, until the person says otherwise.
class CompanionVoiceSettingsController extends VoiceOutputSettingsController {
  @override
  VoiceSettingsKeys get keys => companionVoiceKeys;

  @override
  CompanionVoiceSettings get defaults => const CompanionVoiceSettings(follow: true);
}

final companionVoiceSettingsProvider = NotifierProvider<CompanionVoiceSettingsController, CompanionVoiceSettings?>(
  CompanionVoiceSettingsController.new,
);

// ── Fetching ───────────────────────────────────────────────────────────────

class CompanionVoiceError implements Exception {
  const CompanionVoiceError(this.reason);

  /// Short and technical: `HTTP 401 …`, `timeout`, `not audio`, `no field data.audio`.
  final String reason;

  @override
  String toString() => 'CompanionVoiceError($reason)';
}

@immutable
class CompanionVoiceAudio {
  const CompanionVoiceAudio(this.bytes, this.ext);

  final Uint8List bytes;

  /// wav, mp3, ogg, flac, m4a, or bin when unknown (the player may still manage).
  final String ext;
}

/// The format [bytes] are in, by their first bytes.
String companionAudioKind(Uint8List bytes) {
  bool at(int i, List<int> magic) =>
      bytes.length >= i + magic.length && Iterable<int>.generate(magic.length).every((k) => bytes[i + k] == magic[k]);
  if (at(0, ascii.encode('RIFF')) && at(8, ascii.encode('WAVE'))) return 'wav';
  if (at(0, ascii.encode('ID3')) || (bytes.length > 1 && bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0)) return 'mp3';
  if (at(0, ascii.encode('OggS'))) return 'ogg';
  if (at(0, ascii.encode('fLaC'))) return 'flac';
  if (at(4, ascii.encode('ftyp'))) return 'm4a';
  return 'bin';
}

/// One sentence of [text] from the settings' external source.
Future<CompanionVoiceAudio> fetchCompanionVoice(
  CompanionVoiceSettings settings,
  String text,
  http.Client client, {
  Duration timeout = const Duration(seconds: 20),
  DeepSeekSpeechResolver? deepseek,
}) async {
  if (settings.source == CompanionVoiceSource.deepseek) return _deepseek(settings, text, deepseek, timeout);
  if (settings.cloning) {
    final voice = await companionCloneVoice(settings.cloneSample);
    settings = settings.copyWith(presetVoices: {...settings.presetVoices, settings.preset: voice});
  }
  settings = settings.resolved();
  final http.Response response;
  try {
    response = await switch (settings.source) {
      CompanionVoiceSource.openai => client.post(
        Uri.parse('${settings.openaiBase.trim().replaceAll(RegExp(r'/+$'), '')}/audio/speech'),
        headers: {
          'content-type': 'application/json',
          if (settings.openaiKey.trim().isNotEmpty) 'authorization': 'Bearer ${settings.openaiKey.trim()}',
        },
        body: jsonEncode({
          'model': settings.openaiModel.trim(),
          'input': text,
          'voice': settings.openaiVoice.trim(),
          // Raw loudness for her mouth; servers that can't still answer in their own format.
          'response_format': 'wav',
          if (settings.openaiInstructions.trim().isNotEmpty) 'instructions': settings.openaiInstructions.trim(),
        }),
      ),
      CompanionVoiceSource.custom => _custom(settings, text, client),
      CompanionVoiceSource.deepseek ||
      CompanionVoiceSource.system ||
      CompanionVoiceSource.preset => throw const CompanionVoiceError('system voice is not fetched'),
    }.timeout(timeout);
  } on TimeoutException {
    throw const CompanionVoiceError('timeout');
  } on CompanionVoiceError {
    rethrow;
  } on Object catch (error) {
    throw CompanionVoiceError(error.toString().split('\n').first);
  }
  if (response.statusCode != 200) {
    final note = utf8.decode(response.bodyBytes.take(160).toList(), allowMalformed: true).replaceAll('\n', ' ').trim();
    throw CompanionVoiceError('HTTP ${response.statusCode}${note.isEmpty ? '' : ' $note'}');
  }
  var bytes = response.bodyBytes;
  final field = settings.source == CompanionVoiceSource.custom ? settings.customField.trim() : '';
  if (field.isNotEmpty) bytes = await _fromJson(bytes, field, client, timeout);
  final kind = companionAudioKind(bytes);
  // A JSON or HTML error page that came back as 200.
  if (kind == 'bin' && bytes.isNotEmpty && (bytes.first == 0x7B || bytes.first == 0x3C)) {
    throw const CompanionVoiceError('not audio');
  }
  if (bytes.isEmpty) throw const CompanionVoiceError('empty reply');
  return CompanionVoiceAudio(bytes, kind);
}

/// One sentence from DeepSeek, as a WAV (her mouth reads its loudness).
Future<CompanionVoiceAudio> _deepseek(
  CompanionVoiceSettings settings,
  String text,
  DeepSeekSpeechResolver? resolve,
  Duration timeout,
) async {
  final speech = resolve == null ? null : await resolve();
  if (speech == null) throw const CompanionVoiceError('no-deepseek');
  try {
    final pcm = BytesBuilder(copy: false);
    await for (final chunk in speech.synthesize(text, voice: settings.deepseekVoice).timeout(timeout)) {
      pcm.add(chunk);
    }
    if (pcm.isEmpty) throw const CompanionVoiceError('empty reply');
    return CompanionVoiceAudio(deepSeekWav(pcm.takeBytes()), 'wav');
  } on DeepSeekSpeechError catch (error) {
    throw CompanionVoiceError('deepseek ${error.failure.name}${error.detail.isEmpty ? '' : ' ${error.detail}'}');
  } on TimeoutException {
    throw const CompanionVoiceError('timeout');
  } finally {
    speech.close();
  }
}

Future<http.Response> _custom(CompanionVoiceSettings settings, String text, http.Client client) {
  final url = Uri.parse(settings.customUrl.trim().replaceAll('{text}', Uri.encodeQueryComponent(text)));
  final headers = <String, String>{};
  for (final line in const LineSplitter().convert(settings.customHeaders)) {
    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    headers[line.substring(0, colon).trim()] = line.substring(colon + 1).trim();
  }
  if (!settings.customPost) return client.get(url, headers: headers);
  // Inside the template's quotes: the text escaped as a JSON string's content.
  final escaped = jsonEncode(text);
  final body = settings.customBody.replaceAll('{text}', escaped.substring(1, escaped.length - 1));
  headers.putIfAbsent('content-type', () => 'application/json');
  return client.post(url, headers: headers, body: body);
}

/// The audio at [path] in a JSON reply: base64 (a data: URL too) or a link.
Future<Uint8List> _fromJson(Uint8List body, String path, http.Client client, Duration timeout) async {
  Object? node;
  try {
    node = jsonDecode(utf8.decode(body));
  } on FormatException {
    throw const CompanionVoiceError('reply is not JSON');
  }
  for (final step in path.split('.')) {
    final index = int.tryParse(step);
    if (node is Map && node.containsKey(step)) {
      node = node[step];
    } else if (node is List && index != null && index >= 0 && index < node.length) {
      node = node[index];
    } else {
      throw CompanionVoiceError('no field $path');
    }
  }
  if (node is! String || node.isEmpty) throw CompanionVoiceError('no field $path');
  if (node.startsWith('http://') || node.startsWith('https://')) {
    try {
      final audio = await client.get(Uri.parse(node)).timeout(timeout);
      if (audio.statusCode != 200) throw CompanionVoiceError('HTTP ${audio.statusCode} for the audio link');
      return audio.bodyBytes;
    } on TimeoutException {
      throw const CompanionVoiceError('timeout');
    }
  }
  final data = node.contains(',') && node.startsWith('data:') ? node.substring(node.indexOf(',') + 1) : node;
  try {
    return base64.decode(base64.normalize(data.replaceAll(RegExp(r'\s'), '')));
  } on FormatException {
    throw CompanionVoiceError('field $path is neither base64 nor a link');
  }
}

// ── Cloning ────────────────────────────────────────────────────────────────

/// The largest recording kept for cloning: MiMo takes at most 10 MB of base64.
const companionCloneMaxBytes = 7 * 1024 * 1024;

String? _cloneKey;
String? _cloneUri;

/// The recording at [path] as the `data:` URI a cloning request carries. Kept
/// in memory while the file is unchanged: every sentence sends it.
Future<String> companionCloneVoice(String path) async {
  final file = File(path);
  final FileStat stat;
  try {
    stat = await file.stat();
  } on FileSystemException {
    throw const CompanionVoiceError('recording missing');
  }
  if (stat.type != FileSystemEntityType.file) throw const CompanionVoiceError('recording missing');
  final key = '$path:${stat.size}:${stat.modified.millisecondsSinceEpoch}';
  if (key == _cloneKey && _cloneUri != null) return _cloneUri!;
  final bytes = await file.readAsBytes();
  final mime = switch (companionAudioKind(bytes)) {
    'wav' => 'audio/wav',
    'mp3' => 'audio/mpeg',
    _ => throw const CompanionVoiceError('recording is not mp3 or wav'),
  };
  _cloneKey = key;
  return _cloneUri = 'data:$mime;base64,${base64.encode(bytes)}';
}

/// Keeps a picked recording in [folder] as the one to clone from, replacing
/// the one before. Checks its size as it arrives and its format once it has.
Future<File> companionKeepRecording(Stream<List<int>> bytes, Directory folder) async {
  await folder.create(recursive: true);
  final incoming = File('${folder.path}/voice-sample.part');
  try {
    final sink = incoming.openWrite();
    var size = 0;
    try {
      await for (final chunk in bytes) {
        size += chunk.length;
        if (size > companionCloneMaxBytes) throw const CompanionVoiceError('too-large');
        sink.add(chunk);
      }
    } finally {
      await sink.close();
    }
    final head = await incoming.openRead(0, 16).fold<List<int>>([], (all, part) => all..addAll(part));
    final ext = switch (companionAudioKind(Uint8List.fromList(head))) {
      'wav' => 'wav',
      'mp3' => 'mp3',
      _ => throw const CompanionVoiceError('not-audio'),
    };
    for (final old in ['wav', 'mp3']) {
      final previous = File('${folder.path}/voice-sample.$old');
      if (await previous.exists()) await previous.delete();
    }
    return await incoming.rename('${folder.path}/voice-sample.$ext');
  } finally {
    // Refused or failed: nothing half-written stays. (Once renamed, it is gone from here.)
    if (await incoming.exists()) await incoming.delete();
  }
}

/// How long a WAV recording lasts; null for other formats.
Duration? companionRecordingLength(Uint8List head, int size) {
  if (companionAudioKind(head) != 'wav' || head.length < 32) return null;
  final data = ByteData.sublistView(head);
  final byteRate = data.getUint32(28, Endian.little);
  if (byteRate == 0) return null;
  return Duration(milliseconds: (size - 44) * 1000 ~/ byteRate);
}

// ── Loudness ───────────────────────────────────────────────────────────────

/// How open her mouth should be every [frameMs] while a WAV plays (0–1), from
/// its loudness against its own loudest moment; null for anything that isn't
/// 16-bit PCM WAV.
List<double>? companionLoudness(Uint8List wav, {int frameMs = 40}) {
  if (companionAudioKind(wav) != 'wav') return null;
  final data = ByteData.sublistView(wav);
  int? channels;
  int? rate;
  int? bits;
  var offset = 12;
  int? start;
  int? length;
  while (offset + 8 <= wav.length) {
    final id = ascii.decode(wav.sublist(offset, offset + 4), allowInvalid: true);
    var size = data.getUint32(offset + 4, Endian.little);
    final body = offset + 8;
    if (id == 'fmt ' && body + 16 <= wav.length) {
      if (data.getUint16(body, Endian.little) != 1) return null; // Not PCM.
      channels = data.getUint16(body + 2, Endian.little);
      rate = data.getUint32(body + 4, Endian.little);
      bits = data.getUint16(body + 14, Endian.little);
    } else if (id == 'data') {
      start = body;
      // Streaming servers write a placeholder size: take what is there.
      if (size == 0 || size == 0xFFFFFFFF || body + size > wav.length) size = wav.length - body;
      length = size;
      break;
    }
    offset = body + size + (size.isOdd ? 1 : 0);
  }
  if (channels == null || rate == null || bits != 16 || start == null || length == null || channels == 0) return null;
  final frameSamples = max(1, rate * frameMs ~/ 1000);
  final stride = 2 * channels;
  final count = length ~/ stride;
  final levels = <double>[];
  for (var first = 0; first < count; first += frameSamples) {
    var sum = 0.0;
    final last = min(count, first + frameSamples);
    for (var i = first; i < last; i++) {
      final sample = data.getInt16(start + i * stride, Endian.little) / 32768.0;
      sum += sample * sample;
    }
    levels.add(sqrt(sum / (last - first)));
  }
  final peak = levels.fold<double>(0, max);
  if (peak < 1e-4) return List.filled(levels.length, 0);
  return [
    for (final level in levels)
      // Quiet breaths stay closed; speech opens it, never all the way.
      level / peak < 0.12 ? 0 : (pow(level / peak, 0.7) * 0.9).toDouble(),
  ];
}
