// v1.2 capabilities of native plugins (docs/design/native-plugins-protocol.md
// §11): a finite audio clip from the Host, speech activity detected in the app,
// a small caption channel and one floating caption line.
//
// One owner at a time, app-wide: the tap that started it (plugin, instance,
// bridge lease, session, stream connection). Every async completion checks
// it is still the owner it started for. Nothing here exists while no plugin
// declares a capability: no platform call, no event channel, no timer.
//
// Speech: the native side detects it, stops the owner's playback itself and
// only then reports `voice.speechStart` (with `localStopped`); this side
// tells the plugin afterwards. The network is never on the stopping path.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../state/hosts_state.dart';
import '../../state/sessions_state.dart';
import '../../ui_config/ui_config_ignores.dart' show uiHostKey;
import 'native_model.dart';
import 'native_platform.dart';
import 'native_file_platform.dart';
import 'native_state.dart';

/// An `audio` / `voice` / `overlay` effect from an invoke answer, with the
/// lease the bridge added.
@immutable
class NativeCapabilityEffect {
  const NativeCapabilityEffect(this.type, this.op, this.instance, this.lease, {this.resource, this.key});

  /// `audio`, `voice`, `overlay`.
  final String type;
  final String op;
  final String instance;
  final String lease;

  /// The media id (`audio play`) or the overlay id.
  final String? resource;
  final String? key;

  bool get starts => op == 'play' || op == 'start' || op == 'show';

  static bool isType(Object? value) => const {'audio', 'voice', 'overlay'}.contains(value);

  static final _key = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  /// The effect, or null when anything about it is off: an unknown op, a
  /// source that isn't `media:<id>`, a missing lease, an unknown field.
  static NativeCapabilityEffect? parse(Map<String, Object?> value) {
    final type = value['type'], op = value['op'], instance = value['instance'], lease = value['lease'];
    if (type is! String ||
        op is! String ||
        instance is! String ||
        !dshGoValidId(instance) ||
        lease is! String ||
        lease.isEmpty ||
        lease.length > 256) {
      return null;
    }
    final ops = switch (type) {
      'audio' => const {'play', 'pause', 'resume', 'stop'},
      'voice' => const {'start', 'stop'},
      'overlay' => const {'show', 'hide'},
      _ => const <String>{},
    };
    if (!ops.contains(op)) return null;
    String? resource, key;
    final fields = {'type', 'op', 'instance', 'lease'};
    if (type == 'audio' && op == 'play') {
      fields.addAll(const {'src', 'key'});
      final src = value['src'];
      if (src is! String || !src.startsWith('media:') || !dshGoValidId(src.substring(6))) return null;
      resource = src.substring(6);
      if (value.containsKey('key')) {
        final k = value['key'];
        if (k is! String || !_key.hasMatch(k)) return null;
        key = k;
      }
    } else if (type == 'overlay') {
      fields.add('id');
      final id = value['id'];
      if (id is! String || !dshGoValidId(id)) return null;
      resource = id;
    }
    if (value.keys.any((k) => !fields.contains(k))) return null;
    return NativeCapabilityEffect(type, op, instance, lease, resource: resource, key: key);
  }
}

/// Reads a clip into the app's private cache: `<cache>/native-media/<owner>/clip`.
typedef NativeMediaDownload = Future<(File, String)> Function(String pkg, NativeCapabilityEffect effect, String owner);

/// [NativeMediaDownload] over the Host's bridge ([DshGoApi.readDshGoMedia]).
Future<(File, String)> downloadNativeMedia(
  DshClient client,
  String pkg,
  NativeCapabilityEffect effect,
  String owner,
) async {
  final media = await client.readDshGoMedia(pkg, effect.resource!, lease: effect.lease, key: effect.key);
  final root = Directory('${(await getTemporaryDirectory()).path}/native-media');
  final directory = Directory('${root.path}/$owner');
  await directory.create(recursive: true);
  // Left over by a process that died mid-clip.
  try {
    final old = DateTime.now().subtract(const Duration(hours: 1));
    await for (final entry in root.list()) {
      if (entry.path != directory.path && (await entry.stat()).modified.isBefore(old)) {
        await entry.delete(recursive: true);
      }
    }
  } catch (_) {}
  final file = File('${directory.path}/clip');
  try {
    await file.writeAsBytes(media.bytes, flush: true);
  } catch (_) {
    await directory.delete(recursive: true);
    rethrow;
  }
  return (file, media.contentType);
}

