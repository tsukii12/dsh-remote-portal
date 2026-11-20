import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/notify_state.dart' show launchNoticeShownProvider;
import '../../state/update_state.dart';
import 'update_sheet.dart';

/// Mounted once in the home shell; draws nothing.
///
/// A few seconds after launch (the engine starts first) it runs the daily
/// automatic check and offers the sheet when there's a version the person
/// hasn't skipped. It also tells the controller when the app comes back to
/// the front, which continues an install waiting on the "install unknown
/// apps" permission.
class UpdateLaunchCheck extends ConsumerStatefulWidget {
  const UpdateLaunchCheck({super.key, this.delay = const Duration(seconds: 6)});

  final Duration delay;

  @override
  ConsumerState<UpdateLaunchCheck> createState() => _UpdateLaunchCheckState();
}

class _UpdateLaunchCheckState extends ConsumerState<UpdateLaunchCheck> {
  Timer? _timer;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.delay, () => unawaited(_run()));
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(ref.read(appUpdateProvider.notifier).onAppResumed()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    if (!mounted) return;
    final offer = await ref.read(appUpdateProvider.notifier).autoCheckIfDue();
    if (!offer || !mounted) return;
    // Don't cover a page or sheet the person is in, or interrupt typing (raw
    // view insets: a Scaffold on the way may have consumed the keyboard's).
    // The mark in 设置 → 关于 stays either way.
    if (ModalRoute.of(context)?.isCurrent == false || View.of(context).viewInsets.bottom > 0) return;
    ref.read(launchNoticeShownProvider.notifier).set(true);
    await showUpdateSheet(context);
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
