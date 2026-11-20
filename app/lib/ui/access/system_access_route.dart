// One item's step on its own page: from 设置 › 系统权限 and from first run's
// summary, the same step first run walks.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/access_state.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import 'access_walk.dart';

/// Pushes [item]'s step; it closes itself once the item is on (or 设好了,
/// or 跳过), and back closes it any time.
Future<void> openAccessItem(BuildContext context, AccessItem item) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => AccessItemPage(item: item)));

class AccessItemPage extends ConsumerWidget {
  const AccessItemPage({super.key, required this.item});

  final AccessItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final navigator = Navigator.of(context);
    return AccessWalk(
      items: [item],
      revisit: true,
      leading: GlassIconButton(
        icon: AppIcons.back,
        tooltip: context.l10n.commonBack,
        grouped: false,
        onPressed: () => navigator.maybePop(),
      ),
      onDone: () {
        if (navigator.canPop()) navigator.pop();
      },
    );
  }
}
