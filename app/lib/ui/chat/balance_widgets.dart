// DeepSeek balance surfaces: the balance from `/user/balance` and a
// low-balance reminder with a top-up link.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/l10n.dart';
import '../../state/balance_state.dart';
import '../common/app_dialog.dart';
import '../common/app_sheet.dart';
import '../common/sheet_title_bar.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'usage_sheet.dart' show UsageFigure;

/// `¥110.00`
String formatMoney(DeepSeekBalance b, [double? amount]) => '${b.symbol}${(amount ?? b.total).toStringAsFixed(2)}';

/// `¥5`、`¥0.5`
String formatThreshold(double value, [String symbol = '¥']) {
  final text = value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
  return '$symbol$text';
}

/// 打开 DeepSeek 开放平台的充值页(外部浏览器)。
Future<void> openTopUp(BuildContext context) async {
  try {
    if (await launchUrl(Uri.parse(deepSeekTopUpUrl), mode: LaunchMode.externalApplication)) return;
  } catch (_) {
    // A thrown launch and a false result share the visible feedback below.
  }
  if (!context.mounted) return;
  // The balance card can be inside a modal sheet, above the page's SnackBars.
  await showAppDialog<void>(
    context: context,
    builder: (dialog) => AlertDialog(
      content: Text(dialog.l10n.engineAccountBrowserFailed),
      actions: [TextButton(onPressed: () => Navigator.of(dialog).pop(), child: Text(dialog.l10n.commonClose))],
    ),
  );
}

/// 设置 → 模型与密钥里、API Key 下面的一行余额。
///
/// 只在有话可说时出现:查到余额 → "余额 ¥110.00";Key 无效 → 一句警告;
/// 没联网 / 还没查到 → 什么也不画(安静失败)。点它打开余额弹层(提醒线、充值)。
class BalanceSettingsLine extends ConsumerStatefulWidget {
  const BalanceSettingsLine({super.key});

  @override
  ConsumerState<BalanceSettingsLine> createState() => _BalanceSettingsLineState();
}

class _BalanceSettingsLineState extends ConsumerState<BalanceSettingsLine> {
  @override
  void initState() {
    super.initState();
    // Opening settings counts as "open": refresh (throttled to once a minute).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(balanceProvider.notifier).refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = ref.watch(balanceProvider);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dsh = DshColors.of(context);
    final balance = state.balance;

    final Widget value;
    if (state.status == BalanceStatus.invalidKey) {
      value = Text(l10n.viewBalanceInvalidKey, style: theme.textTheme.bodySmall?.copyWith(color: dsh.warning));
    } else if (balance != null) {
      final low = state.isLow;
      value = Text.rich(
        TextSpan(
          children: [
            TextSpan(text: l10n.viewBalancePrefix),
            TextSpan(
              text: formatMoney(balance),
              style: AppType.monoLabel(color: low ? dsh.warning : colors.onSurfaceVariant, weight: FontWeight.w500),
            ),
            if (low)
              TextSpan(
                text: balance.available ? l10n.viewBalanceLowSuffix : l10n.viewBalanceUnavailableSuffix,
                style: TextStyle(color: dsh.warning),
              ),
          ],
        ),
        style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
      );
    } else {
      return const SizedBox.shrink();
    }

    return InkWell(
      onTap: () => showBalanceSheet(context),
      child: Padding(
        // Lines up with the key row's title (icon 32 + gaps).
        padding: const EdgeInsets.fromLTRB(60, 0, 12, 10),
        child: Row(
          children: [
            Expanded(child: value),
            if (balance != null)
              Text(l10n.viewBalanceTopUp, style: theme.textTheme.labelMedium?.copyWith(color: colors.primary)),
            Icon(AppIcons.disclosure, size: 18, color: dsh.textTertiary),
          ],
        ),
      ),
    );
  }
}