/// Asks the person whether [package] may listen for them speaking: true
/// allowed, false not (and remembered; the switch in its settings turns it
/// back on).
typedef NativeVoiceConsent = Future<bool> Function(String package);

const _terminals = {'audio.ended', 'audio.stopped', 'audio.error', 'voice.stopped', 'voice.error', 'overlay.closed'};

class _Owner {
  _Owner(this.token, this.generation, this.pkg, this.instance, this.lease, this.scope, this.conn);

  final String token;
  final int generation;
  final String pkg;
  final String instance;
  final String lease;
  final DshGoScope scope;
  final String conn;

  /// Roles running now, roles ever started, roles that have ended.
  final roles = <String>{};
  final claimed = <String>{};
  final ended = <String>{};

  /// Roles being stopped by the app itself (after the audio).
  final stopping = <String>{};

  /// `cap.event`s not sent yet (at most 4, one every 100 ms).
  final events = <(String, String?)>[];
  int seq = 0;

  /// Bumped by stop / speech: a download that finishes later must not play.
  int audioGeneration = 0;
  bool granted = false, denied = false, speaking = false;
  File? file;
  StreamSubscription<DshGoEvent>? captions;
  Timer? eventTimer;

  Map<String, Object?> get args => {'owner': token, 'generation': generation, 'lease': lease};
}

/// Runs capability effects for the active host's stream.
class NativeCapabilityRuntime {
  NativeCapabilityRuntime({
    required this.platform,
    required this.stream,
    required this.download,
    required this.plugin,
    required this.hostIdentity,
    required this.hostTitle,
    required this.session,
    this.pluginTitle,
    this.overlayTop,
    this.onNativeFailure,
    this._foreground = true,
  }) {
    _links = stream.links.listen((link) {
      if (link != DshGoLink.open) unawaited(revoke());
    });
    _events = platform.events.listen(_event, onError: (Object _) => unawaited(revoke()));
  }

  final NativeMediaPlatform platform;
  final DshGoStream stream;
  final NativeMediaDownload download;
  final NativePlugin? Function(String pkg) plugin;
  final String? Function(String pkg)? pluginTitle;

  /// Where the native indicator and caption start (logical px from the top).
  final double? Function()? overlayTop;
  final String hostIdentity, hostTitle;
  final String? Function() session;
  final void Function()? onNativeFailure;
  late final StreamSubscription<DshGoLink> _links;
  late final StreamSubscription<Object?> _events;
  _Owner? _owner;
  int _generation = 0;
  bool _foreground, _disposed = false, _nativeFailed = false;
  Future<void>? _closing;
  final _deniedLeases = <String>{};

  bool get active => _owner != null;

  bool _current(_Owner o) {
    if (_disposed || _nativeFailed || !_foreground || !identical(_owner, o)) return false;
    if (stream.conn != o.conn || session() != o.scope.sessionId) return false;
    final p = plugin(o.pkg);
    return p != null && p.native && o.claimed.every(p.capabilities.contains);
  }

  /// The app is on screen (resumed or inactive) or not; leaving stops all.
  void foreground(bool value) {
    _foreground = value;
    if (!value) unawaited(revoke());
  }

  /// The contributions changed: an owner whose plugin went away or dropped
  /// a capability it uses stops.
  void revalidate() {
    final o = _owner;
    if (o != null && !_current(o)) unawaited(revoke());
  }

