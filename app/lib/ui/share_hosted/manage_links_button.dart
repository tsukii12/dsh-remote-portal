// 「我的分享链接」 at the foot of the share panel's link page (re-exported by
// ui/replay/conversation_out.dart for the panel).

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../theme/theme.dart';
import 'hosted_links_page.dart';

/// A quiet text button: closes the sheet it sits in and opens
/// 「我的分享链接」.
class ManageLinksButton extends StatelessWidget {
  const ManageLinksButton({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return TextButton(
      style: TextButton.styleFrom(
        foregroundColor: DshColors.of(context).textTertiary,
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: 16),
      ),
      onPressed: () {
        final navigator = Navigator.of(context);
        navigator.pop();
        navigator.push(HostedLinksPage.route());
      },
      child: Text(l10n.remoteHostedMyLinks),
    );
  }
}
