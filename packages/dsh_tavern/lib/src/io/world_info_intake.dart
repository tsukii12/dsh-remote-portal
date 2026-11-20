import 'dart:convert';

import '../import_report.dart';
import '../worldinfo/world_info.dart';

/// Static capabilities of the stored document, not a predicted activation.
final class WorldInfoIntakeResult {
  WorldInfoIntakeResult({required Map<String, int> counts, required Iterable<TavernImportFinding> findings})
    : counts = Map.unmodifiable(counts),
      findings = List.unmodifiable(findings);
  final Map<String, int> counts;
  final List<TavernImportFinding> findings;
}

/// Does not compile patterns, expand macros, choose a runtime fallback, or
/// change [raw]. Regex compilation receipts are combined by the caller.
WorldInfoIntakeResult inspectWorldInfoFeatures(Map<String, Object?> raw, {String path = r'$', bool embedded = false}) =>
    _WorldInfoIntake(raw, path, embedded).inspect();

class _WorldInfoIntake {
  _WorldInfoIntake(this.raw, this.path, this.embedded);
  final Map<String, Object?> raw;
  final String path;
  final bool embedded;
  final findings = <TavernImportFinding>[];
  final counts = <String, int>{
    'worldInfoBooks': 1,
    'entriesStored': 0,
    'entriesInExecutionView': 0,
    'entriesEnabled': 0,
    'entriesDisabled': 0,
    'entriesShadowed': 0,
    'primaryKeys': 0,
    'secondaryKeys': 0,
    'ignoredKeywordValues': 0,
    'decoratorLines': 0,
    'recognizedDecorators': 0,
    'unknownDecorators': 0,
    'unavailableDecorators': 0,
    'invalidDecoratorValues': 0,
    'invalidDecoratorSyntax': 0,
    'fallbackDecoratorLines': 0,
    'unknownPreservedFields': 0,
  };

  void increment(String name, [int amount = 1]) => counts[name] = (counts[name] ?? 0) + amount;

  void add(
    String location,
    String code,
    String message,
    TavernImportFindingKind kind, {
    String? identifier,
    WorldInfoDecoratorHeaderLine? header,
    bool conditional = false,
  }) {
    findings.add(
      TavernImportFinding(
        path: location,
        code: code,
        message: message,
        kind: kind,
        identifier: identifier,
        line: header?.number,
        offset: header?.offset,
        conditional: conditional || header?.isFallback == true,
        fallback: header?.isFallback == true,
      ),
    );
  }

