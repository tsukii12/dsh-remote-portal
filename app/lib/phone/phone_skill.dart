import 'dart:convert';

final _draftId = RegExp(r'^[a-f0-9]{32}$');
final _skillName = RegExp(r'^phone-task-[a-f0-9]{32}$');

/// Completed native trace candidate; the person still has to confirm the goal succeeded.
class PhoneSkillCandidate {
  const PhoneSkillCandidate({required this.taskId, required this.generation, required this.steps});
  final int taskId;
  final int generation;
  final int steps;

  static PhoneSkillCandidate? parse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['taskId'], generation = raw['generation'], steps = raw['steps'];
    if (id is! int || id <= 0 || generation is! int || generation <= 0 || steps is! int || steps < 1 || steps > 60) return null;
    return PhoneSkillCandidate(taskId: id, generation: generation, steps: steps);
  }
}

class PhoneSkillStatus {
  const PhoneSkillStatus({this.available = false, this.askAfterSuccess = false, this.candidates = const [], this.saveResults = const []});
  final bool available;
  final bool askAfterSuccess;
  final List<PhoneSkillCandidate> candidates;
  final List<PhoneSkillSaveResult> saveResults;

  factory PhoneSkillStatus.parse(Object? raw) {
    if (raw is! Map || raw['v'] is! int || raw['v'] != 1) return const PhoneSkillStatus();
    final values = raw['candidates'];
    final results = raw['saveResults'];
    return PhoneSkillStatus(
      saveResults: List.unmodifiable([
        if (results is List)
          for (final result in results.take(8)) ?PhoneSkillSaveResult.parse(result),
      ]),
      available: true,
      askAfterSuccess: raw['askAfterSuccess'] == true,
      candidates: List.unmodifiable([
        if (values is List)
          for (final value in values.take(8))
            ?PhoneSkillCandidate.parse(value),
      ]),
    );
  }
}

/// The exact native revision shown to the person. Only this revision can be saved.
class PhoneSkillDraftView {
  const PhoneSkillDraftView({required this.draftId, required this.taskId, required this.generation,
    required this.revision, required this.skillName, required this.markdown, required this.stepOrder,
    required this.parameterizedFields, this.phase, this.bundleRevision});
  final String draftId;
  final int taskId;
  final int generation;
  final int revision;
  final String skillName;
  final String markdown;
  final List<int> stepOrder;
  final List<String> parameterizedFields;
  final String? phase;
  final String? bundleRevision;

  static PhoneSkillDraftView? parse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['draftId'], task = raw['taskId'], generation = raw['generation'], revision = raw['revision'];
    final name = raw['skillName'], markdown = raw['markdown'], order = raw['stepOrder'], fields = raw['parameterizedFields'];
    final phase = raw['phase'];
    final bundle = raw['bundleRevision'];
    if (raw.containsKey('bundleRevision') && (bundle is! String || !_draftId.hasMatch(bundle))) return null;
    if (id is! String || !_draftId.hasMatch(id) || task is! int || task <= 0 ||
        generation is! int || generation <= 0 || revision is! int || revision <= 0 ||
        name is! String || !_skillName.hasMatch(name) || markdown is! String ||
        markdown.length > 32768 || utf8.encode(markdown).length > 32768 ||
        order is! List || order.isEmpty || order.length > 60 ||
        order.any((v) => v is! int || v < 0 || v >= 60) || order.toSet().length != order.length ||
        fields is! List || fields.length > 62 || fields.any((v) => v is! String || v.length > 32) ||
        phase != null && !const {'staging', 'committing', 'finished', 'cancelled'}.contains(phase)) {
      return null;
    }
    return PhoneSkillDraftView(draftId: id, taskId: task, generation: generation, revision: revision,
      skillName: name, markdown: markdown, stepOrder: List<int>.unmodifiable(order),
      parameterizedFields: List<String>.unmodifiable(fields), phase: phase as String?, bundleRevision: bundle as String?);
  }
}

enum PhoneSkillReplyKind { shown, saved, discarded, rejected, saving, unverified }

class PhoneSkillReply {
  const PhoneSkillReply._(this.kind, {this.draft, this.code, this.name, this.relativePath, this.phase, this.bundleRevision, this.publication});
  const PhoneSkillReply.unavailable() : this._(PhoneSkillReplyKind.rejected, code: 'unavailable');
  final PhoneSkillReplyKind kind;
  final PhoneSkillDraftView? draft;
  final String? code;
  final String? name;
  final String? relativePath;
  final String? phase;
  final String? bundleRevision;
  final String? publication;

  static const _codes = {'stale', 'busy', 'confirmation_required', 'unavailable', 'invalid', 'sensitive',
    'too_large', 'no_home', 'conflict', 'io', 'cannot_cancel'};

