import 'dart:convert';

import 'director/direct_tool.dart' show directorEvery;
import 'io/card_codec.dart' show CardCodec;
import 'state/state_engine.dart' show CardEventDefinition, SecretDefinition, StateDefinition;
import 'story/story_engine.dart' show StoryDefinition;
import 'tool_policy.dart' show parseToolCardDeclaration;

enum TavernDshgoBlockOwner { engine, app, opaque }

/// A declaration summary, separate from its native definition's executable flag.
/// Conditional declarations still need their normal runtime context or admission.
enum TavernDshgoBlockStatus { absent, executable, conditional, unsupported, invalid, opaque }

/// Paths are JSON Pointers relative to the supplied dshgo extension.
/// Diagnostic maps keep their original fields and add a sourcePath.
final class TavernDshgoBlockInspection {
  const TavernDshgoBlockInspection({
    required this.path,
    required this.owner,
    required this.present,
    required this.status,
    required this.executable,
    required this.issues,
  });

  final String path;
  final TavernDshgoBlockOwner owner;
  final bool present;
  final TavernDshgoBlockStatus status;

  /// The native definition flag, or null where no such definition gate exists.
  /// True does not imply that every child declaration is executable.
  final bool? executable;
  final List<Map<String, Object?>> issues;

  Map<String, Object?> toJson() => {
    'path': path,
    'owner': owner.name,
    'present': present,
    'status': status.name,
    'executable': executable,
    'issues': issues,
  };
}

/// Detached inspection of the supplied JSON. No live resource or runtime is read.
final class TavernDshgoInspection {
  const TavernDshgoInspection({required this.present, required this.raw, required this.blocks, required this.issues});

  final bool present;
  final Object? raw;
  final List<TavernDshgoBlockInspection> blocks;
  final List<Map<String, Object?>> issues;

  Map<String, Object?> toJson() => {
    'present': present,
    'raw': raw,
    'blocks': [for (final block in blocks) block.toJson()],
    'issues': issues,
  };
}

/// Only validates the explicitly supplied value; defaults and derive never run.
/// sourcePath is rooted at /value for value diagnostics, or /state when the
/// definition is not executable and the native validator returns its issues.
final class TavernDshgoValueValidation {
  const TavernDshgoValueValidation({
    required this.raw,
    required this.valueExists,
    required this.value,
    required this.validated,
    required this.issues,
  });

  final Object? raw;
  final bool valueExists;
  final Object? value;

  /// Equals StateDefinition.executable. When false, even an empty issues list
  /// means no value validation ran. When true, issues are the native validator's
  /// result and do not certify unsupported child constraints.
  final bool validated;
  final List<Map<String, Object?>> issues;

  Map<String, Object?> toJson() => {
    'raw': raw,
    'valueExists': valueExists,
    'value': value,
    'validated': validated,
    'issues': issues,
  };
}