  WorldInfoIntakeResult inspect() {
    unknownFields(raw, _bookFields, path);
    opaqueExtensions(raw['extensions'], _field(path, 'extensions'));
    for (final key in const ['scan_depth', 'token_budget', 'recursive_scanning']) {
      if (!raw.containsKey(key)) {
        continue;
      }
      final value = raw[key];
      final valid = key == 'recursive_scanning' ? value is bool : value is num && value.isFinite;
      add(
        _field(path, key),
        valid
            ? switch (key) {
                'scan_depth' => 'wi-book-scan-depth-ignored',
                'token_budget' => 'wi-book-token-budget-ignored',
                _ => 'wi-book-recursion-setting-ignored',
              }
            : 'wi-invalid-book-field',
        valid
            ? switch (key) {
                'scan_depth' => '书级扫描深度已保留；当前使用全局设置和条目扫描深度。',
                'token_budget' => '书级 token 预算已保留；当前没有每本书独立预算。',
                _ => '书级递归开关未执行；true 和 false 均不覆盖当前全局及条目递归设置。',
              }
            : '此书级字段的值类型不适用，保留原值而不执行。',
        valid ? TavernImportFindingKind.unsupported : TavernImportFindingKind.invalid,
      );
    }

    final entries = raw['entries'];
    var malformed = false;
    if (entries is Map<String, Object?>) {
      counts['entriesStored'] = entries.length;
      for (final entry in entries.entries) {
        if (entry.value is Map<String, Object?>) {
          continue;
        }
        malformed = true;
        add(
          '$path.entries[${jsonEncode(entry.key)}]',
          'wi-invalid-entry',
          '世界书条目必须为对象；原始数据保留，但此书不能进入执行视图。',
          TavernImportFindingKind.invalid,
        );
      }
    } else if (entries is List<Object?>) {
      counts['entriesStored'] = entries.length;
      for (var index = 0; index < entries.length; index++) {
        if (entries[index] is Map<String, Object?>) {
          continue;
        }
        malformed = true;
        add(
          '$path.entries[$index]',
          'wi-invalid-entry',
          '世界书条目必须为对象；原始数据保留，但此书不能进入执行视图。',
          TavernImportFindingKind.invalid,
        );
      }
    } else {
      malformed = true;
      add(
        _field(path, 'entries'),
        'wi-invalid-entries',
        '当前世界书需要根 entries 对象或数组；此结构没有可执行的条目视图。',
        TavernImportFindingKind.invalid,
      );
    }
    if (malformed) {
      countUnparsedKeywords(entries);
      return finish();
    }

    final WorldInfoBook book;
    try {
      book = WorldInfoBook.fromJson(
        id: 'intake',
        source: embedded ? WorldInfoSource.character : WorldInfoSource.global,
        json: raw,
      );
    } on FormatException {
      countUnparsedKeywords(entries);
      add(path, 'wi-invalid-book', '世界书无法按当前条目格式读取。', TavernImportFindingKind.invalid);
      return finish();
    } on JsonUnsupportedObjectError {
      countUnparsedKeywords(entries);
      add(path, 'wi-invalid-book', '世界书含不能保存为 JSON 的值。', TavernImportFindingKind.invalid);
      return finish();
    }
    counts['entriesInExecutionView'] = book.entries.length;
    counts['entriesEnabled'] = book.entries.where((entry) => !entry.disabled).length;
    counts['entriesDisabled'] = book.entries.where((entry) => entry.disabled).length;
    counts['entriesShadowed'] = counts['entriesStored']! - book.entries.length;
    final stored = worldInfoStoredEntries(book).toList();
    final lastById = <String, String>{for (final row in stored) row.entry.uid: row.path};
    final v3 = entries is List<Object?>;
    for (final row in stored) {
      final entryPath = '$path.${row.path}';
      inspectEntry(row.entry, entryPath, v3);
      if (v3 && lastById[row.entry.uid] != row.path) {
        add(
          entryPath,
          'wi-shadowed-entry',
          '同一 ID 的后续条目覆盖此行；此原始行仍保留供导出。',
          TavernImportFindingKind.conditional,
          identifier: row.entry.uid,
          conditional: true,
        );
      }
    }
    return finish();
  }

  WorldInfoIntakeResult finish() {
    counts['unsupportedWorldInfoFeatures'] = findings
        .where((value) => value.kind == TavernImportFindingKind.unsupported)
        .length;
    return WorldInfoIntakeResult(counts: counts, findings: findings);
  }

  void countUnparsedKeywords(Object? entries) {
    if (entries is List<Object?>) {
      for (var index = 0; index < entries.length; index++) {
        final entry = entries[index];
        if (entry is! Map<String, Object?>) {
          continue;
        }
        keywords(entry['keys'], '$path.entries[$index].keys', 'primaryKeys', null);
        keywords(entry['secondary_keys'], '$path.entries[$index].secondary_keys', 'secondaryKeys', null);
      }
    } else if (entries is Map<String, Object?>) {
      for (final row in entries.entries) {
        final entry = row.value;
        if (entry is! Map<String, Object?>) {
          continue;
        }
        final location = '$path.entries[${jsonEncode(row.key)}]';
        keywords(entry['key'], '$location.key', 'primaryKeys', null);
        keywords(entry['keysecondary'], '$location.keysecondary', 'secondaryKeys', null);
      }
    }
  }

