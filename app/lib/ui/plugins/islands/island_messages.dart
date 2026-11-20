import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';

/// Why an island gave up (`empty` / `error` messages, or the app's own
/// timers): every one of them falls back to "open in DSH Web".
enum IslandFailure {
  /// The official client didn't come up.
  boot,

  /// No outlet for the slot (a DSH upgrade renamed it, the plugin is off).
  slotMissing,

  /// The outlet is there with nothing in it.
  empty,

  /// island.js threw.
  crash,

  /// No `ready` in time.
  timeout,

  /// The page didn't load.
  load,

  /// The WebView's renderer died (every island goes with it).
  renderer,

  /// The budget closed it (memory, background, an island that ranks higher).
  evicted;

  static IslandFailure parse(Object? code) => switch (code) {
    'boot' => boot,
    'slot-missing' => slotMissing,
    'empty' => empty,
    'crash' => crash,
    _ => crash,
  };
}

/// One message from island.js on the `DshGoIsland` channel (§6.3). The
/// channel is reachable from every frame on the page, so everything here is
/// untrusted input: [parseIslandMessage] checks types, sizes and ranges and
/// drops anything else.
@immutable
sealed class IslandMessage {
  const IslandMessage();
}

/// The slot is on screen: show the island.
final class IslandReady extends IslandMessage {
  const IslandReady({required this.slot, this.cell, this.release, this.found = 0, this.probe = false});
  final String slot;
  final String? cell;

  /// DSH Web's release (`__DSH_BOOT__.release.version`).
  final String? release;

  /// Entries in the slot's outlet.
  final int found;

  /// A probe island finished (the bridge reported its occupancy).
  final bool probe;
}

/// The island can't show its slot: close it and fall back.
final class IslandGaveUp extends IslandMessage {
  const IslandGaveUp({required this.slot, required this.failure, this.detail = ''});
  final String slot;
  final IslandFailure failure;
  final String detail;
}

/// A panel island's content height, CSS px (= logical px).
final class IslandSize extends IslandMessage {
  const IslandSize(this.height);
  final double height;
}

/// An overlay island's touch regions, CSS px; touches elsewhere go through.
final class IslandHit extends IslandMessage {
  const IslandHit(this.rects);
  final List<Rect> rects;
}

/// A link the island's content wants to open outside: https only, and the
/// app asks first.
final class IslandLink extends IslandMessage {
  const IslandLink(this.url);
  final Uri url;
}

/// The plugin wants a conversation opened: the app checks it exists first.
final class IslandOpenSession extends IslandMessage {
  const IslandOpenSession(this.sessionId);
  final String sessionId;
}

/// Limits on what the page may send.
abstract final class IslandMessageLimits {
  static const maxBytes = 16 * 1024;
  static const maxRects = 16;
  static const maxExtent = 100000.0;
  static const maxUrl = 2048;
  static const maxText = 200;
  static final sessionId = RegExp(r'^[A-Za-z0-9._:-]{1,200}$');
}

/// Null for anything that isn't a well-formed message of ours.
IslandMessage? parseIslandMessage(String raw) {
  if (raw.length > IslandMessageLimits.maxBytes) return null;
  final Object? json;
  try {
    json = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (json is! Map) return null;
  String? text(Object? v) {
    if (v is! String) return null;
    final s = v.length > IslandMessageLimits.maxText ? v.substring(0, IslandMessageLimits.maxText) : v;
    return s;
  }

  final slot = text(json['slot']) ?? '';
  switch (json['t']) {
    case 'ready':
      final found = json['found'];
      return IslandReady(
        slot: slot,
        cell: text(json['cell']),
        release: text(json['release']),
        found: found is int && found >= 0 ? found : 0,
        probe: json['probe'] == true,
      );
    case 'empty':
    case 'error':
      final code = json['code'];
      return IslandGaveUp(
        slot: slot,
        failure: json['t'] == 'empty' && code == 'empty' ? IslandFailure.empty : IslandFailure.parse(code),
        detail: text(json['detail']) ?? '',
      );
    case 'size':
      final h = json['h'];
      if (h is! num || !h.isFinite || h < 0) return null;
      return IslandSize(h.toDouble().clamp(0, IslandMessageLimits.maxExtent));
    case 'hit':
      final rects = json['rects'];
      if (rects is! List || rects.length > IslandMessageLimits.maxRects) return null;
      final out = <Rect>[];
      for (final r in rects) {
        if (r is! List || r.length != 4 || r.any((v) => v is! num || !v.isFinite)) return null;
        double c(Object v) =>
            (v as num).toDouble().clamp(-IslandMessageLimits.maxExtent, IslandMessageLimits.maxExtent);
        final w = c(r[2]);
        final h = c(r[3]);
        if (w <= 0 || h <= 0) continue;
        out.add(Rect.fromLTWH(c(r[0]), c(r[1]), w, h));
      }
      return IslandHit(List.unmodifiable(out));
    case 'link':
      final url = json['url'];
      if (url is! String || url.length > IslandMessageLimits.maxUrl) return null;
      final uri = Uri.tryParse(url);
      if (uri == null || uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) return null;
      return IslandLink(uri);
    case 'session':
      final id = json['id'];
      if (id is! String || !IslandMessageLimits.sessionId.hasMatch(id)) return null;
      return IslandOpenSession(id);
  }
  return null;
}
