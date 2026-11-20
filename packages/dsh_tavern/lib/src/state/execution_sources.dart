part of 'state_engine.dart';

/// A branch-consumption domain, independent of content version and raw ids.
enum StateExecutionSourceKind { legacy, pack }

final class StateExecutionSource {
  const StateExecutionSource.legacy()
    : kind = StateExecutionSourceKind.legacy,
      installedPackId = null,
      bindingId = null,
      onceEpoch = null;
  const StateExecutionSource.pack({
    required String this.installedPackId,
    required String this.bindingId,
    required int this.onceEpoch,
  }) : kind = StateExecutionSourceKind.pack;

  final StateExecutionSourceKind kind;
  final String? installedPackId, bindingId;
  final int? onceEpoch;
  bool get isPack => kind == StateExecutionSourceKind.pack;

  Map<String, Object?> toJson() => switch (kind) {
    StateExecutionSourceKind.legacy => {'kind': 'legacy'},
    StateExecutionSourceKind.pack => {
      'kind': 'pack',
      'installedPackId': installedPackId,
      'bindingId': bindingId,
      'onceEpoch': onceEpoch,
    },
  };

  @override
  bool operator ==(Object other) =>
      other is StateExecutionSource &&
      kind == other.kind &&
      installedPackId == other.installedPackId &&
      bindingId == other.bindingId &&
      onceEpoch == other.onceEpoch;

  @override
  int get hashCode => Object.hash(kind, installedPackId, bindingId, onceEpoch);
}

/// The complete original rule list is retained for ids, occurrence and slots.
final class StateRuleSource {
  StateRuleSource({
    required this.source,
    required Map<String, Object?> state,
    Map<(int, int), StateEventTarget> actionTargets = const {},
  }) : _state = _mapCopy(state),
       _actionTargets = Map.unmodifiable(actionTargets);
  final StateExecutionSource source;
  final _Json _state;
  final Map<(int, int), StateEventTarget> _actionTargets;
  Map<String, Object?> get state => _mapCopy(_state);
}

typedef StateEventTarget = ({StateExecutionSource source, String name});

final class CardEventRegistrySource {
  CardEventRegistrySource({
    required this.source,
    required Object? raw,
    Object? version = 1,
    Map<int, StateEventTarget> eventTargets = const {},
    Map<(int, int), StateEventTarget> actionTargets = const {},
  }) : _eventTargets = Map.unmodifiable(eventTargets),
       _actionTargets = Map.unmodifiable(actionTargets),
       _raw = _eventCopy(raw),
       _version = _eventCopy(version);
  final StateExecutionSource source;
  final Object? _raw, _version;
  final Map<int, StateEventTarget> _eventTargets;
  final Map<(int, int), StateEventTarget> _actionTargets;
  Object? get raw => _eventCopy(_raw);
  Object? get version => _eventCopy(_version);
}

List<_Json> _actionTargetIdentity(Map<(int, int), StateEventTarget> targets) {
  final indexes = targets.keys.toList()
    ..sort((left, right) {
      final byDeclaration = left.$1.compareTo(right.$1);
      return byDeclaration != 0 ? byDeclaration : left.$2.compareTo(right.$2);
    });
  return [
    for (final index in indexes)
      {
        'index': index.$1,
        'actionIndex': index.$2,
        'source': targets[index]!.source.toJson(),
        'name': targets[index]!.name,
      },
  ];
}

final class CardEventHandlerRef {
  const CardEventHandlerRef({required this.source, required this.localId});
  final StateExecutionSource source;
  final String localId;
  Map<String, Object?> toJson() => {'source': source.toJson(), 'localId': localId};

  @override
  bool operator ==(Object other) => other is CardEventHandlerRef && source == other.source && localId == other.localId;

  @override
  int get hashCode => Object.hash(source, localId);
}

/// A detached view of the selected branch. Only a requested source is checked.
final class StatePackWorldInfoSnapshot {
  StatePackWorldInfoSnapshot({required bool exists, Object? raw}) : _runtime = _PackRuntime(exists: exists, raw: raw);
  final _PackRuntime _runtime;

  ({bool exists, Object? raw, List<Map<String, Object?>> issues}) read(StateExecutionSource source) {
    final read = _runtime._read(source, _PackDomain.worldInfo);
    return (
      exists: read.row?.containsKey('worldInfo') ?? false,
      raw: _eventCopy(read.row?['worldInfo']),
      issues: _maps(read.issues),
    );
  }
}

