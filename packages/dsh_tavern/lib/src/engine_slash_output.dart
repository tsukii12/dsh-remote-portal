// Private STscript CC output policy and the single post-model effect unit.
// SillyTavern 7e8663cd9c184a550b37238218bdd32c6efc68e9, script.js
// 5485-5528 / 6442-6592 and reasoning.js 1429-1489 (AGPL-3.0).
// The public B2 decoded-result contract is deliberately unchanged.
part of 'engine.dart';

class _SlashOutputPolicy {
  _SlashOutputPolicy({
    required this.cleanup,
    required this.customStops,
    required this.expandCustomStops,
    required this.autoParseReasoning,
    required this.reasoningPrefix,
    required this.reasoningSuffix,
    required this.reasoningSeparator,
    required this.showThoughts,
  });

  factory _SlashOutputPolicy.capture(_ScriptGenerationCapture capture) {
    Map<String, Object?> object(Map<String, Object?> source, String key, String path) {
      if (!source.containsKey(key)) return <String, Object?>{};
      final value = source[key];
      if (value is Map<String, Object?>) return value;
      throw _scriptError(
        TavernScriptErrorCode.invalidArgument,
        'generate',
        'Expected an object in the captured generation settings.',
        contextId: capture.context.value.id,
        fieldPath: path,
      );
    }

    final power = object(capture.settings, 'power_user', 'power_user');
    final reasoning = object(power, 'reasoning', 'power_user.reasoning');
    bool boolean(Map<String, Object?> source, String key, bool fallback, String prefix) {
      if (!source.containsKey(key)) return fallback;
      final value = source[key];
      if (value is bool) return value;
      throw _scriptError(
        TavernScriptErrorCode.invalidArgument,
        'generate',
        'Expected a boolean in the captured generation settings.',
        contextId: capture.context.value.id,
        fieldPath: '$prefix.$key',
      );
    }

    String string(Map<String, Object?> source, String key, String fallback, String prefix) {
      if (!source.containsKey(key)) return fallback;
      final value = source[key];
      if (value is String) return value;
      throw _scriptError(
        TavernScriptErrorCode.invalidArgument,
        'generate',
        'Expected a string in the captured generation settings.',
        contextId: capture.context.value.id,
        fieldPath: '$prefix.$key',
      );
    }

    final preset = capture.promptPreset;
    if (preset == null) {
      throw StateError('A Slash generation must capture its effective CC parameter preset.');
    }
    return _SlashOutputPolicy(
      cleanup: StOutputCleanupOptions(
        collapseNewlines: boolean(power, 'collapse_newlines', false, 'power_user'),
        trimSentences: boolean(power, 'trim_sentences', false, 'power_user'),
        trimSpaces: boolean(power, 'trim_spaces', true, 'power_user'),
        allowUserName: boolean(power, 'allow_name1_display', false, 'power_user'),
        allowCharacterName: boolean(power, 'allow_name2_display', false, 'power_user'),
        fixMarkdown: boolean(power, 'auto_fix_generated_markdown', true, 'power_user'),
        disableGroupTrimming: boolean(power, 'disable_group_trimming', false, 'power_user'),
        userPromptBias: string(power, 'user_prompt_bias', '', 'power_user'),
      ),
      customStops: string(power, 'custom_stopping_strings', '', 'power_user'),
      expandCustomStops: boolean(power, 'custom_stopping_strings_macro', true, 'power_user'),
      autoParseReasoning: boolean(reasoning, 'auto_parse', false, 'power_user.reasoning'),
      reasoningPrefix: string(reasoning, 'prefix', '<think>', 'power_user.reasoning'),
      reasoningSuffix: string(reasoning, 'suffix', '</think>', 'power_user.reasoning'),
      reasoningSeparator: string(reasoning, 'separator', '\n', 'power_user.reasoning'),
      showThoughts: presetTruthy(preset.settings['show_thoughts']),
    );
  }

  final StOutputCleanupOptions cleanup;
  final String customStops;
  final bool expandCustomStops;
  final bool autoParseReasoning;
  final String reasoningPrefix, reasoningSuffix, reasoningSeparator;
  final bool showThoughts;

  /// Called at each real wire/cleanup stage. Only JSON decoding has the fixed
  /// compatibility fallback; a macro failure is never caught as bad JSON.
  List<String> stoppingStrings(_MacroEnvironment environment, List<String> ephemeral) {
    Object? decoded;
    if (customStops.isNotEmpty) {
      try {
        decoded = jsonDecode(customStops);
      } on FormatException {
        decoded = null;
      }
    }
    final permanent = <String>[];
    if (decoded is List<Object?>) {
      for (final value in decoded) {
        if (value is! String || value.isEmpty) continue;
        permanent.add(expandCustomStops ? environment.expand(value, const {}) : value);
      }
    }
    return [...permanent, ...ephemeral];
  }
}

