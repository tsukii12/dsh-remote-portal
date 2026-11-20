// Character Card V3 SPEC_V3.md, blob cb9749821955047890ac88aa84ec0b235ae0fb5d,
// plus the two native ST decorators at commit 7e8663cd9c184a550b37238218bdd32c6efc68e9.
part of 'world_info.dart';

/// One lexical header line. No macro expansion, fallback choice or runtime
/// context is evaluated by this descriptor.
class WorldInfoDecoratorHeaderLine {
  const WorldInfoDecoratorHeaderLine({
    required this.number,
    required this.offset,
    required this.isFallback,
    required this.name,
    required this.value,
  });

  /// One-based line number in the original content.
  final int number;

  /// Zero-based UTF-16 offset of the first @ in the original content.
  final int offset;
  final bool isFallback;
  final String? name;
  final String value;
}

/// Reads the same leading header boundary used by execution and regex intake.
/// The returned list is immutable; ordinary body lines are not decorators.
List<WorldInfoDecoratorHeaderLine> worldInfoDecoratorHeader(String content) =>
    List.unmodifiable(_decoratorHeader(content).lines);

/// Shared lexical boundary for execution and import inspection. This does not
/// decide runtime fallback eligibility or evaluate any macro.
({List<WorldInfoDecoratorHeaderLine> lines, int end}) _decoratorHeader(String text) {
  final lines = <WorldInfoDecoratorHeaderLine>[];
  var offset = 0;
  var number = 0;
  while (offset < text.length) {
    final line = RegExp(r'[^\r\n]*(?:\r\n|\r|\n|$)').matchAsPrefix(text, offset);
    if (line == null || line.end == offset) break;
    final raw = line[0]!.replaceFirst(RegExp(r'[\r\n]+$'), '');
    if (!raw.startsWith('@@')) break;
    final lineOffset = offset;
    offset = line.end;
    number++;
    final isFallback = raw.startsWith('@@@');
    final body = raw.substring(isFallback ? 3 : 2);
    final parsed = RegExp(r'^([a-z_]+)(?:[ \t]+(.*))?$').firstMatch(body);
    lines.add(
      WorldInfoDecoratorHeaderLine(
        number: number,
        offset: lineOffset,
        isFallback: isFallback,
        name: parsed?[1],
        value: (parsed?[2] ?? '').trim(),
      ),
    );
  }
  return (lines: lines, end: offset);
}

List<String>? _decoratorKeys(String text) {
  final keys = text.split(',').map((value) => value.trim()).toList();
  return keys.any((value) => value.isEmpty) ? null : keys;
}

/// Full V3 semantics. ST's limited parser is kept separately for timer hashes.
class _Decorators {
  _Decorators(this.entry, this.input) {
    final text = entry.content;
    final header = _decoratorHeader(text);
    var fallback = false;
    for (final line in header.lines) {
      if (line.isFallback && !fallback) continue;
      final name = line.name;
      if (name == null) {
        fallback = true;
        continue;
      }
      final accepted = _parse(name, line.value);
      fallback = accepted == null || (name != 'additional_keys' && values.containsKey(name));
      if (!fallback) {
        if (name == 'additional_keys') {
          additionalKeys.add(accepted as List<String>);
        } else {
          values[name] = accepted;
        }
      }
    }
    // V3 requires trimming newlines adjacent to decorator lines, but not the
    // ordinary content's spaces or trailing newlines.
    content = header.end == 0 ? text : text.substring(header.end).replaceFirst(RegExp(r'^[\r\n]+'), '');
  }

  final WorldInfoEntry entry;
  final WorldInfoInput input;
  final values = <String, Object?>{};
  final additionalKeys = <List<String>>[];
  late final String content;

  Object? _parse(String name, String text) {
    if (const {
      'activate',
      'dont_activate',
      'keep_activate_after_match',
      'dont_activate_after_match',
      'ignore_on_max_context',
    }.contains(name)) {
      if (text.isNotEmpty) return null;
      if (name == 'ignore_on_max_context' && input.contextAtCapacity == null) return null;
      return true;
    }
    if (const {
      'activate_only_after',
      'activate_only_every',
      'depth',
      'reverse_depth',
      'scan_depth',
      'is_greeting',
    }.contains(name)) {
      final number = num.tryParse(text);
      if (number == null || !number.isFinite) return null;
      if (name == 'activate_only_every' && number <= 0) return null;
      if ((name == 'activate_only_after' || name == 'activate_only_every') && input.assistantMessageCount == null) {
        return null;
      }
      if (name == 'is_greeting' && (input.greetingIndex == null || number < 0 || number != number.toInt())) return null;
      return number;
    }
    if (name == 'role') return const {'system': 0, 'user': 1, 'assistant': 2}[text];
    if (name == 'position') {
      if (text == 'before_desc' || text == 'after_desc') return text;
      if (text == 'personality' &&
          input.characterPersonality.isNotEmpty &&
          (input.availablePromptSections?.contains(text) ?? true)) {
        return text;
      }
      if (text == 'scenario' && input.scenario.isNotEmpty && (input.availablePromptSections?.contains(text) ?? true)) {
        return text;
      }
      return null;
    }
    if (name == 'additional_keys' || name == 'exclude_keys') {
      if (name == 'exclude_keys' && entry.useRegex) return null;
      return _decoratorKeys(text);
    }
    if (name == 'is_user_icon') return input.userIconName == null || text.isEmpty || text.contains(',') ? null : text;
    if (name == 'disable_ui_prompt') {
      return const {'system_prompt', 'post_history_instructions'}.contains(text) ? text : null;
    }
    return null;
  }

