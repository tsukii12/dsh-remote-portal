// The `@` picker's state, after DSH's `dsh-client-ui-reference` source: files
// first, then the current conversation's subagents, then other conversations;
// one domain failing leaves the others listed.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../l10n/l10n.dart';
import '../../../state/mention_state.dart';
import 'mention_syntax.dart';
import 'mention_text_controller.dart';

/// One row of the picker.
class MentionItem {
  const MentionItem({
    required this.key,
    required this.kind,
    required this.label,
    required this.mention,
    this.detail,
    this.path,
    this.sessionId,
    this.subagent = false,
  });

  /// `f:<path>` or `s:<sessionId>`.
  final String key;
  final MentionKind kind;

  /// File name, `folder/`, or the conversation title.
  final String label;

  /// Parent folder, or the conversation's age (and workspace when it is
  /// another one).
  final String? detail;

  /// What goes into the prompt.
  final String mention;

  /// Files and folders: the path relative to the workspace.
  final String? path;
  final String? sessionId;
  final bool subagent;

  bool get drillable => kind == MentionKind.folder;
}

/// A titled group of rows.
class MentionSection {
  const MentionSection(this.title, this.items);
  final String title;
  final List<MentionItem> items;
}

/// `@` 面板的状态:跟着输入框里光标所在的 `@` 词,查候选、排序、选中。
///
/// 只有一个 `@` 时列出各类的前几项(「最近」在最前);继续打字就过滤
/// (文件由引擎模糊匹配,对话在本地模糊匹配并补上引擎的子串结果)。
/// 打了字时第一行是"发送"会选中的那一行。
class MentionPickerController extends ChangeNotifier {
  MentionPickerController({
    required this.input,
    required this.source,
    required this.sessionId,
    required this.localSessions,
    required this.recents,
    this.debounce = const Duration(milliseconds: 120),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    input.addListener(_onInput);
    // Sent bubbles show a conversation reference as `@title`: know the
    // titles before the first `@`.
    unawaited(
      _local().then((list) {
        final titles = [
          for (final s in list)
            if (s.title?.trim() case final t? when t.isNotEmpty) t,
        ];
        MentionLabels.addAll(titles);
      }),
    );
  }

  final MentionTextController input;
  final MentionSource? Function() source;
  final String? Function() sessionId;

  /// The visible (not archived, not subagent) conversations of this host.
  final Future<List<SessionSummary>> Function() localSessions;
  final MentionRecents recents;
  final Duration debounce;
  final DateTime Function() _clock;

  MentionQuery? _query;
  int? _dismissedAt;
  List<MentionSection> _sections = const [];
  int _highlight = -1;
  bool _loading = false;
  Timer? _timer;
  int _generation = 0;

  // Per conversation: the session list and the unfiltered candidates, read
  // once per opening.
  String? _cacheFor;
  Future<List<SessionSummary>>? _allSessions;
  Future<List<SessionReferenceCandidate>>? _baseCandidates;

  /// The workspace of the last listing (recent files belong to it).
  String? _lastCwd;

  MentionQuery? get query => _query;

  bool get isOpen => _query != null && _dismissedAt != _query!.start;

  bool get loading => _loading;

  List<MentionSection> get sections => _sections;

  List<MentionItem> get items => [for (final s in _sections) ...s.items];

  /// Index into [items] that sending / Enter picks; -1 for none.
  int get highlighted => _highlight;

  MentionItem? get highlightedItem {
    final all = items;
    return _highlight >= 0 && _highlight < all.length ? all[_highlight] : null;
  }

  void _onInput() {
    final selection = input.selection;
    final next = selection.isValid && selection.isCollapsed
        ? activeMentionQuery(input.text, selection.baseOffset, tokens: input.tokens)
        : null;
    if (next == _query) return;
    final wasOpen = isOpen;
    final previous = _query;
    _query = next;
    if (next == null) {
      _timer?.cancel();
      _generation++;
      _loading = false;
      _dismissedAt = null;
      _cacheFor = null;
      if (wasOpen) notifyListeners();
      return;
    }
    if (previous == null || previous.start != next.start) {
      _dismissedAt = null;
    }
    if (previous != null &&
        previous.start == next.start &&
        previous.query == next.query &&
        previous.quoted == next.quoted) {
      // Only the caret's bookkeeping changed.
      return;
    }
    // Closed with Esc: nothing to look up until the next `@`.
    if (_dismissedAt == next.start) return;
    // The old rows belong to the previous query, including while typing
    // is debounced or the next lookup is still pending.
    _sections = const [];
    _highlight = -1;
    _loading = true;
    _timer?.cancel();
    final generation = ++_generation;
    // The first listing goes out at once; typing is debounced.
    if (previous == null || previous.start != next.start) {
      unawaited(_fetch(next, generation));
    } else {
      _timer = Timer(debounce, () => unawaited(_fetch(next, generation)));
    }
    notifyListeners();
  }

  Future<void> _fetch(MentionQuery q, int generation) async {
    final src = source();
    final sid = sessionId();
    ({List<MentionSection> sections, String? cwd}) result;
    try {
      result = await _lookup(src, sid, q);
    } catch (_) {
      result = (sections: const <MentionSection>[], cwd: null);
    }
    if (generation != _generation) return;
    _sections = result.sections;
    _lastCwd = result.cwd;
    _loading = false;
    final count = items.length;
    _highlight = q.query.isEmpty || count == 0 ? -1 : 0;
    notifyListeners();
  }

  Future<({List<MentionSection> sections, String? cwd})> _lookup(
    MentionSource? src,
    String? sid,
    MentionQuery q,
  ) async {
    final now = _clock();
    if (src == null) return (sections: const <MentionSection>[], cwd: null);
    if (sid == null) {
      // A new chat has no workspace yet: other conversations only, built
      // from the local list.
      if (q.pathOnly) return (sections: const <MentionSection>[], cwd: null);
      final rows = <(MentionItem, double, DateTime)>[];
      for (final s in await _local()) {
        final title = _titleOf(s);
        final score = fuzzyScore(title, q.query);
        if (score == null) continue;
        rows.add((
          MentionItem(
            key: 's:${s.sessionId}',
            kind: MentionKind.session,
            label: title,
            detail: mentionAge(s.updatedAt, now),
            mention: formatSessionMention(s.sessionId, title),
            sessionId: s.sessionId,
          ),
          score,
          s.updatedAt,
        ));
      }
      final conversations = _rank(rows, q.query.isEmpty);
      MentionLabels.addAll(conversations.map((i) => i.label));
      return (
        sections: _assemble(
          q,
          files: const [],
          subagents: const [],
          conversations: conversations,
          cwd: null,
          sid: null,
        ),
        cwd: null,
      );
    }

    if (_cacheFor != sid) {
      _cacheFor = sid;
      _allSessions = src.allSessions().catchError((_) => <SessionSummary>[]);
      _baseCandidates = src.sessions(sid, '').catchError((_) => <SessionReferenceCandidate>[]);
    }
    final filesFuture = src.files(sid, q.query).catchError((_) => <FileReferenceCandidate>[]);
    final typedFuture = q.pathOnly || q.query.isEmpty
        ? Future.value(const <SessionReferenceCandidate>[])
        : src.sessions(sid, q.query).catchError((_) => <SessionReferenceCandidate>[]);
    final files = await filesFuture;
    final all = await _allSessions!;
    final base = q.pathOnly ? const <SessionReferenceCandidate>[] : await _baseCandidates!;
    final typed = await typedFuture;

    final byId = {for (final s in all) s.sessionId: s};
    final cwd = byId[sid]?.cwd;
    final visible = {for (final s in await _local()) s.sessionId};

    final fileItems = <MentionItem>[
      for (final c in files)
        if (formatFileMention(c.path, directory: c.isDirectory, preserveQuote: q.quoted) case final mention?)
          MentionItem(
            key: 'f:${c.path}',
            kind: c.isDirectory ? MentionKind.folder : MentionKind.file,
            label: c.isDirectory ? '${c.name}/' : c.name,
            detail: q.query.contains('/') || c.parent.isEmpty ? null : c.parent,
            mention: mention,
            path: c.path,
          ),
    ];

    final subagentRows = <(MentionItem, double, DateTime)>[];
    final conversationRows = <(MentionItem, double, DateTime)>[];
    final seen = <String>{};
    for (final c in [...base, ...typed]) {
      if (!seen.add(c.sessionId)) continue;
      final summary = byId[c.sessionId];
      final child = summary?.origin == 'subagent' && summary?.parentSessionId == sid;
      if (!child) {
        // Other conversations' subagents and archived conversations stay out.
        if (summary?.origin == 'subagent') continue;
        if (visible.isNotEmpty && !visible.contains(c.sessionId)) continue;
      }
      final title = c.title;
      final fromServer = typed.any((t) => t.sessionId == c.sessionId);
      final score = fuzzyScore(title, q.query) ?? (fromServer ? 100.0 : null);
      if (score == null) continue;
      final when = summary?.updatedAt ?? c.createdAt;
      final age = mentionAge(when, now);
      final place = c.sameWorkspace || c.cwd == null ? null : _basename(c.cwd!);
      final item = MentionItem(
        key: 's:${c.sessionId}',
        kind: MentionKind.session,
        label: title,
        detail: place == null ? age : '$place · $age',
        mention: c.mention,
        sessionId: c.sessionId,
        subagent: child,
      );
      (child ? subagentRows : conversationRows).add((item, score, when));
    }
    final subagents = _rank(subagentRows, q.query.isEmpty);
    final conversations = _rank(conversationRows, q.query.isEmpty);
    MentionLabels.addAll([
      for (final i in [...subagents, ...conversations]) i.label,
    ]);
    return (
      sections: _assemble(
        q,
        files: _boost(fileItems),
        subagents: subagents,
        conversations: conversations,
        cwd: cwd,
        sid: sid,
      ),
      cwd: cwd,
    );
  }

  Future<List<SessionSummary>> _local() async {
    try {
      return await localSessions().timeout(const Duration(seconds: 5));
    } catch (_) {
      return const [];
    }
  }

  /// Recent picks first, then (typed) best match, then newest.
  List<MentionItem> _rank(List<(MentionItem, double, DateTime)> rows, bool byTime) {
    rows.sort((a, b) {
      final ra = recents.rank(a.$1.key);
      final rb = recents.rank(b.$1.key);
      if (ra != null || rb != null) {
        if (ra == null) return 1;
        if (rb == null) return -1;
        return ra.compareTo(rb);
      }
      if (!byTime) {
        final byScore = b.$2.compareTo(a.$2);
        if (byScore != 0) return byScore;
      }
      return b.$3.compareTo(a.$3);
    });
    return [for (final r in rows) r.$1];
  }

  /// The Host's file order, with recent picks moved to the front.
  List<MentionItem> _boost(List<MentionItem> items) {
    final recent = items.where((i) => recents.rank(i.key) != null).toList()
      ..sort((a, b) => recents.rank(a.key)!.compareTo(recents.rank(b.key)!));
    return [...recent, ...items.where((i) => recents.rank(i.key) == null)];
  }

  List<MentionSection> _assemble(
    MentionQuery q, {
    required List<MentionItem> files,
    required List<MentionItem> subagents,
    required List<MentionItem> conversations,
    required String? cwd,
    required String? sid,
  }) {
    if (q.query.isNotEmpty || q.pathOnly) {
      return [
        if (files.isNotEmpty) MentionSection(appL10n.chatFile, files),
        if (subagents.isNotEmpty) MentionSection(appL10n.chatSubagent, subagents),
        if (conversations.isNotEmpty) MentionSection(appL10n.chatChat, conversations.take(20).toList()),
      ];
    }
    // A bare `@`: what was picked lately, then a few of each.
    final candidates = [...files, ...subagents, ...conversations];
    final recent = <MentionItem>[];
    for (final entry in recents.entries) {
      if (recent.length == 3) break;
      if (entry.key.startsWith('f:') && entry.cwd != cwd) continue;
      if (entry.key == 's:$sid') continue;
      final match = candidates.where((i) => i.key == entry.key).firstOrNull;
      if (match != null) recent.add(match);
    }
    final taken = {for (final i in recent) i.key};
    List<MentionItem> rest(List<MentionItem> list, int n) => [
      for (final i in list)
        if (!taken.contains(i.key)) i,
    ].take(n).toList();
    final f = rest(files, 5);
    final s = rest(subagents, 4);
    final c = rest(conversations, 8);
    return [
      if (recent.isNotEmpty) MentionSection(appL10n.chatRecent, recent),
      if (f.isNotEmpty) MentionSection(appL10n.chatFile, f),
      if (s.isNotEmpty) MentionSection(appL10n.chatSubagent, s),
      if (c.isNotEmpty) MentionSection(appL10n.chatChat, c),
    ];
  }

  /// Puts [item] into the draft as a reference chip.
  void pick(MentionItem item) {
    if (!_canSelect(item)) return;
    final q = _query!;
    HapticFeedback.selectionClick();
    final sid = sessionId();
    recents.record(
      MentionRecent(
        key: item.key,
        mention: item.mention,
        cwd: item.path == null ? null : _lastCwd,
        sessionId: item.sessionId ?? sid,
      ),
    );
    if (item.kind == MentionKind.session) MentionLabels.add(item.label);
    input.insertMention(item.mention, start: q.start, end: q.end);
  }

  /// Opens [item] (a folder) in the picker instead of picking it.
  void drill(MentionItem item) {
    if (!item.drillable || !_canSelect(item)) return;
    final q = _query!;
    HapticFeedback.selectionClick();
    final text = input.text;
    final next = text.replaceRange(q.start, q.end, item.mention);
    final caret = q.start + item.mention.length;
    input.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: caret),
    );
  }

  // A row callback can outlive its rendered batch, even when a new batch
  // contains an item with the same path or session key.
  bool _canSelect(MentionItem item) =>
      isOpen && _sections.any((section) => section.items.any((current) => identical(current, item)));

  /// Sending while the picker shows a typed query picks the marked row.
  bool pickHighlighted() {
    if (!isOpen || _query!.query.isEmpty) return false;
    final item = highlightedItem;
    if (item == null) return false;
    pick(item);
    return true;
  }

  /// Hides the picker until the caret leaves this `@` word.
  void dismiss() {
    final q = _query;
    if (q == null || _dismissedAt == q.start) return;
    _dismissedAt = q.start;
    notifyListeners();
  }

  /// Hardware keys while the picker is open: ↑ ↓ move, Enter / Tab pick
  /// (Tab opens a folder), Esc closes.
  KeyEventResult handleKey(FocusNode node, KeyEvent event) {
    if (!isOpen || event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final all = items;
    if (key == LogicalKeyboardKey.escape) {
      dismiss();
      return KeyEventResult.handled;
    }
    if (all.isEmpty) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.arrowDown) {
      _highlight = (_highlight + 1) % all.length;
      notifyListeners();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _highlight = _highlight <= 0 ? all.length - 1 : _highlight - 1;
      notifyListeners();
      return KeyEventResult.handled;
    }
    final item = highlightedItem;
    if (item == null || event is KeyRepeatEvent) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.tab && item.drillable) {
      drill(item);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter || key == LogicalKeyboardKey.tab) {
      pick(item);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _timer?.cancel();
    input.removeListener(_onInput);
    super.dispose();
  }
}

String _titleOf(SessionSummary s) {
  final title = s.title?.trim();
  return title == null || title.isEmpty ? s.sessionId : title;
}

String _basename(String path) {
  final parts = path.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty);
  return parts.isEmpty ? path : parts.last;
}
