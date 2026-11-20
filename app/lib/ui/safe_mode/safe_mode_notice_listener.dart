import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../runtime/runtime_state.dart';

/// Shows the runtime's one-off notices ("已用安全模式启动", "已恢复正常模式") as snack
/// bars. Wrap the home shell (below the MaterialApp) with it once.
class SafeModeNoticeListener extends ConsumerWidget {
  const SafeModeNoticeListener({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<RuntimeNotice?>(localRuntimeProvider.select((s) => s.notice), (previous, next) {
      if (next == null || next.seq == previous?.seq) return;
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(next.text), duration: const Duration(seconds: 6)));
    });
    return child;
  }
}
