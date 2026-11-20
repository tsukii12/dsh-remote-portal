import 'dart:convert';

import 'regex_library.dart';

class TavernLorebookSummary {
  const TavernLorebookSummary({required this.id, required this.name, required this.entryCount, this.stWorldName});
  final String id;
  final String name;
  final int entryCount;

  /// Original ST filename without .json, separate from the display title.
  final String? stWorldName;
}

final class TavernLorebook extends TavernLorebookSummary {
  TavernLorebook({
    required super.id,
    required super.name,
    required super.entryCount,
    super.stWorldName,
    required Map<String, Object?> raw,
  }) : _raw = jsonDecode(jsonEncode(raw)) as Map<String, Object?>;
  final Map<String, Object?> _raw;
  Map<String, Object?> get raw => jsonDecode(jsonEncode(_raw)) as Map<String, Object?>;
}

final class TavernLorebookImportResult {
  TavernLorebookImportResult(this.book, Iterable<TavernRegexDiagnostic> diagnostics)
    : diagnostics = List.unmodifiable(diagnostics);
  final TavernLorebook book;
  final List<TavernRegexDiagnostic> diagnostics;
}
