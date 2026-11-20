// A panel's v1.2 micro caption — one line under the view, fed by its own small
// channel (up to 10 updates a second) and never by the panel's data. Subscribed
// only while it can be seen: the app in the foreground, its route on top,
// tickers on.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../plugins/native/native_capabilities.dart';
import '../../../plugins/native/native_state.dart';

final _microProvider = StreamProvider.autoDispose.family<DshGoEvent, (String, String, DshGoScope)>((ref, key) {
  final stream = ref.watch(nativeStreamProvider);
  return stream?.subscribeMicro(pkg: key.$1, id: key.$2, scope: key.$3) ?? const Stream.empty();
});

class NativeMicroCaption extends ConsumerStatefulWidget {
  const NativeMicroCaption({super.key, required this.package, required this.channel, required this.scope});

  final String package;
  final String channel;
  final DshGoScope scope;

  @override
  ConsumerState<NativeMicroCaption> createState() => _NativeMicroCaptionState();
}

class _NativeMicroCaptionState extends ConsumerState<NativeMicroCaption> {
  late final AppLifecycleListener _lifecycle;
  bool _foreground = _onScreen(WidgetsBinding.instance.lifecycleState);

  static bool _onScreen(AppLifecycleState? state) =>
      state == null || state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (mounted && _onScreen(state) != _foreground) setState(() => _foreground = _onScreen(state));
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(nativeCapabilityDiscoveryProvider);
    final plugin = ref.watch(nativeContributionsProvider.select((c) => c.plugin(widget.package)));
    if (!_foreground ||
        !TickerMode.valuesOf(context).enabled ||
        ModalRoute.of(context)?.isCurrent == false ||
        plugin == null ||
        !plugin.native ||
        !plugin.micro.contains(widget.channel)) {
      return const SizedBox.shrink();
    }
    final event = ref.watch(_microProvider((widget.package, widget.channel, widget.scope))).value;
    final text = switch (event) {
      DshGoData(data: {'text': final String text}) when text.trim().isNotEmpty => text,
      _ => null,
    };
    if (text == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }
}
