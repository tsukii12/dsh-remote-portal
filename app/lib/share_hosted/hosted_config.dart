// Where hosted conversation links live (docs/design/share-links.md). Same level
// as `shareLandingUrl` in share_code/share_link.dart: change the host here, in
// services/share-worker/wrangler.jsonc, and redeploy.

/// The share host (services/share-worker). A link is
/// `$shareHostOrigin/c/<id>#k=<key>`; the key never reaches the server.
const shareHostOrigin = 'https://go.dshtui.com';
