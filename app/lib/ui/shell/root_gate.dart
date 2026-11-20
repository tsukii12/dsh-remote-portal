import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../remote/remote_screen.dart';
import 'home_shell.dart';

class RootGate extends ConsumerWidget {
  const RootGate({super.key, this.home});
  final Widget? home;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hosts = ref.watch(hostsProvider);
    final active = ref.watch(activeHostProvider);
    if (!hosts.loaded) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final config = hosts.portalById(active.id);
    if (config == null) return const RemoteScreen();
    final connection = ref.watch(activeConnectionProvider);
    final error = connection.error;
    if (error is HostLinkError && error.kind == HostLinkErrorKind.authFailed) {
      return RemoteScreen(key: ValueKey(config.id), host: config);
    }
    return home ?? const HomeShell();
  }
}
