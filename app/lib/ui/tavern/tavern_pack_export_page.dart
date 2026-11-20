// Two-step exports (STAGE3-APP-INTEGRATION §7): a card with chosen pack
// resources folded in, or a new .dshpack from a draft. First 预览 shows what
// would be written and what blocks it; 导出 then takes exactly that request.
// Changing anything asks for a new preview.

import 'dart:async';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_packs.dart';
import '../../tavern/tavern_provider.dart';
import '../common/brief_notice.dart';
import '../features/feature_kit.dart' show QuietSpinner;
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import 'tavern_chat_files.dart' show tavernChatFileName;
import 'tavern_pack_widgets.dart';
import 'tavern_widgets.dart' show tavernCardFileName, tavernCardSinkProvider;

/// A preview and the request it was made for.
typedef _Previewed = ({TavernGameplayExportRequest request, TavernGameplayExportPreview preview});

/// The preview's findings and the 导出 button: shared by both exports.
mixin _TwoStep<W extends ConsumerStatefulWidget> on ConsumerState<W> {
  _Previewed? previewed;
  bool busy = false;

  /// Counts changes, so a preview asked for before one is not shown after it.
  int _edits = 0;

  TavernGameplayExportRequest request();
  Future<Uint8List> produce(TavernGameplayExportRequest request, String previewId);

  /// Hands on [bytes] made for [request] (its format and names, not the
  /// form's as it is now).
  Future<void> deliver(TavernGameplayExportRequest request, Uint8List bytes);

  void changed(VoidCallback change) => setState(() {
    change();
    _edits++;
    previewed = null;
  });

  Future<void> preview() async {
    final l10n = context.l10n;
    final r = request();
    final asked = _edits;
    setState(() => busy = true);
    try {
      final p = await ref.read(tavernProvider).previewGameplayExport(r);
      if (mounted && asked == _edits) setState(() => previewed = (request: r, preview: p));
    } on Object catch (e) {
      if (mounted) showBriefNotice(context, tavernPackErrorText(l10n, e));
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> export() async {
    final l10n = context.l10n;
    final p = previewed!;
    setState(() => busy = true);
    try {
      final bytes = await produce(p.request, p.preview.previewId);
      if (!mounted) return;
      await deliver(p.request, bytes);
    } on TavernGameplayException catch (e) {
      // The sources moved, or something now blocks: look again first.
      if (mounted) setState(() => previewed = null);
      if (mounted) {
        final issues = [for (final i in e.details['issues'] as List<Object?>? ?? const []) i! as Map<String, Object?>];
        if (issues.isEmpty) {
          showBriefNotice(context, tavernPackErrorText(l10n, e));
        } else {
          unawaited(showTavernPackIssues(context, title: l10n.tavernPackExportBlocked, issues: issues));
        }
      }
    } on Object catch (e) {
      if (mounted) showBriefNotice(context, tavernPackErrorText(l10n, e));
    }
    if (mounted) setState(() => busy = false);
  }

  List<Widget> findings(L10n l10n) {
    final p = previewed?.preview;
    final blocking = p?.issues.any(tavernPackIssueBlocking) ?? true;
    return [
      if (p != null)
        SettingsSection(
          key: const ValueKey('tavern-pack-export-findings'),
          title: l10n.tavernPackExportFindings,
          footer: Text(l10n.tavernPackExportMappings(p.idMappings.length, p.resourceMappings.length)),
          children: p.issues.isEmpty
              ? [Padding(padding: const EdgeInsets.all(16), child: Text(l10n.tavernPackNothingNoted))]
              : [
                  for (final issue in p.issues)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: TavernPackIssueText(issue),
                    ),
                ],
        ),
      SettingsSection(
        children: [
          SettingsTile(
            key: const ValueKey('tavern-pack-export-preview'),
            icon: AppIcons.preview,
            tinted: false,
            title: l10n.tavernPackPreview,
            trailing: busy ? const QuietSpinner() : null,
            chevron: false,
            onTap: busy ? null : () => unawaited(preview()),
          ),
          SettingsTile(
            key: const ValueKey('tavern-pack-export-go'),
            icon: AppIcons.share,
            tinted: false,
            title: l10n.tavernPackExportGo,
            subtitle: p == null ? l10n.tavernPackExportPreviewFirst : (blocking ? l10n.tavernPackExportBlocked : null),
            chevron: false,
            onTap: busy || blocking ? null : () => unawaited(export()),
          ),
        ],
      ),
    ];
  }
}

/// A character's card with the chosen resources of its active packs.
class TavernPackCardExportPage extends ConsumerStatefulWidget {
  const TavernPackCardExportPage({super.key, required this.character, this.chatId});

  final TavernCharacter character;
  final String? chatId;

  static Route<void> route(TavernCharacter character, {String? chatId}) => MaterialPageRoute<void>(
    builder: (_) => TavernPackCardExportPage(character: character, chatId: chatId),
  );

  @override
  ConsumerState<TavernPackCardExportPage> createState() => _TavernPackCardExportPageState();
}

/// A resource the card can take: a binding's lorebook, regex or asset.
typedef _Offer = ({String bindingId, String localId, String kind, String pack});

class _TavernPackCardExportPageState extends ConsumerState<TavernPackCardExportPage>
    with _TwoStep<TavernPackCardExportPage> {
  var _format = TavernCardFormat.png;
  var _copyMedia = false;
  final _chosen = <(String, String)>{};
  late final Future<List<_Offer>> _offers = _load();

  /// The active bindings of the scopes this card's chats use, and what of
  /// their exact versions a card can carry.
  Future<List<_Offer>> _load() async {
    final tavern = ref.read(tavernProvider);
    final scopes = [
      const TavernPackScopeTarget(kind: TavernGameplayScope.global),
      TavernPackScopeTarget(kind: TavernGameplayScope.character, targetId: widget.character.id),
      if (widget.chatId case final chat?) TavernPackScopeTarget(kind: TavernGameplayScope.chat, targetId: chat),
    ];
    final offers = <_Offer>[];
    for (final scope in scopes) {
      for (final b in (await tavern.readGameplayBindings(scope)).bindings) {
        if (!b.enabled || b.removed) continue;
        final version = await tavern.readGameplayPack(b.packRef);
        if (version == null) continue;
        for (final r in tavernPackResources(version)) {
          if (const {'lorebook', 'regex', 'asset'}.contains(r['kind'])) {
            offers.add((
              bindingId: b.bindingId,
              localId: r['localId']! as String,
              kind: r['kind']! as String,
              pack: tavernPackTitle(version),
            ));
          }
        }
      }
    }
    return offers;
  }

  @override
  TavernGameplayExportRequest request() => TavernGameplayExportRequest.character(
    context: TavernGameplayContext(characterId: widget.character.id, chatId: widget.chatId),
    format: _format,
    at: DateTime.now(),
    packResources: [
      for (final (binding, local) in _chosen) TavernGameplayPackResourceRef(bindingId: binding, localId: local),
    ],
    copyCardMedia: _copyMedia,
  );

  @override
  Future<Uint8List> produce(TavernGameplayExportRequest request, String previewId) =>
      ref.read(tavernProvider).exportCharacterWithPacks(request, expectedPreviewId: previewId);

  @override
  Future<void> deliver(TavernGameplayExportRequest request, Uint8List bytes) {
    final format = request.format!;
    return ref.read(tavernCardSinkProvider)(tavernCardFileName(widget.character.name, format), bytes, switch (format) {
      TavernCardFormat.png => 'image/png',
      TavernCardFormat.json => 'application/json',
      TavernCardFormat.charx => 'application/zip',
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AppPage.list(
      title: l10n.tavernPackCardExport,
      subtitle: Text(l10n.tavernPackCardExportSubtitle),
      children: [
        SettingsSection(
          children: [
            SettingsSegmentTile<TavernCardFormat>(
              key: const ValueKey('tavern-pack-export-format'),
              title: l10n.tavernPackExportFormat,
              tinted: false,
              segments: const [
                PillSegment(TavernCardFormat.png, 'PNG'),
                PillSegment(TavernCardFormat.json, 'JSON'),
                PillSegment(TavernCardFormat.charx, 'CHARX'),
              ],
              selected: _format,
              onChanged: (value) => changed(() => _format = value),
            ),
            SettingsSwitchTile(
              key: const ValueKey('tavern-pack-export-media'),
              tinted: false,
              title: l10n.tavernPackExportCopyMedia,
              value: _copyMedia,
              onChanged: (value) => changed(() => _copyMedia = value),
            ),
          ],
        ),
        FutureBuilder<List<_Offer>>(
          future: _offers,
          builder: (context, snap) => SettingsSection(
            key: const ValueKey('tavern-pack-export-resources'),
            title: l10n.tavernPackResources,
            footer: Text(l10n.tavernPackExportFlattenNote),
            children: switch (snap.data) {
              null => [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: snap.hasError ? Text(tavernPackErrorText(l10n, snap.error!)) : const QuietSpinner(),
                ),
              ],
              [] => [Padding(padding: const EdgeInsets.all(16), child: Text(l10n.tavernPackExportNoResources))],
              final offers => [
                for (final o in offers)
                  SettingsSwitchTile(
                    key: ValueKey('tavern-pack-export-${o.bindingId}-${o.localId}'),
                    tinted: false,
                    title: o.localId,
                    subtitle: '${o.pack} · ${o.kind}',
                    value: _chosen.contains((o.bindingId, o.localId)),
                    onChanged: (on) => changed(
                      () => on ? _chosen.add((o.bindingId, o.localId)) : _chosen.remove((o.bindingId, o.localId)),
                    ),
                  ),
              ],
            },
          ),
        ),
        ...findings(l10n),
      ],
    );
  }
}

/// A new .dshpack from a draft: its character's declarations and changes,
/// the chosen lorebooks as resources. Installing it is a separate step.
class TavernPackDraftExportPage extends ConsumerStatefulWidget {
  const TavernPackDraftExportPage({super.key, required this.draft, required this.cardResourceId});

  final TavernAuthoringDraft draft;

  /// The draft's character source the pack is made from.
  final String cardResourceId;

  static Route<void> route(TavernAuthoringDraft draft, String cardResourceId) => MaterialPageRoute<void>(
    builder: (_) => TavernPackDraftExportPage(draft: draft, cardResourceId: cardResourceId),
  );

  @override
  ConsumerState<TavernPackDraftExportPage> createState() => _TavernPackDraftExportPageState();
}

class _TavernPackDraftExportPageState extends ConsumerState<TavernPackDraftExportPage>
    with _TwoStep<TavernPackDraftExportPage> {
  late final _packId = TextEditingController(text: _defaultId)..addListener(_changed);
  final _version = TextEditingController(text: '1');
  final _roots = TextEditingController();
  final _books = <String>{};
  Uint8List? _made;

  TavernAuthoringSource get _card =>
      widget.draft.sources.firstWhere((s) => s.physicalResourceId == widget.cardResourceId);

  String get _defaultId => switch (_card.base['data']) {
    {'name': final String name} when name.trim().isNotEmpty => name.trim(),
    _ => 'pack',
  };

  void _changed() => changed(() => _made = null);

  @override
  void initState() {
    super.initState();
    _version.addListener(_changed);
    _roots.addListener(_changed);
  }

  @override
  void dispose() {
    _packId.dispose();
    _version.dispose();
    _roots.dispose();
    super.dispose();
  }

  List<TavernAuthoringSource> get _lorebooks => [
    for (final s in widget.draft.sources)
      if (s.target.kind == TavernAuthoringTargetKind.lorebook) s,
  ];

  @override
  TavernGameplayExportRequest request() {
    final books = [
      for (final s in _lorebooks)
        if (_books.contains(s.physicalResourceId)) s,
    ];
    return TavernGameplayExportRequest.packFromDraft(
      draftId: widget.draft.id,
      draftRevision: widget.draft.draftRevision,
      physicalResourceId: _card.physicalResourceId,
      changeIds: [for (final c in widget.draft.changes) c.id],
      packId: _packId.text.trim(),
      packVersion: _version.text.trim(),
      schemaRoots: [
        for (final root in _roots.text.split(RegExp(r'[\s,，]+')))
          if (root.isNotEmpty) root,
      ],
      draftResources: [
        for (final (i, s) in books.indexed)
          TavernGameplayDraftResource.json(
            physicalResourceId: s.physicalResourceId,
            pointer: '',
            localId: 'lorebook-${i + 1}',
            kind: 'lorebook',
            path: 'lorebooks/${i + 1}.json',
          ),
      ],
      at: DateTime.now(),
    );
  }

  @override
  Future<Uint8List> produce(TavernGameplayExportRequest request, String previewId) =>
      ref.read(tavernProvider).exportGameplayPackFromDraft(request, expectedPreviewId: previewId);

  @override
  Future<void> deliver(TavernGameplayExportRequest request, Uint8List bytes) async {
    // Changed while it was being made (the preview is gone): still handed
    // on as asked, but not offered to install for the form as it is now.
    if (previewed != null) setState(() => _made = bytes);
    await ref.read(tavernCardSinkProvider)(
      tavernChatFileName('${request.packId} ${request.packVersion}', extension: 'dshpack'),
      bytes,
      'application/zip',
    );
  }

  Future<void> _install() async {
    final l10n = context.l10n;
    try {
      final result = await ref.read(tavernProvider).importGameplayPack(_made!);
      if (!mounted) return;
      ref.invalidate(tavernPacksProvider);
      showBriefNotice(context, l10n.tavernPackInstalled(tavernPackTitle(result.version), result.ref.packVersion));
    } on Object catch (e) {
      if (mounted) showBriefNotice(context, tavernPackErrorText(l10n, e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    Widget field(Key key, TextEditingController controller, String label, {String? hint}) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: TextField(
        key: key,
        controller: controller,
        decoration: InputDecoration(labelText: label, hintText: hint),
      ),
    );
    return AppPage.list(
      title: l10n.tavernPackDraftExport,
      subtitle: Text(l10n.tavernPackDraftExportSubtitle(widget.draft.changes.length)),
      children: [
        SettingsSection(
          children: [
            field(const ValueKey('tavern-pack-draft-id'), _packId, l10n.tavernPackDraftId),
            field(const ValueKey('tavern-pack-draft-version'), _version, l10n.tavernPackVersion),
            field(
              const ValueKey('tavern-pack-draft-roots'),
              _roots,
              l10n.tavernPackDraftRoots,
              hint: l10n.tavernPackDraftRootsHint,
            ),
          ],
        ),
        if (_lorebooks.isNotEmpty)
          SettingsSection(
            title: l10n.tavernPackResources,
            children: [
              for (final s in _lorebooks)
                SettingsSwitchTile(
                  key: ValueKey('tavern-pack-draft-book-${s.physicalResourceId}'),
                  tinted: false,
                  title: switch (s.base['name']) {
                    final String name => name,
                    _ => l10n.tavernLorebook,
                  },
                  value: _books.contains(s.physicalResourceId),
                  onChanged: (on) => changed(() {
                    on ? _books.add(s.physicalResourceId) : _books.remove(s.physicalResourceId);
                    _made = null;
                  }),
                ),
            ],
          ),
        ...findings(l10n),
        if (_made != null)
          SettingsSection(
            children: [
              SettingsTile(
                key: const ValueKey('tavern-pack-draft-install'),
                icon: AppIcons.download,
                tinted: false,
                title: l10n.tavernPackInstallMade,
                subtitle: l10n.tavernPackAddNote,
                chevron: false,
                onTap: () => unawaited(_install()),
              ),
            ],
          ),
      ],
    );
  }
}