  void inspectEntry(WorldInfoEntry entry, String entryPath, bool v3) {
    final data = entry.raw;
    final id = entry.uid;
    unknownFields(data, v3 ? _v3EntryFields : _nativeEntryFields, entryPath, identifier: id);
    keywords(data[v3 ? 'keys' : 'key'], _field(entryPath, v3 ? 'keys' : 'key'), 'primaryKeys', id);
    keywords(
      data[v3 ? 'secondary_keys' : 'keysecondary'],
      _field(entryPath, v3 ? 'secondary_keys' : 'keysecondary'),
      'secondaryKeys',
      id,
    );
    final extensionValue = data['extensions'];
    final extensions = extensionValue is Map<String, Object?> ? extensionValue : const <String, Object?>{};
    if (v3) {
      unknownFields(extensions, _v3EntryExtensions, _field(entryPath, 'extensions'), identifier: id);
      if (extensionValue != null && extensionValue is! Map<String, Object?>) {
        add(
          _field(entryPath, 'extensions'),
          'wi-invalid-extensions',
          '条目 extensions 不是对象；当前扩展读取会使用默认值。',
          TavernImportFindingKind.invalid,
          identifier: id,
        );
      }
    } else {
      opaqueExtensions(extensionValue, _field(entryPath, 'extensions'), identifier: id);
    }
    final options = v3 ? extensions : data;
    final optionPath = v3 ? _field(entryPath, 'extensions') : entryPath;
    final vector = options['vectorized'];
    if (vector == true) {
      add(
        _field(optionPath, 'vectorized'),
        'wi-vector-activation-unavailable',
        '向量召回激活尚未实现；字段保留，普通关键词和常驻等路径仍可使用。',
        TavernImportFindingKind.unsupported,
        identifier: id,
      );
    } else if (vector != null && vector is! bool) {
      add(
        _field(optionPath, 'vectorized'),
        'wi-invalid-vector-flag',
        '向量开关不是布尔值；原值保留，当前没有向量激活执行链路。',
        TavernImportFindingKind.invalid,
        identifier: id,
      );
    }
    final automationKey = v3 ? 'automation_id' : 'automationId';
    final automation = options[automationKey];
    if (automation is String && automation.isNotEmpty) {
      add(
        _field(optionPath, automationKey),
        'wi-automation-unavailable',
        '命中后的 automation ID 自动执行尚未实现；世界书正文仍可按其他条件注入。',
        TavernImportFindingKind.unsupported,
        identifier: id,
      );
    } else if (automation != null && automation is! String) {
      add(
        _field(optionPath, automationKey),
        'wi-invalid-automation-id',
        'automation ID 不是字符串，原值保留而不执行。',
        TavernImportFindingKind.invalid,
        identifier: id,
      );
    }
    if (v3 && data.containsKey('priority')) {
      final priority = data['priority'];
      final valid = priority is num && priority.isFinite;
      add(
        _field(entryPath, 'priority'),
        valid ? 'wi-entry-priority-ignored' : 'wi-invalid-entry-priority',
        valid ? '条目 priority 已保留；当前不按此字段进行书级预算淘汰。' : '条目 priority 不是有限数值，原值保留而不执行。',
        valid ? TavernImportFindingKind.unsupported : TavernImportFindingKind.invalid,
        identifier: id,
      );
    }
    triggers(options['triggers'], _field(optionPath, 'triggers'), id);
    if (data['content'] != null && data['content'] is! String) {
      add(
        _field(entryPath, 'content'),
        'wi-invalid-content',
        '条目正文不是字符串，当前执行视图使用空正文。',
        TavernImportFindingKind.invalid,
        identifier: id,
      );
    }
    decorators(entry, _field(entryPath, 'content'));
  }

  void keywords(Object? value, String location, String counter, String? id) {
    if (value == null) {
      return;
    }
    if (value is! List<Object?>) {
      add(location, 'wi-invalid-key-list', '关键词不是数组，当前执行视图忽略此值。', TavernImportFindingKind.invalid, identifier: id);
      return;
    }
    for (var index = 0; index < value.length; index++) {
      if (value[index] is String) {
        increment(counter);
      } else {
        increment('ignoredKeywordValues');
        add(
          '$location[$index]',
          'wi-invalid-key',
          '非字符串关键词已保留，但不参加匹配。',
          TavernImportFindingKind.invalid,
          identifier: id,
        );
      }
    }
  }

