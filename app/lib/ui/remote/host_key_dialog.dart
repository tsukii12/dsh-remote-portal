
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../state/hosts_state.dart';

Future<bool> activateHost(BuildContext context, WidgetRef ref, HostRef host) async {
  if (ref.read(hostsProvider).portalById(host.id) == null) return false;
  ref.read(activeHostProvider.notifier).select(host);
  return true;
}
