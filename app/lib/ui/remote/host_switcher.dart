import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../common/app_sheet.dart';
import '../common/status_chip.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'host_status.dart';

class HostChip extends ConsumerWidget {
  const HostChip({super.key, required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final host = ref.watch(activeHostProvider);
    final name = ref.watch(hostNameProvider(host)) ?? context.l10n.commonRemoteHost;
    final view = watchHostStatus(ref, host);
    return GlassSurface(
      tier: GlassTier.pill,
      stadium: true,
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedStatusDot(tone: view.tone, size: 7),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              '$name · ${view.label}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
          const Icon(AppIcons.dropdown, size: 16),
        ],
      ),
    );
  }
}

Future<void> showHostSheet(BuildContext context, {required VoidCallback onManage}) =>
    showAppSheet<void>(context, builder: (_) => HostSheet(onManage: onManage));

class HostSheet extends ConsumerWidget {
  const HostSheet({super.key, required this.onManage});
  final VoidCallback onManage;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hosts = ref.watch(hostsProvider).portals;
    final active = ref.watch(activeHostProvider);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final host in hosts)
            ListTile(
              leading: Icon(host.id == active.id ? Icons.check_circle : Icons.dns_outlined),
              title: Text(host.name),
              subtitle: Text(host.base.toString()),
              onTap: () {
                ref.read(activeHostProvider.notifier).select(HostRef.portal(host.id, name: host.name));
                Navigator.of(context).pop();
              },
            ),
          ListTile(
            leading: const Icon(Icons.add),
            title: Text(context.l10n.commonRemoteHost),
            onTap: () {
              Navigator.of(context).pop();
              onManage();
            },
          ),
        ],
      ),
    );
  }
}