  void triggers(Object? value, String location, String id) {
    if (value == null) {
      return;
    }
    if (value is! List<Object?>) {
      add(
        location,
        'wi-invalid-trigger-list',
        '生成事件过滤不是数组，当前执行视图忽略此值。',
        TavernImportFindingKind.invalid,
        identifier: id,
      );
      return;
    }
    for (var index = 0; index < value.length; index++) {
      final trigger = value[index];
      if (_engineTriggers.contains(trigger)) {
        continue;
      }
      final known = trigger == 'swipe' || trigger == 'quiet';
      add(
        '$location[$index]',
        trigger is! String
            ? 'wi-invalid-trigger'
            : known
            ? 'wi-generation-trigger-unavailable'
            : 'wi-unknown-generation-trigger',
        trigger is! String
            ? '非字符串生成事件已保留，但不参加过滤。'
            : known
            ? '当前酒馆回合接口不产生此 ST 生成事件；其他受支持事件仍可执行。'
            : '此生成事件不是当前已知事件；保留原值，不推断它的含义。',
        trigger is! String
            ? TavernImportFindingKind.invalid
            : known
            ? TavernImportFindingKind.unsupported
            : TavernImportFindingKind.unknown,
        identifier: id,
      );
    }
  }

  void opaqueExtensions(Object? value, String location, {String? identifier}) {
    if (value == null) {
      return;
    }
    if (value is Map<String, Object?>) {
      unknownFields(value, const <String>{}, location, identifier: identifier);
    } else {
      add(
        location,
        'wi-invalid-extensions',
        'extensions 不是对象；原值保留，未推断其执行含义。',
        TavernImportFindingKind.invalid,
        identifier: identifier,
      );
    }
  }

  void unknownFields(Map<String, Object?> object, Set<String> known, String location, {String? identifier}) {
    for (final key in object.keys) {
      if (known.contains(key)) {
        continue;
      }
      increment('unknownPreservedFields');
      add(
        _field(location, key),
        'wi-unknown-field-preserved',
        '未知字段原样保留；当前不解释其用途，不据此推断为执行功能。',
        TavernImportFindingKind.unknown,
        identifier: identifier,
      );
    }
  }

