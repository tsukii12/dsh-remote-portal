// A hosted conversation link as the app keeps it.

import '../l10n/l10n.dart';
import '../links/app_links.dart' show appLinkScheme;
import 'hosted_config.dart';
import 'hosted_crypto.dart';

/// How long a link lives. [wire] is the API's `ttl`.
enum HostedTtl {
  week('7d'),
  month('30d'),
  forever('forever');

  const HostedTtl(this.wire);

  final String wire;

  /// For a picker: 「7 天」「30 天」「永久」.
  String get label => switch (this) {
    HostedTtl.week => appL10n.remoteHostedTtlWeek,
    HostedTtl.month => appL10n.remoteHostedTtlMonth,
    HostedTtl.forever => appL10n.remoteHostedTtlForever,
  };

  static const fallback = HostedTtl.month;

  static HostedTtl parse(String? wire) => values.firstWhere((t) => t.wire == wire, orElse: () => fallback);
}

/// Ids the share host hands out: 10 base62 characters.
final hostedIdPattern = RegExp(r'^[0-9A-Za-z]{10}$');

/// One link: enough to open it again, show it in 「我的分享链接」 and delete it.
/// [key] and [deleteToken] are secrets; the list lives in secure storage.
class HostedLink {
  const HostedLink({
    required this.id,
    required this.key,
    required this.deleteToken,
    required this.title,
    required this.createdAt,
    required this.ttl,
    this.expiresAt,
    this.origin = shareHostOrigin,
    this.deleting = false,
  });

  final String id;

  /// base64url AES key, only ever in the fragment.
  final String key;
  final String deleteToken;
  final String title;
  final DateTime createdAt;
  final HostedTtl ttl;

  /// Null for 永久.
  final DateTime? expiresAt;

  /// The host it was made on, so a later change of [shareHostOrigin] keeps old
  /// links working.
  final String origin;

  /// Confirmed for deletion, waiting out the undo window (or the next start).
  final bool deleting;

  /// `https://<host>/c/<id>#k=<key>`.
  String get url => '$origin/c/$id#k=$key';

  bool isExpired(DateTime now) => expiresAt != null && !now.isBefore(expiresAt!);

  HostedLink copyWith({bool? deleting, String? title}) => HostedLink(
    id: id,
    key: key,
    deleteToken: deleteToken,
    title: title ?? this.title,
    createdAt: createdAt,
    ttl: ttl,
    expiresAt: expiresAt,
    origin: origin,
    deleting: deleting ?? this.deleting,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'k': key,
    'dt': deleteToken,
    'title': title,
    'created': createdAt.toUtc().toIso8601String(),
    'ttl': ttl.wire,
    'expires': expiresAt?.toUtc().toIso8601String(),
    'origin': origin,
    if (deleting) 'deleting': true,
  };

  /// Null for anything malformed (the entry is dropped, not the whole list).
  static HostedLink? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final key = json['k'];
    final token = json['dt'];
    final created = DateTime.tryParse('${json['created']}');
    if (id is! String || !hostedIdPattern.hasMatch(id)) return null;
    if (key is! String || decodeHostedKey(key) == null) return null;
    if (token is! String || token.isEmpty || created == null) return null;
    final expires = json['expires'];
    final origin = json['origin'];
    return HostedLink(
      id: id,
      key: key,
      deleteToken: token,
      title: json['title'] is String ? json['title'] as String : appL10n.remoteChat,
      createdAt: created,
      ttl: HostedTtl.parse(json['ttl'] as String?),
      expiresAt: expires is String ? DateTime.tryParse(expires) : null,
      origin: origin is String && origin.startsWith('https://') ? origin : shareHostOrigin,
      deleting: json['deleting'] == true,
    );
  }
}

/// Share hosts whose links the app opens itself (a link names where its
/// ciphertext is, so only our own hosts are fetched from).
const hostedOrigins = [shareHostOrigin];

/// The id and key in a hosted link: `https://<host>/c/<id>#k=<key>`, or the
/// same as an app link, `dshgo://<host>/c/<id>#k=<key>` (what the web viewer's
/// 「用 dsh-go 打开」 hands over). Null for anything else; [origin] limits it to
/// one host.
({String origin, String id, String key})? parseHostedUrl(String text, {String? origin}) {
  final uri = Uri.tryParse(text.trim());
  if (uri == null || (uri.scheme != 'https' && uri.scheme != appLinkScheme) || uri.host.isEmpty) return null;
  if (uri.hasPort || uri.userInfo.isNotEmpty) return null;
  final base = 'https://${uri.host.toLowerCase()}';
  if (origin != null && base != origin) return null;
  final match = RegExp(r'^/c/([0-9A-Za-z]{10})/?$').firstMatch(uri.path);
  if (match == null) return null;
  final key = Uri.splitQueryString(uri.fragment)['k'];
  if (key == null || decodeHostedKey(key) == null) return null;
  return (origin: base, id: match.group(1)!, key: key);
}

/// Whether [uri] is a hosted link on one of [hostedOrigins].
bool isHostedLink(Uri uri) {
  final ref = parseHostedUrl(uri.toString());
  return ref != null && hostedOrigins.contains(ref.origin);
}

/// The first hosted link on one of [hostedOrigins] in [text] (a shared or
/// pasted message), as its https URL.
Uri? findHostedUrl(String text) {
  final hosts = hostedOrigins.map((o) => RegExp.escape(Uri.parse(o).host)).join('|');
  // The key is exactly 43 base64url characters, so punctuation right after a
  // link (「…#k=…。」) isn't taken for part of it.
  final pattern = RegExp(
    '(?:https|$appLinkScheme)://(?:$hosts)/c/[0-9A-Za-z]{10}/?#k=[A-Za-z0-9_-]{43}(?![A-Za-z0-9_-])',
    caseSensitive: false,
  );
  for (final match in pattern.allMatches(text)) {
    final ref = parseHostedUrl(match.group(0)!);
    if (ref != null && hostedOrigins.contains(ref.origin)) return Uri.parse('${ref.origin}/c/${ref.id}#k=${ref.key}');
  }
  return null;
}
