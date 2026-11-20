/// What an island does with a navigation request (§6.3, §9).
enum IslandNavigation {
  /// Same origin as the island's host (the session hop's reload, a
  /// plugin's own same-origin page), or inside a sub-frame: let it load.
  stay,

  /// An https page elsewhere: never inside the island. The app may offer it
  /// in the browser after asking, like a `link` message.
  external,

  /// Anything else (other schemes, plain http elsewhere, junk).
  block,
}

/// The island's own copy of `dshWebNavigation`'s rule (that file belongs to
/// the WebUI package), stricter in that only https may leave the island and
/// nothing leaves without the app asking. Sub-frames load what they load:
/// Android doesn't route an iframe's own loads through here, so checking
/// them would only break plugins, not fence them; the channel is
/// presentation-only for that reason.
IslandNavigation islandNavigation(Uri base, String url, {bool isMainFrame = true}) {
  if (!isMainFrame) return IslandNavigation.stay;
  final target = Uri.tryParse(url);
  if (target == null) return IslandNavigation.block;
  final web = target.scheme == 'http' || target.scheme == 'https';
  if (!web || target.host.isEmpty) return IslandNavigation.block;
  if (target.scheme == base.scheme && target.host == base.host && target.port == base.port) {
    return IslandNavigation.stay;
  }
  return target.scheme == 'https' && target.userInfo.isEmpty ? IslandNavigation.external : IslandNavigation.block;
}
