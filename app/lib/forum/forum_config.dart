// Where the dsh-go forum lives and how the app signs in to it (a self-hosted
// Discourse, server kit in infra/forum/, deploy steps in docs/forum/deploy.md).

/// The forum's address (docs/forum/deploy.md). An address set in 论坛设置
/// wins over it.
const forumDefaultBaseUrl = 'https://forum.dshtui.com';

/// Where Discourse sends the encrypted User API Key. Must be listed in the
/// site setting `allowed_user_api_auth_redirects` (infra/forum/settings) and
/// match exactly: Discourse compares path and query too.
const forumAuthRedirect = 'dshgo://forum/auth';

/// The [forumAuthRedirect] route as the link router keys it.
const forumAuthRoute = 'forum/auth';

/// Shown on the Discourse approval page and in the user's API key list.
const forumApplicationName = 'dsh-go';

/// What the key may do: browse, post / like / bookmark / upload,
/// notifications, `/session/current.json`. All four are in Discourse's
/// default `allow_user_api_key_scopes`.
const forumScopes = ['read', 'write', 'notifications', 'session_info'];

/// Turns a typed address into a base URL: https by default, no trailing
/// slash, no path. Null for anything that isn't a web address.
String? normalizeForumBaseUrl(String input) {
  var text = input.trim();
  if (text.isEmpty) return null;
  if (!text.contains('://')) text = 'https://$text';
  final uri = Uri.tryParse(text);
  if (uri == null || uri.host.isEmpty || !uri.host.contains('.') && uri.host != 'localhost') return null;
  if (uri.scheme != 'https' && uri.scheme != 'http') return null;
  final path = uri.path.endsWith('/') ? uri.path.substring(0, uri.path.length - 1) : uri.path;
  return Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null, path: path).toString();
}