/// Parses declarations without initializing state, evaluating user conditions,
/// executing rules, or importing cast members. Finite JSON is captured once;
/// unsupported fields and wrong JSON shapes remain available in [TavernDshgoInspection.raw].
TavernDshgoInspection inspectDshgoExtension(Object? raw, {bool present = true}) {
  final captured = _captureJson(raw);
  final extension = present && captured is Map<String, Object?> ? captured : null;
  final version = extension != null && extension.containsKey('v') ? extension['v'] : 1;
  final blocks = <TavernDshgoBlockInspection>[];
  final issues = <Map<String, Object?>>[];
  if (present && extension == null) {
    issues.add({'code': 'dshgo_shape', 'sourcePath': '', 'message': 'The dshgo extension must be an object.'});
  }
  void add(TavernDshgoBlockInspection block) {
    blocks.add(block);
    issues.addAll(block.issues);
  }

  final state = StateDefinition.parse(extension?['state'], version: version);
  add(_definitionBlock('/state', extension?.containsKey('state') ?? false, state.executable, state.issues));
  final story = StoryDefinition.parse(extension?['story'], version: version);
  add(_definitionBlock('/story', extension?.containsKey('story') ?? false, story.executable, story.issues));

  final director = extension?['director'];
  final directorFields = director is Map<String, Object?> ? director : null;
  final directorPresent = extension?.containsKey('director') ?? false;
  add(
    _declarationBlock(
      '/director',
      directorPresent,
      issues: [
        if (directorPresent && directorFields == null)
          {'code': 'dshgo_director_shape', 'sourcePath': '/director', 'message': 'Director options must be an object.'},
      ],
    ),
  );
  final events = CardEventDefinition.parse(directorFields?['eventRules'], version: version);
  add(
    _definitionBlock(
      '/director/eventRules',
      directorFields?.containsKey('eventRules') ?? false,
      events.executable,
      events.issues,
    ),
  );
  final secrets = SecretDefinition.parse(directorFields?['secretSlots'], state: state, version: version);
  add(
    _definitionBlock(
      '/director/secretSlots',
      directorFields?.containsKey('secretSlots') ?? false,
      secrets.executable,
      secrets.issues,
    ),
  );
  final cadence = directorEvery(card: directorFields ?? const {});
  add(
    _declarationBlock(
      '/director/every',
      directorFields?.containsKey('every') ?? false,
      issues: [
        if (cadence.invalid) {'kind': 'director', 'code': 'invalid_director_every', 'sourcePath': '/director/every'},
      ],
    ),
  );

  final tools = parseToolCardDeclaration({
    'extensions': {if (present) 'dshgo': captured},
  });
  final toolIssues = <Map<String, Object?>>[
    for (final issue in tools['diagnostics']! as List<Map<String, Object?>>)
      {...issue, 'sourcePath': _toolSourcePath(issue['fieldPath']! as String)},
  ];
  add(_declarationBlock('/tools', extension?.containsKey('tools') ?? false, issues: toolIssues));
  final toolFields = extension?['tools'];
  for (final name in const ['roll', 'remember']) {
    final declared = toolFields is Map<String, Object?> && toolFields.containsKey(name);
    // Parent/field diagnostics are kept once on /tools. These summaries only
    // report availability of the declaration, never scope or wire permission.
    blocks.add(
      TavernDshgoBlockInspection(
        path: '/tools/$name',
        owner: TavernDshgoBlockOwner.engine,
        present: declared,
        status: !declared
            ? TavernDshgoBlockStatus.absent
            : tools['${name}Available'] == false
            ? TavernDshgoBlockStatus.invalid
            : TavernDshgoBlockStatus.conditional,
        executable: null,
        issues: const [],
      ),
    );
  }

  final castPresent = extension?.containsKey('cast') ?? false;
  add(_declarationBlock('/cast', castPresent, issues: castPresent ? _inspectCast(extension?['cast']) : const []));
  for (final key in const ['components', 'theme', 'minigames', 'async', 'live2d', 'voice', 'bond', 'dice']) {
    final found = extension?.containsKey(key) ?? false;
    blocks.add(
      TavernDshgoBlockInspection(
        path: '/$key',
        owner: TavernDshgoBlockOwner.app,
        present: found,
        status: found ? TavernDshgoBlockStatus.opaque : TavernDshgoBlockStatus.absent,
        executable: null,
        issues: const [],
      ),
    );
  }
  if (extension != null) {
    for (final key in extension.keys) {
      if (!const {
        'v',
        'state',
        'story',
        'director',
        'tools',
        'cast',
        'components',
        'theme',
        'minigames',
        'async',
        'live2d',
        'voice',
        'bond',
        'dice',
      }.contains(key)) {
        blocks.add(
          TavernDshgoBlockInspection(
            path: '/${_escape(key)}',
            owner: TavernDshgoBlockOwner.opaque,
            present: true,
            status: TavernDshgoBlockStatus.opaque,
            executable: null,
            issues: const [],
          ),
        );
      }
    }
  }
  return TavernDshgoInspection(present: present, raw: captured, blocks: blocks, issues: issues);
}

