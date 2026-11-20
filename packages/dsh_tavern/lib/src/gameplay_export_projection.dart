part of 'engine.dart';

/// Export identities are separate from runtime/branch identities. This object
/// only edits an owned prospective JSON value and records every changed ID.
final class _GameplayExportProjection {
  _GameplayExportProjection(this.resolution, this.issues) {
    for (final source in resolution.sources) {
      if (source['kind'] == 'card') {
        reserveDeclaration(source['raw']);
      }
    }
    for (final definition in resolution.definitions) {
      if (definition['path'] == '/references') {
        for (final row in (definition['items']! as List<Object?>).cast<Map<String, Object?>>()) {
          final source = row['source']! as Map<String, Object?>;
          final pointer = row['pointer'];
          if (pointer is String) {
            _references[(_sourceKey(source), pointer)] = row;
          }
        }
      }
    }
  }

  final TavernGameplayResolution resolution;
  final List<Map<String, Object?>> issues;
  final idMappings = <Map<String, Object?>>[];
  final _used = <String, Set<String>>{};
  final _legacyIds = <String>{};
  final _ids = <(String, String, String), String>{};
  final _references = <(String, String), Map<String, Object?>>{};
  final _destinations = <(String, String), String>{};

  Map<String, Object?> get host => resolution.sources.firstWhere(
    (source) => source['kind'] == 'card' && (source['roles']! as List<Object?>).contains('host'),
  );

  static String _sourceKey(Map<String, Object?> source) =>
      jsonEncode([source['kind'], source['kind'] == 'pack' ? source['bindingId'] : source['characterId']]);

  void reserve(String kind, Object? value) {
    if (value is String) {
      (_used[kind] ??= <String>{}).add(value);
      _legacyIds.add(value);
    }
  }

  void reserveDeclaration(Object? raw) {
    if (raw is! Map<String, Object?>) {
      return;
    }
    void rules(Object? value, bool event) {
      if (value is! List<Object?>) {
        return;
      }
      for (final row in value) {
        if (row is! Map<String, Object?>) {
          continue;
        }
        reserve(event ? 'handler' : 'rule', row['id']);
        if (event) {
          reserve('event', row['name']);
        }
        final actions = row['do'];
        if (actions is List<Object?>) {
          for (final action in actions) {
            if (action is Map<String, Object?> && action['type'] == 'event') {
              reserve('event', action['name']);
            }
          }
        }
      }
    }

    rules(_map(raw['state'])['rules'], false);
    rules(_map(_map(raw['director'])['eventRules'])['rules'], true);
    final custom = _map(raw['components'])['custom'];
    if (custom is List<Object?>) {
      for (final row in custom) {
        if (row is Map<String, Object?>) {
          reserve('component', row['id']);
        }
      }
    }
    for (final key in _map(_map(raw['dice'])['skills']).keys) {
      reserve('skill', key);
    }
  }

  String id(String kind, Map<String, Object?> source, String localId, {String? resourceLocalId, String? path}) {
    if (source['kind'] != 'pack') {
      return localId;
    }
    final local = jsonEncode([resourceLocalId, localId]);
    final key = (kind, _sourceKey(source), local);
    final known = _ids[key];
    if (known != null) {
      return known;
    }
    final used = _used[kind] ??= <String>{};
    final digest = _directorHash({
      'kind': kind,
      'bindingId': source['bindingId'],
      'resourceLocalId': resourceLocalId,
      'localId': localId,
    });
    final base = 'dshgo_export_${kind}_${digest.substring(0, 20)}';
    var value = base;
    var suffix = 1;
    while (_legacyIds.contains(value) || !used.add(value)) {
      value = '$base-${suffix++}';
    }
    _ids[key] = value;
    idMappings.add({
      'kind': kind,
      'source': source,
      'localId': localId,
      'resourceLocalId': ?resourceLocalId,
      'exportedId': value,
      'path': ?path,
    });
    return value;
  }

  Map<String, Object?>? sourceAt(String path) {
    Map<String, Object?>? match;
    for (final row in resolution.fieldSources) {
      final prefix = row['path']! as String;
      if ((path == prefix || path.startsWith('$prefix/')) &&
          (match == null || prefix.length > (match['path']! as String).length)) {
        match = row;
      }
    }
    return match?['winner'] as Map<String, Object?>?;
  }

  void _recordDestination(Map<String, Object?> source, String from, String to) {
    _destinations[(_sourceKey(source), from)] = to;
  }

