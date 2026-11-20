import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/l10n.dart';
import 'app_dialog.dart';

Future<void> openConfirmedLink(BuildContext context, Uri url, {bool Function()? stillCurrent}) async {
  if (url.scheme != 'https') return;
  final l10n = context.l10n;
  final ok = await showAppDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(l10n.commonOpenBrowserHost(url.host)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
        FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(l10n.commonOpen)),
      ],
    ),
  );
  if (ok == true && stillCurrent?.call() != false) {
    await launchUrl(url, mode: LaunchMode.externalApplication).catchError((_) => false);
  }
}
