
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../l10n/l10n.dart';
import '../shell/page_frame.dart';
import 'web_target.dart';
export '../../state/web_target.dart';

class DshWebLink {}


class WebViewPage extends StatelessWidget {
  const WebViewPage({
    super.key,
    required this.url,
    required this.title,
    this.subtitle,
    this.allowOpenExternal = false,
    this.externalDisabledReason,
    this.reloadAfterBackground,
    this.lightBackground = const Color(0xFFFFFFFF),
    this.darkBackground = const Color(0xFF151517),
    this.dshWeb = false,
    this.phoneLayout = true,
    this.openTarget,
    this.leading,
    this.root = false,
    this.link,
    this.onSession,
  });

  final Uri url;
  final String title;
  final String? subtitle;

  /// Show an enabled "在浏览器打开" button. When false the button is still shown,
  /// disabled, with [externalDisabledReason] as its tooltip.
  final bool allowOpenExternal;
  final String? externalDisabledReason;

  /// Reload when returning from the background after this long (remote pages
  /// lose their socket when Android suspends the WebView).
  final Duration? reloadAfterBackground;

  /// The embedded site's page colour: painted before the first frame and used
  /// for the fade behind the controls, so nothing flashes or shows a seam.
  final Color lightBackground;
  final Color darkBackground;

  /// The page is DSH Web: fit it to a touch screen (`assets/web/`). Below
  /// [dshWebDesktopWidth] the sidebar becomes a drawer behind a menu button
  /// in the page's header row; from there up the official layout stays, with
  /// the way back above its sidebar.
  final bool dshWeb;

  /// With [dshWeb]: adapt the layout. Off leaves DSH Web's own layout alone:
  /// at phone widths its drawer keeps a leading seat in the header row for
  /// its sidebar opener, and the handle takes the far left of that row while
  /// the seat moves past it ([WebChrome.seat]); wider windows show the app's
  /// bar ([WebChrome.bar]).
  final bool phoneLayout;

  /// With [dshWeb]: the page to land on after the first load
  /// (`assets/web/dsh_web_open.js`); null opens the home page.
  final DshWebTarget? openTarget;

  /// Takes the back button's seat (网页模式: the native handle), at the
  /// size of the button it replaces. A page without one seats the app's mark
  /// as its way back instead (the marker in DSH Web's leading seat).
  final Widget Function(double size)? leading;

  /// The page is the app's home (网页模式): back leaves the app once the page
  /// has nowhere to go back to, as on the native home ([WebBackDispatcher]).
  final bool root;

  /// Lets the caller act on the live page (open a target, fill the composer).
  final DshWebLink? link;

  /// With [dshWeb]: the conversation on screen, whenever it changes (from
  /// the client's stored selection; null for none).
  final ValueChanged<String?>? onSession;


  @override
  Widget build(BuildContext context) => AppPage.list(title: title, children: [
    Padding(padding: const EdgeInsets.all(20), child: Text(context.l10n.portalWebRemoved)),
    if (allowOpenExternal) Padding(padding: const EdgeInsets.all(20),
      child: FilledButton(onPressed: () => launchUrl(url, mode: LaunchMode.externalApplication),
        child: Text(context.l10n.commonOpen))),
  ]);
}
