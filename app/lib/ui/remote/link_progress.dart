import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../state/hosts_state.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// Step-by-step connect progress: 连接服务器 → 验证主机指纹 → 启动 DSH →
/// 建立隧道 → 登录, each done / running / failed / waiting, with the error
/// (and its technical detail, copyable) under the step that failed.
class LinkProgressCard extends StatelessWidget {
  const LinkProgressCard({super.key, required this.status, this.onRetry});

  final HostLinkStatus status;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final failed = status.phase == HostLinkPhase.failed;
    final done = status.isConnected;
    final current = status.step;
    return GlassSurface(
      tier: GlassTier.card,
      borderRadius: AppShape.radiusLg,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final step in HostLinkStep.values)
            _StepRow(
              label: step.label,
              state: done || status.completed.contains(step)
                  ? _StepState.done
                  : step == current
                  ? (failed ? _StepState.failed : _StepState.running)
                  : _StepState.waiting,
              detail: step == current && !failed && !done ? status.detail : null,
            ),
          if (done && status.detail != null) ...[
            const SizedBox(height: 4),
            Text(status.detail!, style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary)),
          ],
          if (failed && status.error != null) ...[
            const SizedBox(height: 8),
            LinkErrorBox(error: status.error!, action: onRetry == null ? null : (l10n.commonRetry, onRetry!)),
          ],
        ],
      ),
    );
  }
}

enum _StepState { waiting, running, done, failed }

class _StepRow extends StatelessWidget {
  const _StepRow({required this.label, required this.state, this.detail});

  final String label;
  final _StepState state;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final Widget mark = switch (state) {
      _StepState.done => Icon(AppIcons.success, size: 20, color: colors.success),
      _StepState.failed => Icon(AppIcons.stepFailed, size: 20, color: colors.danger),
      _StepState.running => SizedBox.square(
        dimension: 20,
        child: Padding(
          padding: const EdgeInsets.all(2.5),
          child: CircularProgressIndicator(strokeWidth: 2.2, color: scheme.primary),
        ),
      ),
      _StepState.waiting => Icon(AppIcons.pending, size: 20, color: colors.textDisabled),
    };
    final textColor = switch (state) {
      _StepState.waiting => colors.textTertiary,
      _StepState.failed => colors.danger,
      _ => scheme.onSurface,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          mark,
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: textColor,
                    fontWeight: state == _StepState.running ? FontWeight.w600 : FontWeight.w400,
                    height: 1.4,
                  ),
                ),
                if (detail case final d?)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      d,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A failure, said plainly, with the raw detail tucked under "详情".
class LinkErrorBox extends StatefulWidget {
  const LinkErrorBox({super.key, required this.error, this.action});

  final HostLinkError error;

  /// One follow-up, e.g. ('重试', …) or ('主机设置', …).
  final (String, VoidCallback)? action;

  @override
  State<LinkErrorBox> createState() => _LinkErrorBoxState();
}

class _LinkErrorBoxState extends State<LinkErrorBox> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final error = widget.error;
    final detail = error.detail?.trim();
    final security = error.kind == HostLinkErrorKind.hostKeyMismatch;
    final bg = security ? colors.warningContainer : colors.dangerContainer;
    final fg = security ? colors.onWarningContainer : colors.onDangerContainer;
    return DecoratedBox(
      decoration: ShapeDecoration(color: bg, shape: Squircle.border(AppShape.md)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(security ? AppIcons.securityWarning : AppIcons.error, size: 18, color: fg),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(error.message, style: theme.textTheme.bodyMedium?.copyWith(color: fg, height: 1.55)),
                ),
              ],
            ),
            if (_expanded && detail != null && detail.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 8, 4, 0),
                child: SelectableText(detail, style: AppType.mono(size: 12, color: fg, height: 1.5)),
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (detail != null && detail.isNotEmpty) ...[
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: fg, minimumSize: const Size(0, 36)),
                    onPressed: () => setState(() => _expanded = !_expanded),
                    child: Text(_expanded ? l10n.commonCollapse : l10n.commonDetails),
                  ),
                  if (_expanded)
                    TextButton(
                      style: TextButton.styleFrom(foregroundColor: fg, minimumSize: const Size(0, 36)),
                      onPressed: () => Clipboard.setData(ClipboardData(text: '${error.message}\n$detail')),
                      child: Text(l10n.commonCopy),
                    ),
                ],
                if (widget.action case (final label, final onTap))
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: fg, minimumSize: const Size(0, 36)),
                    onPressed: onTap,
                    child: Text(label),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
