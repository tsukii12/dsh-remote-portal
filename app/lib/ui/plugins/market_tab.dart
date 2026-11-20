import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/l10n.dart';
import '../../state/plugins_state.dart';
import '../common/app_sheet.dart' show groupTitleStyle;
import '../common/capsule_chip.dart';
import '../common/list_page_row.dart';
import '../common/search_capsule.dart';
import '../features/feature_kit.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'market_widgets.dart';
import 'plugin_detail_sheet.dart';
import 'plugin_widgets.dart';
import 'plugins_screen.dart';

/// 「插件市场」: search, then three sections (docs/design/plugin-market.md
/// §2) — 官方 and 适配 DSH Go from the official index, 全部 (dshfind's
/// catalogue with the official entries in place, category chips) as cards —
/// and 提交插件 at the bottom.
class MarketSliver extends ConsumerStatefulWidget {
  const MarketSliver({super.key});

  @override
  ConsumerState<MarketSliver> createState() => _MarketSliverState();
}

class _MarketSliverState extends ConsumerState<MarketSliver> {
  late final TextEditingController _search = TextEditingController(text: ref.read(marketFilterProvider).query);
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onQuery(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) ref.read(marketFilterProvider.notifier).setQuery(text);
    });
  }

  void _clear() {
    _debounce?.cancel();
    _search.clear();
    ref.read(marketFilterProvider.notifier).setQuery('');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final filter = ref.watch(marketFilterProvider);
    final catalog = ref.watch(marketAllProvider);
    final official = ref.watch(officialMarketProvider);
    final searching = filter.terms.isNotEmpty;

    final searchField = Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: SearchCapsule(controller: _search, hint: l10n.pluginsSearch, onChanged: _onQuery, onClear: _clear),
    );

    // 官方 and 适配 DSH Go: the official index. Searching hides a section with
    // nothing to show; otherwise it says 暂无, or that it didn't load.
    List<Widget> section(MarketSection which, String title) {
      final entries = official.whenOrNull(data: (c) => marketSection(c, which, filter));
      if (searching && (entries == null || entries.isEmpty)) return const [];
      return [
        SliverToBoxAdapter(child: _SectionTitle(title)),
        if (entries != null && entries.isNotEmpty)
          _cards(entries)
        else
          SliverToBoxAdapter(
            child: official.when(
              skipLoadingOnRefresh: false,
              loading: () => _SectionNote(l10n.marketSectionLoading),
              error: (error, _) => _SectionNote(
                l10n.marketSectionFailed,
                action: l10n.commonRetry,
                onAction: () => ref.invalidate(officialMarketProvider),
              ),
              data: (_) => _SectionNote(l10n.marketSectionEmpty),
            ),
          ),
      ];
    }

    final body = catalog.when<List<Widget>>(
      skipLoadingOnRefresh: false,
      loading: () => [SliverToBoxAdapter(child: PluginsLoading(l10n.pluginsMarketLoading))],
      error: (error, _) => [
        SliverToBoxAdapter(
          child: PluginsErrorCard(
            title: l10n.pluginsMarketLoadFailed,
            message: error is MarketFetchException ? error.message : l10n.pluginsMarketInvalid,
            onRetry: () => ref.invalidate(marketCatalogProvider),
          ),
        ),
      ],
      data: (catalog) {
        final results = filterMarket(catalog, filter);
        final hidden = hiddenWebOnlyCount(catalog, filter);
        final categories = [
          for (final c in catalog.categories)
            if (filter.showWebOnly ||
                filter.category == c.id ||
                catalog.entries.any((e) => e.plugin.category == c.id && !e.webOnly))
              c,
        ];
        return [
          SliverToBoxAdapter(
            child: SizedBox(
              height: 52,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                children: [
                  _CategoryChip(
                    label: l10n.pluginsAll,
                    selected: filter.category == null,
                    onSelected: () => ref.read(marketFilterProvider.notifier).setCategory(null),
                  ),
                  for (final c in categories)
                    _CategoryChip(
                      label: c.title.resolve(Localizations.localeOf(context).languageCode),
                      selected: filter.category == c.id,
                      onSelected: () =>
                          ref.read(marketFilterProvider.notifier).setCategory(filter.category == c.id ? null : c.id),
                    ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      (official.value?.entries.isNotEmpty ?? false)
                          ? l10n.marketCombinedCount(results.length)
                          : l10n.pluginsMarketCount(results.length),
                      style: AppType.tabular(theme.textTheme.bodySmall!.copyWith(color: colors.textTertiary)),
                    ),
                  ),
                  if (hidden > 0 || filter.showWebOnly)
                    TextButton(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 32),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        textStyle: theme.textTheme.labelMedium,
                      ),
                      onPressed: () => ref.read(marketFilterProvider.notifier).setShowWebOnly(!filter.showWebOnly),
                      child: Text(filter.showWebOnly ? l10n.pluginsHideWeb : l10n.pluginsShowWebCount(hidden)),
                    ),
                ],
              ),
            ),
          ),
          if (results.isEmpty)
            SliverToBoxAdapter(
              child: EmptyView(
                icon: AppIcons.noResults,
                title: filter.query.trim().isEmpty
                    ? l10n.pluginsNoCategoryPlugins
                    : l10n.pluginsNoSearchResults(filter.query.trim()),
                padding: const EdgeInsets.fromLTRB(32, 32, 32, 24),
              ),
            )
          else
            _cards(results),
        ];
      },
    );

    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(child: searchField),
        ...section(MarketSection.official, l10n.marketSectionOfficial),
        ...section(MarketSection.adapted, l10n.marketSectionAdapted),
        SliverToBoxAdapter(child: _SectionTitle(l10n.marketSectionAll)),
        ...body,
        const SliverToBoxAdapter(child: _SubmitPlugin()),
      ],
    );
  }

  /// One card in segments, so rows stay lazily built.
  static Widget _cards(List<MarketEntry> entries) => SliverList.builder(
    itemCount: entries.length,
    itemBuilder: (context, i) {
      final first = i == 0;
      final last = i == entries.length - 1;
      return FadeSlideIn(
        index: i,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Material(
            color: DshSurfaces.of(context).card.fill,
            clipBehavior: Clip.antiAlias,
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.vertical(
                top: first ? AppShape.radiusLg.topLeft : Radius.zero,
                bottom: last ? AppShape.radiusLg.bottomLeft : Radius.zero,
              ),
            ),
            child: Padding(
              padding: EdgeInsets.only(top: first ? 4 : 0, bottom: last ? 4 : 0),
              child: MarketCard(key: ValueKey(entries[i].name), entry: entries[i]),
            ),
          ),
        ),
      );
    },
  );
}

