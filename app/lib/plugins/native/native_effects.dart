// What a plugin may ask the app to do after a tap
// (docs/design/native-plugins.md §3.5). A closed list: anything else is dropped
// with an issue. Pure parsing and timing; `native_taps.dart` runs them.

import 'package:flutter/foundation.dart' show immutable;

import '../../l10n/l10n.dart';
import '../../ui_config/ui_config_schema.dart' show UiSchema;
import 'native_model.dart';

/// One whitelisted effect.
@immutable
sealed class NativeEffect {
  const NativeEffect();

  /// A side effect the person sees (everything but data updates): only runs
  /// within [NativeLimits.tapWindow] of the tap.
  bool get needsTap => true;
}

/// Into the composer, at the caret. Never sent.
final class InsertEffect extends NativeEffect {
  const InsertEffect(this.text);
  final String text;
}

/// `/name args` in the current conversation.
final class CommandEffect extends NativeEffect {
  const CommandEffect(this.name, {this.args});
  final String name;
  final String? args;

  String get line => args == null || args!.isEmpty ? '/$name' : '/$name $args';
}

/// An app page (a 全部功能 id, `new-chat`, `settings`) or one of the
/// plugin's own panels ([panel]).
final class OpenEffect extends NativeEffect {
  const OpenEffect({this.page, this.panel}) : assert((page == null) != (panel == null));
  final String? page;
  final String? panel;
}

/// An https page in the browser, after a confirmation naming its host.
final class LinkEffect extends NativeEffect {
  const LinkEffect(this.url);
  final Uri url;
}

/// One short line.
final class ToastEffect extends NativeEffect {
  const ToastEffect(this.text);
  final String text;
}

/// To the clipboard.
final class CopyEffect extends NativeEffect {
  const CopyEffect(this.text);
  final String text;
}

/// A bridge-issued, single-use chooser request. Never accepted as a static effect.
final class PickFileEffect extends NativeEffect {
  const PickFileEffect({
    required this.request,
    required this.action,
    required this.images,
    required this.maxFiles,
    required this.maxBytes,
    required this.maxTotalBytes,
    this.visual = false,
    this.own = false,
  });
  final String request;
  final String action;
  final bool images;

  /// Photos and videos in the system picker (the app's own custom launch screen; plugins
  /// can't ask for it).
  final bool visual;

  /// The app's own pick for its look (the custom launch screen, the wallpaper): one file, held
  /// natively to 30 MB rather than a plugin's 8. Plugins can't ask for it.
  final bool own;
  final int maxFiles;
  final int maxBytes;
  final int maxTotalBytes;
}

/// Read a panel's view again: [panel], or the one tapped in.
final class RefreshEffect extends NativeEffect {
  const RefreshEffect({this.panel});
  final String? panel;

  @override
  bool get needsTap => false;
}

/// Merge [data] (JSON Merge Patch) into a panel's data: [panel], or the one
/// tapped in.
final class PatchEffect extends NativeEffect {
  const PatchEffect(this.data, {this.panel});
  final Object? data;
  final String? panel;

  @override
  bool get needsTap => false;
}

/// The effect names of v1 (sent in `caps.effects`).
const nativeEffectNames = [
  'insert',
  'command',
  'open',
  'link',
  'toast',
  'copy',
  'refresh',
  'patch',
  'pickFile',
  'pickImage',
];