  /// Runs one effect of a tap's answer; true when it was taken. [consent] is
  /// asked before a plugin first listens (and remembered by it).
  Future<bool> execute(
    NativeCapabilityEffect effect, {
    required String pkg,
    required DshGoScope scope,
    required String? connection,
    required DateTime tappedAt,
    required DateTime now,
    NativeVoiceConsent? consent,
  }) async {
    final declaration = plugin(pkg);
    if (_disposed ||
        _nativeFailed ||
        _closing != null ||
        !_foreground ||
        connection == null ||
        connection != stream.conn ||
        scope.sessionId != session() ||
        now.difference(tappedAt) > NativeLimits.tapWindow ||
        now.isBefore(tappedAt) ||
        declaration == null ||
        !declaration.native ||
        !declaration.capabilities.contains(effect.type) ||
        !stream.negotiatedFeatures.contains(effect.type) ||
        (effect.type == 'voice' && effect.op == 'start' && _deniedLeases.contains(effect.lease))) {
      return false;
    }
    if (effect.type == 'audio' && effect.op == 'play' && !declaration.media.contains(effect.resource)) return false;
    final overlay = declaration.overlays.where((v) => v.id == effect.resource).firstOrNull;
    if (effect.type == 'overlay' && overlay == null) return false;

    var owner = _owner;
    if (owner == null ||
        owner.pkg != pkg ||
        owner.instance != effect.instance ||
        owner.lease != effect.lease ||
        owner.scope != scope) {
      // Only a start makes a new owner; it replaces the old one first.
      if (!effect.starts) return false;
      await revoke();
      if (_disposed ||
          _nativeFailed ||
          _owner != null ||
          !_foreground ||
          stream.conn != connection ||
          session() != scope.sessionId) {
        return false;
      }
      final random = Random.secure();
      final token = [for (var i = 0; i < 24; i++) random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
      owner = _Owner(token, ++_generation, pkg, effect.instance, effect.lease, scope, connection);
      owner.claimed.add(effect.type);
      _owner = owner;
      final held = await stream.hold();
      if (!_current(owner) || held != connection) {
        await _revokeOwner(owner);
        return false;
      }
      try {
        await platform.call('activate', {
          ...owner.args,
          'hostIdentity': hostIdentity,
          'hostTitle': hostTitle,
          'pkg': pkg,
          'pluginTitle': pluginTitle?.call(pkg) ?? declaration.title ?? pkg,
          'top': ?overlayTop?.call(),
        });
      } catch (_) {
        await _revokeOwner(owner);
        return false;
      }
    }
    final o = owner;
    if (!_current(o)) return false;
    if (effect.starts) o.claimed.add(effect.type);
    try {
      switch (effect.type) {
        case 'audio':
          if (effect.op == 'play') {
            // One clip per owner: another play is a new tap, a new lease.
            if (o.roles.contains('audio') || o.ended.contains('audio')) return false;
            o.roles.add('audio');
            unawaited(_prepare(o, effect, ++o.audioGeneration));
          } else {
            if (!o.roles.contains('audio')) return false;
            if (effect.op == 'stop') ++o.audioGeneration;
            await platform.call(effect.op, o.args);
            if (!_current(o)) return false;
            if (effect.op == 'stop') _terminal(o, 'audio.stopped');
          }
        case 'voice':
          if (effect.op == 'start') {
            if (o.denied || o.roles.contains('voice') || o.ended.contains('voice')) return false;
            final allowed = consent == null ? false : await consent(pkg);
            if (!_current(o)) return false;
            if (!allowed) {
              _deny(o, 'declined');
              return false;
            }
            // The system permission (asked once by Android, then remembered).
            final granted = await platform.call('requestVoiceGrant', o.args);
            if (!_current(o)) return false;
            if (granted != true) {
              _deny(o, 'permission');
              return false;
            }
            o.granted = true;
            o.roles.add('voice');
            try {
              await platform.call('startVoice', o.args);
            } on PlatformException catch (e) {
              // No microphone now (dictation has it, it would not open): listening is off,
              // the clip and the caption go on.
              if (_current(o)) {
                _terminal(
                  o,
                  'voice.error',
                  const {'busy', 'permission', 'capture', 'indicator'}.contains(e.code) ? e.code : 'error',
                );
              }
              return false;
            }
            if (!_current(o)) return false;
          } else {
            if (!o.roles.contains('voice')) return false;
            await platform.call('stopVoice', o.args);
            if (_current(o)) _terminal(o, 'voice.stopped');
          }
        case 'overlay':
          if (effect.op == 'show') {
            if (o.roles.contains('overlay') || o.ended.contains('overlay')) return false;
            o.roles.add('overlay');
            try {
              await platform.call('showOverlay', {...o.args, 'text': overlay!.text ?? ''});
            } catch (_) {
              // No window here (or no room for one): the caption is off, the rest goes on.
              if (_current(o)) _terminal(o, 'overlay.closed', 'unsupported');
              return false;
            }
            if (!_current(o)) return false;
            final channel = overlay.channel;
            if (channel != null && declaration.micro.contains(channel) && stream.negotiatedFeatures.contains('micro')) {
              o.captions = stream.subscribeMicro(pkg: pkg, id: channel, scope: scope).listen((event) {
                if (!_current(o) || !o.roles.contains('overlay')) return;
                if (event case DshGoData(data: {'text': final String text})) {
                  unawaited(
                    platform
                        .call('updateOverlay', {...o.args, 'text': text})
                        .then<void>(
                          (_) {},
                          onError: (Object _) {
                            if (_current(o)) _terminal(o, 'overlay.closed', 'error');
                          },
                        ),
                  );
                }
              });
            }
          } else {
            if (!o.roles.contains('overlay')) return false;
            await platform.call('hideOverlay', o.args);
            if (_current(o)) _terminal(o, 'overlay.closed');
          }
      }
      return _current(o);
    } catch (_) {
      await _revokeOwner(o);
      return false;
    }
  }

  void _deny(_Owner o, String reason) {
    o.denied = true;
    _deniedLeases.add(o.lease);
    if (_deniedLeases.length > 32) _deniedLeases.remove(_deniedLeases.first);
    o.ended.add('voice');
    _queue(o, 'voice.error', reason);
  }

  Future<void> _prepare(_Owner o, NativeCapabilityEffect effect, int audioGeneration) async {
    File? file;
    var handedToNative = false;
    try {
      final media = await download(o.pkg, effect, o.token);
      file = media.$1;
      if (!_current(o) || !o.roles.contains('audio') || o.audioGeneration != audioGeneration) {
        await _delete(file);
        return;
      }
      o.file = file;
      handedToNative = true;
      await platform.call('play', {...o.args, 'privatePath': file.path, 'contentType': media.$2});
    } catch (_) {
      if (_current(o) && o.roles.contains('audio') && o.audioGeneration == audioGeneration) {
        _terminal(o, 'audio.error', 'media');
      }
      // Once handed over, only a confirmed native close may delete the file.
      if (file != null && !handedToNative) await _delete(file);
    }
  }

  void _event(Object? value) {
    final o = _owner;
    if (o == null ||
        !_current(o) ||
        value is! Map ||
        value['owner'] != o.token ||
        value['generation'] != o.generation ||
        value['lease'] != o.lease) {
      return;
    }
    final kind = value['kind'];
    final reason = value['reason'] is String ? value['reason'] as String : null;
    if (kind == 'owner.revoked') {
      // The 停止 on the listening indicator, dictation taking the
      // microphone, the app leaving the screen: the native side has stopped
      // everything already.
      unawaited(_revokeOwner(o));
      return;
    }
    if (kind == 'voice.speechStart') {
      // Only with proof that this owner's playback is already stopped.
      if (!o.granted || !o.roles.contains('voice') || o.speaking || value['localStopped'] != true) return;
      o.speaking = true;
      ++o.audioGeneration;
      // The bridge ends the audio role on speechStart; no audio.stopped follows.
      if (o.roles.remove('audio')) o.ended.add('audio');
      _queue(o, 'voice.speechStart');
      _afterAudio(o);
    } else if (kind == 'voice.speechEnd') {
      if (!o.roles.contains('voice') || !o.speaking) return;
      o.speaking = false;
      _queue(o, 'voice.speechEnd');
      _afterAudio(o, 'speech-ended');
    } else if (kind is String && _terminals.contains(kind)) {
      _terminal(o, kind, reason);
    }
  }

  void _terminal(_Owner o, String event, [String? reason]) {
    final role = event.split('.').first;
    if (!o.roles.remove(role) || !o.ended.add(role)) return;
    if (role == 'voice') o.granted = false;
    if (role == 'overlay') {
      unawaited(o.captions?.cancel());
      o.captions = null;
    }
    _queue(o, event, reason);
    if (role == 'audio') _afterAudio(o);
  }

  /// Listening and the caption go with the owner's clip: once it is over
  /// (and whatever the person was saying is finished), they stop too.
  void _afterAudio(_Owner o, [String reason = 'audio-ended']) {
    if (!o.claimed.contains('audio') || o.roles.contains('audio')) return;
    if (o.roles.contains('overlay')) unawaited(_stopRole(o, 'overlay', 'audio-ended'));
    if (o.roles.contains('voice') && !o.speaking) unawaited(_stopRole(o, 'voice', reason));
  }

  Future<void> _stopRole(_Owner o, String role, String reason) async {
    if (!o.roles.contains(role) || !o.stopping.add(role)) return;
    try {
      await platform.call(role == 'voice' ? 'stopVoice' : 'hideOverlay', o.args);
    } catch (_) {
      await _revokeOwner(o);
      return;
    }
    if (_current(o)) _terminal(o, role == 'voice' ? 'voice.stopped' : 'overlay.closed', reason);
  }

  void _queue(_Owner o, String event, [String? reason]) {
    if (o.events.isNotEmpty && o.events.last == (event, reason)) return;
    if (o.events.length >= 4) {
      // A flood: stop here and now; only the terminals go out.
      unawaited(revoke(terminal: _terminals.contains(event) ? event : null));
      return;
    }
    o.events.add((event, reason));
    if (o.eventTimer == null) _flush(o);
  }

  void _flush(_Owner o) {
    if (!_current(o)) return;
    if (o.events.isEmpty) {
      o.eventTimer = null;
      if (o.roles.isEmpty) unawaited(revoke());
      return;
    }
    final (event, reason) = o.events.removeAt(0);
    stream.capabilityEvent(o.lease, ++o.seq, event, reason: reason);
    o.eventTimer = Timer(const Duration(milliseconds: 100), () => _flush(o));
  }

  Future<void> _revokeOwner(_Owner owner) => identical(_owner, owner) ? revoke() : Future.value();

  /// Stops the owner here first (native close), then tells the plugin how
  /// each of its roles ended — at most three terminals, 100 ms apart.
  Future<void> revoke({String? terminal}) {
    if (_closing != null) return _closing!;
    final o = _owner;
    _owner = null;
    if (o == null) return Future.value();
    o.eventTimer?.cancel();
    unawaited(o.captions?.cancel());
    final terminals = <String>{
      ?terminal,
      for (final event in o.events)
        if (_terminals.contains(event.$1)) event.$1,
      for (final role in o.claimed.where((r) => !o.ended.contains(r)))
        role == 'overlay' ? 'overlay.closed' : '$role.stopped',
    }.take(3).toList();
    o.events.clear();
    final closing = () async {
      try {
        await platform.call('disposeOwner', o.args);
      } catch (_) {
        // A failed close is no proof of silence: keep the file, switch the
        // capabilities off, and claim nothing stopped.
        _nativeFailed = true;
        onNativeFailure?.call();
        stream.release();
        return;
      }
      for (final event in terminals) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (stream.conn != o.conn) break;
        stream.capabilityEvent(o.lease, ++o.seq, event);
      }
      stream.release();
      if (o.file != null) await _delete(o.file!);
    }();
    _closing = closing;
    return closing.whenComplete(() {
      if (identical(_closing, closing)) _closing = null;
    });
  }

