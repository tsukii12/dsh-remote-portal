part of 'state_engine.dart';

/// Internal compile-only input. The caller already retained each source's
/// presence/version eligibility and passes its original state declaration.
typedef StateCompositionRuleSource = ({Map<String, Object?> source, String sourcePath, Map<String, Object?> state});

/// Plain owned inspection data, never a runnable definition or session.
final class StateCompositionInspection {
  const StateCompositionInspection({
    required this.executable,
    required this.definitionIssues,
    required this.ruleIssues,
    required this.rules,
    required this.validated,
    required this.valueIssues,
    required this.secretExecutable,
    required this.secretIssues,
  });

  final bool executable;
  final List<Map<String, Object?>> definitionIssues;
  final List<Map<String, Object?>> ruleIssues;
  final List<Map<String, Object?>> rules;
  final bool validated;
  final List<Map<String, Object?>> valueIssues;
  final bool secretExecutable;
  final List<Map<String, Object?>> secretIssues;
}

/// Compiles the final schema once. Rule identity/counting stays within each
/// original source while declaration slots share the existing total limit.
StateCompositionInspection inspectStateComposition(
  Object? state, {
  Object? version = 1,
  required List<StateCompositionRuleSource> sources,
  required bool compositionEligible,
  bool validateValue = false,
  bool valueExists = false,
  Object? value,
  Object? secretSlots,
  Object? secretVersion = 1,
}) {
  final schemaState = state is Map<String, Object?> ? (<String, Object?>{...state}..remove('rules')) : state;
  final definition = StateDefinition.parse(schemaState, version: version);
  final compiled = definition.executable
      ? _compileCompositionRules([
          for (final source in sources)
            (
              state: source.state,
              source: source.source,
              sourcePath: source.sourcePath,
              executionSource: const StateExecutionSource.legacy(),
              actionTargets: const {},
            ),
        ])
      : (compiled: <_Rule>[], issues: <_Json>[], summaries: <_Json>[]);
  final validated = validateValue && compositionEligible && definition.executable;
  final valueIssues = validated ? definition.validate(value, valueExists: valueExists) : <Map<String, Object?>>[];
  final secret = SecretDefinition.parse(secretSlots, state: definition, version: secretVersion);
  return StateCompositionInspection(
    executable: definition.executable,
    definitionIssues: definition.issues,
    ruleIssues: compiled.issues,
    rules: compiled.summaries,
    validated: validated,
    valueIssues: valueIssues,
    secretExecutable: secret.executable,
    secretIssues: secret.issues,
  );
}

typedef _CompositionRuleInput = ({
  _Json state,
  _Json source,
  String sourcePath,
  StateExecutionSource executionSource,
  Map<(int, int), StateEventTarget> actionTargets,
});

({List<_Rule> compiled, List<_Json> issues, List<_Json> summaries}) _compileCompositionRules(
  Iterable<_CompositionRuleInput> sources,
) {
  final compiled = <_Rule>[], issues = <_Json>[], summaries = <_Json>[];
  var remaining = 256;
  for (final source in sources) {
    final carrier = StateDefinition._uncompiled(source.state);
    _compileRules(carrier, slotLimit: remaining, source: source.executionSource, actionTargets: source.actionTargets);
    for (final issue in carrier.issues) {
      issues.add({
        'diagnostic': issue,
        'source': source.source,
        'sourcePath': '${source.sourcePath}${issue['path']! as String}',
      });
    }
    final declarations = source.state['rules'];
    if (declarations is List<Object?>) {
      if (remaining < 256 && declarations.length > remaining) {
        issues.add({
          'diagnostic': _issue(
            'rules_composition_limit',
            '/rules',
            'Rules beyond the shared 256 declaration slots are not compiled.',
          ),
          'source': source.source,
          'sourcePath': '${source.sourcePath}/rules',
        });
      }
      remaining = declarations.length >= remaining ? 0 : remaining - declarations.length;
    }
    compiled.addAll(carrier._rules);
    for (final rule in carrier._rules) {
      summaries.add({
        'source': source.source,
        'sourcePath': '${source.sourcePath}/rules/${rule.index}',
        'index': rule.index,
        'key': rule.key,
        'once': rule.once,
      });
    }
  }
  return (compiled: compiled, issues: issues, summaries: summaries);
}

