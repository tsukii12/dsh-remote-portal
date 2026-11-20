// A chat's two card players on the canvas (酒馆助手's 播放音频 pages, 'bgm'
// and 'ambient'): the lists and settings its scripts set, kept on this phone
// per chat. The page plays; what is playing goes with the page.

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const tavernAudioChannels = ['bgm', 'ambient'];
const tavernAudioModes = {'repeat_one', 'repeat_all', 'shuffle', 'play_one_and_stop'};

/// [json] as it is kept: for each channel its list ({title, url}, every one
/// with a url) and the settings it names that are right (enabled, mode,
/// muted, volume 0–100). What is missing or wrong is left out.
Map<String, Object?> tavernAudioState(Object? json) {
  if (json is! Map) return const {};
  return {
    for (final type in tavernAudioChannels)
      if (json[type] case final Map<Object?, Object?> channel)
        type: {
          'list': [
            if (channel['list'] case final List<Object?> items)
              for (final item in items)
                if (item case {'url': final String url} when url.isNotEmpty)
                  {'title': item['title'] is String ? item['title'] : '', 'url': url},
          ],
          'settings': {
            if (channel['settings'] case final Map<Object?, Object?> s) ...{
              if (s['enabled'] case final bool enabled) 'enabled': enabled,
              if (s['mode'] case final String mode when tavernAudioModes.contains(mode)) 'mode': mode,
              if (s['muted'] case final bool muted) 'muted': muted,
              if (s['volume'] case final num volume when volume.isFinite) 'volume': volume.clamp(0, 100),
            },
          },
        },
  };
}

String _key(String chatId) => 'tavern.audio.$chatId';

/// What [chatId]'s players were left at; nothing when never set, or unreadable.
Future<Map<String, Object?>> tavernLoadAudio(String chatId) async {
  try {
    final raw = (await SharedPreferences.getInstance()).getString(_key(chatId));
    return raw == null ? const {} : tavernAudioState(jsonDecode(raw));
  } on Object {
    return const {};
  }
}

/// Keeps what [chatId]'s page says its players are now.
Future<void> tavernSaveAudio(String chatId, Object? state) async {
  await (await SharedPreferences.getInstance()).setString(_key(chatId), jsonEncode(tavernAudioState(state)));
}

/// One of a page's players as the page last said it was: the track it is on
/// (its title; empty when none or not in the list), whether it is playing,
/// how many tracks its list has, and its settings.
class TavernAudioNow {
  const TavernAudioNow({
    this.title = '',
    this.playing = false,
    this.tracks = 0,
    this.enabled = true,
    this.mode = 'repeat_all',
    this.volume = 100,
  });

  static TavernAudioNow? fromJson(Object? json) {
    if (json is! Map) return null;
    final settings = json['settings'] is Map ? json['settings'] as Map : const {};
    return TavernAudioNow(
      title: json['title'] is String ? json['title'] as String : '',
      playing: json['playing'] == true,
      tracks: json['tracks'] is num ? (json['tracks'] as num).toInt() : 0,
      enabled: settings['enabled'] != false,
      mode: tavernAudioModes.contains(settings['mode']) ? settings['mode'] as String : 'repeat_all',
      volume: settings['volume'] is num && (settings['volume'] as num).isFinite
          ? (settings['volume'] as num).clamp(0, 100)
          : 100,
    );
  }

  final String title;
  final bool playing;
  final int tracks;
  final bool enabled;
  final String mode;
  final num volume;

  /// Anything for the player to see: a list, or a track on.
  bool get any => tracks > 0 || title.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is TavernAudioNow &&
      other.title == title &&
      other.playing == playing &&
      other.tracks == tracks &&
      other.enabled == enabled &&
      other.mode == mode &&
      other.volume == volume;

  @override
  int get hashCode => Object.hash(title, playing, tracks, enabled, mode, volume);
}

/// [chatId]'s canvas players as its page says they are ('bgm', 'ambient'),
/// and the way to tell that page what the player wants; empty while no page
/// is up.
final tavernCanvasAudioProvider = NotifierProvider.family<TavernCanvasAudio, Map<String, TavernAudioNow>, String>(
  TavernCanvasAudio.new,
);

class TavernCanvasAudio extends Notifier<Map<String, TavernAudioNow>> {
  TavernCanvasAudio(this.chatId);

  final String chatId;
  Future<void> Function(Map<String, Object?> command)? _send;

  @override
  Map<String, TavernAudioNow> build() => const {};

  /// The page that takes commands now ([send]), or none.
  void attach(Future<void> Function(Map<String, Object?> command) send) => _send = send;

  /// [send]'s page is gone: nothing playing to show, unless another took over.
  void detach(Future<void> Function(Map<String, Object?> command) send) {
    if (_send != send) return;
    _send = null;
    state = const {};
  }

  /// What the page says ({bgm: {title, playing, tracks, settings}, ambient: …}).
  void report(Object? json) {
    final next = {
      if (json is Map)
        for (final type in tavernAudioChannels) type: ?TavernAudioNow.fromJson(json[type]),
    };
    if (next.length != state.length || next.entries.any((e) => state[e.key] != e.value)) state = next;
  }

  /// Plays or pauses [type]'s player.
  Future<void> toggle(String type) => _command({'type': type, 'action': 'toggle'});

  /// Adds the track at [url] to [type]'s list, as a script would (kept with
  /// the chat); not twice.
  Future<void> append(String type, String url) => _command({
    'type': type,
    'append': [
      {'url': url},
    ],
  });

  /// Changes [type]'s settings as a script would (kept with the chat).
  Future<void> settle(String type, Map<String, Object?> settings) => _command({'type': type, 'settings': settings});

  Future<void> _command(Map<String, Object?> command) async {
    try {
      await _send?.call(command);
    } on Object {
      // The page went: nothing to tell.
    }
  }
}

/// A canvas's players while the app is out of sight: [suspend] (true) when it
/// goes, so a card's music does not play on behind other apps, and (false)
/// when it is back, for what was playing to go on.
class TavernCanvasAudioLifecycle {
  TavernCanvasAudioLifecycle(this.suspend) {
    _listener = AppLifecycleListener(onHide: () => suspend(true), onShow: () => suspend(false));
  }

  final void Function(bool on) suspend;
  late final AppLifecycleListener _listener;

  void dispose() => _listener.dispose();
}
