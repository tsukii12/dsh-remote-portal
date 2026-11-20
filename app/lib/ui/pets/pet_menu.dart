// The pet's long-press menu (换宠物 · 藏起来 1 小时 · 宠物设置), in the same sheet as the
// message menu.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../pets/pet_pack.dart';
import '../../pets/pet_prefs.dart';
import '../../pets/pet_signals.dart';
import '../chat/widgets/message_menu.dart' show MenuItem, MenuSheet;
import '../common/app_sheet.dart';
import '../common/sheet_title_bar.dart';
import '../theme/app_icons.dart';
import 'pet_picker.dart';
import 'pet_settings_page.dart';

/// What the menu offers, in its order.
enum PetMenuAction {
  swap,
  hide,
  settings;

  String get label => switch (this) {
    swap => appL10n.botsPetChange,
    hide => appL10n.botsPetHideHour,
    settings => appL10n.botsPetSettings,
  };

  IconData get icon => switch (this) {
    swap => AppIcons.swap,
    hide => AppIcons.hideSecret,
    settings => AppIcons.settings,
  };
}

/// How long 「藏起来」 lasts.
const petHideFor = Duration(hours: 1);

Future<void> showPetMenu(BuildContext context, {required PetPack pack}) async {
  final container = ProviderScope.containerOf(context);
  final action = await showAppSheet<PetMenuAction>(
    context,
    isScrollControlled: true,
    builder: (sheet) => MenuSheet(
      preview: _MenuPreview(pack: pack),
      groups: [
        [
          for (final a in [PetMenuAction.swap, PetMenuAction.hide])
            MenuItem(icon: a.icon, label: a.label, onTap: () => Navigator.pop(sheet, a)),
        ],
        [
          MenuItem(
            icon: PetMenuAction.settings.icon,
            label: PetMenuAction.settings.label,
            onTap: () => Navigator.pop(sheet, PetMenuAction.settings),
          ),
        ],
      ],
    ),
  );
  if (action == null || !context.mounted) return;
  switch (action) {
    case PetMenuAction.swap:
      await showAppSheet<void>(
        context,
        isScrollControlled: true,
        builder: (sheet) => SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetTitleBar(context.l10n.botsPetChange),
              // Brought pets add rows: past the sheet's height the grid
              // scrolls under the title instead of pushing 不显示 off.
              Flexible(
                child: SingleChildScrollView(
                  child: PetPicker(
                    padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 8, SheetTitleBar.inset, 24),
                    onPicked: (_) => Navigator.pop(sheet),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    case PetMenuAction.hide:
      final now = container.read(petClockProvider)();
      unawaited(container.read(petPrefsProvider.notifier).hideUntil(now.add(petHideFor)));
    case PetMenuAction.settings:
      await PetSettingsPage.open(context);
  }
}

class _MenuPreview extends StatelessWidget {
  const _MenuPreview({required this.pack});

  final PetPack pack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox.square(dimension: 56, child: PetPreview(pack: pack, side: 56)),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            pack.name,
            style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onSurface),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
