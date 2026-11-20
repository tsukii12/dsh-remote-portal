import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Asset namespaces are independent: the same id may occur in two libraries.
enum TavernImportKind { character, preset, lorebook, regex }

/// A report describes capabilities, not whether a disabled item will activate.
enum TavernImportVerdict { usable, partial, preserveOnly }

enum TavernImportFindingKind { unsupported, conditional, deferred, invalid, unknown }

/// One finding at one source location. Messages never reproduce source bodies.
final class TavernImportFinding {
  const TavernImportFinding({
    required this.path,
    required this.code,
    required this.message,
    required this.kind,
    this.identifier,
    this.line,
    this.offset,
    this.conditional = false,
    this.fallback = false,
  });

  final String path;
  final String code;
  final String message;
  final TavernImportFindingKind kind;
  final String? identifier;
  final int? line;

  /// Zero-based UTF-16 offset in the string at [path], when available.
  final int? offset;
  final bool conditional;
  final bool fallback;

  Map<String, Object?> toJson() => {
    'path': path,
    'code': code,
    'message': message,
    'kind': kind.name,
    if (identifier != null) 'identifier': identifier,
    if (line != null) 'line': line,
    if (offset != null) 'offset': offset,
    if (conditional) 'conditional': true,
    if (fallback) 'fallback': true,
  };

  factory TavernImportFinding.fromJson(Map<String, Object?> json) => TavernImportFinding(
    path: json['path']! as String,
    code: json['code']! as String,
    message: json['message']! as String,
    kind: TavernImportFindingKind.values.byName(json['kind']! as String),
    identifier: json['identifier'] as String?,
    line: json['line'] as int?,
    offset: json['offset'] as int?,
    conditional: json['conditional'] == true,
    fallback: json['fallback'] == true,
  );
}

/// Persisted capability snapshot. Asset reads compare the current inspection-input
/// fingerprint with [fingerprint] to determine [stale]. Restoring a match can make
/// [stale] false; [checkedAt] and [findings] still describe the saved snapshot.
/// Explicit rechecking and updateRegexScript refresh the snapshot. Reading never executes
/// macros, scripts, or another compatibility probe.
final class TavernImportReport {
  TavernImportReport({
    this.version = 1,
    required this.kind,
    required this.checkedAt,
    required this.verdict,
    required Map<String, int> counts,
    required Iterable<TavernImportFinding> findings,
    this.renderLevel,
    required this.fingerprint,
    this.stale = false,
  }) : counts = Map.unmodifiable(counts),
       findings = List.unmodifiable(findings) {
    if (version != 1) throw FormatException('不支持的导入体检版本：$version');
    final level = renderLevel;
    if (level != null && (level < 0 || level > 2)) {
      throw const FormatException('导入体检的渲染级别必须为 0、1 或 2');
    }
  }

  final int version;
  final TavernImportKind kind;
  final DateTime checkedAt;
  final TavernImportVerdict verdict;
  final Map<String, int> counts;
  final List<TavernImportFinding> findings;

  /// Null means there is no HTML rendering recommendation for this asset.
  final int? renderLevel;

  /// Identity of the inspected JSON and embedded resource paths, not file bytes.
  final String fingerprint;
  final bool stale;

  TavernImportReport withStale(bool value) => TavernImportReport(
    version: version,
    kind: kind,
    checkedAt: checkedAt,
    verdict: verdict,
    counts: counts,
    findings: findings,
    renderLevel: renderLevel,
    fingerprint: fingerprint,
    stale: value,
  );

  Map<String, Object?> toJson() => {
    'version': version,
    'kind': kind.name,
    'checkedAt': checkedAt.toUtc().toIso8601String(),
    'verdict': verdict.name,
    'counts': counts,
    'findings': findings.map((value) => value.toJson()).toList(),
    if (renderLevel != null) 'renderLevel': renderLevel,
    'fingerprint': fingerprint,
    if (stale) 'stale': true,
  };

  factory TavernImportReport.fromJson(Map<String, Object?> json) => TavernImportReport(
    version: json['version']! as int,
    kind: TavernImportKind.values.byName(json['kind']! as String),
    checkedAt: DateTime.parse(json['checkedAt']! as String),
    verdict: TavernImportVerdict.values.byName(json['verdict']! as String),
    counts: (json['counts']! as Map<String, Object?>).map((key, value) => MapEntry(key, value! as int)),
    findings: (json['findings']! as List<Object?>).map(
      (value) => TavernImportFinding.fromJson(value! as Map<String, Object?>),
    ),
    renderLevel: json['renderLevel'] as int?,
    fingerprint: json['fingerprint']! as String,
    stale: json['stale'] == true,
  );
}

/// Canonical JSON makes object key ordering irrelevant while preserving array
/// order and values. The fingerprint is an edit detector, not a signature.
String importFingerprint(
  TavernImportKind kind,
  Map<String, Object?> document, {
  Map<String, Object?>? envelope,
  Iterable<String> embeddedAssetPaths = const [],
}) {
  final paths = embeddedAssetPaths.toSet().toList()..sort();
  final value = <String, Object?>{
    'kind': kind.name,
    'document': document,
    'envelope': envelope,
    'embeddedAssetPaths': paths,
  };
  return sha256.convert(utf8.encode(jsonEncode(_canonical(value)))).toString();
}

Object? _canonical(Object? value) {
  if (value is Map<String, Object?>) {
    final keys = value.keys.toList()..sort();
    return <String, Object?>{for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List<Object?>) return value.map(_canonical).toList();
  return value;
}
