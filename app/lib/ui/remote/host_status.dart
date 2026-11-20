import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../common/status_dot.dart';
import '../theme/app_icons.dart';

class HostStatusView {
  const HostStatusView(this.tone, this.label);
  final StatusTone tone;
  final String label;
  static HostStatusView ofLink(HostLinkStatus status) => switch (status.phase) {
    HostLinkPhase.idle => HostStatusView(StatusTone.idle, appL10n.commonNotConnected),
    HostLinkPhase.connecting => HostStatusView(StatusTone.busy, appL10n.remoteConnecting),
    HostLinkPhase.connected => HostStatusView(StatusTone.ok, appL10n.remoteConnected),
    HostLinkPhase.reconnecting => HostStatusView(StatusTone.warn, appL10n.remoteReconnecting),
    HostLinkPhase.failed => HostStatusView(StatusTone.error, appL10n.commonConnectionFailed),
  };
}

HostStatusView watchHostStatus(WidgetRef ref, HostRef host) =>
    HostStatusView.ofLink(ref.watch(hostLinkStatusProvider(host)).value ?? HostLinkStatus.idle);
IconData hostKindIcon(HostKind kind) => AppIcons.computer;
int hostKindTint(HostKind kind) => 1;
