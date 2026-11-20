
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../launch/launch_state.dart';
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../remote/remote_screen.dart';
import 'home_shell.dart';

class RootGate extends ConsumerStatefulWidget {
  const RootGate({super.key, this.home});
  final Widget? home;
  @override
  ConsumerState<RootGate> createState() => _RootGateState();
}
class _RootGateState extends ConsumerState<RootGate> {
  bool _ready = false;
  @override
  Widget build(BuildContext context) {
    final hosts = ref.watch(hostsProvider);
    final active = ref.watch(activeHostProvider);
    if (!hosts.loaded) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (!_ready) {
      _ready = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => LaunchController.active.value?.ready(waitsForEngine: false));
    }
    final config = hosts.portalById(active.id);
    if (config == null) return const RemoteScreen();
    final connection = ref.watch(activeConnectionProvider);
    final error = connection.error;
    if (error is HostLinkError && error.kind == HostLinkErrorKind.authFailed) {
      return RemoteScreen(key: ValueKey(config.id), host: config);
    }
    return widget.home ?? const HomeShell();
  }
}