/// A section's small faint title, on the page's 24 column.
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
    child: Semantics(header: true, child: Text(text, style: groupTitleStyle(context))),
  );
}

/// What an official section says instead of cards: 暂无, still loading, or
/// that it didn't load (with 重试). One quiet line, not an empty-state block:
/// 全部 below still works.
class _SectionNote extends StatelessWidget {
  const _SectionNote(this.text, {this.action, this.onAction});

  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 16, 0),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 32),
        child: Row(
          children: [
            Expanded(
              child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary)),
            ),
            if (action case final action?)
              TextButton(
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  textStyle: theme.textTheme.labelMedium,
                ),
                onPressed: onAction,
                child: Text(action),
              ),
          ],
        ),
      ),
    );
  }
}

/// The market repository's submission guide (GitHub), at the bottom.
const marketSubmitUrl = 'https://github.com/ccch1mneyyy/dsh-go-market#提交插件';

class _SubmitPlugin extends StatelessWidget {
  const _SubmitPlugin();

  Future<void> _open(BuildContext context) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final uri = Uri.parse(marketSubmitUrl);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      messenger?.showSnackBar(SnackBar(content: Text(l10n.hubPluginBrowserFailed(uri.host))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: ListPageCard(
        children: [
          ListPageRow(
            icon: AppIcons.add,
            title: l10n.marketSubmit,
            subtitle: l10n.marketSubmitHint,
            chevron: true,
            onTap: () => unawaited(_open(context)),
          ),
        ],
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({required this.label, required this.selected, required this.onSelected});

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: CapsuleChoiceChip(label: label, selected: selected, onSelected: onSelected),
  );
}

/// One market entry, app-store style: icon · name / author · one line ·
/// the 获取 capsule, inside the lazily built segmented card.
class MarketCard extends ConsumerWidget {
  const MarketCard({super.key, required this.entry});

  final MarketEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    final locale = Localizations.localeOf(context).languageCode;
    final plugin = entry.plugin;
    final bundles = ref.watch(installedPluginsProvider.select((s) => s.value));
    final job = ref.watch(pluginInstallsProvider.select((jobs) => jobs[plugin.name]));
    final status = marketInstallStatus(plugin, bundles);
    final title = entry.title(locale);
    final description = entry.summary(locale);
    final failed = job != null && job.phase == PluginInstallPhase.failed ? job.failure : null;
    final line = failed != null ? l10n.pluginsFailureDetails(failed.title) : [?plugin.author, ?description].join(' · ');
    final badges = [
      ...marketEntryBadges(context, entry),
      if (entry.featured) PluginBadge(l10n.pluginsFeatured, tone: PluginBadgeTone.featured),
    ];
    void open() => unawaited(showMarketPluginSheet(context, entry));

    // Official cards carry two labels, which need their own wrapping line
    // so translated labels never squeeze out the plugin's name.
    if (entry.listing != null) {
      return InkWell(
        onTap: open,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PluginAvatar(name: plugin.name, title: title, icon: plugin.icon),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: pluginRowTitle(context)),
                    if (line.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        line,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: failed != null ? colors.danger : colors.textTertiary),
                      ),
                    ],
                    if (badges.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(spacing: 4, runSpacing: 4, children: badges),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              PluginInstallButton(status: status, job: job, onPressed: open),
            ],
          ),
        ),
      );
    }

    return ListPageRow(
      leading: PluginAvatar(name: plugin.name, title: title, icon: plugin.icon),
      leadingWidth: 40,
      title: title,
      titleStyle: pluginRowTitle(context),
      badge: badges.isEmpty ? null : Row(mainAxisSize: MainAxisSize.min, spacing: 4, children: badges),
      subtitle: line.isEmpty ? null : line,
      subtitleColor: failed != null ? colors.danger : null,
      trailing: PluginInstallButton(status: status, job: job, onPressed: open),
      onTap: open,
    );
  }
}