  static Future<void> _delete(File file) async {
    try {
      if (await file.parent.exists()) await file.parent.delete(recursive: true);
    } catch (_) {}
  }

  Future<void> dispose() async {
    _disposed = true;
    await revoke();
    await _links.cancel();
    await _events.cancel();
  }
}

/// The native side failed to close an owner: capabilities stay off for
/// this run.
class NativePlatformFault extends Notifier<bool> {
  @override
  bool build() => false;

  void fail() {
    if (ref.mounted) state = true;
  }
}

final nativePlatformFaultProvider = NotifierProvider<NativePlatformFault, bool>(NativePlatformFault.new);

/// What the platform supports (asked once, and only when needed).
final nativePlatformFeaturesProvider = FutureProvider<Set<String>>((ref) {
  if (ref.watch(nativePlatformFaultProvider)) return Future.value(const {});
  return ref.watch(nativeMediaPlatformProvider).capabilities();
});

/// Sets the features the app offers: nothing until a plugin on the active
/// host declares a capability; then `micro` (drawn in Flutter) and what the
/// platform reports.
final nativeCapabilityDiscoveryProvider = FutureProvider.autoDispose<void>((ref) async {
  final declarations = ref
      .watch(nativeContributionsProvider)
      .plugins
      .where((p) => p.native)
      .expand((p) => p.capabilities)
      .toSet();
  final media = declarations.any({'audio', 'voice', 'micro', 'overlay'}.contains);
  final bridge = ref.watch(nativeBridgeProvider);
  // Establish both dependencies before awaiting: a host switch can dispose this
  // discovery while either platform probe is still pending.
  final mediaProbe = media ? ref.watch(nativePlatformFeaturesProvider.future) : Future.value(<String>{});
  final fileProbe = declarations.contains('files') && bridge is ClientNativeBridge && bridge.client.canReachDshGo
      ? ref.watch(nativeFileSupportedProvider.future)
      : Future.value(false);
  final (mediaFeatures, fileSupported) = await (mediaProbe, fileProbe).wait;
  if (!ref.mounted) return;
  final features = {if (media) 'micro', ...mediaFeatures, if (fileSupported) 'files'};
  ref.read(nativeFeatureStateProvider.notifier).setFeatures(features);
});

