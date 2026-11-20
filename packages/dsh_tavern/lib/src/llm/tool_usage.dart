import 'dart:convert';

import '../api.dart';
import 'model_client.dart';

const _fields = ['prompt_tokens', 'completion_tokens', 'cache_hit_tokens'];

/// The single persisted usage ledger for a registered request.
Map<String, Object?> emptyToolUsageLedger() => {
  'version': 1,
  'observations': <Object?>[],
  'reportedUsageObserved': false,
};

/// Coalesces provider streaming snapshots until the request is sealed. Keep
/// the last normalized evidence as well: a later null/invalid raw report must
/// select incomplete fields without erasing the compatibility counters.
final class StreamingToolUsage {
  ModelUsageReport? _report, _normalizedReport;
  TavernUsage? _normalizedUsage;

  bool get isEmpty => _report == null;
  TavernUsage? get normalizedUsage => _normalizedUsage;

  bool observe(ModelUsageReport report, {TavernUsage? normalizedUsage}) {
    final incoming = report.toJson();
    final normalized = _usageJson(normalizedUsage);
    final sameNormalizedReport = _normalizedReport != null && _equal(_normalizedReport!.toJson(), incoming);
    final sameNormalized = sameNormalizedReport && _equal(_usageJson(_normalizedUsage), normalized);
    if (_report != null && _equal(_report!.toJson(), incoming)) {
      if (normalizedUsage == null || sameNormalized) return false;
    } else if (sameNormalizedReport && (normalizedUsage == null || sameNormalized)) {
      // Finished may repeat the retained earlier normalized report after a
      // newer raw-only report. That duplicate cannot select it again.
      return false;
    }
    _report = report;
    if (normalizedUsage != null) {
      _normalizedReport = report;
      _normalizedUsage = normalizedUsage;
    }
    return true;
  }

  ({Map<String, Object?> ledger, List<Map<String, Object?>> diagnostics}) record(Map<String, Object?> previous) {
    final report = _report;
    if (report == null) return (ledger: previous, diagnostics: <Map<String, Object?>>[]);
    final normalizedReport = _normalizedReport;
    if (normalizedReport == null) return recordToolUsageObservation(previous, report: report);
    final normalized = recordToolUsageObservation(
      previous,
      report: normalizedReport,
      normalizedUsage: _normalizedUsage,
    );
    if (_equal(normalizedReport.toJson(), report.toJson())) return normalized;
    final latest = recordToolUsageObservation(normalized.ledger, report: report);
    return (ledger: latest.ledger, diagnostics: [...normalized.diagnostics, ...latest.diagnostics]);
  }

  void clear() {
    _report = null;
    _normalizedReport = null;
    _normalizedUsage = null;
  }
}

Map<String, Object?>? _usageJson(TavernUsage? usage) => usage == null
    ? null
    : {
        'promptTokens': usage.promptTokens,
        'cacheHitTokens': usage.cacheHitTokens,
        'completionTokens': usage.completionTokens,
        'model': usage.model,
      };

