import 'dart:convert';

import 'import_report.dart';
import 'regex/regex_types.dart';

/// Dynamic patterns are deferred; importing never expands macros.
enum TavernRegexCompatibility { compatible, literalFallback, incompatible, deferred, skipped }

final class TavernRegexDiagnostic {
  const TavernRegexDiagnostic({
    required this.path,
    required this.status,
    required this.code,
    required this.message,
    this.identifier,
    this.line,
    this.decorator,
    this.keyIndex,
    this.conditional = false,
    this.fallback = false,
  });
  final String path;
  final TavernRegexCompatibility status;
  final String code;
  final String message;
  final String? identifier;
  final int? line;
  final String? decorator;
  final int? keyIndex;
  final bool conditional;
  final bool fallback;
  Map<String, Object?> toJson() => {
    'path': path,
    'status': status.name,
    'code': code,
    'message': message,
    if (identifier != null) 'identifier': identifier,
    if (line != null) 'line': line,
    if (decorator != null) 'decorator': decorator,
    if (keyIndex != null) 'keyIndex': keyIndex,
    if (conditional) 'conditional': true,
    if (fallback) 'fallback': true,
  };
  factory TavernRegexDiagnostic.fromJson(Map<String, Object?> json) => TavernRegexDiagnostic(
    path: json['path']! as String,
    status: TavernRegexCompatibility.values.byName(json['status']! as String),
    code: json['code']! as String,
    message: json['message']! as String,
    identifier: json['identifier'] as String?,
    line: json['line'] as int?,
    decorator: json['decorator'] as String?,
    keyIndex: json['keyIndex'] as int?,
    conditional: json['conditional'] == true,
    fallback: json['fallback'] == true,
  );
}

/// Internal ids are independent of ST ids, so duplicate imports keep their
/// original JSON and both ordered executions.
final class TavernRegexScript {
  TavernRegexScript({
    required this.id,
    required this.sourceText,
    required Map<String, Object?> raw,
    required this.importedAt,
    Iterable<TavernRegexDiagnostic> diagnostics = const [],
    TavernImportReport? importReport,
  }) : _raw = _copy(raw),
       diagnostics = List.unmodifiable(diagnostics),
       _importReport = importReport;
  final String id;
  final String sourceText;
  final Map<String, Object?> _raw;
  final DateTime importedAt;
  final List<TavernRegexDiagnostic> diagnostics;
  final TavernImportReport? _importReport;
  TavernImportReport? get importReport {
    final report = _importReport;
    return report?.withStale(report.fingerprint != importFingerprint(TavernImportKind.regex, _raw));
  }

  Map<String, Object?> get raw => _copy(_raw);
  String get name => _raw['scriptName'] is String ? _raw['scriptName']! as String : '';
  bool get enabled => !_truthy(_raw['disabled']);
  bool get compatible => !diagnostics.any((value) => value.status == TavernRegexCompatibility.incompatible);
}

final class TavernRegexImportResult {
  TavernRegexImportResult(Iterable<TavernRegexScript> scripts) : scripts = List.unmodifiable(scripts);
  final List<TavernRegexScript> scripts;
  List<TavernRegexDiagnostic> get diagnostics =>
      List.unmodifiable([for (final script in scripts) ...script.diagnostics]);
}

/// Ephemeral text. A superseded result must not replace a newer view.
final class TavernDisplayResult {
  TavernDisplayResult({
    required this.text,
    Iterable<RegexDisplayWarning> warnings = const [],
    this.replacements = 0,
    this.superseded = false,
  }) : warnings = List.unmodifiable(warnings);
  final String text;
  final List<RegexDisplayWarning> warnings;
  final int replacements;
  final bool superseded;
}

Map<String, Object?> _copy(Map<String, Object?> value) => jsonDecode(jsonEncode(value)) as Map<String, Object?>;
bool _truthy(Object? value) =>
    value != null && value != false && value != '' && !(value is num && (value == 0 || value.isNaN));
