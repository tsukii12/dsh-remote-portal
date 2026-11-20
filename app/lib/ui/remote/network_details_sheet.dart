import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../common/app_sheet.dart';
import '../theme/theme.dart';

Future<void> showRemoteNetworkDetails(BuildContext context, HostRef host) => showAppSheet<void>(
  context,
  dismissal: SheetDismissal.button,
  isScrollControlled: true,
  builder: (_) => RemoteNetworkDetailsSheet(host: host),
);

class RemoteNetworkDetailsSheet extends ConsumerWidget {
  const RemoteNetworkDetailsSheet({super.key, required this.host});
  final HostRef host;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final status = ref.watch(hostLinkStatusProvider(host)).value ?? HostLinkStatus.idle;
    final name = ref.watch(hostNameProvider(host)) ?? l10n.commonRemoteHost;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetHeader(l10n.remoteNetworkDetails),
            SheetGroup(
              children: [
                _NetworkValue(label: l10n.remoteHost, value: name),
                _NetworkValue(label: l10n.hostDetailsConnectionType, value: 'Portal HTTP / WebSocket'),
                _NetworkValue(label: l10n.commonStatus, value: status.summary),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _NetworkValue extends StatelessWidget {
  const _NetworkValue({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(label, style: TextStyle(color: DshColors.of(context).textTertiary)),
        ),
        const SizedBox(width: 16),
        Expanded(child: Text(value, textAlign: TextAlign.end)),
      ],
    ),
  );
}
