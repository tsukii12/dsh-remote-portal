import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../phone/phone_channel.dart';
import '../common/app_dialog.dart';

const phoneBackgroundGuideSeenKey = 'phone_background_guide_seen_v1';

/// Advice for the phone-control feature; opens only the standard App info
/// entry when chosen. Vendor menu names vary, so no private Intent is assumed.
Future<bool> showPhoneBackgroundGuide(BuildContext context, PhoneDevice device) async {
  final manufacturer = device.manufacturer?.toLowerCase() ?? '';
  final vendorHint = ['vivo', 'iqoo', 'xiaomi', 'redmi'].any(manufacturer.contains);
  final open = await showAppDialog<bool>(
    context: context,
    builder: (dialog) {
      final l10n = dialog.l10n;
      return AlertDialog(
        key: const Key('phone-background-guide'),
        scrollable: true,
        title: Text(l10n.phoneBackgroundGuideTitle),
        content: Text(
          [
            l10n.phoneBackgroundGuideBody,
            if (vendorHint) l10n.phoneBackgroundOemHint,
            l10n.phoneBackgroundReturnHint,
          ].join('\n\n'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.phoneBackgroundGotIt)),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(l10n.phoneBackgroundOpenSettings)),
        ],
      );
    },
  );
  return open == true;
}
