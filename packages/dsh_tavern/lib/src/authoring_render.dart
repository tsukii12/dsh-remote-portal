import 'dart:typed_data';

import 'authoring.dart';
import 'authoring_preview.dart';
import 'scripts.dart' show TavernScriptCancellation;

/// Only static markup is connected. This mode never runs preparation hooks,
/// injection filters, live script callbacks or a model request.
enum TavernAuthoringRenderMode { staticMarkup }

enum TavernAuthoringRenderStatus { complete, unsupported, cancelled, superseded, failed }

/// Caller choices. Candidates, media and capture identity are supplied by the
/// engine from this exact saved revision, never accepted from the caller.
final class TavernAuthoringRenderRequest {
  TavernAuthoringRenderRequest({
    required this.requestId,
    required this.draftId,
    required this.draftRevision,
    required this.physicalResourceId,
    required List<String> changeIds,
    required this.viewportWidth,
    required this.viewportHeight,
    this.devicePixelRatio = 1,
    this.theme = 'light',
    this.mode = TavernAuthoringRenderMode.staticMarkup,
    List<TavernAuthoringSampleMessage> samples = const [],
  }) : changeIds = List.unmodifiable(changeIds),
       samples = List.unmodifiable(samples);

  final String requestId, draftId, physicalResourceId, theme;
  final int draftRevision, viewportWidth, viewportHeight;
  final double devicePixelRatio;
  final TavernAuthoringRenderMode mode;
  final List<String> changeIds;
  final List<TavernAuthoringSampleMessage> samples;

  Map<String, Object?> toJson() => {
    'requestId': requestId,
    'draftId': draftId,
    'draftRevision': draftRevision,
    'physicalResourceId': physicalResourceId,
    'changeIds': changeIds,
    'viewportWidth': viewportWidth,
    'viewportHeight': viewportHeight,
    'devicePixelRatio': devicePixelRatio,
    'theme': theme,
    'mode': mode.name,
    'samples': [for (final sample in samples) sample.toJson()],
  };
}

/// A detached resource delivered across the host boundary. Actual current raw
/// and its old authority token are independent facts; the token does not
/// attest to raw which has not been observed by a managed writer.
final class TavernAuthoringCapturedResource {
  const TavernAuthoringCapturedResource({
    required this.target,
    required this.present,
    required this.fromDraft,
    this.rawText,
    this.identityText,
    this.sourceFormat,
    this.document,
    this.candidate,
    this.knownAuthority,
    this.knownAuthoritySnapshotHash,
    this.seedDraftId,
    this.mediaRefs = const [],
    this.media = const {},
  });

  final TavernAuthoringTarget target;
  final bool present, fromDraft;
  final String? rawText, identityText, sourceFormat, knownAuthoritySnapshotHash, seedDraftId;
  final TavernAuthorityRevision? knownAuthority;
  final List<String> mediaRefs;
  final Map<String, Uint8List> media;

  /// JSON belongs to this delivery. Local mutations cannot change the private
  /// capture or another reader/render delivery.
  final Map<String, Object?>? document, candidate;
}

/// During openPreview, named dependencies may join this capture. After seal,
/// already captured values remain readable; new dependencies are unsupported.
/// Cancellation closes all reader admission. There is no path/network reader.
abstract interface class TavernAuthoringCaptureReader {
  Future<TavernAuthoringCapturedResource> read(TavernAuthoringTarget target);
}

final class TavernAuthoringHostCapture {
  TavernAuthoringHostCapture({
    required this.request,
    required this.captureId,
    required this.resource,
    required this.reader,
    required List<TavernAuthoringTarget> draftTargets,
  }) : draftTargets = List.unmodifiable(draftTargets);
  final TavernAuthoringRenderRequest request;
  final String captureId;
  final TavernAuthoringCapturedResource resource;
  final List<TavernAuthoringTarget> draftTargets;
  final TavernAuthoringCaptureReader reader;
}

/// The engine creates this only after dependency capture has sealed. Rendering
/// consumes these values and does not implicitly perform prompt preparation.
final class TavernAuthoringHostRenderRequest {
  TavernAuthoringHostRenderRequest({
    required this.request,
    required this.captureId,
    required Map<String, TavernAuthoringCapturedResource> resources,
  }) : resources = Map.unmodifiable(resources);
  final TavernAuthoringRenderRequest request;
  final String captureId;
  final Map<String, TavernAuthoringCapturedResource> resources;
  TavernAuthoringCapturedResource get resource => resources[request.physicalResourceId]!;
}

/// Actual capabilities of this new rendering domain. The byte limit is
/// checked before decoding; decoded dimensions are checked after decoding.
/// These limits are not a promise about the decoder's allocation budget.
final class TavernAuthoringHostBinding {
  TavernAuthoringHostBinding({
    required this.hostEpoch,
    required Set<TavernAuthoringRenderMode> renderModes,
    required Set<String> formats,
    required this.maxImageBytes,
    required this.maxPixelWidth,
    required this.maxPixelHeight,
  }) : renderModes = Set.unmodifiable(renderModes),
       formats = Set.unmodifiable(formats);
  final String hostEpoch;
  final Set<TavernAuthoringRenderMode> renderModes;
  final Set<String> formats;
  final int maxImageBytes, maxPixelWidth, maxPixelHeight;
}

/// App-supplied independent renderer. This interface is not a sandbox: the App
/// must disconnect live SDK/network capabilities and resolve only capture media.
/// A failed open must clean up any domain for which no session was delivered.
abstract interface class TavernAuthoringPreviewHost {
  Future<TavernAuthoringPreviewSession> openPreview(
    TavernAuthoringHostCapture capture,
    TavernScriptCancellation cancellation,
  );
}

abstract interface class TavernAuthoringPreviewSession {
  TavernAuthoringHostBinding get binding;

  /// Synchronously invalidated if the copied source environment changes before
  /// seal. Changes after seal never redirect the isolated domain to live data.
  TavernScriptCancellation get sourceInvalidated;
  Future<TavernAuthoringRenderResult> render(TavernAuthoringHostRenderRequest request);

  /// Idempotent. Success proves this domain and every returned callback Future
  /// have ended. Failure means cleanup is unconfirmed, not a successful cancel.
  /// A post-cleanup notification failure must be reported separately.
  Future<void> close();
}

/// Host results echo every identity, including errors. Only engine-accepted
/// complete results carry a verified PNG/JPEG image. Bytes are detached and
/// unmodifiable; HTML/source strings are not image results.
final class TavernAuthoringRenderResult {
  TavernAuthoringRenderResult({
    required this.requestId,
    required this.captureId,
    required this.draftId,
    required this.draftRevision,
    required this.physicalResourceId,
    required List<String> changeIds,
    required this.mode,
    required this.status,
    this.mimeType,
    Uint8List? bytes,
    this.pixelWidth,
    this.pixelHeight,
    List<TavernAuthoringIssue> issues = const [],
  }) : changeIds = List.unmodifiable(changeIds),
       bytes = bytes == null ? null : Uint8List.fromList(bytes).asUnmodifiableView(),
       issues = List.unmodifiable(issues);
  final String requestId, captureId, draftId, physicalResourceId;
  final int draftRevision;
  final List<String> changeIds;
  final TavernAuthoringRenderMode mode;
  final TavernAuthoringRenderStatus status;
  final String? mimeType;
  final Uint8List? bytes;
  final int? pixelWidth, pixelHeight;
  final List<TavernAuthoringIssue> issues;
}
