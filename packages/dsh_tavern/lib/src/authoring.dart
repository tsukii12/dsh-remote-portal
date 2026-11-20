import 'import_report.dart';
import 'regex/regex_types.dart';

/// Stable failures at the authoring boundary. A prepared resource write keeps
/// its original cause and receipt; an exception alone never proves adoption.
final class TavernAuthoringException implements Exception {
  const TavernAuthoringException(
    this.code,
    this.message, {
    this.physicalResourceId,
    this.changeId,
    this.receipt,
    this.cause,
    this.blockedOperationId,
    this.blockedDomainId,
  });

  /// Stable boundary code, including conflicts and unresolved operations.
  final String code;
  final String message;
  final String? physicalResourceId;
  final String? changeId;
  final TavernAuthoringReceipt? receipt;
  final Object? cause;
  final String? blockedOperationId;
  final String? blockedDomainId;

  String? get operationId => receipt?.operationId;
  String? get domainId => receipt?.domainId;
  bool? get committed => receipt?.committed;

  @override
  String toString() => 'TavernAuthoringException($code): $message';
}

enum TavernAuthoringTargetKind { character, lorebook, regexLibrary, preset }

enum TavernAuthoringSourceOrigin { existing, seed }

/// A resource named in a draft. A seed reserves an ID without a live file.
/// Embedded books belong to their character; the regex library uses 'global'.
final class TavernAuthoringTarget {
  const TavernAuthoringTarget({required this.kind, required this.id});

  final TavernAuthoringTargetKind kind;
  final String id;

  String get physicalResourceId => switch (kind) {
    TavernAuthoringTargetKind.character => 'character:$id',
    TavernAuthoringTargetKind.lorebook => 'lorebook:$id',
    TavernAuthoringTargetKind.regexLibrary => 'regex-library',
    TavernAuthoringTargetKind.preset => 'preset:$id',
  };
}

/// A durable authority token, distinct from a draft's edit revision and the
/// script bridge's runtime token. A restored root receives a new domain.
final class TavernAuthorityRevision {
  const TavernAuthorityRevision({required this.domainId, required this.revision});

  final String domainId;
  final int revision;

  @override
  bool operator ==(Object other) =>
      other is TavernAuthorityRevision && other.domainId == domainId && other.revision == revision;

  @override
  int get hashCode => Object.hash(domainId, revision);
}

/// Detached complete JSON, including the original envelope and unknown keys.
/// Media references are retained; their files are not part of a JSON edit.
final class TavernAuthoringSource {
  const TavernAuthoringSource({
    required this.target,
    required this.sourceFormat,
    required this.base,
    this.mediaRefs = const [],
    this.authorityRevision,
    this.applySupported = false,
    this.origin = TavernAuthoringSourceOrigin.existing,
  });

  final TavernAuthoringTarget target;
  final TavernAuthoringSourceOrigin origin;
  String get physicalResourceId => target.physicalResourceId;
  final String sourceFormat;
  final Map<String, Object?> base;
  final List<String> mediaRefs;
  final TavernAuthorityRevision? authorityRevision;

  /// True only for a supported adapter and a saved durable base. A draft
  /// captured before authority was installed requires an explicit rebase.
  final bool applySupported;
}

enum TavernAuthoringChangeKind { set, remove }

/// A JSON Pointer change. Set supports object keys and existing array slots;
/// remove deletes an object key. Edit array length/order with an entire-array
/// set. Overlapping paths require an explicit dependency on the earlier change.
final class TavernAuthoringChange {
  const TavernAuthoringChange({
    required this.id,
    required this.physicalResourceId,
    required this.path,
    required this.operation,
    this.value,
    this.dependsOn = const [],
  });

  final String id;
  final String physicalResourceId;
  final String path;
  final TavernAuthoringChangeKind operation;
  final Object? value;
  final List<String> dependsOn;
}

final class TavernAuthoringDiff {
  const TavernAuthoringDiff({
    required this.changeId,
    required this.physicalResourceId,
    required this.path,
    required this.beforeExists,
    required this.before,
    required this.afterExists,
    required this.after,
  });

  final String changeId;
  final String physicalResourceId;
  final String path;
  final bool beforeExists;
  final Object? before;
  final bool afterExists;
  final Object? after;
}

