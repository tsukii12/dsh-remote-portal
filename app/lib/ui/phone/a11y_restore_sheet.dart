import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/phone_state.dart';
import '../common/app_sheet.dart';
import '../common/brief_notice.dart';
import '../common/risk_notice.dart';
import 'dnd_mode_page.dart';

Future<void> showA11yRestoreSheet(BuildContext context) =>
    showAppSheet<void>(context, isScrollControlled: true, builder: (_) => const A11yRestoreSheet());

class A11yRestoreSheet extends ConsumerStatefulWidget {
  const A11yRestoreSheet({super.key});

  @override
  ConsumerState<A11yRestoreSheet> createState() => _A11yRestoreSheetState();
}

class _A11yRestoreSheetState extends ConsumerState<A11yRestoreSheet> {
  bool _busy = false;
  String? _message;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(ref.read(phoneProvider.notifier).refreshStatus()));
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _grant(String path) async {
    final status = ref.read(phoneProvider).status;
    if (_busy || !status.ready || !status.enabled || status.background.root.starting) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    final result = await ref.read(phoneProvider.notifier).grantSecureSettings();
    if (!mounted) return;
    final l10n = context.l10n;
    setState(() {
      _busy = false;
      _message = result.pending
          ? (path == 'suiPermission' ? l10n.a11yRestoreWaitingSui : l10n.a11yRestoreWaiting)
          : result.ok
          ? null
          : result.reason ?? l10n.phoneActionFailedLater;
    });
  }

  /// Only a root connection; 不打扰模式 stays as it is, and so does an Android
  /// version that can't run it (the grant needs no virtual display).
  Future<void> _prepareRoot() async {
    if (_busy || !ref.read(phoneProvider).status.ready ||
        !await confirmRisk(context, RiskNotices.rootChannel) || !mounted) {
      return;
    }
    final status = ref.read(phoneProvider).status;
    if (_busy || !status.ready || !status.enabled || status.background.root.starting) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    final result = await ref.read(phoneProvider.notifier).prepareRoot();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = result.ok ? null : result.reason ?? context.l10n.phoneActionFailedLater;
    });
  }

  Future<void> _setUp() async {
    await Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const PhoneDndPage()));
    if (mounted) await ref.read(phoneProvider.notifier).refreshStatus();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final status = ref.watch(phoneProvider).status;
    final keeper = status.a11yKeeper;
    final privileged = status.background.privileged;
    // The versioned path names Sui and root too; old native modules say it in a11yKeeper.
    final path = privileged?.grantPath ?? keeper.path;
    // Root was picked but its connection is gone: never quietly another way.
    final rootLost = path == 'setup' && (privileged?.rootSelected ?? false);
    final offerRoot =
        path == 'setup' && !rootLost && status.background.supportedModes.contains(PhonePrivilegedMode.root);
    // A root prompt already open (from either page) is answered first, not asked twice.
    final idle = status.ready && status.enabled && !_busy && !status.background.root.starting;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SheetHeader(l10n.a11yRestoreTitle),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(l10n.a11yRestoreNotice),
                  const SizedBox(height: 12),
                  Text(l10n.a11yRestoreForceStop, style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 20),
                  if (keeper.granted)
                    Text(status.enabled ? l10n.phoneEnabled : l10n.phoneDisabled)
                  else ...[
                    FilledButton(
                      key: const Key('a11y-restore-grant'),
                      onPressed: !idle
                          ? null
                          : path != 'setup'
                          ? () => _grant(path)
                          : rootLost
                          ? _prepareRoot
                          : _setUp,
                      child: Text(switch (path) {
                        'setup' => rootLost ? l10n.phonePrivilegedRootPrepare : l10n.a11yRestoreSetup,
                        'shizuku' => l10n.a11yRestoreGrantShizuku,
                        'shizukuPermission' => l10n.a11yRestoreGrantShizukuPermission,
                        'sui' => l10n.phonePrivilegedGrantSui,
                        'suiPermission' => l10n.phonePrivilegedGrantSuiPermission,
                        'root' => l10n.phonePrivilegedGrantRoot,
                        'adb' => l10n.a11yRestoreGrantAdb,
                        _ => l10n.a11yRestoreGrant,
                      }),
                    ),
                    if (path == 'root') ...[
                      const SizedBox(height: 8),
                      Text(l10n.a11yRestoreRootNote, style: Theme.of(context).textTheme.bodySmall),
                    ],
                    if (offerRoot)
                      TextButton(
                        key: const Key('a11y-restore-root'),
                        onPressed: idle ? _prepareRoot : null,
                        child: Text(l10n.phonePrivilegedRootPrepare),
                      ),
                    if (_message != null) ...[const SizedBox(height: 8), Text(_message!)],
                  ],
                  if (keeper.command.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Text(l10n.a11yRestoreComputer),
                    const SizedBox(height: 8),
                    SelectableText(keeper.command, style: Theme.of(context).textTheme.bodySmall),
                    TextButton(
                      key: const Key('a11y-restore-copy'),
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: keeper.command));
                        if (context.mounted) showBriefNotice(context, l10n.a11yRestoreCopied);
                      },
                      child: Text(l10n.a11yRestoreCopy),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