/// 余额弹层(设置页进入):余额卡片 + 提醒线。
Future<void> showBalanceSheet(BuildContext context) {
  return showAppSheet<void>(
    context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            SheetTitleBar(context.l10n.viewBalanceTitle),
            const BalanceCard(margin: EdgeInsets.symmetric(horizontal: SheetTitleBar.inset)),
          ],
        ),
      ),
    ),
  );
}

/// 余额卡片:金额、构成、去充值、低余额提醒线。用量弹层和余额弹层共用。
///
/// ```
///     DeepSeek 余额
///   ╭──────────────────────────────────╮
///   │ ¥110.00                 去充值 ↗ │
///   │ 充值 ¥100.00 · 赠送 ¥10.00         │
///   │ 低余额提醒               低于 ¥5 ⇕ │
///   ╰──────────────────────────────────╯
/// ```
class BalanceCard extends ConsumerStatefulWidget {
  const BalanceCard({super.key, this.title, this.margin = const EdgeInsets.symmetric(horizontal: AppSpace.gutter)});

  /// 卡片上方的小标题(用量弹层里是"DeepSeek 余额")。
  final String? title;

  /// 卡片离两边的距离;小标题再往里 8。
  final EdgeInsets margin;

  @override
  ConsumerState<BalanceCard> createState() => _BalanceCardState();
}