/// The runtime for the active host's stream; rebuilt (and so stopped) when
/// the host, the stream or the conversation changes.
final nativeCapabilityRuntimeProvider = Provider.autoDispose<NativeCapabilityRuntime?>((ref) {
  final bridge = ref.watch(nativeBridgeProvider);
  final stream = ref.watch(nativeStreamProvider);
  final host = ref.watch(activeHostProvider);
  ref.watch(currentSessionProvider);
  if (bridge is! ClientNativeBridge || stream == null) return null;
  final fault = ref.read(nativePlatformFaultProvider.notifier);
  bool onScreen(AppLifecycleState? state) =>
      state == null || state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
  final runtime = NativeCapabilityRuntime(
    platform: ref.watch(nativeMediaPlatformProvider),
    stream: stream,
    download: (pkg, effect, owner) => downloadNativeMedia(bridge.client, pkg, effect, owner),
    plugin: (pkg) => ref.read(nativeContributionsProvider).plugin(pkg),
    pluginTitle: (pkg) => ref.read(nativePluginTitleProvider(pkg)),
    overlayTop: () => ref.read(nativeOverlayTopProvider),
    onNativeFailure: fault.fail,
    hostIdentity: uiHostKey(host),
    hostTitle: hostLabel(host.kind, host.name),
    session: () => ref.read(currentSessionProvider),
    foreground: onScreen(WidgetsBinding.instance.lifecycleState),
  );
  // Inactive (a system dialog such as the microphone permission, the
  // notification shade) keeps it; hidden / paused stops it.
  final lifecycle = AppLifecycleListener(onStateChange: (s) => runtime.foreground(onScreen(s)));
  ref.listen(nativeContributionsProvider, (previous, next) => runtime.revalidate());
  // The plugin's 「听你开口」 switch turned off while it listens: stop listening.
  ref.listen(nativeVoiceConsentProvider, (previous, next) {
    final o = runtime._owner;
    if (o != null && o.roles.contains('voice') && next[NativeVoiceConsents.keyOf(host, o.pkg)] != true) {
      unawaited(runtime._stopRole(o, 'voice', 'declined'));
    }
  });
  ref.onDispose(() {
    lifecycle.dispose();
    unawaited(runtime.dispose());
  });
  return runtime;
});