  void decorators(WorldInfoEntry entry, String location) {
    final headers = worldInfoDecoratorHeader(entry.content);
    increment('decoratorLines', headers.length);
    final states = [for (final header in headers) _decoratorState(header.name, header.value, entry.useRegex)];
    bool override(WorldInfoDecoratorHeaderLine header, _DecoratorState state) =>
        (state == _DecoratorState.valid || state == _DecoratorState.contextual) &&
        const {'depth', 'reverse_depth', 'position'}.contains(header.name);
    final hasPossibleOverride = [
      for (var index = 0; index < headers.length; index++) override(headers[index], states[index]),
    ].any((value) => value);
    final hasGuaranteedOverride = [
      for (var index = 0; index < headers.length; index++)
        !headers[index].isFallback && states[index] == _DecoratorState.valid && override(headers[index], states[index]),
    ].any((value) => value);
    final seen = <String>{};
    for (var index = 0; index < headers.length; index++) {
      final header = headers[index];
      final state = states[index];
      final name = header.name;
      if (header.isFallback) {
        increment('fallbackDecoratorLines');
      }
      if (name == null) {
        increment('invalidDecoratorSyntax');
        add(
          location,
          'wi-invalid-decorator-syntax',
          '装饰器 header 语法无效；原文保留，运行时忽略此 header 行。',
          TavernImportFindingKind.invalid,
          identifier: entry.uid,
          header: header,
        );
        continue;
      }
      if (_recognizedDecorators.contains(name)) {
        increment('recognizedDecorators');
      } else if (_instructDecorators.contains(name)) {
        increment('unavailableDecorators');
      } else {
        increment('unknownDecorators');
      }
      if (state == _DecoratorState.invalid) {
        increment('invalidDecoratorValues');
        add(
          location,
          'wi-invalid-decorator-value',
          '此装饰器的参数不适用，运行时忽略并考虑后备分支。',
          TavernImportFindingKind.invalid,
          identifier: entry.uid,
          header: header,
        );
        continue;
      }
      if (state == _DecoratorState.unknown) {
        add(
          location,
          'wi-unknown-decorator-preserved',
          '未知装饰器不执行；源数据保留，若后备分支可用则按链处理。',
          TavernImportFindingKind.unknown,
          identifier: entry.uid,
          header: header,
        );
        continue;
      }
      if (state == _DecoratorState.instruct) {
        add(
          location,
          'wi-instruct-decorator-inapplicable',
          '当前是聊天上下文，没有 token 位置的 instruct 执行路径；此项保留并允许后备分支。',
          TavernImportFindingKind.conditional,
          identifier: entry.uid,
          header: header,
          conditional: true,
        );
        continue;
      }
      if (state == _DecoratorState.ignored) {
        add(
          location,
          'wi-regex-exclude-ignored',
          'V3 use_regex 模式按既定规则忽略 exclude_keys；不作为引擎缺失。',
          TavernImportFindingKind.conditional,
          identifier: entry.uid,
          header: header,
          conditional: true,
        );
        continue;
      }
      final duplicate = name != 'additional_keys' && !seen.add(name);
      if (duplicate) {
        add(
          location,
          'wi-duplicate-decorator-conditional',
          '前面的同名装饰器被接受时，此项不再执行；实际选择取决于上下文和后备分支。',
          TavernImportFindingKind.conditional,
          identifier: entry.uid,
          header: header,
          conditional: true,
        );
      }
      if (state == _DecoratorState.contextual) {
        add(
          location,
          'wi-decorator-context-required',
          _contextMessage(name),
          TavernImportFindingKind.conditional,
          identifier: entry.uid,
          header: header,
          conditional: true,
        );
      }
      if (entry.position == 7 && !hasGuaranteedOverride && (name == 'role' || name == 'ignore_on_max_context')) {
        final conditional = header.isFallback || hasPossibleOverride || duplicate;
        add(
          location,
          name == 'role' ? 'wi-outlet-role-unapplied' : 'wi-outlet-trim-unapplied',
          name == 'role' ? '最终仍为 outlet 时，此角色设置不改变承载 outlet 的宿主消息角色。' : '最终仍为 outlet 字符串时，不能按此装饰器单独裁剪该片段。',
          conditional ? TavernImportFindingKind.conditional : TavernImportFindingKind.unsupported,
          identifier: entry.uid,
          header: header,
          conditional: conditional,
        );
      }
    }
  }
}

enum _DecoratorState { valid, contextual, ignored, invalid, instruct, unknown }

_DecoratorState _decoratorState(String? name, String value, bool useRegex) {
  if (_instructDecorators.contains(name)) {
    return _DecoratorState.instruct;
  }
  if (!_recognizedDecorators.contains(name)) {
    return _DecoratorState.unknown;
  }
  if (const {
    'activate',
    'dont_activate',
    'keep_activate_after_match',
    'dont_activate_after_match',
    'ignore_on_max_context',
  }.contains(name)) {
    if (value.isNotEmpty) {
      return _DecoratorState.invalid;
    }
    return const {'keep_activate_after_match', 'dont_activate_after_match'}.contains(name)
        ? _DecoratorState.contextual
        : _DecoratorState.valid;
  }
  if (const {
    'activate_only_after',
    'activate_only_every',
    'depth',
    'reverse_depth',
    'scan_depth',
    'is_greeting',
  }.contains(name)) {
    final number = num.tryParse(value);
    if (number == null ||
        !number.isFinite ||
        (name == 'activate_only_every' && number <= 0) ||
        (name == 'is_greeting' && (number < 0 || number != number.toInt()))) {
      return _DecoratorState.invalid;
    }
    return const {'activate_only_after', 'activate_only_every', 'is_greeting'}.contains(name)
        ? _DecoratorState.contextual
        : _DecoratorState.valid;
  }
  if (name == 'role') {
    return const {'system', 'user', 'assistant'}.contains(value) ? _DecoratorState.valid : _DecoratorState.invalid;
  }
  if (name == 'position') {
    if (value == 'before_desc' || value == 'after_desc') {
      return _DecoratorState.valid;
    }
    if (value == 'personality' || value == 'scenario') {
      return _DecoratorState.contextual;
    }
    return _DecoratorState.invalid;
  }
  if (name == 'additional_keys' || name == 'exclude_keys') {
    if (name == 'exclude_keys' && useRegex) {
      return _DecoratorState.ignored;
    }
    return value.split(',').any((key) => key.trim().isEmpty) ? _DecoratorState.invalid : _DecoratorState.valid;
  }
  if (name == 'is_user_icon') {
    return value.isEmpty || value.contains(',') ? _DecoratorState.invalid : _DecoratorState.contextual;
  }
  return const {'system_prompt', 'post_history_instructions'}.contains(value)
      ? _DecoratorState.valid
      : _DecoratorState.invalid;
}

