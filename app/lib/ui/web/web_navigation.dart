/// Navigation policy for the embedded DSH site.
enum DshWebNavigation { stay, external, block }

DshWebNavigation dshWebNavigation(Uri base, String url, bool isMainFrame) {
  if (!isMainFrame) return DshWebNavigation.stay;
  final target = Uri.tryParse(url);
  if (target == null) return DshWebNavigation.block;
  final web = target.scheme == 'http' || target.scheme == 'https';
  if (web && target.host.isNotEmpty) {
    if (target.scheme == base.scheme && target.host == base.host && target.port == base.port) {
      return DshWebNavigation.stay;
    }
    return DshWebNavigation.external;
  }
  return target.scheme == 'mailto' ? DshWebNavigation.external : DshWebNavigation.block;
}
