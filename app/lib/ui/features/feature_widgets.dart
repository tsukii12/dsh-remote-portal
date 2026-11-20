import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../../state/sessions_state.dart';
import '../common/feature_tile.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'feature_format.dart';
import 'feature_kit.dart';

/// Empty / failed / not-connected message inside a feature page: one glyph,
/// one line, at most one button ([EmptyView]).
class FeatureMessage extends StatelessWidget {
  const FeatureMessage({super.key, this.icon, this.tile, required this.title, this.body, this.action})
    : assert(icon != null || tile != null);

  FeatureMessage.error({super.key, required this.title, required Object error, VoidCallback? onRetry})
    : icon = AppIcons.error,
      tile = null,
      body = featureErrorReason(error),
      action = onRetry == null ? null : (appL10n.commonRetry, onRetry);

  final IconData? icon;

  /// The feature's own graphic instead of [icon] (an empty list: 还没有…).
  final FeatureKind? tile;
  final String title;
  final String? body;
  final (String, VoidCallback)? action;

  @override
  Widget build(BuildContext context) => EmptyView(
    icon: icon,
    art: switch (tile) {
      final kind? => FeatureTile(kind, size: FeatureTile.empty),
      null => null,
    },
    title: title,
    message: body,
    actionLabel: action?.$1,
    onAction: action?.$2,
    padding: const EdgeInsets.fromLTRB(32, 40, 32, 24),
  );
}

/// "Not connected" for pages that need the active host: a spinner while
/// connecting, a retry when the connection failed.
class FeatureOffline extends ConsumerWidget {
  const FeatureOffline({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final connection = ref.watch(activeConnectionProvider);
    final host = ref.watch(activeHostProvider);
    final name = host.isLocal ? null : ref.watch(hostNameProvider(host)) ?? l10n.commonRemoteHost;
    if (connection.hasError) {
      if (host.isLocal) {
        return FeatureMessage(
          icon: AppIcons.error,
          title: l10n.commonEngineUnreachable,
          action: (l10n.commonRetry, () => ref.invalidate(localConnectionProvider)),
        );
      }
      final status = ref.watch(hostLinkStatusProvider(host)).value ?? HostLinkStatus.idle;
      return FeatureMessage(
        icon: AppIcons.disconnected,
        title: l10n.featuresHostUnreachable(name ?? l10n.commonRemoteHost),
        body: status.error?.message,
        action: status.error?.retryable ?? true
            ? (l10n.commonRetry, () => ref.read(remoteConnectionProvider(host).notifier).retry())
            : null,
      );
    }
    if (connection.isLoading) {
      return host.isLocal
          ? const QuietSpinner()
          : QuietSpinner(label: l10n.featuresHostConnecting(name ?? l10n.commonRemoteHost));
    }
    return FeatureMessage(icon: AppIcons.offline, title: l10n.commonEngineUnreachable);
  }
}

/// Loading inside a feature page: a small quiet ring.
class FeatureLoading extends StatelessWidget {
  const FeatureLoading({super.key});

  @override
  Widget build(BuildContext context) => const QuietSpinner();
}

/// Footnote under a group: faint, lined up with the rows' content.
class FeatureNote extends StatelessWidget {
  const FeatureNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
    ),
  );
}

/// Opens [sessionId] in the chat: selects it and returns to the home page.
void openSessionInChat(BuildContext context, WidgetRef ref, String? sessionId) {
  ref.read(currentSessionProvider.notifier).select(sessionId);
  Navigator.of(context).popUntil((route) => route.isFirst);
}

/// Full-width, start-aligned content inside a [SheetGroup] (whose column
/// centres narrower children).
class FeatureBlock extends StatelessWidget {
  const FeatureBlock({super.key, required this.padding, required this.child});

  final EdgeInsetsGeometry padding;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: SizedBox(width: double.infinity, child: child),
  );
}