/// Actual changes to the WI child of each source, never an entire pack carrier.
final class StatePackWorldInfoDelta {
  StatePackWorldInfoDelta(Map<StateExecutionSource, Map<String, Object?>> replacements)
    : _replacements = Map.unmodifiable({
        for (final entry in replacements.entries) entry.key: _eventCopy(entry.value)! as _Json,
      });
  final Map<StateExecutionSource, _Json> _replacements;
  bool get isEmpty => _replacements.isEmpty;
}

/// Called at the actual adoption boundary after the caller's source/CAS check.
/// Same-epoch rule/event ledgers and all other bindings remain in the candidate.
({bool exists, Object? raw, List<Map<String, Object?>> issues}) mergeStatePackWorldInfo({
  required bool exists,
  Object? raw,
  required StatePackWorldInfoDelta delta,
}) => _PackRuntime(exists: exists, raw: raw)._mergeWorldInfo(delta);

enum _PackDomain { rules, events, worldInfo }

/// A single detached candidate shared by the state and event settlement.
/// Validation is deferred until a pack domain is actually read or consumed.
class _PackRuntime {
  _PackRuntime({required bool exists, Object? raw})
    : exists = exists,
      _packRaw = _eventCopy(raw),
      _packOriginalExists = exists,
      _packOriginal = _eventCopy(raw);

  bool exists;
  Object? _packRaw;
  bool _packOriginalExists;
  Object? _packOriginal;
  Object? get raw => _eventCopy(_packRaw);
  bool get changed => exists != _packOriginalExists || !_eventEqual(_packRaw, _packOriginal);

  _Json _issueFor(StateExecutionSource source, String code, String suffix, String message) => {
    ..._issue(code, '/dshgoPackRuntime$suffix', message),
    'source': source.toJson(),
  };

  ({_Json? row, List<_Json> issues}) _read(StateExecutionSource source, _PackDomain domain) {
    if (!source.isPack) {
      throw StateError('Legacy consumption does not belong to the pack runtime.');
    }
    if (!exists) {
      return (row: null, issues: []);
    }
    final raw = _packRaw;
    if (raw is! _Json || raw['v'] != 1 || raw['bindings'] is! _Json) {
      return (
        row: null,
        issues: [
          _issueFor(source, 'pack_runtime_shape', '', 'Existing pack runtime requires v:1 and a bindings object.'),
        ],
      );
    }
    final bindings = raw['bindings']! as _Json;
    final bindingId = source.bindingId!;
    if (!bindings.containsKey(bindingId)) {
      return (row: null, issues: []);
    }
    final row = bindings[bindingId];
    final path = '/bindings/${_escape(bindingId)}';
    if (row is! _Json ||
        row['installedPackId'] != source.installedPackId ||
        row['onceEpoch'] is! int ||
        (row['onceEpoch']! as int) < 0 ||
        (row['onceEpoch']! as int) > source.onceEpoch!) {
      return (
        row: null,
        issues: [
          _issueFor(
            source,
            'pack_runtime_identity',
            path,
            'The saved binding identity and epoch must match or precede this admitted source.',
          ),
        ],
      );
    }
    if (row['onceEpoch'] != source.onceEpoch) {
      // An explicit newer epoch starts fresh only when an action is accepted.
      return (row: null, issues: []);
    }
    final key = domain.name;
    if (!row.containsKey(key)) {
      return (row: row, issues: []);
    }
    final value = row[key];
    var valid = true;
    if (domain == _PackDomain.rules) {
      valid = value is List<Object?> && value.every((id) => id is String) && value.toSet().length == value.length;
    } else if (value is! _Json) {
      valid = false;
    } else if (domain == _PackDomain.events) {
      final consumed = value['consumed'];
      final once = value['once'];
      if (value.containsKey('consumed')) {
        if (consumed is! List<Object?>) {
          valid = false;
        } else {
          final seen = <(String, String)>{};
          for (final item in consumed) {
            if (item is! _Json ||
                item['eventId'] is! String ||
                item['handlerId'] is! String ||
                !seen.add((item['eventId']! as String, item['handlerId']! as String))) {
              valid = false;
              break;
            }
          }
        }
      }
      if (value.containsKey('once') &&
          (once is! List<Object?> || once.any((id) => id is! String) || once.toSet().length != once.length)) {
        valid = false;
      }
      if (value.containsKey('pendingPrompts')) {
        final pending = value['pendingPrompts'];
        final seen = <String>{};
        if (pending is! List<Object?> ||
            pending.any(
              (item) =>
                  item is! _Json ||
                  item['id'] is! String ||
                  item['text'] is! String ||
                  !seen.add(item['id']! as String),
            )) {
          valid = false;
        }
      }
    }
    return (
      row: row,
      issues: valid
          ? []
          : [
              _issueFor(
                source,
                'pack_runtime_${domain.name}',
                '$path/$key',
                'The required saved pack consumption domain is malformed and is preserved.',
              ),
            ],
    );
  }

