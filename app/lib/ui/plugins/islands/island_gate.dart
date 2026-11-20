
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../state/hosts_state.dart';

enum RouteGuard { unknown, absent, present }
bool islandHostAllowed(HostKind kind, {bool? reported, RouteGuard probed = RouteGuard.unknown,
  bool override = false}) => false;
final islandHostGateProvider = Provider.family<bool, HostRef>((ref, host) => false);
final islandHostUrlProvider = Provider.autoDispose.family<Uri?, HostRef>((ref, host) => null);