/// Reads [effects] (each `{"type": "insert", "text": …}` or the short
/// `{"insert": "…"}`), keeping whitelisted, well-formed ones. Problems are
/// added to [issues] under `/effects/<i>`.
List<NativeEffect> parseNativeEffects(List<Map<String, Object?>> effects, List<NativeIssue> issues) {
  final l10n = appL10n;
  final out = <NativeEffect>[];
  for (final (i, raw) in effects.indexed) {
    final pointer = '/effects/$i';
    final String type;
    final Map<String, Object?> body;
    if (raw['type'] case final String t) {
      type = t;
      body = raw;
    } else if (raw.length == 1) {
      type = raw.keys.single;
      final value = raw.values.single;
      body = switch (type) {
        'insert' || 'toast' || 'copy' => {'text': value},
        'link' => {'url': value},
        'open' => value is String ? {'page': value} : _map(value),
        'command' => value is String ? {'name': value} : _map(value),
        'patch' => {'data': value},
        'refresh' => value is String ? {'id': value} : const <String, Object?>{},
        _ => _map(value),
      };
    } else {
      issues.add(NativeIssue(pointer, l10n.plugslotsIssueMissing));
      continue;
    }
    String? text(String key) {
      final v = body[key];
      return v is String && v.trim().isNotEmpty ? v : null;
    }

    switch (type) {
      case 'pickFile' || 'pickImage':
        final request = text('request');
        final action = text('action');
        final count = body['maxFiles'];
        final bytes = body['maxBytes'];
        final total = body['maxTotalBytes'];
        if (request == null ||
            !RegExp(r'^[A-Za-z0-9_-]{32}$').hasMatch(request) ||
            action == null ||
            !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}$').hasMatch(action) ||
            count is! int ||
            count < 1 ||
            count > 4 ||
            bytes is! int ||
            bytes < 1 ||
            bytes > 8 * 1024 * 1024 ||
            total is! int ||
            total < 1 ||
            total > 16 * 1024 * 1024) {
          issues.add(NativeIssue(pointer, nativeIssueText('bad-effect'), code: 'bad-effect'));
        } else {
          out.add(
            PickFileEffect(
              request: request,
              action: action,
              images: type == 'pickImage',
              maxFiles: count,
              maxBytes: bytes,
              maxTotalBytes: total,
            ),
          );
        }
      case 'insert':
        final t = text('text');
        if (t == null) {
          issues.add(NativeIssue('$pointer/text', l10n.plugslotsIssueMissing));
        } else {
          out.add(InsertEffect(_cut(t, UiSchema.sendTextMax, '$pointer/text', issues)));
        }
      case 'command':
        final name = text('name')?.trim().replaceFirst(RegExp('^/'), '');
        if (name == 'permission') {
          // Check after the same whitespace/slash normalization used to execute.
          issues.add(NativeIssue('$pointer/name', nativeIssueText('bad-effect'), code: 'bad-effect'));
        } else if (name == null || !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$').hasMatch(name)) {
          issues.add(NativeIssue('$pointer/name', l10n.plugslotsIssueMissing));
        } else {
          final args = text('args');
          out.add(
            CommandEffect(
              name,
              args: args == null ? null : _cut(args, UiSchema.commandArgsMax, '$pointer/args', issues),
            ),
          );
        }
      case 'open':
        final page = text('page') ?? text('panel');
        if (page == null) {
          issues.add(NativeIssue('$pointer/page', l10n.plugslotsIssueMissing));
        } else if (body['panel'] is String) {
          out.add(OpenEffect(panel: page));
        } else if (page.startsWith('panel:') && page.length > 6) {
          out.add(OpenEffect(panel: page.substring(6)));
        } else if (UiSchema.pages.contains(page)) {
          out.add(OpenEffect(page: page));
        } else {
          issues.add(NativeIssue('$pointer/page', l10n.plugslotsIssueUnknownPage(page)));
        }
      case 'link':
        final url = Uri.tryParse(text('url')?.trim() ?? '');
        if (url == null ||
            url.scheme != 'https' ||
            url.host.isEmpty ||
            url.userInfo.isNotEmpty ||
            url.toString().length > 2048) {
          issues.add(NativeIssue('$pointer/url', l10n.plugslotsIssueHttps));
        } else {
          out.add(LinkEffect(url));
        }
      case 'toast':
        final t = text('text');
        if (t == null) {
          issues.add(NativeIssue('$pointer/text', l10n.plugslotsIssueMissing));
        } else {
          out.add(ToastEffect(_cut(_oneLine(t), NativeLimits.toastMax, '$pointer/text', issues)));
        }
      case 'copy':
        final t = body['text'];
        if (t is! String || t.isEmpty) {
          issues.add(NativeIssue('$pointer/text', l10n.plugslotsIssueMissing));
        } else {
          out.add(CopyEffect(_cut(t, 8000, '$pointer/text', issues)));
        }
      case 'refresh':
        out.add(RefreshEffect(panel: text('id')));
      case 'patch':
        if (body['data'] is! Map) {
          issues.add(NativeIssue('$pointer/data', l10n.plugslotsIssueMissing));
        } else {
          out.add(PatchEffect(body['data'], panel: text('id')));
        }
      default:
        issues.add(NativeIssue(pointer, l10n.plugslotsIssueUnknownEffect(type), code: 'unknown-effect'));
    }
  }
  return out;
}

Map<String, Object?> _map(Object? value) =>
    value is Map ? {for (final e in value.entries) '${e.key}': e.value} : const {};

String _oneLine(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

String _cut(String text, int max, String pointer, List<NativeIssue> issues) {
  final runes = text.runes.toList();
  if (runes.length <= max) return text;
  issues.add(NativeIssue(pointer, appL10n.plugslotsIssueTrimmed(max)));
  return String.fromCharCodes(runes.take(max));
}

/// A host-clock rollback cannot extend a gesture's lifetime.
bool nativeTapIsFresh(DateTime tappedAt, DateTime now) {
  final age = now.difference(tappedAt);
  return !age.isNegative && age <= NativeLimits.tapWindow;
}

/// Effects of a tap made at [tappedAt] that may still run at [now]: all of
/// them within [NativeLimits.tapWindow], only data updates after it (the
/// rest are dropped with one issue).
List<NativeEffect> effectsInWindow(
  List<NativeEffect> effects, {
  required DateTime tappedAt,
  required DateTime now,
  bool userGesture = true,
  List<NativeIssue>? issues,
}) {
  if (userGesture && nativeTapIsFresh(tappedAt, now)) return effects;
  final kept = [
    for (final e in effects)
      if (!e.needsTap) e,
  ];
  if (kept.length < effects.length) {
    issues?.add(
      NativeIssue(
        '/effects',
        now.difference(tappedAt) > NativeLimits.tapWindow
            ? appL10n.plugslotsIssueLate
            : appL10n.plugInputGestureRequired,
      ),
    );
  }
  return kept;
}

/// Toasts per plugin: one every [gap]; the ones in between are skipped.
class ToastThrottle {
  ToastThrottle({this.gap = const Duration(seconds: 2)});

  final Duration gap;
  final _last = <String, DateTime>{};

  bool allow(String package, DateTime now) {
    final last = _last[package];
    if (last != null && now.difference(last) < gap) return false;
    _last[package] = now;
    return true;
  }
}