  List<_Json> issues(StateExecutionSource source, _PackDomain domain) => _read(source, domain).issues;

  bool ruleFired(StateExecutionSource source, String localId) {
    final read = _read(source, _PackDomain.rules);
    if (read.issues.isNotEmpty) {
      throw StateError('Pack rule runtime must be checked before reading it.');
    }
    return (read.row?['rules'] as List<Object?>?)?.contains(localId) ?? false;
  }

  bool eventConsumed(StateExecutionSource source, String eventId, String handlerId) {
    final read = _read(source, _PackDomain.events);
    if (read.issues.isNotEmpty) {
      throw StateError('Pack event runtime must be checked before reading it.');
    }
    final events = read.row?['events'] as _Json?;
    final consumed = events?['consumed'] as List<Object?>?;
    return consumed?.any((item) {
          final row = item! as _Json;
          return row['eventId'] == eventId && row['handlerId'] == handlerId;
        }) ??
        false;
  }

  bool eventFired(StateExecutionSource source, String handlerId) {
    final read = _read(source, _PackDomain.events);
    if (read.issues.isNotEmpty) {
      throw StateError('Pack event runtime must be checked before reading it.');
    }
    final events = read.row?['events'] as _Json?;
    return (events?['once'] as List<Object?>?)?.contains(handlerId) ?? false;
  }

  _Json _writeRow(StateExecutionSource source, _PackDomain domain) {
    final read = _read(source, domain);
    if (read.issues.isNotEmpty) {
      throw StateError('A malformed pack domain cannot be replaced by an empty ledger.');
    }
    if (!exists) {
      exists = true;
      _packRaw = <String, Object?>{'v': 1, 'bindings': <String, Object?>{}};
    }
    final bindings = (_packRaw! as _Json)['bindings']! as _Json;
    var row = read.row;
    if (row == null) {
      final previous = bindings[source.bindingId!];
      row = previous is _Json ? Map<String, Object?>.of(previous) : <String, Object?>{};
      row
        ..remove('rules')
        ..remove('events')
        ..remove('worldInfo');
      row['installedPackId'] = source.installedPackId;
      row['onceEpoch'] = source.onceEpoch;
    }
    bindings[source.bindingId!] = row;
    return row;
  }

  ({bool exists, Object? raw, List<Map<String, Object?>> issues}) _mergeWorldInfo(StatePackWorldInfoDelta delta) {
    final problems = <_Json>[
      for (final source in delta._replacements.keys) ..._read(source, _PackDomain.worldInfo).issues,
    ];
    if (problems.isEmpty) {
      for (final entry in delta._replacements.entries) {
        final row = _writeRow(entry.key, _PackDomain.worldInfo);
        row['worldInfo'] = _eventCopy(entry.value);
      }
    }
    return (exists: exists, raw: raw, issues: _maps(problems));
  }

  ({bool exists, Object? raw, List<Map<String, Object?>> issues}) _adoptWorldInfo(StatePackWorldInfoDelta delta) {
    final baseline = _PackRuntime(exists: _packOriginalExists, raw: _packOriginal)._mergeWorldInfo(delta);
    if (baseline.issues.isNotEmpty) {
      return (exists: exists, raw: raw, issues: baseline.issues);
    }
    final candidate = _mergeWorldInfo(delta);
    if (candidate.issues.isEmpty) {
      _packOriginalExists = baseline.exists;
      _packOriginal = _eventCopy(baseline.raw);
    }
    return candidate;
  }

  void consumeRule(StateExecutionSource source, String localId) {
    final row = _writeRow(source, _PackDomain.rules);
    final fired = row.putIfAbsent('rules', () => <Object?>[])! as List<Object?>;
    if (!fired.contains(localId)) {
      fired.add(localId);
    }
  }

  void consumeEvent(StateExecutionSource source, String eventId, String handlerId, {required bool once}) {
    final row = _writeRow(source, _PackDomain.events);
    final events = row.putIfAbsent('events', () => <String, Object?>{})! as _Json;
    final consumed = events.putIfAbsent('consumed', () => <Object?>[])! as List<Object?>;
    consumed.add({'eventId': eventId, 'handlerId': handlerId});
    if (once) {
      final fired = events.putIfAbsent('once', () => <Object?>[])! as List<Object?>;
      if (!fired.contains(handlerId)) {
        fired.add(handlerId);
      }
    }
  }
}
