// The two keys that fold and unfold 对话详情 beside the
// chat. They take turns on one spot — the window's top-right corner — so the
// key stays under the finger: the panel's own key while it shows, the chat
// header's corner key once it is folded (DSH Web's expand button lives in
// the conversation header's corner the same way).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/adaptive_layout_state.dart';
import '../../common/smooth_size.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../page_frame.dart' show GlassIconButton;
import 'adaptive_layout.dart';
import 'adaptive_scaffold.dart';

/// The glyph of both keys: a frame with a column on its right.
const detailPanelIcon = AppIcons.sidebar;

/// The chat header's corner key: unfolds 对话详情 again. Draws nothing on
/// phones, without a conversation, or while the panel shows. Goes last in
/// the header row, after the new-chat key.
class DetailPanelKey extends ConsumerWidget {
  const DetailPanelKey({super.key, this.gap = AdaptiveMetrics.gap});

  /// Space before the key (the header's gap between pieces).
  final double gap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final shows = AdaptiveChrome.maybeOf(context)?.showsPanelKey ?? false;
    return SmoothSize(
      duration: AppMotion.of(context, AppMotion.quick),
      curve: AppMotion.std,
      alignment: Alignment.centerRight,
      child: shows
          ? Padding(
              padding: EdgeInsets.only(left: gap),
              child: GlassIconButton(
                key: const ValueKey('chat-panel-key'),
                icon: detailPanelIcon,
                tooltip: l10n.shellChatDetails,
                onPressed: () => ref.read(layoutPrefsProvider.notifier).setPanelOpen(true),
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}

/// The panel's own key, at the end of its bar: folds it away.
class DetailPanelCollapseKey extends ConsumerWidget {
  const DetailPanelCollapseKey({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => GlassIconButton(
    key: const ValueKey('panel-collapse'),
    icon: detailPanelIcon,
    tooltip: context.l10n.shellCollapseDetails,
    onPressed: () => ref.read(layoutPrefsProvider.notifier).setPanelOpen(false),
  );
}