String _contextMessage(String name) => switch (name) {
  'is_greeting' => '需要当前分支已知的开场编号；未知时忽略并考虑后备分支。',
  'is_user_icon' => '需要显式的 userIconName；不从头像路径猜测 V3 资源名称。',
  'position' => '此位置需要非空角色字段及当前预设启用对应槽位；导入时不假定槽位状态。',
  'keep_activate_after_match' || 'dont_activate_after_match' => '使用本分支已记录的命中历史，不推测导入前发生过的命中。',
  _ => '需要当前聊天的角色消息计数；导入时不预测是否满足条件。',
};

String _field(String base, String key) =>
    RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(key) ? '$base.$key' : '$base[${jsonEncode(key)}]';

const _engineTriggers = {'normal', 'continue', 'regenerate', 'impersonate'};
const _instructDecorators = {'instruct_depth', 'reverse_instruct_depth', 'instruct_scan_depth'};
const _recognizedDecorators = {
  'activate',
  'dont_activate',
  'keep_activate_after_match',
  'dont_activate_after_match',
  'ignore_on_max_context',
  'activate_only_after',
  'activate_only_every',
  'depth',
  'reverse_depth',
  'scan_depth',
  'is_greeting',
  'role',
  'position',
  'additional_keys',
  'exclude_keys',
  'is_user_icon',
  'disable_ui_prompt',
};
const _bookFields = {
  'name',
  'description',
  'entries',
  'extensions',
  'originalData',
  'scan_depth',
  'token_budget',
  'recursive_scanning',
};
const _v3EntryFields = {
  'keys',
  'secondary_keys',
  'content',
  'extensions',
  'enabled',
  'insertion_order',
  'case_sensitive',
  'use_regex',
  'constant',
  'name',
  'priority',
  'id',
  'comment',
  'selective',
  'position',
};
const _nativeEntryFields = {
  'uid',
  'world',
  'hash',
  'decorators',
  'key',
  'keysecondary',
  'name',
  'comment',
  'content',
  'constant',
  'vectorized',
  'selective',
  'selectiveLogic',
  'addMemo',
  'order',
  'position',
  'disable',
  'ignoreBudget',
  'excludeRecursion',
  'preventRecursion',
  'matchPersonaDescription',
  'matchCharacterDescription',
  'matchCharacterPersonality',
  'matchCharacterDepthPrompt',
  'matchScenario',
  'matchCreatorNotes',
  'delayUntilRecursion',
  'probability',
  'useProbability',
  'depth',
  'outletName',
  'group',
  'groupOverride',
  'groupWeight',
  'scanDepth',
  'caseSensitive',
  'matchWholeWords',
  'useGroupScoring',
  'automationId',
  'role',
  'sticky',
  'cooldown',
  'delay',
  'triggers',
  'characterFilter',
  'displayIndex',
  'extensions',
  'case_sensitive',
  'use_regex',
};
const _v3EntryExtensions = {
  'position',
  'exclude_recursion',
  'prevent_recursion',
  'delay_until_recursion',
  'display_index',
  'probability',
  'useProbability',
  'depth',
  'selectiveLogic',
  'outlet_name',
  'group',
  'group_override',
  'group_weight',
  'scan_depth',
  'case_sensitive',
  'match_whole_words',
  'use_group_scoring',
  'automation_id',
  'role',
  'vectorized',
  'sticky',
  'cooldown',
  'delay',
  'match_persona_description',
  'match_character_description',
  'match_character_personality',
  'match_character_depth_prompt',
  'match_scenario',
  'match_creator_notes',
  'triggers',
  'ignore_budget',
};