/// A detached draft snapshot. Its base never refreshes implicitly on reopen.
final class TavernAuthoringDraft {
  const TavernAuthoringDraft({
    required this.id,
    required this.draftRevision,
    required this.sources,
    required this.changes,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final int draftRevision;
  final List<TavernAuthoringSource> sources;
  final List<TavernAuthoringChange> changes;
  final DateTime createdAt;
  final DateTime updatedAt;
}

final class TavernAuthoringDraftSummary {
  const TavernAuthoringDraftSummary({
    required this.id,
    required this.draftRevision,
    required this.targets,
    required this.updatedAt,
  });

  final String id;
  final int draftRevision;
  final List<TavernAuthoringTarget> targets;
  final DateTime updatedAt;
}

/// Static validation and selected candidates; this is not a prompt assembly or
/// a claim that a rule will activate in a future turn. No candidate is adopted.
final class TavernAuthoringPreview {
  const TavernAuthoringPreview({
    required this.draftId,
    required this.draftRevision,
    required this.changeIds,
    required this.candidates,
    required this.diffs,
    required this.reports,
    required this.issues,
  });

  final String draftId;
  final int draftRevision;
  final List<String> changeIds;
  final Map<String, Map<String, Object?>> candidates;
  final List<TavernAuthoringDiff> diffs;
  final Map<String, List<TavernImportReport>> reports;
  final Map<String, List<TavernImportFinding>> issues;
}

/// Tests only a draft script's pattern. A null match means matching did not
/// execute (for example, compilation was skipped for a runtime macro).
final class TavernAuthoringRegexTest {
  const TavernAuthoringRegexTest({
    required this.draftId,
    required this.draftRevision,
    required this.physicalResourceId,
    required this.scriptPath,
    required this.compilation,
    this.match,
  });

  final String draftId;
  final int draftRevision;
  final String physicalResourceId;
  final String scriptPath;
  final RegexCompileResult compilation;
  final RegexMatchResult? match;
}

enum TavernAuthoringOperationState { prepared, notAdopted, unconfirmed, adopted, published, noChange }

/// A failure actually observed while recording or publishing a resource edit.
final class TavernAuthoringIssue {
  const TavernAuthoringIssue({required this.type, required this.message});
  final String type;
  final String message;
}

/// The result of one physical resource operation. Unknown adoption is null;
/// callers must not turn it into an invitation to retry the file effect.
final class TavernAuthoringReceipt {
  const TavernAuthoringReceipt({
    required this.domainId,
    required this.operationId,
    required this.physicalResourceId,
    required this.state,
    this.adoptedRevision,
    required this.historyPending,
    this.issue,
  });

  final String domainId;
  final String operationId;
  final String physicalResourceId;
  final TavernAuthoringOperationState state;
  final int? adoptedRevision;
  final bool historyPending;
  final TavernAuthoringIssue? issue;

  bool? get committed => switch (state) {
    TavernAuthoringOperationState.prepared || TavernAuthoringOperationState.unconfirmed => null,
    TavernAuthoringOperationState.notAdopted || TavernAuthoringOperationState.noChange => false,
    TavernAuthoringOperationState.adopted || TavernAuthoringOperationState.published => true,
  };
}

/// Saved intent and observed outcome. Snapshots contain present/rawText/
/// identityText; internal staging or trash paths are not public write commands.
final class TavernAuthoringOperation extends TavernAuthoringReceipt {
  const TavernAuthoringOperation({
    required super.domainId,
    required super.operationId,
    required super.physicalResourceId,
    required super.state,
    super.adoptedRevision,
    required super.historyPending,
    super.issue,
    required this.request,
    required this.before,
    required this.after,
    required this.createdAt,
    required this.updatedAt,
  });

  final Map<String, Object?> request;
  final Map<String, Object?> before;
  final Map<String, Object?> after;
  final DateTime createdAt;
  final DateTime updatedAt;
}

final class TavernAuthoringRevisionSummary {
  const TavernAuthoringRevisionSummary({
    required this.domainId,
    required this.physicalResourceId,
    required this.revision,
    required this.operationId,
    required this.at,
  });
  final String domainId;
  final String physicalResourceId;
  final int revision;
  final String operationId;
  final DateTime at;
}
