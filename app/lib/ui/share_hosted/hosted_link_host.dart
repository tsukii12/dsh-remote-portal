// Hosted conversation links opened in the app.
// `https://go.dshtui.com/c/<id>#k=<key>` — an App Link, shared text
// (lib/links/share_intake.dart → the link router) or the web viewer's
// `dshgo://go.dshtui.com/c/…` — is fetched, decrypted on the phone and opened
// in the replay page.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../links/app_links.dart';
import '../../share_code/conversation_share.dart' show DecodedConversation, decodeConversationFile;
import '../../share_code/share_models.dart' show ShareFormatException;
import '../../share_hosted/hosted_client.dart';
import '../../share_hosted/hosted_link.dart';
import '../../share_hosted/hosted_links_state.dart';
import '../replay/replay_page.dart' show openConversationReplay;

/// Short copy for a hosted link that can't be opened.
String hostedOpenError(Object error) => switch (error) {
  HostedShareException(:final message) => message,
  ShareFormatException(reason: 'newer format') => appL10n.remoteHostedUpdateRequired,
  _ => appL10n.remoteHostedCannotOpen,
};

/// Fetches [uri]'s conversation and opens its replay. Errors become a toast.
/// False when [uri] isn't a hosted link on one of our hosts.
Future<bool> openHostedLink(BuildContext context, Uri uri) async {
  final l10n = context.l10n;
  if (!isHostedLink(uri)) return false;
  final container = ProviderScope.containerOf(context, listen: false);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final ref = parseHostedUrl(uri.toString())!;
  // Quiet unless it takes a moment.
  var hinted = false;
  final hint = Timer(const Duration(milliseconds: 600), () {
    if (!context.mounted) return;
    hinted = true;
    messenger?.showSnackBar(SnackBar(content: Text(l10n.remoteOpening), duration: const Duration(seconds: 20)));
  });
  try {
    final bytes = await container.read(hostedShareClientProvider).download('${ref.origin}/c/${ref.id}#k=${ref.key}');
    final conversation = await compute(_decodeConversation, (bytes, l10n.pluginsChat));
    hint.cancel();
    if (hinted && messenger?.mounted == true) messenger!.hideCurrentSnackBar();
    if (!context.mounted) return true;
    await openConversationReplay(context, conversation);
  } catch (e) {
    hint.cancel();
    if (hinted && messenger?.mounted == true) messenger!.hideCurrentSnackBar();
    if (context.mounted) {
      messenger?.showSnackBar(SnackBar(content: Text(hostedOpenError(e))));
    }
  }
  return true;
}

DecodedConversation _decodeConversation((Uint8List, String) input) =>
    decodeConversationFile(utf8.decode(input.$1), fallbackTitle: input.$2);

/// Registers `<share host>/c` with [router] — https and `dshgo://` links
/// alike — so hosted links open in the replay page. [LinkHost] calls it.
/// Returns the unregister function.
VoidCallback registerHostedLinks(LinkRouter router) {
  Future<bool> open(Uri uri) async {
    final ui = router.context;
    if (ui == null) return false;
    return openHostedLink(ui, uri);
  }

  final off = [for (final origin in hostedOrigins) router.registerLinkHandler('${Uri.parse(origin).host}/c', open)];
  return () {
    for (final f in off) {
      f();
    }
  };
}
