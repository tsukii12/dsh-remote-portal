import 'dart:convert';

import 'package:dsh_tavern/src/import_report.dart';
import 'package:dsh_tavern/src/io/world_info_intake.dart';
import 'package:dsh_tavern/src/worldinfo/world_info.dart';
import 'package:test/test.dart';

void main() {
  test('ordinary native features metadata and inactive states are not incompatibilities', () {
    final result = inspectWorldInfoFeatures(
      _native([
        {
          'name': 'commentary',
          'comment': 'display only',
          'disable': true,
          'probability': 0,
          'useProbability': true,
          'key': <String>[],
          'constant': true,
          'addMemo': true,
          'displayIndex': 9,
          'sticky': 2,
          'cooldown': 3,
          'delay': 4,
          'group': 'g',
          'groupWeight': 0,
          'scanDepth': 0,
          'characterFilter': {
            'names': ['other'],
            'tags': [],
            'isExclude': false,
          },
        },
        {
          'key': ['absent'],
          'keysecondary': ['also absent'],
          'selective': true,
          'selectiveLogic': 2,
          'triggers': ['normal', 'continue', 'regenerate', 'impersonate'],
        },
      ]),
    );
    expect(result.findings, isEmpty);
    expect(result.counts['worldInfoBooks'], 1);
    expect(result.counts['entriesStored'], 2);
    expect(result.counts['entriesInExecutionView'], 2);
    expect(result.counts['entriesEnabled'], 1);
    expect(result.counts['entriesDisabled'], 1);
    expect(result.counts['primaryKeys'], 1);
    expect(result.counts['secondaryKeys'], 1);
    expect(result.counts['unsupportedWorldInfoFeatures'], 0);
  });

  test('native vector and automation findings preserve object key and distinct uid', () {
    final raw = <String, Object?>{
      'entries': {
        'source-key': {
          'uid': 42,
          'key': ['key'],
          'content': 'body',
          'vectorized': true,
          'automationId': 'command-id',
        },
      },
    };
    final result = inspectWorldInfoFeatures(raw);
    expect(result.findings.map((value) => value.code), [
      'wi-vector-activation-unavailable',
      'wi-automation-unavailable',
    ]);
    expect(result.findings.map((value) => value.path), [
      r'$.entries["source-key"].vectorized',
      r'$.entries["source-key"].automationId',
    ]);
    expect(result.findings.map((value) => value.identifier), ['42', '42']);
    expect(result.findings.every((value) => value.kind == TavernImportFindingKind.unsupported), isTrue);
  });

  test('V3 field locations use the card prefix and actual extension spelling', () {
    final result = inspectWorldInfoFeatures(
      _v3(
        [
          {
            'id': 'entry',
            'priority': 0,
            'extensions': {'vectorized': true, 'automation_id': 'a'},
          },
        ],
        fields: {'scan_depth': 0, 'token_budget': 0, 'recursive_scanning': false},
      ),
      path: r'$.data.character_book',
      embedded: true,
    );
    final byCode = {for (final finding in result.findings) finding.code: finding.path};
    expect(byCode, {
      'wi-book-scan-depth-ignored': r'$.data.character_book.scan_depth',
      'wi-book-token-budget-ignored': r'$.data.character_book.token_budget',
      'wi-book-recursion-setting-ignored': r'$.data.character_book.recursive_scanning',
      'wi-vector-activation-unavailable': r'$.data.character_book.entries[0].extensions.vectorized',
      'wi-automation-unavailable': r'$.data.character_book.entries[0].extensions.automation_id',
      'wi-entry-priority-ignored': r'$.data.character_book.entries[0].priority',
    });
    expect(result.counts['unsupportedWorldInfoFeatures'], 6);
  });

  test('false recursion is reported while false vector and empty automation are inert', () {
    final result = inspectWorldInfoFeatures(
      _v3(
        [
          {
            'extensions': {'vectorized': false, 'automation_id': ''},
          },
        ],
        fields: {'recursive_scanning': false},
      ),
    );
    expect(result.findings.single.code, 'wi-book-recursion-setting-ignored');
    expect(result.findings.single.kind, TavernImportFindingKind.unsupported);
  });

  test('invalid requested feature values are separate from unsupported valid values', () {
    final result = inspectWorldInfoFeatures(
      _v3(
        [
          {
            'priority': 'high',
            'extensions': {'vectorized': 'yes', 'automation_id': 7},
          },
        ],
        fields: {'scan_depth': '4', 'token_budget': null, 'recursive_scanning': 0},
      ),
    );
    expect(result.findings, hasLength(6));
    expect(result.findings.every((value) => value.kind == TavernImportFindingKind.invalid), isTrue);
    expect(result.counts['unsupportedWorldInfoFeatures'], 0);
  });

  test('known unavailable generation events are reported separately at each original index', () {
    final result = inspectWorldInfoFeatures(
      _native([
        {
          'triggers': ['normal', 'swipe', 'quiet', 'future-event', 17],
        },
      ]),
    );
    expect(result.findings.map((value) => value.path), [
      r'$.entries["0"].triggers[1]',
      r'$.entries["0"].triggers[2]',
      r'$.entries["0"].triggers[3]',
      r'$.entries["0"].triggers[4]',
    ]);
    expect(result.findings.map((value) => value.kind), [
      TavernImportFindingKind.unsupported,
      TavernImportFindingKind.unsupported,
      TavernImportFindingKind.unknown,
      TavernImportFindingKind.invalid,
    ]);
  });

  test('execution-view counts deduplicate V3 ids while stored rows keep their own findings', () {
    final result = inspectWorldInfoFeatures(
      _v3([
        {
          'id': 1.0,
          'enabled': false,
          'extensions': {'vectorized': true},
        },
        {
          'id': '1',
          'enabled': true,
          'keys': ['last', 'second'],
        },
        {'id': 2, 'enabled': false},
      ]),
    );
    expect(result.counts['entriesStored'], 3);
    expect(result.counts['entriesInExecutionView'], 2);
    expect(result.counts['entriesEnabled'], 1);
    expect(result.counts['entriesDisabled'], 1);
    expect(result.counts['entriesShadowed'], 1);
    expect(result.counts['primaryKeys'], 4);
    final shadowed = result.findings.singleWhere((value) => value.code == 'wi-shadowed-entry');
    expect(shadowed.path, r'$.entries[0]');
    expect(shadowed.identifier, '1');
    expect(shadowed.kind, TavernImportFindingKind.conditional);
    expect(
      result.findings.singleWhere((value) => value.code == 'wi-vector-activation-unavailable').path,
      r'$.entries[0].extensions.vectorized',
    );
  });

  test('nonstring keywords are counted separately without compacting source indices', () {
    final result = inspectWorldInfoFeatures(
      _v3([
        {
          'keys': <Object?>[null, 'one', false, 'two'],
          'secondary_keys': <Object?>['side', 8],
        },
      ]),
    );
    expect(result.counts['primaryKeys'], 2);
    expect(result.counts['secondaryKeys'], 1);
    expect(result.counts['ignoredKeywordValues'], 3);
    expect(result.findings.map((value) => value.path), [
      r'$.entries[0].keys[0]',
      r'$.entries[0].keys[2]',
      r'$.entries[0].secondary_keys[1]',
    ]);
  });

  test('unknown fields are opaque namespaces and do not masquerade as supported features', () {
    final raw = _v3(
      [
        {
          'mystery': {
            'a': {'b': true},
          },
          'extensions': {
            'vendor': {
              'x': 1,
              'nested': {'z': 2},
            },
          },
        },
      ],
      fields: {
        'extensions': {
          'book_vendor': {'one': 1, 'two': 2},
        },
      },
    );
    final result = inspectWorldInfoFeatures(raw);
    expect(result.findings, hasLength(3));
    expect(result.findings.every((value) => value.kind == TavernImportFindingKind.unknown), isTrue);
    expect(result.findings.map((value) => value.path), [
      r'$.extensions.book_vendor',
      r'$.entries[0].mystery',
      r'$.entries[0].extensions.vendor',
    ]);
    expect(result.counts['unknownPreservedFields'], 3);
    expect(result.counts['unsupportedWorldInfoFeatures'], 0);
  });

  test('native extension keys are not reinterpreted as V3 execution configuration', () {
    final result = inspectWorldInfoFeatures(
      _native([
        {
          'extensions': {'vectorized': true, 'automation_id': 'a'},
        },
      ]),
    );
    expect(result.findings, hasLength(2));
    expect(result.findings.every((value) => value.kind == TavernImportFindingKind.unknown), isTrue);
    expect(result.counts['unsupportedWorldInfoFeatures'], 0);
  });

  test('archival originalData entries do not double-count books or runtime features', () {
    final raw = _native([{}]);
    raw['originalData'] = _v3(
      [
        {
          'extensions': {'vectorized': true},
        },
      ],
      fields: {'token_budget': 3},
    );
    final result = inspectWorldInfoFeatures(raw);
    expect(result.counts['worldInfoBooks'], 1);
    expect(result.counts['entriesStored'], 1);
    expect(result.findings, isEmpty);
  });

  test('path segments preserve arbitrary native object keys and unknown field names', () {
    const key = 'a.b["c"]';
    final result = inspectWorldInfoFeatures({
      'entries': {
        key: {
          'uid': 5,
          'key': <String>[],
          'content': '',
          'vendor.field': {'nested': 1},
        },
      },
    });
    expect(result.findings.single.path, r'$.entries["a.b[\"c\"]"]["vendor.field"]');
    expect(result.findings.single.identifier, '5');
  });

  test('missing or malformed entries receive invalid findings and no executable view', () {
    final missing = inspectWorldInfoFeatures({'name': 'empty'});
    expect(missing.findings.single.code, 'wi-invalid-entries');
    expect(missing.counts['entriesInExecutionView'], 0);
    final mixed = inspectWorldInfoFeatures({
      'entries': <Object?>[
        {
          'id': 1,
          'keys': ['preserved'],
          'content': 'body',
          'enabled': true,
        },
        'bad row',
      ],
    });
    expect(mixed.counts['entriesStored'], 2);
    expect(mixed.counts['entriesInExecutionView'], 0);
    expect(mixed.counts['primaryKeys'], 1);
    expect(mixed.findings.single.path, r'$.entries[1]');
  });

  test('empty books remain structurally usable and contain no unsupported findings', () {
    for (final entries in <Object?>[<String, Object?>{}, <Object?>[]]) {
      final result = inspectWorldInfoFeatures({'entries': entries});
      expect(result.counts['worldInfoBooks'], 1);
      expect(result.counts['entriesStored'], 0);
      expect(result.counts['entriesInExecutionView'], 0);
      expect(result.findings, isEmpty);
    }
  });

  test('regex and macro inputs are left for the central compatibility probe', () {
    final raw = _v3([
      {
        'use_regex': true,
        'keys': ['[', '{{setglobalvar::must_not_run::1}}'],
        'content': '@@additional_keys /[/,{{random::a::b}}\n{{banned::literal}}',
      },
    ]);
    final before = jsonEncode(raw);
    final result = inspectWorldInfoFeatures(raw);
    expect(result.findings, isEmpty);
    expect(result.counts['primaryKeys'], 2);
    expect(result.counts['recognizedDecorators'], 1);
    expect(jsonEncode(raw), before);
  });

  test('shared header descriptors preserve CRLF CR offsets fallback and immutable boundaries', () {
    const content = '@@unknown\r\n@@@role user\rbody\n@@not_header';
    final header = worldInfoDecoratorHeader(content);
    expect(header.map((value) => value.number), [1, 2]);
    expect(header.map((value) => value.offset), [0, content.indexOf('@@@role')]);
    expect(header.map((value) => value.name), ['unknown', 'role']);
    expect(header.map((value) => value.isFallback), [false, true]);
    expect(header.last.value, 'user');
    expect(() => header.clear(), throwsUnsupportedError);
    final result = inspectWorldInfoFeatures(
      _native([
        {'content': content},
      ]),
    );
    expect(result.counts['decoratorLines'], 2);
    expect(result.counts['recognizedDecorators'], 1);
    expect(result.counts['unknownDecorators'], 1);
    expect(result.counts['fallbackDecoratorLines'], 1);
    expect(result.findings.single.line, 1);
    expect(result.findings.single.offset, 0);
  });

  test('unknown fallback lines keep source flags without claiming a failed primary choice', () {
    const content = '@@depth 4\n@@@vendor_feature value\nbody';
    final result = inspectWorldInfoFeatures(
      _native([
        {'content': content},
      ]),
    );
    final finding = result.findings.single;
    expect(finding.code, 'wi-unknown-decorator-preserved');
    expect(finding.kind, TavernImportFindingKind.unknown);
    expect(finding.line, 2);
    expect(finding.offset, content.indexOf('@@@vendor_feature'));
    expect(finding.conditional, isTrue);
    expect(finding.fallback, isTrue);
    expect(result.counts['unsupportedWorldInfoFeatures'], 0);
  });

  test('leading spaces and body decorator lookalikes stay ordinary content', () {
    for (final content in [' @@role user\nbody', 'body\n@@unknown', '\uFEFF@@unknown\nbody']) {
      final result = inspectWorldInfoFeatures(
        _native([
          {'content': content},
        ]),
      );
      expect(result.counts['decoratorLines'], 0);
      expect(result.findings, isEmpty);
    }
  });

  test('all 17 implemented decorator names are recognized without unsupported claims', () {
    const content =
        '@@activate\n@@dont_activate\n@@keep_activate_after_match\n@@dont_activate_after_match\n'
        '@@ignore_on_max_context\n@@activate_only_after 2\n@@activate_only_every 3\n@@depth 0\n'
        '@@reverse_depth 1\n@@scan_depth 2\n@@is_greeting 0\n@@role assistant\n'
        '@@position before_desc\n@@additional_keys key\n@@exclude_keys absent\n@@is_user_icon pilot\n'
        '@@disable_ui_prompt system_prompt\nbody';
    final result = inspectWorldInfoFeatures(
      _native([
        {'content': content},
      ]),
    );
    expect(result.counts['decoratorLines'], 17);
    expect(result.counts['recognizedDecorators'], 17);
    expect(result.counts['unknownDecorators'], 0);
    expect(result.findings.every((value) => value.kind == TavernImportFindingKind.conditional), isTrue);
    expect(result.counts['unsupportedWorldInfoFeatures'], 0);
  });

  test('the three instruct decorators are distinct known context limitations', () {
    final result = inspectWorldInfoFeatures(
      _v3([
        {'content': '@@instruct_depth 0\n@@reverse_instruct_depth 3\n@@instruct_scan_depth 4\nbody'},
      ]),
    );
    expect(result.counts['unavailableDecorators'], 3);
    expect(result.counts['unknownDecorators'], 0);
    expect(result.findings.map((value) => value.line), [1, 2, 3]);
    expect(
      result.findings.every(
        (value) =>
            value.code == 'wi-instruct-decorator-inapplicable' &&
            value.kind == TavernImportFindingKind.conditional &&
            value.conditional,
      ),
      isTrue,
    );
  });

  test('invalid decorator syntax and values retain separate source locations', () {
    final result = inspectWorldInfoFeatures(
      _native([
        {
          'content':
              '@@Bad-name\n@@role other\n@@activate_only_every 0\n@@is_greeting -1\n'
              '@@additional_keys key,\n@@activate extra\nbody',
        },
      ]),
    );
    expect(result.counts['invalidDecoratorSyntax'], 1);
    expect(result.counts['invalidDecoratorValues'], 5);
    expect(result.findings.map((value) => value.line), [1, 2, 3, 4, 5, 6]);
    expect(result.findings.every((value) => value.kind == TavernImportFindingKind.invalid), isTrue);
  });

  test('regex exclusion and supported contextual conditions are not unsupported features', () {
    final result = inspectWorldInfoFeatures(
      _v3([
        {
          'use_regex': true,
          'content': '@@exclude_keys ignored\n@@is_greeting 1\n@@is_user_icon pilot\n@@position scenario\nbody',
        },
      ]),
    );
    expect(result.findings.map((value) => value.code), [
      'wi-regex-exclude-ignored',
      'wi-decorator-context-required',
      'wi-decorator-context-required',
      'wi-decorator-context-required',
    ]);
    expect(result.findings.every((value) => value.kind == TavernImportFindingKind.conditional), isTrue);
  });

  test('outlet role and independent trim limitations are two findings', () {
    final result = inspectWorldInfoFeatures(
      _native([
        {'position': 7, 'outletName': 'slot', 'content': '@@role user\n@@ignore_on_max_context\nbody'},
      ]),
    );
    expect(result.findings.map((value) => value.code), ['wi-outlet-role-unapplied', 'wi-outlet-trim-unapplied']);
    expect(result.findings.map((value) => value.line), [1, 2]);
    expect(result.findings.every((value) => value.kind == TavernImportFindingKind.unsupported), isTrue);
  });

  test('valid unconditional depth or section avoids blanket outlet limitations', () {
    for (final override in ['@@depth 0', '@@reverse_depth 2', '@@position before_desc', '@@position after_desc']) {
      final result = inspectWorldInfoFeatures(
        _native([
          {'position': 7, 'outletName': 'slot', 'content': '@@role user\n@@ignore_on_max_context\n$override\nbody'},
        ]),
      );
      expect(result.findings, isEmpty, reason: override);
    }
  });

  test('a context-dependent section makes the outlet limitations conditional', () {
    final result = inspectWorldInfoFeatures(
      _native([
        {
          'position': 7,
          'outletName': 'slot',
          'content': '@@role user\n@@ignore_on_max_context\n@@position scenario\nbody',
        },
      ]),
    );
    final limitations = result.findings.where((value) => value.code.startsWith('wi-outlet-'));
    expect(limitations, hasLength(2));
    expect(
      limitations.every((value) => value.kind == TavernImportFindingKind.conditional && value.conditional),
      isTrue,
    );
  });

  test('duplicate accepted names are conditional while repeated additional groups stay supported', () {
    final result = inspectWorldInfoFeatures(
      _native([
        {'content': '@@role user\n@@role assistant\n@@additional_keys first\n@@additional_keys second\nbody'},
      ]),
    );
    expect(result.findings.single.code, 'wi-duplicate-decorator-conditional');
    expect(result.findings.single.line, 2);
    expect(result.findings.single.kind, TavernImportFindingKind.conditional);
    expect(result.counts['recognizedDecorators'], 4);
  });

  test('source documents are untouched and result containers reject mutation', () {
    final raw = _v3([
      {
        'extensions': {
          'vendor': {
            'nested': [1, 2, 3],
          },
        },
        'content': '@@unknown\nbody',
      },
    ]);
    final before = jsonEncode(raw);
    final result = inspectWorldInfoFeatures(raw);
    expect(jsonEncode(raw), before);
    expect(() => result.counts['entriesStored'] = 99, throwsUnsupportedError);
    expect(() => result.findings.clear(), throwsUnsupportedError);
    (raw['entries']! as List<Object?>).clear();
    expect(result.counts['entriesStored'], 1);
    expect(result.findings, hasLength(2));
  });
}

Map<String, Object?> _native(List<Map<String, Object?>> rows) => {
  'name': 'book',
  'entries': {
    for (var index = 0; index < rows.length; index++)
      '$index': <String, Object?>{
        'uid': index,
        'key': ['key'],
        'content': 'body',
        'position': 0,
        'order': 100,
        ...rows[index],
      },
  },
};

Map<String, Object?> _v3(List<Map<String, Object?>> rows, {Map<String, Object?> fields = const {}}) => {
  'name': 'book',
  'entries': [
    for (var index = 0; index < rows.length; index++)
      <String, Object?>{
        'id': index,
        'keys': ['key'],
        'content': 'body',
        'enabled': true,
        'insertion_order': 100,
        'position': 'before_char',
        'extensions': <String, Object?>{},
        ...rows[index],
      },
  ],
  ...fields,
};