  /// A reference in a shadowed declaration has no destination in this export.
  String? destination(Map<String, Object?> source, String pointer) {
    final key = _sourceKey(source);
    String? result;
    var length = -1;
    for (final entry in _destinations.entries) {
      final from = entry.key.$2;
      if (entry.key.$1 == key && (pointer == from || pointer.startsWith('$from/')) && from.length > length) {
        result = '${entry.value}${pointer.substring(from.length)}';
        length = from.length;
      }
    }
    if (result != null) {
      return result;
    }
    for (final row in resolution.fieldSources) {
      final owner = row['winner']! as Map<String, Object?>;
      final from = row['sourcePath']! as String;
      if (_sourceKey(owner) == key && (pointer == from || pointer.startsWith('$from/')) && from.length > length) {
        final candidate = '${row['path']}${pointer.substring(from.length)}';
        final winner = sourceAt(candidate);
        if (winner != null && _sourceKey(winner) == key) {
          result = candidate;
          length = from.length;
        }
      }
    }
    return result;
  }

  String _eventName(Map<String, Object?> source, String pointer, String original) {
    final ref = _references[(_sourceKey(source), pointer)];
    if (ref != null) {
      if (ref['resolved'] != true ||
          ref['kind'] != 'event' ||
          ref['target'] is! Map<String, Object?> ||
          ref['localId'] is! String) {
        issues.add(
          _gameplayExportIssue(
            'export_reference_unresolved',
            'The selected event reference has no resolved export target.',
            source: source,
            path: pointer,
          ),
        );
        return original;
      }
      return id('event', ref['target']! as Map<String, Object?>, ref['localId']! as String);
    }
    return id('event', source, original);
  }

  void _rule(
    Map<String, Object?> row,
    Map<String, Object?> source,
    String sourcePath,
    String outputPath, {
    required bool event,
  }) {
    _recordDestination(source, sourcePath, outputPath);
    if (source['kind'] != 'pack') {
      return;
    }
    final originalId = row['id'];
    if (originalId is String) {
      row['id'] = id(event ? 'handler' : 'rule', source, originalId, path: '$outputPath/id');
    }
    final name = row['name'];
    if (event && name is String) {
      row['name'] = _eventName(source, '$sourcePath/name', name);
    }
    final actions = row['do'];
    if (actions is List<Object?>) {
      for (final (index, action) in actions.indexed) {
        if (action is Map<String, Object?> && action['type'] == 'event' && action['name'] is String) {
          action['name'] = _eventName(source, '$sourcePath/do/$index/name', action['name']! as String);
        }
      }
    }
  }

