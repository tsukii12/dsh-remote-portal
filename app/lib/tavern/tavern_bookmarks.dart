// 书签 (docs/design/roleplay-roadmap.md P1, 分支树和书签): lines of a chat you
// want to find again, kept on this phone per chat. Going to one switches to
// its branch and scrolls there (tavern_jump.dart).

import 'dart:async';
import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TavernBookmark {
  const TavernBookmark({
    required this.nodeId,
    required this.siblingIndex,
    required this.speaker,
    required this.preview,
    required this.at,
  });

  factory TavernBookmark.of(TavernMessage m) => TavernBookmark(
    nodeId: m.nodeId,
    siblingIndex: m.siblingIndex,
    speaker: m.speaker,
    preview: m.text.trim().split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => '').trim(),
    at: m.at,
  );

  static TavernBookmark? fromJson(Object? json) {
    if (json is! Map) return null;
    final nodeId = json['nodeId'];
    if (nodeId is! String || nodeId.isEmpty) return null;
    return TavernBookmark(
      nodeId: nodeId,
      siblingIndex: (json['siblingIndex'] as num?)?.toInt() ?? 0,
      speaker: json['speaker'] as String? ?? '',
      preview: json['preview'] as String? ?? '',
      at: DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  final String nodeId;

  /// Its place among its siblings, for switching to its branch.
  final int siblingIndex;
  final String speaker;

  /// Its first line, as it read when marked.
  final String preview;
  final DateTime at;

  Map<String, Object?> toJson() => {
    'nodeId': nodeId,
    'siblingIndex': siblingIndex,
    'speaker': speaker,
    'preview': preview,
    'at': at.toIso8601String(),
  };
}

/// [chatId]'s bookmarks, the newest marked first.
final tavernBookmarksProvider = NotifierProvider.family<TavernBookmarks, List<TavernBookmark>, String>(
  TavernBookmarks.new,
);

class TavernBookmarks extends Notifier<List<TavernBookmark>> {
  TavernBookmarks(this.chatId);

  final String chatId;
  var _changed = false;

  String get _key => 'tavern.bookmarks.$chatId';

  @override
  List<TavernBookmark> build() {
    unawaited(_load());
    return const [];
  }

  Future<void> _load() async {
    try {
      final stored = (await SharedPreferences.getInstance()).getString(_key);
      if (stored == null || _changed || !ref.mounted) return;
      final list = jsonDecode(stored);
      state = [for (final item in list is List ? list : const []) ?TavernBookmark.fromJson(item)];
    } catch (_) {}
  }

  bool has(String nodeId) => state.any((b) => b.nodeId == nodeId);

  /// Marks [m], or takes its mark off; true when it is now marked.
  Future<bool> toggle(TavernMessage m) async {
    final marked = !has(m.nodeId);
    await _set([
      if (marked) TavernBookmark.of(m),
      for (final b in state)
        if (b.nodeId != m.nodeId) b,
    ]);
    return marked;
  }

  Future<void> remove(String nodeId) => _set([
    for (final b in state)
      if (b.nodeId != nodeId) b,
  ]);

  Future<void> _set(List<TavernBookmark> marks) async {
    _changed = true;
    state = marks;
    try {
      final prefs = await SharedPreferences.getInstance();
      marks.isEmpty
          ? await prefs.remove(_key)
          : await prefs.setString(_key, jsonEncode([for (final b in marks) b.toJson()]));
    } catch (_) {}
  }
}
