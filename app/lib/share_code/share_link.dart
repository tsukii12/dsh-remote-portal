// Share links (docs/design/share-codes.md).
//
//   dshgo://share/<kind>?p=<code>                app link, code inline
//   dshgo://share/profile?gist=<id>&c=<sum>      a profile too large to inline
//   <shareLandingUrl>#p=<code>                    the same on the landing page
//   <shareLandingUrl>#gist=<id>&c=<sum>
//
// The landing page keeps everything in the fragment, so nothing reaches its
// server. `<code>` is `<data>.<sum>` (share_codec.dart).

import '../links/app_links.dart' show appLinkScheme;
import '../share_hosted/hosted_config.dart' show shareHostOrigin;
import 'share_models.dart';

/// The static landing page (site/share/), served by the share host next to
/// hosted conversation links (docs/design/share-links.md). App Links would
/// also need the manifest and an assetlinks.json on that domain.
const shareLandingUrl = '$shareHostOrigin/share/';

/// Where the landing page used to live. That site stays up, so links made
/// there keep opening in browsers, and the app still reads them.
const legacyShareLandingUrls = ['https://ccch1mneyyy.github.io/dsh-go/share/'];

/// The current landing page first, then the old ones.
const _landingUrls = [shareLandingUrl, ...legacyShareLandingUrls];

/// Host of the app links.
const shareLinkHost = 'share';

/// Longest web link carried inline (comfortable in a QR code); a larger
/// profile goes to a Gist or a `.dshgo` file.
const maxInlineLinkChars = 1800;

/// GitHub Gist ids are hex.
final _gistId = RegExp(r'^[0-9a-f]{20,40}$');
final _sum = RegExp(r'^[A-Za-z0-9_-]{8}$');

/// A parsed share link: the code itself, or where to fetch it.
class ShareLink {
  const ShareLink.inline(ShareKind this.kind, String this.code) : gistId = null, gistSum = null;

  const ShareLink.gist(String this.gistId, String this.gistSum) : kind = ShareKind.profile, code = null;

  /// A landing link: the kind is only known once the code is decoded.
  const ShareLink._landing(String this.code) : kind = null, gistId = null, gistSum = null;

  /// Null for a landing link (the kind is inside the code).
  final ShareKind? kind;
  final String? code;
  final String? gistId;

  /// Checksum of the code the Gist holds.
  final String? gistSum;

  bool get isGist => gistId != null;

  /// `dshgo://share/…`.
  Uri get appLink => isGist
      ? Uri(
          scheme: appLinkScheme,
          host: shareLinkHost,
          path: '/profile',
          queryParameters: {'gist': gistId, 'c': gistSum},
        )
      : Uri(
          scheme: appLinkScheme,
          host: shareLinkHost,
          path: '/${(kind ?? ShareKind.plugin).name}',
          queryParameters: {'p': code},
        );

  /// The landing page link (for chats, QR codes, browsers).
  String get webLink => isGist ? '$shareLandingUrl#gist=$gistId&c=$gistSum' : '$shareLandingUrl#p=$code';

  /// Reads an app link or a landing link; null for anything else.
  static ShareLink? parse(Uri uri) {
    try {
      if (uri.scheme == appLinkScheme) {
        if (uri.host != shareLinkHost) return null;
        return _fromParams(uri.queryParameters, ShareKind.parse(uri.pathSegments.firstOrNull));
      }
      if ((uri.scheme == 'https' || uri.scheme == 'http') && isLandingUri(uri)) {
        return _fromParams(Uri.splitQueryString(uri.fragment), null);
      }
    } on FormatException {
      // A structurally valid URI can still contain non-UTF8 component bytes.
      return null;
    }
    return null;
  }

  static ShareLink? _fromParams(Map<String, String> params, ShareKind? kind) {
    final code = params['p'];
    if (code != null && code.contains('.') && code.length <= 1024 * 1024) {
      return kind == null ? ShareLink._landing(code) : ShareLink.inline(kind, code);
    }
    final gist = params['gist'];
    final sum = params['c'];
    if (gist != null && sum != null && _gistId.hasMatch(gist) && _sum.hasMatch(sum)) return ShareLink.gist(gist, sum);
    return null;
  }

  /// The first share link in [text] (a pasted message, a shared text).
  static ShareLink? find(String text) {
    final landing = _landingUrls.map((u) => RegExp.escape(u.replaceFirst(RegExp(r'^https?://'), ''))).join('|');
    final pattern = RegExp('(?:$appLinkScheme://$shareLinkHost/[^\\s"\'<>]+|https?://(?:$landing)#[^\\s"\'<>]+)');
    for (final match in pattern.allMatches(text)) {
      final uri = Uri.tryParse(match.group(0)!);
      final link = uri == null ? null : parse(uri);
      if (link != null) return link;
    }
    return null;
  }
}

/// Host + path of the landing page, as LinkRouter keys https links.
String get shareLandingRoute {
  final uri = Uri.parse(shareLandingUrl);
  final path = uri.path.endsWith('/') ? uri.path.substring(0, uri.path.length - 1) : uri.path;
  return '${uri.host}$path';
}

/// Whether [uri] points at the landing page, current or old (with or without
/// the trailing slash, or `index.html`).
bool isLandingUri(Uri uri) {
  final path = uri.path.replaceFirst(RegExp(r'/(index\.html)?$'), '');
  for (final url in _landingUrls) {
    final base = Uri.parse(url);
    if (uri.host.toLowerCase() != base.host) continue;
    final want = base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path;
    if (path == want) return true;
  }
  return false;
}
