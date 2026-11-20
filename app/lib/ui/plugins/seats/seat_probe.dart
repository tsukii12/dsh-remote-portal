// The bridge's occupancy table on a cold start (docs/design/plugin-seams.md
// §5.2): when it's missing or belongs to another boot graph, a hidden probe
// island loads DSH Web once so the bridge reports, then goes; the inventory
// is read again and the seats that need the table fill in. Sits beside the
// pages that list seats (设置, 全部功能), outside their lists, taking no
// room: nothing at all otherwise.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../plugins/seams/seams.dart';
import '../../../state/hosts_state.dart';
import '../islands/island_gate.dart';
import '../islands/island_view.dart';

class SeatProbe extends ConsumerStatefulWidget {
  const SeatProbe({super.key});

  @override
  ConsumerState<SeatProbe> createState() => _SeatProbeState();
}

class _SeatProbeState extends ConsumerState<SeatProbe> {
  /// The boot graph probed for (once each, whatever the outcome).
  final _probed = <String>{};

  void _finish(String key) {
    if (_probed.add(key)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {});
        ref.invalidate(bridgeInventoryProvider);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final inventory = ref.watch(seatInventoryProvider);
    if (inventory == null || !inventory.needsProbe) return const SizedBox.shrink();
    final host = ref.watch(activeHostProvider);
    final key = '${host.kind.name}|${host.id}|${inventory.bootRev}';
    if (_probed.contains(key) || !ref.watch(islandHostGateProvider(host))) return const SizedBox.shrink();
    // 1×1 for the WebView, taking no room in the page.
    return SizedBox.shrink(
      child: OverflowBox(
        minWidth: 1,
        maxWidth: 1,
        minHeight: 1,
        maxHeight: 1,
        alignment: Alignment.topLeft,
        child: IslandView(
          key: ValueKey(key),
          spec: IslandSpec(host: host, form: IslandForm.probe, slot: 'probe'),
          fallback: (context) {
            _finish(key);
            return const SizedBox.shrink();
          },
          onReady: (_) => _finish(key),
        ),
      ),
    );
  }
}