class _BalanceCardState extends ConsumerState<BalanceCard> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(balanceProvider.notifier).refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = ref.watch(balanceProvider);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dsh = DshColors.of(context);
    final balance = state.balance;

    Widget status(String text, {Color? color, IconData? icon}) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Row(
        children: [
          if (icon != null) ...[Icon(icon, size: 18, color: color ?? dsh.textTertiary), const SizedBox(width: 10)],
          Expanded(
            child: Text(text, style: theme.textTheme.bodyMedium?.copyWith(color: color ?? dsh.textTertiary)),
          ),
        ],
      ),
    );

    final Widget top;
    if (state.status == BalanceStatus.noKey) {
      top = status(l10n.viewBalanceKeyRequired, icon: AppIcons.noApiKey);
    } else if (state.status == BalanceStatus.invalidKey) {
      top = status(l10n.viewBalanceKeyInvalid, color: dsh.warning, icon: AppIcons.error);
    } else if (balance != null) {
      final low = state.isLow;
      final parts = [
        if (balance.toppedUp case final paid?) l10n.viewBalancePaid(formatMoney(balance, paid)),
        if (balance.granted case final granted? when granted > 0)
          l10n.viewBalanceGranted(formatMoney(balance, granted)),
        if (low) balance.available ? l10n.viewBalanceLow : l10n.viewBalanceUnavailable,
      ];
      top = Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 2),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AnimatedSwitcher(
                    duration: AppMotion.of(context, AppMotion.quick),
                    layoutBuilder: (current, previous) =>
                        Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
                    child: UsageFigure(
                      formatMoney(balance),
                      key: ValueKey(formatMoney(balance)),
                      style: theme.textTheme.headlineMedium!.copyWith(fontWeight: FontWeight.w500, height: 1.2),
                      color: low ? dsh.warning : colors.onSurface,
                    ),
                  ),
                  if (parts.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        parts.join(' · '),
                        style: AppType.tabular(
                          theme.textTheme.bodySmall!.copyWith(color: low ? dsh.warning : dsh.textTertiary),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const _TopUpButton(),
          ],
        ),
      );
    } else if (state.loading || state.status == BalanceStatus.unknown) {
      top = Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2, strokeCap: StrokeCap.round, color: dsh.textTertiary),
            ),
            const SizedBox(width: 12),
            Text(l10n.viewBalanceChecking, style: theme.textTheme.bodyMedium?.copyWith(color: dsh.textTertiary)),
          ],
        ),
      );
    } else {
      top = status(l10n.viewBalanceCheckFailed, icon: AppIcons.offline);
    }

    final symbol = balance?.symbol ?? '¥';
    String thresholdLabel(double v) =>
        v == 0 ? l10n.viewBalanceNoAlert : l10n.viewBalanceBelow(formatThreshold(v, symbol));
    final title = widget.title;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title != null) SheetSectionLabel(title, inset: widget.margin.left),
        SheetGroup(
          margin: widget.margin,
          children: [
            SizedBox(width: double.infinity, child: top),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 6, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.viewBalanceAlert,
                      style: theme.textTheme.bodyMedium?.copyWith(color: colors.onSurface),
                    ),
                  ),
                  PopupMenuButton<double>(
                    tooltip: l10n.viewBalanceThreshold,
                    initialValue: state.threshold,
                    onSelected: (value) => ref.read(balanceProvider.notifier).setThreshold(value),
                    itemBuilder: (context) => [
                      for (final value in lowBalanceThresholds)
                        CheckedPopupMenuItem<double>(
                          value: value,
                          checked: value == state.threshold,
                          child: Text(thresholdLabel(value)),
                        ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            thresholdLabel(state.threshold),
                            style: theme.textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
                          ),
                          const SizedBox(width: 2),
                          Icon(AppIcons.dropdown, size: 18, color: dsh.textTertiary),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// "去充值 ↗":外部浏览器打开 DeepSeek 开放平台的充值页。
class _TopUpButton extends StatelessWidget {
  const _TopUpButton();

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: () => openTopUp(context),
    iconAlignment: IconAlignment.end,
    icon: const Icon(AppIcons.openLink, size: 16),
    label: Text(context.l10n.viewBalanceGoTopUp),
  );
}

/// 输入条上方的低余额提示:一颗安静的玻璃胶囊(和输入条上方的活动胶囊同一族),钱包图标
/// 与金额用警示色;右端「去充值」和关闭(本次运行不再出现)。
///
/// ```
/// ( ▣ 余额仅剩 ¥3.20 · 低于 ¥5            去充值  × )
/// ```
class LowBalanceBanner extends ConsumerWidget {
  const LowBalanceBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final state = ref.watch(balanceProvider);
    final balance = state.balance;
    if (!state.showBanner || balance == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dsh = DshColors.of(context);
    final text = balance.available ? l10n.viewBalanceRemaining(formatMoney(balance)) : l10n.viewBalanceModelDisabled;
    final detail = balance.available && state.threshold > 0
        ? l10n.viewBalanceBelow(formatThreshold(state.threshold, balance.symbol))
        : l10n.viewBalanceRestore;

    return Semantics(
      liveRegion: true,
      container: true,
      child: GlassSurface(
        tier: GlassTier.chrome,
        stadium: true,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 2, 0),
            child: Row(
              children: [
                Icon(AppIcons.balance, size: 18, color: dsh.warning),
                const SizedBox(width: 10),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: text,
                          style: TextStyle(color: colors.onSurface, fontWeight: FontWeight.w600),
                        ),
                        TextSpan(
                          text: ' · $detail',
                          style: TextStyle(color: dsh.textTertiary),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.tabular(theme.textTheme.bodySmall!),
                  ),
                ),
                TextButton(
                  onPressed: () => openTopUp(context),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(48, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(l10n.viewBalanceGoTopUp),
                ),
                IconButton(
                  tooltip: l10n.commonClose,
                  onPressed: () {
                    final balance = ref.read(balanceProvider.notifier);
                    balance.dismissBanner();
                    // For good: the same as 「不提醒」 in the balance sheet.
                    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                      SnackBar(
                        content: Text(l10n.viewBalanceBannerHidden),
                        persist: true,
                        action: SnackBarAction(
                          label: l10n.viewBalanceTurnOff,
                          onPressed: () => unawaited(balance.setThreshold(0)),
                        ),
                      ),
                    );
                  },
                  iconSize: 18,
                  style: IconButton.styleFrom(
                    minimumSize: const Size(40, 40),
                    foregroundColor: dsh.textTertiary,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const Icon(AppIcons.close),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