/// Appends actual new evidence without changing an earlier observation. A
/// provider/custom observation index is a correlation hint, not ordering power.
({Map<String, Object?> ledger, List<Map<String, Object?>> diagnostics}) recordToolUsageObservation(
  Map<String, Object?> previous, {
  required ModelUsageReport report,
  TavernUsage? normalizedUsage,
}) {
  final ledger = _ledger(previous);
  final observations = ledger['observations']! as List<Object?>;
  final incoming = report.toJson();
  final normalized = _usageJson(normalizedUsage);
  var provenanceConflict = false;
  var normalizedConflict = false;
  var addedNormalized = false;
  for (final item in observations) {
    final old = item! as Map<String, Object?>;
    final oldReport = old['report']! as Map<String, Object?>;
    final sameReport = _equal(oldReport, incoming);
    final oldNormalized = old['normalizedUsage'];
    if (sameReport && (normalized == null || _equal(oldNormalized, normalized))) {
      // In particular, Finished's report-only duplicate cannot erase the
      // normalized evidence on the earlier ModelUsage event or select it anew.
      return (ledger: ledger, diagnostics: <Map<String, Object?>>[]);
    }
    if (oldReport['observationIndex'] == report.observationIndex) {
      if (!sameReport) provenanceConflict = true;
      if (oldNormalized != null && normalized != null && !_equal(oldNormalized, normalized)) normalizedConflict = true;
    }
    if (sameReport && normalized != null) {
      if (oldNormalized == null) {
        addedNormalized = true;
      } else if (!_equal(oldNormalized, normalized)) {
        normalizedConflict = true;
      }
    }
  }
  final sequence = observations.isEmpty ? 0 : (observations.last! as Map<String, Object?>)['sequence']! as int;
  if (sequence == 0x7fffffffffffffff) throw const FormatException('Usage observation sequence exhausted.');
  final nextSequence = observations.isEmpty ? 0 : sequence + 1;
  observations.add({'sequence': nextSequence, 'report': incoming, 'normalizedUsage': ?normalized});
  ledger['selectedObservationSequence'] = nextSequence;
  ledger['reportedUsageObserved'] =
      ledger['reportedUsageObserved'] == true ||
      report.rawPresent == true ||
      report.origin == 'legacy_normalized' ||
      normalized != null;
  return (
    ledger: ledger,
    diagnostics: [
      if (provenanceConflict) {'code': 'usage_observation_conflict', 'observationIndex': report.observationIndex},
      if (normalizedConflict) {'code': 'usage_normalized_conflict', 'observationIndex': report.observationIndex},
      if (addedNormalized) {'code': 'usage_normalized_observed', 'observationIndex': report.observationIndex},
    ],
  );
}

/// Uses one selected report per registered request. Subtotals are exact BigInt
/// sums; the compatibility int projection is absent on signed-64-bit overflow.
Map<String, Object?> summarizeToolUsage(Iterable<({int requestIndex, Map<String, Object?> usage})> requests) {
  final ordered = requests.toList()..sort((a, b) => a.requestIndex.compareTo(b.requestIndex));
  final indexes = <int>{};
  final selected = <({int index, ModelUsageReport? report})>[];
  for (final request in ordered) {
    if (request.requestIndex < 0 || !indexes.add(request.requestIndex)) {
      throw const FormatException('Usage requests require distinct nonnegative indexes.');
    }
    final ledger = _ledger(request.usage);
    final sequence = ledger['selectedObservationSequence'];
    ModelUsageReport? report;
    if (sequence != null) {
      for (final value in ledger['observations']! as List<Object?>) {
        final observation = value! as Map<String, Object?>;
        if (observation['sequence'] == sequence) {
          report = ModelUsageReport.fromJson(observation['report']! as Map<String, Object?>);
          break;
        }
      }
    }
    selected.add((index: request.requestIndex, report: report));
  }
  final result = <String, Object?>{};
  final maximum = BigInt.parse('9223372036854775807');
  for (final key in _fields) {
    var subtotal = BigInt.zero;
    final missing = <int>[];
    final invalid = <int>[];
    final unknown = <int>[];
    for (final request in selected) {
      final field = request.report?.fields[key] as Map<String, Object?>?;
      switch (field?['state']) {
        case 'reported':
          subtotal += BigInt.from(field!['value']! as int);
        case 'missing':
          missing.add(request.index);
        case 'invalid':
          invalid.add(request.index);
        default:
          unknown.add(request.index);
      }
    }
    final overflow = subtotal > maximum;
    final known = overflow ? null : subtotal.toInt();
    final complete = selected.isNotEmpty && !overflow && missing.isEmpty && invalid.isEmpty && unknown.isEmpty;
    result[key] = {
      'knownSubtotal': known,
      'exactKnownSubtotal': subtotal.toString(),
      'overflow': overflow,
      'missingRequestIndexes': missing,
      'invalidRequestIndexes': invalid,
      'unknownRequestIndexes': unknown,
      'complete': complete,
      'total': complete ? known : null,
    };
  }
  return {'version': 1, 'summaryScope': 'selected_reported_values', 'requestCount': selected.length, 'fields': result};
}