  Map<String, Object?> definitions() {
    final output = _authoringCopy(resolution.effective)! as Map<String, Object?>;
    final state = output['state'];
    final rules = state is Map<String, Object?> ? state['rules'] : null;
    if (rules is List<Object?>) {
      for (final (index, rule) in rules.indexed) {
        if (rule is! Map<String, Object?>) {
          continue;
        }
        final path = '/state/rules/$index';
        final field = resolution.fieldSources.where((row) => row['path'] == path).firstOrNull;
        final source = field?['winner'] as Map<String, Object?>? ?? host;
        _rule(rule, source, field?['sourcePath'] as String? ?? path, path, event: false);
      }
    }

    final event = resolution.definitions.where((row) => row['path'] == '/director/eventRules').firstOrNull;
    final director = output['director'];
    if (event != null && director is Map<String, Object?> && director['eventRules'] is Map<String, Object?>) {
      final original = _map(_map(host['raw'])['director'])['eventRules'];
      final registry = <String, Object?>{
        if (original is Map<String, Object?>) ...(_authoringCopy(original)! as Map<String, Object?>),
        ...(director['eventRules']! as Map<String, Object?>),
      };
      final values = registry['rules']! as List<Object?>;
      var outputIndex = 0;
      for (final row in (event['registries']! as List<Object?>).cast<Map<String, Object?>>()) {
        if (row['executable'] != true) {
          continue;
        }
        final source = row['source']! as Map<String, Object?>;
        final raw = row['raw']! as Map<String, Object?>;
        for (final (index, _) in (raw['rules']! as List<Object?>).indexed) {
          if (outputIndex >= values.length) {
            issues.add(
              _gameplayExportIssue(
                'export_definition_shape',
                'The composed event display does not match its actual registries.',
              ),
            );
            break;
          }
          final value = values[outputIndex];
          if (value is Map<String, Object?>) {
            _rule(
              value,
              source,
              '/director/eventRules/rules/$index',
              '/director/eventRules/rules/$outputIndex',
              event: true,
            );
          }
          outputIndex++;
        }
      }
      final expected = <String>[
        for (final sourceRegistry in (event['registries']! as List<Object?>).cast<Map<String, Object?>>())
          for (final handler in (sourceRegistry['handlers']! as List<Object?>).cast<Map<String, Object?>>())
            id('handler', sourceRegistry['source']! as Map<String, Object?>, handler['localId']! as String),
      ];
      final checked = state_core.CardEventDefinition.parse(
        registry,
        version: output.containsKey('v') ? output['v'] : 1,
      );
      if (!checked.executable || !_stateJsonEqual(checked.handlerIds, expected)) {
        issues.add(
          _gameplayExportIssue(
            'export_event_handler_conversion',
            'The ordinary card parser would change which original handlers are executable after identity rewriting.',
            path: '/director/eventRules',
          ),
        );
      }
      director['eventRules'] = registry;
    }

    for (final path in const ['/components/custom', '/dice/skills']) {
      final definition = resolution.definitions.where((row) => row['path'] == path).firstOrNull;
      if (definition == null || definition['present'] != true) {
        continue;
      }
      final items = (definition['items']! as List<Object?>).cast<Map<String, Object?>>();
      if (path == '/components/custom') {
        final components = output['components'];
        if (components is! Map<String, Object?>) {
          continue;
        }
        final custom = <Object?>[];
        for (final item in items) {
          final source = item['source']! as Map<String, Object?>;
          final raw = _authoringCopy(item['raw']);
          final outputPath = '/components/custom/${custom.length}';
          _recordDestination(source, item['sourcePath']! as String, outputPath);
          if (raw is Map<String, Object?> && raw['id'] is String && source['kind'] == 'pack') {
            raw['id'] = id('component', source, raw['id']! as String, path: '$outputPath/id');
          }
          custom.add(raw);
        }
        components['custom'] = custom;
      } else {
        final dice = output['dice'];
        if (dice is! Map<String, Object?>) {
          continue;
        }
        final skills = <String, Object?>{};
        for (final item in items) {
          final source = item['source']! as Map<String, Object?>;
          final key = id('skill', source, item['localId']! as String);
          skills[key] = _authoringCopy(item['raw']);
          _recordDestination(source, item['sourcePath']! as String, '/dice/skills/${_gameplayPointerToken(key)}');
        }
        dice['skills'] = skills;
      }
    }

    // Event names were handled while their original registry/rule positions
    // were still known. Other references use the same resolved source table.
    for (final ref in _references.values) {
      if (ref['kind'] != 'component' || ref['resolved'] != true) {
        continue;
      }
      final source = ref['source']! as Map<String, Object?>;
      final outputPath = destination(source, ref['pointer']! as String);
      if (outputPath == null) {
        continue;
      }
      final value = id('component', ref['target']! as Map<String, Object?>, ref['localId']! as String);
      _putGameplayExportReference(output, outputPath, value, issues, source: source);
    }
    final enabled = _map(output['components'])['enabled'];
    if (enabled is List<Object?>) {
      for (final (index, value) in enabled.indexed) {
        final path = '/components/enabled/$index';
        final source = sourceAt(path);
        if (value is! String ||
            source == null ||
            source['kind'] != 'pack' ||
            _references.containsKey((_sourceKey(source), path))) {
          continue;
        }
        final renamed = _ids[('component', _sourceKey(source), jsonEncode([null, value]))];
        if (renamed != null) {
          issues.add(
            _gameplayExportIssue(
              'export_component_reference_required',
              'This custom component was renamed; declare its supported source/localId reference explicitly.',
              source: source,
              path: path,
            ),
          );
        }
      }
    }
    return output;
  }

  Iterable<Map<String, Object?>> get assetReferences => _references.values.where((row) => row['kind'] == 'asset');
}

void _putGameplayExportReference(
  Map<String, Object?> root,
  String path,
  Object? value,
  List<Map<String, Object?>> issues, {
  Map<String, Object?>? source,
}) {
  final tokens = _gameplayCompositionPointer(path);
  if (tokens == null || tokens.isEmpty || !_authoringLookup(root, tokens).exists) {
    issues.add(
      _gameplayExportIssue(
        'export_reference_destination',
        'A supported reference has no actual destination in the exported value.',
        source: source,
        path: path,
      ),
    );
    return;
  }
  final parent = _authoringLookup(root, tokens.sublist(0, tokens.length - 1)).value;
  if (parent is Map<String, Object?>) {
    parent[tokens.last] = value;
  } else if (parent is List<Object?>) {
    final index = _authoringIndex(tokens.last, parent.length);
    if (index == null) {
      issues.add(
        _gameplayExportIssue(
          'export_reference_destination',
          'The exported array reference is outside the actual array.',
          source: source,
          path: path,
        ),
      );
      return;
    }
    parent[index] = value;
  } else {
    issues.add(
      _gameplayExportIssue(
        'export_reference_destination',
        'The exported reference parent is not an object or array.',
        source: source,
        path: path,
      ),
    );
  }
}
