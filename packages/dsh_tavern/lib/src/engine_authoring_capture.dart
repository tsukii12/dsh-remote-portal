part of 'engine.dart';

/// Owned preview inputs. A fresh file snapshot and its existing ledger row
/// remain separate facts: capture never observes a new authority version.
final class _AuthoringCapturedResource {
  const _AuthoringCapturedResource({
    required this.target,
    required this.document,
    required this.sourceFormat,
    required this.snapshot,
    this.mediaRefs = const [],
    this.media = const {},
    this.ledger,
    this.character,
    this.seedDraftId,
    this.seedRevision,
    AuthoringCharacterCapture? characterCapture,
    List<TavernRegexScript>? regexRecords,
    String? seedSourceText,
  }) : _characterCapture = characterCapture,
       _regexRecords = regexRecords,
       _seedSourceText = seedSourceText;

  final TavernAuthoringTarget target;
  final Map<String, Object?>? document;
  final String? sourceFormat;
  final AuthoringResourceSnapshot snapshot;
  final List<String> mediaRefs;

  /// Root-relative within the captured card, or the seed's stored blob names.
  final Map<String, Uint8List> media;
  final AuthoringResourceVersion? ledger;
  final StoredCharacter? character;
  final String? seedDraftId;
  final int? seedRevision;
  final AuthoringCharacterCapture? _characterCapture;
  final List<TavernRegexScript>? _regexRecords;
  final String? _seedSourceText;
}

extension _AuthoringResourceCapture on TavernEngine {
  /// The caller owns dependency de-duplication. Assembly may still use the
  /// same captured book more than once with different WorldInfoSource values.
  Future<_AuthoringCapturedResource> _captureAuthoringResource(
    TavernAuthoringTarget target, {
    StoredAuthoringDraft? seedDraft,
  }) async {
    if (seedDraft != null) {
      final source = (seedDraft.data['sources']! as List<Object?>)
          .cast<Map<String, Object?>>()
          .where(
            (value) =>
                value['origin'] == 'seed' &&
                _authoringTarget(value['target']! as Map<String, Object?>).physicalResourceId ==
                    target.physicalResourceId,
          )
          .firstOrNull;
      if (source != null) {
        return _AuthoringCapturedResource(
          target: target,
          document: source['base']! as Map<String, Object?>,
          sourceFormat: source['sourceFormat']! as String,
          snapshot: AuthoringResourceSnapshot.fromJson(source),
          mediaRefs: (source['mediaRefs']! as List<Object?>).cast<String>(),
          media: _store.readAuthoringSeedBlobs(seedDraft.id, target.physicalResourceId),
          seedDraftId: seedDraft.id,
          seedRevision: seedDraft.revision,
          seedSourceText: jsonEncode(source),
        );
      }
    }
    switch (target.kind) {
      case TavernAuthoringTargetKind.character:
        final captured = await _library.readAuthoringCapture(target.id);
        return _AuthoringCapturedResource(
          target: target,
          document: captured.document,
          sourceFormat: captured.character?.card.sourceFormat.name,
          snapshot: captured.snapshot,
          mediaRefs: captured.mediaRefs,
          media: captured.media,
          ledger: captured.ledger,
          character: captured.character,
          characterCapture: captured,
        );
      case TavernAuthoringTargetKind.lorebook:
        _requireBookId(target.id);
        return _bookOperation(() async {
          _authoringAuthority.checkWritable(target.physicalResourceId);
          final snapshot = await _readBookResource(File('${directory.path}/lorebooks/${target.id}.json'));
          Map<String, Object?>? document;
          String? format;
          if (snapshot.present) {
            document = _decodeObject(decodeAuthoringText(utf8.encode(snapshot.rawText!)).text, 'Lorebook');
            _authoringBook(document);
            final envelope = !document.containsKey('entries') && document['format'] == 'dshgo-lorebook';
            if (envelope && document['importReport'] != null) {
              TavernImportReport.fromJson(document['importReport']! as Map<String, Object?>);
            }
            format = envelope ? 'dshgo-lorebook' : 'st-json';
          }
          return _AuthoringCapturedResource(
            target: target,
            document: document,
            sourceFormat: format,
            snapshot: snapshot,
            ledger: _authoringAuthority.peek(target.physicalResourceId),
          );
        });
      case TavernAuthoringTargetKind.regexLibrary:
        // The getter copies the list, not its stable record objects. Capture
        // before waiting so a managed edit while this read is queued conflicts.
        final records = _regexLibrary.scripts;
        final captured = await _regexLibrary.readAuthoringSnapshot();
        return _AuthoringCapturedResource(
          target: target,
          document: captured.document,
          sourceFormat: 'regex-library-v1',
          snapshot: AuthoringResourceSnapshot(present: captured.present, rawText: captured.rawText),
          regexRecords: records,
        );
      case TavernAuthoringTargetKind.preset:
        return _presetOperation(() {
          final document = _store.readAuthoringPresetData(target.id);
          return _AuthoringCapturedResource(
            target: target,
            document: document,
            sourceFormat: document == null
                ? null
                : document['envelope'] == null
                ? 'st-json'
                : 'dsh-preset-enhance',
            // Presets have current database columns rather than one raw file.
            // Include the whole row, never just its archived sourceText.
            snapshot: AuthoringResourceSnapshot(
              present: document != null,
              rawText: document == null ? null : jsonEncode(document),
            ),
          );
        });
    }
  }