/// Compatibility projection for a multi-request turn. Missing evidence is
/// never filled with zero, and an incomplete field makes the whole view absent.
TavernUsage? completeToolUsage(Map<String, Object?> summary, {String? model}) {
  final fields = summary['fields'];
  if (summary['version'] is! int || summary['version'] != 1 || fields is! Map<String, Object?>) {
    throw const FormatException('Invalid tool usage summary.');
  }
  final totals = <String, int>{};
  for (final key in _fields) {
    final field = fields[key];
    if (field is! Map<String, Object?>) throw const FormatException('Invalid tool usage summary field.');
    if (field['complete'] != true || field['overflow'] != false) return null;
    final total = field['total'];
    if (total is! int || total < 0) throw const FormatException('Invalid complete usage total.');
    totals[key] = total;
  }
  return TavernUsage(
    promptTokens: totals['prompt_tokens']!,
    cacheHitTokens: totals['cache_hit_tokens']!,
    completionTokens: totals['completion_tokens']!,
    model: model,
  );
}

Map<String, Object?> _ledger(Map<String, Object?> input) {
  _finite(input, Set<Object>.identity());
  final value = jsonDecode(jsonEncode(input)) as Map<String, Object?>;
  final observations = value['observations'];
  if (value['version'] is! int ||
      value['version'] != 1 ||
      observations is! List<Object?> ||
      value['reportedUsageObserved'] is! bool) {
    throw const FormatException('Invalid tool usage ledger.');
  }
  var previous = -1;
  for (final item in observations) {
    if (item is! Map<String, Object?> ||
        item['sequence'] is! int ||
        (item['sequence']! as int) <= previous ||
        item['report'] is! Map<String, Object?>) {
      throw const FormatException('Invalid usage observation order.');
    }
    previous = item['sequence']! as int;
    ModelUsageReport.fromJson(item['report']! as Map<String, Object?>);
    final normalized = item['normalizedUsage'];
    if (normalized != null) {
      if (normalized is! Map<String, Object?> ||
          normalized['promptTokens'] is! int ||
          normalized['cacheHitTokens'] is! int ||
          normalized['completionTokens'] is! int ||
          (normalized['model'] != null && normalized['model'] is! String)) {
        throw const FormatException('Invalid normalized usage observation.');
      }
    }
  }
  final selected = value['selectedObservationSequence'];
  if (observations.isEmpty ? selected != null : selected != previous) {
    throw const FormatException('Usage selection must identify the latest added observation.');
  }
  return value;
}

void _finite(Object? item, Set<Object> parents) {
  if (item == null || item is String || item is bool || item is int) return;
  if (item is double && item.isFinite) return;
  if (item is Map<String, Object?> || item is List<Object?>) {
    if (!parents.add(item)) throw const FormatException('Cyclic usage ledger.');
    final children = item is Map<String, Object?> ? item.values : (item as List<Object?>);
    for (final child in children) {
      _finite(child, parents);
    }
    parents.remove(item);
    return;
  }
  throw const FormatException('Usage ledger requires finite JSON.');
}

bool _equal(Object? left, Object? right) {
  if (left is num && right is num && (left is int) != (right is int)) return false;
  if (left is Map<String, Object?> && right is Map<String, Object?>) {
    return left.length == right.length &&
        left.keys.every((key) => right.containsKey(key) && _equal(left[key], right[key]));
  }
  if (left is List<Object?> && right is List<Object?>) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!_equal(left[index], right[index])) return false;
    }
    return true;
  }
  return left == right;
}
