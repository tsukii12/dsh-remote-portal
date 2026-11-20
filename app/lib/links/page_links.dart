import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ui/settings/index/settings_pages.dart';
import 'app_links.dart';

const pageLinkHost = 'open';
Set<String> get pageLinkIds => SettingsIndex.linkIds;

String? pageLinkId(Uri uri) {
  if (uri.scheme.toLowerCase() != appLinkScheme || uri.host.toLowerCase() != pageLinkHost) return null;
  if (uri.userInfo.isNotEmpty || uri.hasPort || uri.hasQuery || uri.hasFragment) return null;
  final segments = uri.pathSegments.where((part) => part.isNotEmpty).toList();
  if (segments.length != 1 || !pageLinkIds.contains(segments.single)) return null;
  return segments.single;
}

Widget? pageForId(String id, String? sessionId) => settingsPageForLink(id, sessionId: sessionId);
typedef PageResolver = Widget? Function(String id, String? sessionId);
final pageLinkResolverProvider = Provider<PageResolver>((ref) => pageForId);

VoidCallback registerPageLinks(LinkRouter router, {String? Function()? session, PageResolver page = pageForId}) =>
    router.registerLinkHandler(pageLinkHost, (uri) async {
      final id = pageLinkId(uri);
      final context = router.context;
      if (id == null || context == null || !context.mounted) return false;
      final widget = page(id, session?.call());
      if (widget == null) return false;
      unawaited(Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => widget)));
      return true;
    });

bool openReplyPageLink(BuildContext context, String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.scheme.toLowerCase() != appLinkScheme || uri.host.toLowerCase() != pageLinkHost) return false;
  try {
    unawaited(ProviderScope.containerOf(context, listen: false).read(linkRouterProvider).open(uri));
  } catch (_) {}
  return true;
}
