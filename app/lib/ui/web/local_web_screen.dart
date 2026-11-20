
import 'package:flutter/material.dart';
import '../../l10n/l10n.dart';
import '../shell/page_frame.dart';
import 'web_target.dart';
import 'web_view_page.dart' show DshWebLink;

Uri localWebUri(String baseUrl, String token) => Uri.parse(baseUrl);
class LocalWebScreen extends StatelessWidget {
  const LocalWebScreen({super.key, this.target, this.handle, this.link, this.onSession});

  /// Page to land on (a session, a panel, a settings section…).
  final DshWebTarget? target;

  /// 网页模式: the page is the app's home; [handle] takes the back button's
  /// seat (and a place in the engine page's bar while the engine is down).
  final Widget Function(double size)? handle;

  /// See [WebViewPage.link] and [WebViewPage.onSession].
  final DshWebLink? link;
  final ValueChanged<String?>? onSession;


  @override
  Widget build(BuildContext context) => AppPage.list(title: context.l10n.commonWeb, children: [
    Padding(padding: const EdgeInsets.all(20), child: Text(context.l10n.portalWebRemoved)),
  ]);
}
