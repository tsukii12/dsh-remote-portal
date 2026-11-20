import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/phone_state.dart';
import '../common/app_dialog.dart';
import '../common/app_sheet.dart';
import '../common/list_page_row.dart';
import '../common/risk_notice.dart';
import '../common/segmented_pill.dart';
import '../features/feature_kit.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'phone_widgets.dart';

extension AppRuleText on AppRule {
  String get label => switch (this) {
    AppRule.deny => appL10n.phoneAppRuleDeny,
    AppRule.confirmEachStep => appL10n.phoneAppRuleConfirm,
    AppRule.normal => appL10n.phoneAppRuleNormal,
  };

  String get detail => switch (this) {
    AppRule.deny => appL10n.phoneAppRuleDenyHint,
    AppRule.confirmEachStep => appL10n.phoneAppRuleConfirmHint,
    AppRule.normal => appL10n.phoneAppRuleNormalHint,
  };

  IconData get icon => switch (this) {
    AppRule.deny => AppIcons.blocked,
    AppRule.confirmEachStep => AppIcons.askFirst,
    AppRule.normal => AppIcons.allowed,
  };

  /// Higher is looser.
  int get looseness => index;
}

/// Every package the page lists: both lists, the shipped defaults, and what the
/// person changed this session.
List<String> listedPackages(PhoneState state) {
  final p = state.policies;
  if (p == null) return const [];
  return {
    ...p.denyPackages,
    ...p.confirmEveryWritePackages,
    ...p.defaultDeny,
    ...p.defaultConfirm,
    ...state.retained,
  }.toList();
}

/// 应用名单: banks and payment apps are off limits by default, WeChat asks at
/// every step. Loosening a rule first shows the risk.
class PhoneAppRulesPage extends ConsumerWidget {
  const PhoneAppRulesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final state = ref.watch(phoneProvider);
    final policies = state.policies;
    final packages = listedPackages(state);
    List<String> by(AppRule rule) => [
      for (final p in packages)
        if (policies!.ruleFor(p) == rule) p,
    ];

    final groups = [
      for (final rule in AppRule.values)
        if (by(rule) case final list when list.isNotEmpty) (rule, list),
    ];
    return AppPage.list(
      title: l10n.phoneAppRulesTitle,
      subtitle: Text(l10n.phoneAppRulesSubtitle),
      children: [
        if (policies == null)
          EmptyView(
            icon: AppIcons.appRules,
            title: l10n.phoneAppRulesUnavailable,
            message: l10n.phoneTryLater,
            padding: const EdgeInsets.fromLTRB(32, 40, 32, 24),
          )
        else ...[
          for (final (i, (rule, list)) in groups.indexed) ...[
            if (i > 0) const SizedBox(height: 24),
            ListPageCard(
              title: switch (rule) {
                AppRule.deny => l10n.phoneAppRuleDeny,
                AppRule.confirmEachStep => l10n.phoneAppRuleConfirm,
                AppRule.normal => l10n.phoneAppRulesChanged,
              },
              children: [for (final package in list) _AppRow(package: package, policies: policies)],
            ),
          ],
          const SizedBox(height: 24),
          ListPageCard(
            children: [
              ListPageRow(
                icon: AppIcons.add,
                iconColor: Theme.of(context).colorScheme.primary,
                title: l10n.phoneAppRulesAdd,
                subtitle: l10n.phoneAppRulesAddHint,
                onTap: () => _add(context, ref),
              ),
            ],
          ),
        ],
        PageFootnote(l10n.phoneSensitiveActionsNote),
      ],
    );
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final added = await showAppDialog<(String, AppRule)>(context: context, builder: (_) => const _AddAppDialog());
    if (added == null) return;
    final ok = await ref.read(phoneProvider.notifier).setRule(added.$1, added.$2);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.phoneAppRulesSaveFailed)));
    }
  }
}

class _AppRow extends ConsumerWidget {
  const _AppRow({required this.package, required this.policies});

  final String package;
  final PhonePolicies policies;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final rule = policies.ruleFor(package);
    final label = policies.labelFor(package);
    final fallback = policies.defaultRuleFor(package);
    final changed = fallback != null && fallback != rule;
    return ListPageRow(
      icon: rule.icon,
      iconColor: rule == AppRule.deny ? DshColors.of(context).danger : null,
      title: label,
      subtitle: [
        if (label != package) package,
        if (changed) l10n.phoneAppRuleDefault(fallback.label),
      ].join(' · ').ifEmpty(null),
      onTap: () => _change(context, ref, rule, label),
    );
  }

  Future<void> _change(BuildContext context, WidgetRef ref, AppRule current, String label) async {
    final next = await showAppSheet<AppRule>(
      context,
      builder: (sheet) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SheetHeader(label),
            SheetGroup(
              children: [
                for (final rule in AppRule.values)
                  ListPageRow(
                    icon: rule.icon,
                    title: rule.label,
                    subtitle: rule.detail,
                    chevron: false,
                    trailing: rule == current
                        ? Icon(AppIcons.selected, size: 22, color: Theme.of(sheet).colorScheme.primary)
                        : const SizedBox.square(dimension: 22),
                    onTap: () => Navigator.pop(sheet, rule),
                  ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
    if (next == null || next == current || !context.mounted) return;
    if (next.looseness > current.looseness) {
      final ok = await confirmLoosening(context, label: label, from: current);
      if (!ok || !context.mounted) return;
    }
    final saved = await ref.read(phoneProvider.notifier).setRule(package, next);
    if (!saved && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.phoneAppRulesSaveFailed)));
    }
  }
}

/// The risk note shown before a rule gets looser. True to go ahead.
Future<bool> confirmLoosening(BuildContext context, {required String label, required AppRule from}) =>
    confirmRisk(context, RiskNotices.appRule(label, fromDeny: from == AppRule.deny));

class _AddAppDialog extends StatefulWidget {
  const _AddAppDialog();

  @override
  State<_AddAppDialog> createState() => _AddAppDialogState();
}

class _AddAppDialogState extends State<_AddAppDialog> {
  final _package = TextEditingController();
  AppRule _rule = AppRule.deny;

  static final _pattern = RegExp(r'^[A-Za-z][\w]*(\.[A-Za-z][\w]*)+$');

  @override
  void dispose() {
    _package.dispose();
    super.dispose();
  }

  bool get _valid => _pattern.hasMatch(_package.text.trim());

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.phoneAppRulesAdd),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _package,
            autofocus: true,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: l10n.phoneAppRulesPackage,
              hintText: 'com.taobao.taobao',
              helperText: l10n.phoneAppRulesPackageHint,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          // Natural width: the dialog sizes itself by intrinsics, which a
          // full-width (LayoutBuilder) pill can't report.
          Center(
            child: SegmentedPill<AppRule>(
              expand: false,
              segments: [
                PillSegment(AppRule.deny, l10n.phoneAppRuleDeny),
                PillSegment(AppRule.confirmEachStep, l10n.phoneAppRuleConfirm),
              ],
              selected: _rule,
              onChanged: (rule) => setState(() => _rule = rule),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.commonCancel)),
        FilledButton(
          onPressed: _valid ? () => Navigator.pop(context, (_package.text.trim(), _rule)) : null,
          child: Text(l10n.commonAdd),
        ),
      ],
    );
  }
}

extension on String {
  String? ifEmpty(String? other) => isEmpty ? other : this;
}
