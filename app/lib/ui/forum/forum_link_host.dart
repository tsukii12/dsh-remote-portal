// The forum's app links, registered for as long as the home shell is up (so a
// sign-in that returns after Android killed the app still lands):
//
//   dshgo://forum/auth?payload=…   Discourse's User API Key redirect
//   dshgo://forum/t/<id>[/<n>]     a topic (and post) in the app
//   dshgo://forum                  the forum's home

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../forum/forum_auth.dart';
import '../../forum/forum_config.dart';
import '../../links/app_links.dart';
import 'forum_home_page.dart';
import 'forum_topic_page.dart';
import '../common/brief_notice.dart';

/// Draws nothing. Put it once in the home shell's stack, next to `LinkHost`.
class ForumLinkHost extends ConsumerStatefulWidget {
  const ForumLinkHost({super.key});

  @override
  ConsumerState<ForumLinkHost> createState() => _ForumLinkHostState();
}

class _ForumLinkHostState extends ConsumerState<ForumLinkHost> {
  final _off = <VoidCallback>[];
  late final LinkRouter _router;

  @override
  void initState() {
    super.initState();
    _router = ref.read(linkRouterProvider);
    _off
      ..add(_router.registerLinkHandler(forumAuthRoute, _auth))
      ..add(_router.registerLinkHandler('forum', _open));
  }

  @override
  void dispose() {
    for (final off in _off) {
      off();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();

  Future<bool> _auth(Uri uri) async {
    final ok = await ref.read(forumAuthProvider.notifier).handleRedirect(uri);
    final context = _router.context;
    if (ok && context != null && context.mounted) {
      showBriefNotice(context, context.l10n.remoteForumSignedIn);
    }
    return ok;
  }

  Future<bool> _open(Uri uri) async {
    final context = _router.context;
    if (context == null || !context.mounted) return false;
    final route = forumRouteFor(uri);
    if (route == null) return false;
    unawaited(Navigator.of(context).push(route));
    return true;
  }
}

/// The page for a `dshgo://forum/…` link; null for paths it doesn't know.
Route<void>? forumRouteFor(Uri uri) {
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) return ForumHomePage.route();
  if (segments.first == 't') {
    // /t/<id>, /t/<id>/<post>, /t/<slug>/<id>[/<post>] (the web's shape).
    final numbers = [for (final s in segments.skip(1)) ?int.tryParse(s)];
    if (numbers.isEmpty) return null;
    return ForumTopicPage.route(topicId: numbers.first, postNumber: numbers.length > 1 ? numbers[1] : null);
  }
  return null;
}
