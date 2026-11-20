import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../common/app_sheet.dart';
import '../theme/theme.dart';
import 'qr_code.dart';

class ShareQrPage extends StatelessWidget {
  const ShareQrPage({super.key, required this.link, required this.title});
  final String link;
  final String title;
  static const size = 248.0;
  static const padding = 16.0;
  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(context.l10n.viewQrCode),
        const SizedBox(height: 8),
        Center(
          child: DecoratedBox(
            key: const ValueKey('share-qr-card'),
            decoration: ShapeDecoration(color: Colors.white, shape: Squircle.border(AppShape.lg)),
            child: Padding(
              padding: const EdgeInsets.all(padding),
              child: QrCodeView(
                data: link,
                size: size,
                ecc: link.length > 600 ? QrEcc.low : QrEcc.medium,
                quietZone: 2,
                semanticLabel: context.l10n.viewQrCode,
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: kSheetGutter),
          child: Text(
            title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        const SizedBox(height: 28),
      ],
    ),
  );
}
