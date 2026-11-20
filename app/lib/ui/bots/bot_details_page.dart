// Bot 详情: who the Bot is, its model, its
// memory, its token use, and the full record of its current part.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/bots_state.dart';
import '../chat/chat_list.dart';
import '../common/app_sheet.dart';
import '../common/list_page_row.dart';
import '../common/page_hero.dart';
import '../common/sheet_title_bar.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'bot_avatar.dart';
import 'unavailable_message.dart';
import 'bot_action_scope.dart';
import 'bot_chat_page.dart';
import 'bot_format.dart';
import 'bot_sheets.dart';
import 'duplicate_bot_row.dart';
import 'memory_card.dart';
import 'working_folder_sheet.dart';

class BotDetailsPage extends ConsumerWidget {
  const BotDetailsPage({super.key, required this.botId});

  final String botId;

  static Route<void> route(String botId) => MaterialPageRoute<void>(builder: (_) => BotDetailsPage(botId: botId));

  Future<void> _update(
    BuildContext context,
    WidgetRef ref,
    BotActionScope scope,
    Future<void> Function(DsBotApi api) call,
  ) async {
    final hub = ref.read(dsBotProvider.notifier);
    if (!context.mounted || !scope.current(context, ref)) return;
    final api = scope.api!;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await call(api);
      if (context.mounted && scope.current(context, ref)) await hub.refresh();
    } catch (error) {
      if (context.mounted && scope.current(context, ref)) {
        messenger?.showSnackBar(SnackBar(content: Text(describeDsBotError(error))));
      }
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, DsBot bot) async {
    final scope = BotActionScope(ref, botId: bot.id);
    final ok = await confirmDelete(
      context,
      title: context.l10n.botsDeleteNamed(bot.name),
      body: context.l10n.botsDeleteBotBody,
    );
    if (!ok || !context.mounted || !scope.current(context, ref)) return;
    final navigator = Navigator.of(context);
    await _update(context, ref, scope, (api) => api.deleteBot(bot.id));
    // Removal is expected after success; only connection identity may govern navigation.
    if (context.mounted && scope.connected(context, ref) && ref.read(dsBotProvider).team?.bot(bot.id) == null) {
      navigator.popUntil((route) => route.isFirst);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final status = ref.watch(dsBotProvider);
    final team = status.team;
    final bot = team?.bot(botId);
    final mobileUnavailable =
        status.availability == DsBotAvailability.missing || status.availability == DsBotAvailability.outdated;
    if (team == null || bot == null || mobileUnavailable) {
      return AppPage.list(
        title: 'Bot',
        children: [
          DsBotUnavailableMessage(status: status, goneIcon: AppIcons.bot, goneTitle: l10n.botsBotGone),
        ],
      );
    }
    final usageResult = ref.watch(dsBotUsageProvider(bot.id));
    final usage = usageResult.value;
    final memory = ref.watch(dsBotMemoryProvider((botId: bot.id, roomId: null))).value;
    final work = status.live.bots[bot.id];
    final main = team.isMain(bot.id);
    final writable = status.readOnly == null;
    final scope = BotActionScope(ref, botId: bot.id);
    final model = modelLabel(bot.modelRef, team.models);
    final doing = workPhrase(work, activity: status.live.activity[bot.id]);
    const gap = SizedBox(height: 24);
    return AppPage(
      title: bot.name,
      hero: PageHero(
        leading: BotAvatar(bot: bot, size: 56, working: work != null),
        title: bot.name,
        subtitle: Text(
          [if (main) l10n.botsMainBot, if (bot.role.isNotEmpty) bot.role, ?doing].join(' · ').ifEmpty('Bot'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        stats: [
          (usage == null || usage.scanning ? '—' : compactCount(usage.day.total), l10n.botsTokensToday),
          (memory == null ? '—' : '${memory.entries.length}', l10n.botsMemoryUnit),
          ('${team.rooms.where((room) => room.members.contains(bot.id)).length}', l10n.botsRoomUnit),
        ],
      ),
      slivers: [
        SliverList.list(
          children: [
            ListPageCard(
              title: l10n.botsProfile,
              children: [
                ListPageRow(
                  icon: AppIcons.model,
                  title: l10n.botsModel,
                  value: bot.effort == null ? model : '$model · ${effortName(bot.effort!)}',
                  onTap: writable ? () => pickBotModel(context, ref, bot, scope: scope) : null,
                ),
                ListPageRow(
                  key: const ValueKey('bot-working-folder'),
                  icon: AppIcons.folder,
                  title: l10n.botsWorkingFolder,
                  subtitle: bot.workDir ?? l10n.botsFolderTeamDefault,
                  subtitleMaxLines: 3,
                  onTap: () =>
                      showWorkingFolderSheet(context, botId: bot.id, workDir: bot.workDir, scope: scope, ref: ref),
                ),
                ListPageRow(
                  icon: AppIcons.nameTag,
                  title: l10n.botsBotName,
                  value: bot.name,
                  onTap: writable
                      ? () async {
                          final next = await showTextEditSheet(
                            context,
                            title: l10n.botsBotName,
                            initial: bot.name,
                            maxLength: 40,
                          );
                          if (next != null && next != bot.name && context.mounted) {
                            await _update(context, ref, scope, (api) => api.updateBot(bot.id, name: next));
                          }
                        }
                      : null,
                ),
                ListPageRow(
                  icon: AppIcons.botRole,
                  title: l10n.botsRole,
                  value: bot.role.isEmpty ? l10n.commonNotSet : bot.role,
                  onTap: writable
                      ? () async {
                          final next = await showTextEditSheet(
                            context,
                            title: l10n.botsRole,
                            initial: bot.role,
                            hint: l10n.botsWriterExample,
                            maxLength: 24,
                            allowEmpty: true,
                          );
                          if (next != null && next != bot.role && context.mounted) {
                            await _update(context, ref, scope, (api) => api.updateBot(bot.id, role: next));
                          }
                        }
                      : null,
                ),
                ListPageRow(
                  icon: AppIcons.instructions,
                  title: l10n.botsInstructions,
                  subtitle: bot.instructions.isEmpty ? l10n.commonNotSet : bot.instructions,
                  subtitleMaxLines: 3,
                  onTap: writable
                      ? () async {
                          final next = await showTextEditSheet(
                            context,
                            title: l10n.botsInstructions,
                            initial: bot.instructions,
                            hint: l10n.botsInstructionsHint,
                            multiline: true,
                            allowEmpty: true,
                          );
                          if (next != null && next != bot.instructions && context.mounted) {
                            await _update(context, ref, scope, (api) => api.updateBot(bot.id, instructions: next));
                          }
                        }
                      : null,
                ),
                ListPageRow(
                  icon: AppIcons.color,
                  title: l10n.botsColor,
                  trailing: _Swatch(color: bot.ink),
                  chevron: writable,
                  onTap: writable
                      ? () async {
                          final next = await showColorSheet(context, current: bot.ink);
                          if (next != null && next != bot.ink && context.mounted) {
                            await _update(context, ref, scope, (api) => api.updateBot(bot.id, color: next));
                          }
                        }
                      : null,
                ),
              ],
            ),
            gap,
            BotMemoryCard(botId: bot.id),
            if (usage != null) ...[
              gap,
              ListPageCard(
                title: l10n.botsUsage,
                children: [
                  if (usage.scanning)
                    Padding(
                      key: const ValueKey('usage-scanning'),
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Semantics(liveRegion: true, child: Text(l10n.botsUsageScanning)),
                          if (usageResult.hasError) Text(describeDsBotError(usageResult.error!)),
                          const SizedBox(height: 8),
                          TextButton(
                            key: const ValueKey('usage-refresh'),
                            onPressed: status.ready && !usageResult.isLoading
                                ? () => ref.invalidate(dsBotUsageProvider(bot.id))
                                : null,
                            child: Text(l10n.botsUsageRefresh),
                          ),
                        ],
                      ),
                    ),
                  ListPageRow(
                    icon: AppIcons.today,
                    title: l10n.botsToday,
                    value: '${compactCount(usage.day.total)} tokens',
                  ),
                  ListPageRow(
                    icon: AppIcons.lastWeek,
                    title: l10n.botsLastWeek,
                    value: '${compactCount(usage.week.total)} tokens',
                  ),
                  ListPageRow(
                    icon: AppIcons.lastMonth,
                    title: l10n.botsLastMonth,
                    value: '${compactCount(usage.month.total)} tokens',
                  ),
                  for (final m in usage.models)
                    ListPageRow(
                      icon: AppIcons.modelItem,
                      title: shortModel(m.name),
                      subtitle: l10n.botsMonthCalls(m.totals.calls),
                      value: '${compactCount(m.totals.total)} tokens',
                    ),
                ],
              ),
            ],
            gap,
            ListPageCard(
              title: l10n.commonMore,
              children: [
                ListPageRow(
                  icon: AppIcons.fullLog,
                  title: l10n.botsFullRecord,
                  subtitle: l10n.botsEveryToolCall,
                  onTap: () => Navigator.of(context).push(BotRecordPage.route(bot)),
                ),
                DuplicateBotRow(
                  key: ValueKey((status.host, status.hello?.boot, ref.read(dsBotProvider.notifier).api, bot.id)),
                  bot: bot,
                ),
                if (writable)
                  ListPageRow(
                    icon: main ? AppIcons.favoriteActive : AppIcons.favorite,
                    title: main ? l10n.botsUnsetMain : l10n.botsSetMain,
                    chevron: false,
                    onTap: () => _update(context, ref, scope, (api) => api.setMain(bot.id, main: !main)),
                  ),
              ],
            ),
            if (writable) ...[
              gap,
              Center(
                child: TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: DshColors.of(context).danger),
                  onPressed: () => _delete(context, ref, bot),
                  icon: const Icon(AppIcons.delete, size: 19),
                  label: Text(l10n.botsDeleteBot),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

/// 「DeepSeek-V4-Pro」 → 「V4 Pro」, kept short for the figures.
String shortModel(String name) {
  final stripped = name.replaceFirst(RegExp(r'^deepseek[-_ ]?', caseSensitive: false), '');
  final words = stripped
      .split(RegExp(r'[-_ ]+'))
      .where((w) => w.isNotEmpty)
      .map((w) {
        return w.length == 1 ? w.toUpperCase() : w[0].toUpperCase() + w.substring(1);
      })
      .join(' ');
  return words.isEmpty ? name : words;
}

/// The thinking level's Chinese name.
String effortName(String id) => switch (id) {
  'off' || 'none' => appL10n.botsEffortOff,
  'minimal' => appL10n.botsEffortMinimal,
  'low' => appL10n.botsEffortLow,
  'medium' => appL10n.botsEffortMedium,
  'high' => appL10n.botsEffortHigh,
  'xhigh' => appL10n.botsEffortXhigh,
  'max' => appL10n.botsEffortMax,
  _ => id,
};

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color});

  final String color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 20,
    child: DecoratedBox(
      decoration: ShapeDecoration(color: botInk(context, color), shape: const CircleBorder()),
    ),
  );
}

/// Picks a Bot color from DS Bot's swatches.
Future<String?> showColorSheet(BuildContext context, {required String current}) {
  return showAppSheet<String>(
    context,
    builder: (sheet) => SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetTitleBar(context.l10n.botsColor),
          Padding(
            padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 4, SheetTitleBar.inset, 24),
            child: BotColorPicker(selected: current, onPick: (color) => Navigator.of(sheet).pop(color)),
          ),
        ],
      ),
    ),
  );
}