/// Where the native listening indicator and caption start: just under the
/// chat header (logical px). The chat's capability scope keeps it current.
class NativeOverlayTop extends Notifier<double?> {
  @override
  double? build() => null;

  void set(double value) {
    if (state != value) state = value;
  }
}

final nativeOverlayTopProvider = NotifierProvider<NativeOverlayTop, double?>(NativeOverlayTop.new);

// ── Listening consent ────────────────────────────────────────────────────────

/// Whether a plugin may listen for the person speaking, per host and plugin:
/// true allowed, false declined, missing never asked. Turned back on or off
/// with the plugin's 「听你开口」 switch.
class NativeVoiceConsents extends Notifier<Map<String, bool>> {
  static const prefsKey = 'native_plugins.voice';

  @override
  Map<String, bool> build() {
    unawaited(_load());
    return const {};
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(prefsKey) ?? const [];
      final loaded = <String, bool>{
        for (final entry in list)
          if (entry.length > 2 && (entry.startsWith('1:') || entry.startsWith('0:')))
            entry.substring(2): entry[0] == '1',
      };
      if (ref.mounted) state = {...loaded, ...state};
    } catch (_) {}
  }

  static String keyOf(HostRef host, String package) => '${uiHostKey(host)}|$package';

  bool? of(HostRef host, String package) => state[keyOf(host, package)];

  Future<void> set(HostRef host, String package, bool allowed) async {
    state = {...state, keyOf(host, package): allowed};
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(prefsKey, [
        for (final MapEntry(:key, :value) in state.entries) '${value ? 1 : 0}:$key',
      ]);
    } catch (_) {}
  }
}

final nativeVoiceConsentProvider = NotifierProvider<NativeVoiceConsents, Map<String, bool>>(NativeVoiceConsents.new);