  factory PhoneSkillReply.parse(Object? raw) {
    if (raw is! Map) return const PhoneSkillReply.unavailable();
    final bundle = raw['bundleRevision'];
    if (raw.containsKey('bundleRevision') && (bundle is! String || !_draftId.hasMatch(bundle))) {
      return const PhoneSkillReply.unavailable();
    }
    switch (raw['kind']) {
      case 'shown':
        final draft = PhoneSkillDraftView.parse(raw['draft']);
        return draft == null ? const PhoneSkillReply.unavailable() : PhoneSkillReply._(PhoneSkillReplyKind.shown, draft: draft);
      case 'saved':
        final name = raw['name'], path = raw['relativePath'];
        if (name is! String || !_skillName.hasMatch(name) || path != 'skills/$name/SKILL.md') return const PhoneSkillReply.unavailable();
        return PhoneSkillReply._(PhoneSkillReplyKind.saved, name: name, relativePath: path as String, bundleRevision: bundle as String?);
      case 'discarded':
        return const PhoneSkillReply._(PhoneSkillReplyKind.discarded);
      case 'saving':
        final phase = raw['phase'];
        if (phase != 'staging' && phase != 'committing') return const PhoneSkillReply.unavailable();
        final name = raw['name'];
        if (bundle != null && (name is! String || !_skillName.hasMatch(name)) ||
            bundle == null && raw.containsKey('name')) {
          return const PhoneSkillReply.unavailable();
        }
        return PhoneSkillReply._(PhoneSkillReplyKind.saving, phase: phase as String,
          name: name as String?, bundleRevision: bundle as String?);
      case 'unverified':
        final name = raw['name'], path = raw['relativePath'];
        final publication = raw['publication'], code = raw['code'];
        if (bundle == null || name is! String || !_skillName.hasMatch(name) || path != 'skills/$name/SKILL.md' ||
            !const {'published', 'unknown'}.contains(publication) ||
            !const {'verification_unavailable', 'bundle_invalid', 'origin_unavailable'}.contains(code)) {
          return const PhoneSkillReply.unavailable();
        }
        return PhoneSkillReply._(PhoneSkillReplyKind.unverified, name: name, relativePath: path as String,
          bundleRevision: bundle as String, publication: publication as String, code: code as String);
      case 'rejected':
        final code = raw['code'];
        return PhoneSkillReply._(PhoneSkillReplyKind.rejected, code: code is String && _codes.contains(code) ? code : 'unavailable');
      default:
        return const PhoneSkillReply.unavailable();
    }
  }
}

/// An existing native save record, not an editable draft or a filesystem path.
class PhoneSkillSaveHandle {
  const PhoneSkillSaveHandle._(this.taskId, this.draftId, this.name, this.bundleRevision);
  final int taskId;
  final String draftId;
  final String name;
  final String bundleRevision;

  static PhoneSkillSaveHandle? fromDraft(PhoneSkillDraftView draft) => draft.bundleRevision == null ? null
    : PhoneSkillSaveHandle._(draft.taskId, draft.draftId, draft.skillName, draft.bundleRevision!);

  static PhoneSkillSaveHandle? parse(Object? raw) {
    if (raw is! Map) return null;
    final task = raw['taskId'], id = raw['draftId'], name = raw['name'], revision = raw['bundleRevision'];
    if (task is! int || task <= 0 || id is! String || !_draftId.hasMatch(id) ||
        name is! String || !_skillName.hasMatch(name) || revision is! String || !_draftId.hasMatch(revision)) {
      return null;
    }
    return PhoneSkillSaveHandle._(task, id, name, revision);
  }

  Map<String, Object> get query => {'action': 'check_save', 'taskId': taskId, 'draftId': draftId,
    'name': name, 'bundleRevision': bundleRevision};
}

class PhoneSkillSaveResult {
  const PhoneSkillSaveResult._(this.handle, this.reply);
  final PhoneSkillSaveHandle handle;
  final PhoneSkillReply reply;

  static PhoneSkillSaveResult? parse(Object? raw) {
    final handle = PhoneSkillSaveHandle.parse(raw);
    if (handle == null || raw is! Map) return null;
    if (!const {'saving', 'saved', 'unverified'}.contains(raw['kind'])) return null;
    // Display-only path. Queries send the frozen native identity, never a path.
    final reply = PhoneSkillReply.parse({...raw, 'relativePath': 'skills/${handle.name}/SKILL.md'});
    if (reply.kind == PhoneSkillReplyKind.rejected) return null;
    return PhoneSkillSaveResult._(handle, reply);
  }
}