  bool get activate => values['activate'] == true;
  bool get dontActivate => values['dont_activate'] == true;
  bool get keepAfterMatch => values['keep_activate_after_match'] == true;
  bool get dontAfterMatch => values['dont_activate_after_match'] == true;
  bool get ignoreOnMaxContext => values['ignore_on_max_context'] == true;
  String? get section => values['position'] as String?;
  String? get disabledUiPrompt => values['disable_ui_prompt'] as String?;
  int? get scanDepth => (values['scan_depth'] as num?)?.toInt();
  int? get role => values['role'] as int?;
  bool get assistantPrefill {
    if (section != null || role != 2) {
      return false;
    }
    final explicitDepth = values['depth'] as num?;
    final reverse = values['reverse_depth'] as num?;
    final rawDepth = explicitDepth ?? (reverse == null ? null : input.messageCount - reverse);
    // A clamped or truncated depth of zero does not declare V3 prefill.
    return rawDepth == 0;
  }

  int? get depth {
    if (section != null) return null;
    final value = values['depth'] as num?;
    if (value != null) return math.min(input.messageCount, math.max(0, value.toInt()));
    final reverse = values['reverse_depth'] as num?;
    return reverse == null ? null : math.min(input.messageCount, math.max(0, (input.messageCount - reverse).toInt()));
  }

  Future<bool> allows(_ScanBuffer buffer, WorldInfoScanPhase phase) async {
    buffer.checkCancelled();
    final after = values['activate_only_after'] as num?;
    if (after != null && input.assistantMessageCount! < after) return false;
    final every = values['activate_only_every'] as num?;
    if (every != null && input.assistantMessageCount! % every != 0) return false;
    final greeting = values['is_greeting'] as num?;
    if (greeting != null && input.greetingIndex != greeting) return false;
    final icon = values['is_user_icon'];
    if (icon != null && input.userIconName != icon) return false;
    if (ignoreOnMaxContext && input.contextAtCapacity == true) return false;
    final text = buffer.get(entry, phase, scanDepth: scanDepth);
    for (var groupIndex = 0; groupIndex < additionalKeys.length; groupIndex++) {
      final expanded = additionalKeys[groupIndex].map(buffer.expand).toList();
      if (entry.useRegex) {
        for (var index = 0; index < expanded.length; index++) {
          await buffer.validate(expanded[index], entry, phase, 'content.@@additional_keys[$groupIndex][$index]');
          buffer.checkCancelled();
        }
      }
      var matched = false;
      for (var index = 0; index < expanded.length; index++) {
        final key = expanded[index];
        if (key.isEmpty) continue;
        matched = await buffer.matches(
          text,
          key.trim(),
          entry,
          phase,
          'content.@@additional_keys[$groupIndex][$index]',
        );
        buffer.checkCancelled();
        if (matched) break;
      }
      if (!matched) return false;
    }
    final excluded = values['exclude_keys'] as List<String>?;
    if (excluded != null) {
      for (var index = 0; index < excluded.length; index++) {
        final expanded = buffer.expand(excluded[index]);
        final found =
            expanded.isNotEmpty &&
            await buffer.matches(text, expanded.trim(), entry, phase, 'content.@@exclude_keys[$index]');
        buffer.checkCancelled();
        if (found) return false;
      }
    }
    return true;
  }
}

/// Observed admissions on the selected branch; prior imported history is never
/// guessed. A content hash change starts a fresh record. Same-count previews or
/// retries cannot increment a record twice.
class _DecoratorHistory {
  _DecoratorHistory(this.input, this.pack)
    : state = jsonDecode(jsonEncode(input.decoratorState)) as Map<String, Object?>;
  final WorldInfoInput input;
  final _PackWorldInfoState pack;
  final Map<String, Object?> state;
  _DecoratorHistory._fork(this.input, this.pack, this.state);
  _DecoratorHistory fork(_PackWorldInfoState candidate) =>
      _DecoratorHistory._fork(input, candidate, jsonDecode(jsonEncode(state)) as Map<String, Object?>);
  int previous(_RuntimeEntry entry) => entry.packSource == null
      ? math.max(0, _integer(_object(state['${entry.hash}'])['matches']) ?? 0)
      : pack.previous(entry);
  void finish(Iterable<_RuntimeEntry> activated) {
    if (input.dryRun) return;
    for (final entry in activated) {
      if (entry.packSource != null) {
        pack.finishAdmission(entry);
        continue;
      }
      final old = _object(state['${entry.hash}']);
      if (_integer(old['lastMessageCount']) == input.messageCount) continue;
      state['${entry.hash}'] = {...old, 'matches': previous(entry) + 1, 'lastMessageCount': input.messageCount};
    }
  }
}