extension _SlashGenerationOutput on _ScriptCoordinator {
  Future<String> _finishSlashGenerationOutput(
    _SlashInvocation invocation,
    _ScriptGenerationRecord child,
    TavernScriptGenerationResult decoded,
  ) async {
    final owner = invocation.owner;
    final spec = child.slashSpec!;
    final frozen = child.capture!;
    final policy = spec.outputPolicy;
    owner.checkAlive();
    owner.stage = TavernSlashEffectStage.outputCleanup;
    final unit = await _captureMacroUnit(
      owner,
      frozenGeneration: frozen,
      collapseNewlinesOverride: policy.cleanup.collapseNewlines,
      prepareCharacterFieldsOnDemand: false,
      // D-B3-COMPOSER-INPUT-01: frozen private composer projection is empty.
      input: '',
      generationType: spec.raw ? 'normal' : 'quiet',
    );
    try {
      owner.checkAlive();
      final environment = unit.environment;
      final diagnostics = <TavernScriptIssue>[];

      String regex(String text, int placement, String phase) {
        final rendered = environment.regex.applyWithDiagnostics(
          text,
          placement: placement,
          phase: RegexPhase.writeBack,
          expand: environment.regexExpand,
        );
        if (text.isNotEmpty) {
          diagnostics.add(
            TavernScriptIssue(
              code: 'slashOutputRegex',
              message: 'The output regex stage was evaluated once.',
              committed: false,
              contextId: owner.context.value.id,
              generationId: child.id,
              sourceSpan: invocation.sourceSpan,
              stage: 'outputCleanup',
              details: {
                'phase': phase,
                'placement': placement,
                'replacements': rendered.replacements,
                'warnings': [
                  for (final warning in rendered.warnings)
                    {
                      'ruleId': warning.ruleId,
                      'ruleName': warning.ruleName,
                      'ruleIndex': warning.ruleIndex,
                      'reason': warning.reason,
                      'message': warning.message,
                    },
                ],
              },
            ),
          );
        }
        return rendered.text;
      }

      String clean(
        String original, {
        required String phase,
        required bool incomplete,
        required bool bias,
        required bool trimNames,
        required bool trimWrongNames,
      }) => stCleanUpMessage(
        original,
        options: policy.cleanup,
        expand: (text) => environment.expand(text, const {}),
        stoppingStrings: () => policy.stoppingStrings(environment, spec.ephemeralStops),
        outputRegex: (text) => regex(text, RegexPlacement.aiOutput, phase),
        userName: () => environment.userName,
        characterName: unit.requireCharacterName,
        groupNames: () => frozen.groupView?.names ?? const [],
        isGroup: frozen.groupView != null,
        includeUserPromptBias: bias,
        displayIncompleteSentences: incomplete,
        trimNames: trimNames,
        trimWrongNames: trimWrongNames,
      );

      String reasoning() {
        final original = policy.showThoughts ? child.reasoning.toString() : '';
        final text = regex(original, RegexPlacement.reasoning, 'providerReasoning');
        return policy.cleanup.trimSpaces ? trimJsWhitespace(text) : text;
      }

      late final String output;
      try {
        if (spec.raw) {
          final text = clean(
            decoded.text,
            phase: 'raw',
            incomplete: true,
            bias: false,
            trimNames: spec.trimNames,
            trimWrongNames: spec.trimNames,
          );
          if (text.isEmpty) {
            throw TavernScriptException(
              code: TavernScriptErrorCode.model,
              operation: 'slashOutputCleanup',
              message: 'The raw generation produced an empty cleaned response.',
              contextId: owner.context.value.id,
              generationId: child.id,
              executionId: owner.id,
              sourceSpan: invocation.sourceSpan,
              modelFailure: TavernFailure.server,
            );
          }
          output = text;
        } else {
          // C1's text is intentionally discarded; its effects remain in this unit.
          clean(decoded.text, phase: 'quietC1', incomplete: false, bias: true, trimNames: true, trimWrongNames: true);
          // Provider reasoning is a separate channel. Do not inspect text tags or
          // use the public result.reasoning presentation switch to infer absence.
          reasoning();
          var text = clean(
            decoded.text,
            phase: 'quietC2',
            incomplete: !spec.quietToLoud,
            bias: true,
            trimNames: true,
            trimWrongNames: true,
          );
          if (spec.trimToSentence) text = stTrimToEndSentence(text);
          output = stRemoveInlineReasoning(
            text,
            autoParse: policy.autoParseReasoning,
            prefix: policy.reasoningPrefix,
            suffix: policy.reasoningSuffix,
            trimSpaces: policy.cleanup.trimSpaces,
          );
        }
        unit.checkDependencies();
      } catch (_) {
        owner.observeIssues(diagnostics);
        // Legacy compatibility catches cannot turn a missing real source into a
        // literal fallback accepted by this compound operation.
        unit.checkDependencies();
        rethrow;
      }
      owner.observeIssues(diagnostics);
      owner.checkAlive();
      await _commitMacroUnit(owner, unit, stage: TavernSlashEffectStage.outputCleanup, operation: 'slashOutputCleanup');
      owner.checkAlive();
      return output;
    } finally {
      _discardMacroUnit(owner, unit);
    }
  }
}