StateDefinition _composeStateDefinition(
  Object? state, {
  required Object? version,
  required String effectiveConfigId,
  required Iterable<StateRuleSource> sources,
  required bool compositionEligible,
}) {
  final retained = sources.toList();
  final schemaState = state is _Json ? (<String, Object?>{...state}..remove('rules')) : state;
  final definition = StateDefinition.parse(schemaState, version: version);
  final nativeExecutable = definition.executable;
  definition._compositionIdentity = {
    'effectiveConfigId': effectiveConfigId,
    'sources': [
      for (final source in retained)
        {
          'source': source.source.toJson(),
          'state': source._state,
          'actionTargets': _actionTargetIdentity(source._actionTargets),
        },
    ],
  };
  definition._compositionEligible = compositionEligible;
  if (!compositionEligible) {
    definition._issues.add(
      _issue('state_composition', '', 'The admitted source composition is not eligible for execution.'),
    );
  }
  if (nativeExecutable) {
    final compiled = _compileCompositionRules([
      for (final source in retained)
        (
          state: source._state,
          source: source.source.toJson(),
          sourcePath: '/state',
          executionSource: source.source,
          actionTargets: source._actionTargets,
        ),
    ]);
    definition._rules.addAll(compiled.compiled);
    for (final row in compiled.issues) {
      definition._issues.add({
        ...row['diagnostic']! as _Json,
        'source': row['source'],
        'sourcePath': row['sourcePath'],
      });
    }
  }
  return definition;
}

CardEventDefinition _composeCardEventDefinition(
  Iterable<CardEventRegistrySource> sources, {
  required String effectiveConfigId,
  required bool compositionEligible,
}) {
  final retained = sources.toList();
  final definition = CardEventDefinition._composed({
    'registries': [
      for (final source in retained)
        {
          'source': source.source.toJson(),
          'version': source._version,
          'raw': source._raw,
          'actionTargets': _actionTargetIdentity(source._actionTargets),
          'eventTargets': [
            for (final index in (source._eventTargets.keys.toList()..sort()))
              {
                'index': index,
                'source': source._eventTargets[index]!.source.toJson(),
                'name': source._eventTargets[index]!.name,
              },
          ],
        },
    ],
  }, defined: retained.any((source) => source._raw != null));
  definition._compositionIdentity = {'effectiveConfigId': effectiveConfigId};
  var eligible = compositionEligible;
  var declared = 0;
  for (final source in retained) {
    final parsed = CardEventDefinition.parse(source._raw, version: source._version);
    for (final issue in parsed.issues) {
      definition._issues.add({
        ...issue,
        'source': source.source.toJson(),
        'sourcePath': '/director/eventRules${issue['path']! as String}',
      });
    }
    final raw = source._raw;
    if (raw is _Json && raw['rules'] is List<Object?>) {
      declared += (raw['rules']! as List<Object?>).length;
    }
    if (parsed.defined && !parsed.executable) {
      eligible = false;
    }
    for (final handler in parsed._handlers) {
      definition._handlers.add(
        _EventHandler(
          handler.id,
          handler.name,
          handler.index,
          handler.once,
          handler.condition,
          handler.expectations,
          handler.actions,
          source: source.source,
          eventTarget: source._eventTargets[handler.index],
          actionTargets: {
            for (final entry in source._actionTargets.entries)
              if (entry.key.$1 == handler.index) entry.key.$2: entry.value,
          },
        ),
      );
    }
  }
  if (declared > 256) {
    eligible = false;
    definition._issues.add(
      _issue(
        'card_events_composition_limit',
        '/rules',
        'The composed event registries exceed 256 original handler declarations.',
      ),
    );
  }
  definition._executable = definition.defined && eligible;
  if (!eligible) {
    definition._issues.add(
      _issue('card_events_composition', '', 'The admitted event composition is not eligible for execution.'),
    );
  }
  return definition;
}