/// Uses the same state parser and validator as native state operations. A missing
/// or non-executable schema never turns an empty diagnostic list into validation.
TavernDshgoValueValidation validateDshgoStateValue(Object? raw, {required bool valueExists, Object? value}) {
  final captured = _captureJson(raw);
  final capturedValue = _captureJson(value);
  final extension = captured is Map<String, Object?> ? captured : null;
  final version = extension != null && extension.containsKey('v') ? extension['v'] : 1;
  final state = StateDefinition.parse(extension?['state'], version: version);
  final issues = state.validate(capturedValue, valueExists: valueExists);
  return TavernDshgoValueValidation(
    raw: captured,
    valueExists: valueExists,
    value: capturedValue,
    validated: state.executable,
    issues: _withSource(issues, state.executable ? '/value' : '/state'),
  );
}

TavernDshgoBlockInspection _definitionBlock(
  String path,
  bool present,
  bool executable,
  List<Map<String, Object?>> issues,
) {
  final status = !present
      ? TavernDshgoBlockStatus.absent
      : executable
      ? TavernDshgoBlockStatus.executable
      : issues.any(
          (issue) =>
              issue['kind'] == 'unsupported' ||
              const {'state_version', 'story_version', 'card_events_version', 'secret_version'}.contains(issue['code']),
        )
      ? TavernDshgoBlockStatus.unsupported
      : issues.isNotEmpty
      ? TavernDshgoBlockStatus.invalid
      : TavernDshgoBlockStatus.conditional;
  return TavernDshgoBlockInspection(
    path: path,
    owner: TavernDshgoBlockOwner.engine,
    present: present,
    status: status,
    executable: executable,
    issues: _withSource(issues, path),
  );
}

TavernDshgoBlockInspection _declarationBlock(String path, bool present, {required List<Map<String, Object?>> issues}) =>
    TavernDshgoBlockInspection(
      path: path,
      owner: TavernDshgoBlockOwner.engine,
      present: present,
      status: issues.isNotEmpty
          ? TavernDshgoBlockStatus.invalid
          : present
          ? TavernDshgoBlockStatus.conditional
          : TavernDshgoBlockStatus.absent,
      executable: null,
      issues: issues,
    );

List<Map<String, Object?>> _withSource(List<Map<String, Object?>> issues, String base) => [
  for (final issue in issues) {...issue, 'sourcePath': '$base${issue['path'] ?? ''}'},
];

String _toolSourcePath(String path) {
  const prefix = 'extensions.dshgo';
  final suffix = path.substring(prefix.length);
  return suffix.isEmpty ? '' : '/${suffix.substring(1).split('.').map(_escape).join('/')}';
}

List<Map<String, Object?>> _inspectCast(Object? raw) {
  final issues = <Map<String, Object?>>[];
  if (raw is! List<Object?>) {
    return [
      {'code': 'dshgo_cast_shape', 'sourcePath': '/cast', 'message': 'Cast must be an array.'},
    ];
  }
  final ids = <String>{};
  for (var i = 0; i < raw.length; i++) {
    final item = raw[i];
    final path = '/cast/$i';
    if (item is! Map<String, Object?>) {
      issues.add({'code': 'dshgo_cast_shape', 'sourcePath': path, 'message': 'A cast member must be an object.'});
      continue;
    }
    final id = item['id'];
    if (id is! String || id.isEmpty || !ids.add(id)) {
      issues.add({
        'code': 'dshgo_cast_id',
        'sourcePath': '$path/id',
        'message': 'A cast member requires a unique nonempty local id.',
      });
    }
    try {
      const CardCodec().validateAuthority({'spec': 'chara_card_v3', 'spec_version': '3.0', 'data': item['card']});
    } on FormatException catch (error) {
      issues.add({'code': 'dshgo_cast_card', 'sourcePath': '$path/card', 'message': error.message});
    }
  }
  return issues;
}

Object? _captureJson(Object? value) {
  try {
    return jsonDecode(
      jsonEncode(
        value,
        toEncodable: (_) {
          throw const FormatException('Inspection inputs must contain only finite JSON values.');
        },
      ),
    );
  } on JsonUnsupportedObjectError {
    throw const FormatException('Inspection inputs must contain only finite JSON values.');
  }
}

String _escape(String value) => value.replaceAll('~', '~0').replaceAll('/', '~1');