  /// Called after the reader has closed dependency admission. Queued file
  /// comparisons precede one synchronous ledger/database/caller check. This
  /// does not claim an atomic snapshot of externally edited filesystem paths.
  Future<void> _recheckCapturedAuthoringResources(
    Iterable<_AuthoringCapturedResource> values, {
    void Function()? check,
  }) async {
    final captured = values.toList(growable: false);
    for (final resource in captured) {
      if (resource.seedDraftId != null) {
        continue;
      }
      final target = resource.target;
      switch (target.kind) {
        case TavernAuthoringTargetKind.character:
          if (!await _library.recheckAuthoringCapture(target.id, resource._characterCapture!)) {
            _authoringCaptureConflict(target);
          }
        case TavernAuthoringTargetKind.lorebook:
          final same = await _bookOperation(
            () async => (await _readBookResource(
              File('${directory.path}/lorebooks/${target.id}.json'),
            )).sameAs(resource.snapshot),
          );
          if (!same) {
            _authoringCaptureConflict(target);
          }
        case TavernAuthoringTargetKind.regexLibrary:
          if (!await _regexLibrary.recheckAuthoringSnapshot(
            present: resource.snapshot.present,
            rawText: resource.snapshot.rawText,
          )) {
            _authoringCaptureConflict(target);
          }
        case TavernAuthoringTargetKind.preset:
          break;
      }
    }
    // No await in this final block: a managed mutation cannot fall between
    // its resource token check and the caller's draft/chat/host seal.
    for (final resource in captured) {
      final target = resource.target;
      final ledger = resource.ledger;
      if (ledger != null && !ledger.sameAs(_authoringAuthority.peek(target.physicalResourceId))) {
        _authoringCaptureConflict(target);
      }
      final seedDraftId = resource.seedDraftId;
      if (seedDraftId != null) {
        final draft = _store.readAuthoringDraftData(seedDraftId);
        if (draft == null || draft.revision != resource.seedRevision) {
          _authoringCaptureConflict(target);
        }
        final source = (draft.data['sources']! as List<Object?>)
            .cast<Map<String, Object?>>()
            .where(
              (value) =>
                  _authoringTarget(value['target']! as Map<String, Object?>).physicalResourceId ==
                  target.physicalResourceId,
            )
            .firstOrNull;
        if (source == null ||
            jsonEncode(source) != resource._seedSourceText ||
            !_stateJsonEqual(resource.media, _store.readAuthoringSeedBlobs(seedDraftId, target.physicalResourceId))) {
          _authoringCaptureConflict(target);
        }
      } else if (target.kind == TavernAuthoringTargetKind.preset) {
        final document = _store.readAuthoringPresetData(target.id);
        if ((document != null) != resource.snapshot.present ||
            (document == null ? null : jsonEncode(document)) != resource.snapshot.rawText) {
          _authoringCaptureConflict(target);
        }
      } else if (target.kind == TavernAuthoringTargetKind.regexLibrary) {
        final before = resource._regexRecords!;
        final current = _regexLibrary.scripts;
        if (before.length != current.length) {
          _authoringCaptureConflict(target);
        }
        for (var index = 0; index < before.length; index++) {
          if (!identical(before[index], current[index])) {
            _authoringCaptureConflict(target);
          }
        }
      }
    }
    check?.call();
  }
}

Never _authoringCaptureConflict(TavernAuthoringTarget target) => throw TavernAuthoringException(
  'capture_conflict',
  'An authoring preview dependency changed during capture.',
  physicalResourceId: target.physicalResourceId,
);