/// A row of round swatches; the picked one wears a ring.
class BotColorPicker extends StatelessWidget {
  const BotColorPicker({super.key, required this.selected, required this.onPick});

  final String selected;
  final ValueChanged<String> onPick;

  static const size = 36.0;
  static const perRow = 5;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget swatch(String color) => Semantics(
      button: true,
      selected: color == selected,
      label: color,
      child: GestureDetector(
        key: ValueKey('color-$color'),
        onTap: () {
          HapticFeedback.selectionClick();
          onPick(color);
        },
        child: SizedBox.square(
          dimension: size,
          child: DecoratedBox(
            decoration: ShapeDecoration(
              shape: CircleBorder(
                side: BorderSide(color: color == selected ? scheme.onSurface : Colors.transparent, width: 2),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: DecoratedBox(
                decoration: ShapeDecoration(color: botInk(context, color), shape: const CircleBorder()),
              ),
            ),
          ),
        ),
      ),
    );
    // Two even rows: the first and last swatch of each row sit on the edges.
    return Column(
      spacing: 12,
      children: [
        for (var row = 0; row < dsBotPickerColors.length; row += perRow)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [for (final color in dsBotPickerColors.skip(row).take(perRow)) swatch(color)],
          ),
      ],
    );
  }
}

/// The current part of a Bot's chat in the chat's own list: every tool call
/// and step, read only.
class BotRecordPage extends StatelessWidget {
  const BotRecordPage({super.key, required this.bot});

  final DsBot bot;

  static Route<void> route(DsBot bot) => MaterialPageRoute<void>(builder: (_) => BotRecordPage(bot: bot));

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final padding = MediaQuery.paddingOf(context);
    const bar = 56.0;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: dshSystemOverlay(Theme.of(context).brightness),
      child: AppBackdrop(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            children: [
              Positioned.fill(
                child: ChatList(
                  sessionId: bot.sessionId,
                  topInset: padding.top + bar + 8,
                  bottomInset: padding.bottom + 16,
                ),
              ),
              Positioned(left: 0, right: 0, top: 0, child: TopFade(height: padding.top + bar + 12)),
              Positioned(
                left: 12,
                right: 12,
                top: padding.top,
                height: bar,
                child: BackdropGroup(
                  child: Row(
                    children: [
                      GlassIconButton(
                        icon: AppIcons.back,
                        tooltip: l10n.commonBack,
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          l10n.botsNamedRecord(bot.name),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      const SizedBox(width: 52),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
