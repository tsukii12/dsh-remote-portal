import 'dart:convert';

import 'package:dsh_tavern/src/io/preset_codec.dart';
import 'package:dsh_tavern/src/preset_library.dart';
import 'package:dsh_tavern/src/prompt/preset.dart';
import 'package:test/test.dart';

const _codec = PresetCodec();

void main() {
  test('native BOM JSON keeps macros, connection data and unknown JSON detached', () {
    final source =
        '\uFEFF\r\n${jsonEncode(_raw({
          'reverse_proxy': 'https://example.invalid/custom',
          'foreign': {
            'array': [false, null, '鲸🐳'],
          },
        }))}\r\n';
    final decoded = _codec.decode(source, fileName: r'C:\presets\鲸.dsh-preset.json');
    expect(decoded.name, '鲸');
    expect(decoded.envelope, isNull);
    expect(_prompt(decoded)['content'], '{{user}} / {{incvar::n}}');
    expect(decoded.raw['reverse_proxy'], 'https://example.invalid/custom');
    expect(decoded.raw['foreign'], {
      'array': [false, null, '鲸🐳'],
    });
    _object(decoded.raw['foreign'])['array'] = [];
    expect(decoded.raw['foreign'], {
      'array': [false, null, '鲸🐳'],
    });
    expect(jsonDecode(_codec.encode(decoded.raw)), decoded.raw);
  });

  test('legacy native presets without prompts remain valid', () {
    final raw = {
      'main_prompt': 'OLD {{char}}',
      'unknown': <Object?>[1, null],
    };
    final decoded = _codec.decode(jsonEncode(raw));
    expect(decoded.raw, raw);
    expect(decoded.issues, isEmpty);
    expect(decoded.name, '未命名预设');
    expect(ChatPreset(decoded.raw).settings['prompts'], isNotEmpty);
  });

  test('wrapper extracts explicit target and retains every opaque container', () {
    final wrapper = _wrapper(raw: _raw({'dsh_prefill_target': 'reasoning'}));
    wrapper['metadata'] = {
      'name': '包名称',
      'future': [1, false],
    };
    wrapper['topFuture'] = {'x': null};
    wrapper['tools'] = {
      'version': 9,
      'future': {
        'a': [1, 2],
      },
    };
    wrapper['extensions'] = {
      'assets': {
        'opaque': {'data': 'bytes', 'future': 7},
      },
    };
    _object(wrapper['preset'])['future'] = 'kept';
    _object(wrapper['prefill'])['future'] = {'switch': null};
    final original = jsonEncode(wrapper);
    final decoded = _codec.decode(original, fileName: 'fallback.json');
    expect(decoded.name, '包名称');
    expect(_prefill(decoded.raw), {'enabled': true, 'target': 'reasoning'});
    final retained = decoded.envelope!;
    expect(retained['topFuture'], wrapper['topFuture']);
    expect(retained['tools'], wrapper['tools']);
    expect(retained['extensions'], wrapper['extensions']);
    expect(_object(retained['preset'])['future'], 'kept');
    expect(_object(retained['prefill'])['future'], {'switch': null});
    expect(jsonEncode(wrapper), original);
    expect(decoded.issues.any((issue) => issue.code == 'tools-preserved'), isTrue);
  });

  test('ADD04 missing targets default to content for native and wrapper sources', () {
    final wrapped = _codec.decode(jsonEncode(_wrapper()));
    expect(_prefill(wrapped.raw), {'enabled': true, 'target': 'content'});
    final native = _codec.decode(jsonEncode(_raw({'assistant_prefill': 'TEXT'})));
    expect(native.raw.containsKey('extensions'), isFalse);
    final configured = _codec.decode(
      jsonEncode(
        _raw({
          'extensions': {
            'dshgo': {
              'prefill': {'enabled': true},
            },
          },
        }),
      ),
    );
    expect(_prefill(configured.raw), {'enabled': true});
  });

  test('attached false replaces conflicting known keys while unknown keys survive', () {
    final wrapped = _wrapper(
      raw: _raw({
        'extensions': {
          'dshgo': {
            'sibling': 7,
            'prefill': {
              'enabled': true,
              'target': 'reasoning',
              'future': {'x': null},
            },
          },
        },
      }),
    );
    _object(wrapped['prefill'])['enabled'] = false;
    final decoded = _codec.decode(jsonEncode(wrapped));
    expect(_prefill(decoded.raw), {
      'enabled': false,
      'target': 'content',
      'future': {'x': null},
    });
    expect(_object(_object(decoded.raw['extensions'])['dshgo'])['sibling'], 7);
    expect(
      decoded.issues.any(
        (issue) =>
            issue.path == r'$.preset.data.extensions.dshgo.prefill' &&
            issue.severity == TavernPresetIssueSeverity.normalized,
      ),
      isTrue,
    );
  });

  for (final attachedNull in [false, true]) {
    test('missing/null attached settings preserve explicit raw enhancement: $attachedNull', () {
      final wrapped = _wrapper(
        raw: _raw({
          'extensions': {
            'dshgo': {
              'prefill': {'enabled': true, 'target': 'reasoning'},
            },
          },
        }),
      );
      if (attachedNull) {
        wrapped['prefill'] = null;
      } else {
        wrapped.remove('prefill');
      }
      final decoded = _codec.decode(jsonEncode(wrapped));
      expect(_prefill(decoded.raw), {'enabled': true, 'target': 'reasoning'});
      final plain = _wrapper();
      if (attachedNull) {
        plain['prefill'] = null;
      } else {
        plain.remove('prefill');
      }
      expect(_codec.decode(jsonEncode(plain)).raw.containsKey('extensions'), isFalse);
    });
  }

  test('recognized wrapper with unknown main version rejects without native fallback', () {
    for (final patch in <Map<String, Object?>>[
      {'version': 2},
      {'version': '1'},
    ]) {
      final wrapped = {..._wrapper(), ...patch};
      expect(() => _codec.decode(jsonEncode(wrapped)), throwsA(isA<TavernPresetImportError>()));
    }
  });

  test('legacy unknown format/version/preset fields do not imply a share package', () {
    final raw = <String, Object?>{
      'main_prompt': 'OLD',
      'format': 'foreign',
      'version': 42,
      'preset': {'foreign': 1},
    };
    final decoded = _codec.decode(jsonEncode(raw), fileName: 'legacy.dsh-preset.json');
    expect(decoded.raw, raw);
    expect(decoded.envelope, isNull);
    expect(jsonDecode(_codec.encode(decoded.raw)), raw);
  });

  test('package prefill is typed and diagnostics point at the failed field', () {
    final wrapped = _wrapper();
    _object(wrapped['prefill'])['enabled'] = 'true';
    expect(() => _codec.decode(jsonEncode(wrapped)), _hasError(r'$.prefill.enabled', 'boolean-required'));
    final badTarget = _wrapper(raw: _raw({'dsh_prefill_target': null}));
    expect(
      () => _codec.decode(jsonEncode(badTarget)),
      _hasError(r'$.preset.data.dsh_prefill_target', 'invalid-prefill-target'),
    );
  });

  test('identifier numbers, empty values and duplicates are never silently renamed', () {
    for (final value in <Object?>[null, '', 7, false]) {
      final raw = _raw();
      _object(_array(raw['prompts']).first)['identifier'] = value;
      expect(() => _codec.decode(jsonEncode(raw)), _hasError(r'$.prompts[0].identifier', 'invalid-identifier'));
    }
    final duplicate = _raw();
    _array(duplicate['prompts']).add({'identifier': 'p', 'role': 'user'});
    expect(
      () => _codec.decode(jsonEncode(duplicate)),
      _hasError(r'$.prompts[1].identifier', 'duplicate-identifier', id: 'p'),
    );
  });

  test('role defaults, case and model alias normalize with entry diagnostics', () {
    final raw = _raw({
      'prompts': [
        {'identifier': 'a'},
        {'identifier': 'b', 'role': ' MODEL '},
        {'identifier': 'c', 'role': 'USER'},
      ],
      'prompt_order': [],
    });
    final before = jsonEncode(raw);
    final decoded = _codec.validate(raw);
    expect(_array(decoded.raw['prompts']).map((value) => _object(value)['role']), ['system', 'assistant', 'user']);
    expect(decoded.issues.map((issue) => issue.identifier), ['a', 'b', 'c']);
    expect(decoded.issues.every((issue) => issue.severity == TavernPresetIssueSeverity.normalized), isTrue);
    expect(jsonEncode(raw), before);
    for (final role in <Object?>[null, 7, 'tool', 'alien']) {
      final invalid = _raw();
      _object(_array(invalid['prompts']).first)['role'] = role;
      expect(() => _codec.validate(invalid), _hasError(r'$.prompts[0].role', 'invalid-role', id: 'p'));
    }
  });

  test('integer injection fields normalize without conflating null with omission', () {
    final raw = _raw();
    final prompt = _object(_array(raw['prompts']).first);
    prompt['injection_position'] = ' +01 ';
    prompt['injection_depth'] = 4.0;
    final decoded = _codec.validate(raw);
    expect(_prompt(decoded)['injection_position'], 1);
    expect(_prompt(decoded)['injection_depth'], 4);
    expect(_prompt(decoded)['injection_depth'], isA<int>());
    expect(decoded.issues.map((issue) => issue.path), [
      r'$.prompts[0].injection_position',
      r'$.prompts[0].injection_depth',
    ]);
    expect(_prompt(_codec.validate(_raw())).containsKey('injection_depth'), isFalse);
    for (final key in ['injection_position', 'injection_depth']) {
      for (final value in <Object?>[null, -1, 0.5, '1.0', '1e0', '0x1', {}, []]) {
        final invalid = _raw();
        _object(_array(invalid['prompts']).first)[key] = value;
        expect(
          () => _codec.validate(invalid),
          _hasError(
            '\$.prompts[0].$key',
            key == 'injection_position' ? 'invalid-injection-position' : 'invalid-injection-depth',
            id: 'p',
          ),
        );
      }
    }
  });

  test('out-of-native-range integral depth is preserved without saturating to int', () {
    final raw = _raw();
    _object(_array(raw['prompts']).first)['injection_depth'] = 1e100;
    final decoded = _codec.validate(raw);
    expect(_prompt(decoded)['injection_depth'], 1e100);
    expect(decoded.issues.single.code, 'depth-outside-st-range');
    expect(decoded.issues.single.severity, TavernPresetIssueSeverity.warning);
  });

  test('prompt content normalization follows ST text reads and preserves foreign fields', () {
    final raw = _raw({'assistant_prefill': false});
    _object(_array(raw['prompts']).first)['content'] = [1, null, 3];
    final decoded = _codec.validate(raw);
    expect(_prompt(decoded)['content'], '1,,3');
    expect(_prompt(decoded)['future'], [1, null]);
    expect(decoded.raw['assistant_prefill'], '');
  });

  test('order diagnostics preserve first-empty semantics and distinguish builtin references', () {
    final raw = _raw({
      'prompt_order': [
        {'character_id': 100001, 'order': [], 'unknown': 'FIRST'},
        {
          'character_id': 100001,
          'order': [
            {'identifier': 'p', 'enabled': 'false', 'unknown': 7},
            {'identifier': 'chatHistory', 'enabled': true},
            {'identifier': 'missing', 'enabled': true},
          ],
        },
      ],
    });
    final decoded = _codec.validate(raw);
    final groups = _array(decoded.raw['prompt_order']);
    expect(_object(groups.first)['order'], isEmpty);
    expect(_object(groups.first)['unknown'], 'FIRST');
    final second = _array(_object(groups[1])['order']);
    expect(_object(second.first), {'identifier': 'p', 'enabled': true, 'unknown': 7});
    expect(decoded.issues.where((issue) => issue.code == 'missing-prompt').single.identifier, 'missing');
    final effective = _array(ChatPreset(decoded.raw).settings['prompt_order']);
    expect(_object(effective.first)['order'], isEmpty);
  });

  test('null first order remains an empty first group and duplicate references are errors', () {
    final raw = _raw({
      'prompt_order': [
        {'character_id': 100001, 'order': null},
      ],
    });
    final decoded = _codec.validate(raw);
    expect(_object(_array(decoded.raw['prompt_order']).single)['order'], isNull);
    expect(decoded.issues.single.code, 'empty-order');
    final duplicate = _raw();
    _array(_object(_array(duplicate['prompt_order']).first)['order']).add({'identifier': 'p', 'enabled': false});
    expect(
      () => _codec.validate(duplicate),
      _hasError(r'$.prompt_order[0].order[1].identifier', 'duplicate-order-identifier', id: 'p'),
    );
  });

  test('ST export keeps legacy helper raw without applying strict import normalization', () {
    final raw = _raw({
      'prompts': [
        {
          'identifier': 'numericRole',
          'role': 7,
          'content': false,
          'unknown': {'v': null},
        },
        {'identifier': 'missingRole', 'content': '{{raw}}'},
      ],
      'extensions': ['legacy', null],
    });
    final exported = _codec.encode(raw);
    expect(jsonDecode(exported), raw);
    expect(ChatPreset.decode(exported).raw, raw);
    expect(() => _codec.decode(exported), throwsA(isA<TavernPresetImportError>()));
    expect(_object(_array(raw['prompts'])[1]).containsKey('role'), isFalse);
    final oldReservedKey = <String, Object?>{
      'extensions': {
        'dshgo': {'presetEnvelope': 'old opaque value'},
      },
    };
    expect(jsonDecode(_codec.encode(oldReservedKey)), oldReservedKey);
  });

  test('native exports retain opaque envelopes without recursive data growth', () {
    final wrapper = _wrapper(raw: _raw({'dsh_prefill_target': 'reasoning'}));
    wrapper['topUnknown'] = {
      'nested': [false, null, 3],
    };
    wrapper['tools'] = {
      'version': 29,
      'opaque': ['future'],
    };
    _object(wrapper['preset'])['wrapperUnknown'] = 9;
    var decoded = _codec.decode(jsonEncode(wrapper));
    final initial = _codec.encode(decoded.raw, envelope: decoded.envelope);
    var output = initial;
    for (var cycle = 0; cycle < 4; cycle++) {
      decoded = _codec.decode(output);
      final snapshot = _object(_object(_object(decoded.raw['extensions'])['dshgo'])['presetEnvelope']);
      expect(_object(snapshot['preset']).containsKey('data'), isFalse);
      expect(snapshot['topUnknown'], wrapper['topUnknown']);
      expect(snapshot['tools'], wrapper['tools']);
      expect(_object(decoded.envelope!['preset'])['data'], decoded.raw);
      output = _codec.encode(decoded.raw, envelope: decoded.envelope);
      expect(output, initial);
    }
  });

  test('direct wrapper rejects a conflicting saved shell without losing unknown fields', () {
    final outer = _wrapper();
    outer['unknown'] = {
      'source': 'outer',
      'onlyOuter': [null, false],
    };
    final inner = _wrapper();
    inner['unknown'] = {
      'source': 'inner',
      'onlyInner': [1, 2],
    };
    final raw = _object(jsonDecode(_codec.encode(_raw(), envelope: inner)));
    _object(outer['preset'])['data'] = raw;
    final original = jsonEncode(outer);
    expect(
      () => _codec.decode(original),
      _hasError(r'$.preset.data.extensions.dshgo.presetEnvelope', 'conflicting-envelope-carrier'),
    );
    expect(jsonEncode(outer), original);
  });

  test('direct wrapper accepts the same saved shell regardless of object key order', () {
    final outer = _wrapper();
    outer['unknown'] = {
      'first': [
        null,
        {'a': 1, 'b': false},
      ],
      'second': 'kept',
    };
    final raw = _object(jsonDecode(_codec.encode(_raw(), envelope: outer)));
    final dshgo = _object(_object(raw['extensions'])['dshgo']);
    final carrier = _object(dshgo['presetEnvelope']);
    final reordered = _object(_reverseObjectKeys(carrier));
    expect(jsonEncode(reordered), isNot(jsonEncode(carrier)));
    dshgo['presetEnvelope'] = reordered;
    _object(outer['preset'])['data'] = raw;
    final decoded = _codec.decode(jsonEncode(outer));
    expect(_object(_object(decoded.raw['extensions'])['dshgo'])['presetEnvelope'], carrier);
    final exported = _object(jsonDecode(_codec.encode(decoded.raw, envelope: decoded.envelope)));
    final saved = _object(_object(_object(exported['extensions'])['dshgo'])['presetEnvelope']);
    expect(saved, carrier);
    expect(saved['unknown'], outer['unknown']);
    expect(_object(saved['preset']).containsKey('data'), isFalse);
  });

  test('saved shells containing their own data are rejected instead of discarded', () {
    final raw = _object(jsonDecode(_codec.encode(_raw(), envelope: _wrapper())));
    final carrier = _object(_object(_object(raw['extensions'])['dshgo'])['presetEnvelope']);
    _object(carrier['preset'])['data'] = {'opaque': 'DO_NOT_DROP'};
    expect(
      () => _codec.decode(jsonEncode(raw)),
      _hasError(r'$.extensions.dshgo.presetEnvelope.preset.data', 'noncanonical-envelope-carrier'),
    );
    expect(
      () => _codec.validate(raw, envelope: _wrapper()),
      _hasError(r'$.extensions.dshgo.presetEnvelope.preset.data', 'noncanonical-envelope-carrier'),
    );
    expect(
      () => _codec.decode(jsonEncode(_wrapper(raw: raw))),
      _hasError(r'$.preset.data.extensions.dshgo.presetEnvelope.preset.data', 'noncanonical-envelope-carrier'),
    );
    expect(jsonDecode(_codec.encode(raw)), raw);
  });

  test('editing native enhancement never reapplies saved package switches', () {
    final decoded = _codec.decode(jsonEncode(_wrapper(raw: _raw({'dsh_prefill_target': 'reasoning'}))));
    final edited = decoded.raw;
    _prefill(edited)['enabled'] = false;
    _prefill(edited)['target'] = 'content';
    final validated = _codec.validate(edited, envelope: decoded.envelope);
    expect(_prefill(validated.raw), {'enabled': false, 'target': 'content'});
    final reopened = _codec.decode(_codec.encode(validated.raw, envelope: validated.envelope));
    expect(_prefill(reopened.raw), {'enabled': false, 'target': 'content'});
    expect(_object(reopened.envelope!['prefill'])['enabled'], isTrue);
    expect(reopened.raw['dsh_prefill_target'], 'reasoning');
  });

  test('opaque envelope namespaces are never overwritten to force export', () {
    final decoded = _codec.decode(jsonEncode(_wrapper()));
    final raw = decoded.raw;
    raw['extensions'] = {
      'dshgo': 'foreign scalar',
      'other': [1, 2],
    };
    expect(() => _codec.encode(raw, envelope: decoded.envelope), _hasError(r'$.extensions.dshgo', 'object-required'));
    expect(raw['extensions'], {
      'dshgo': 'foreign scalar',
      'other': [1, 2],
    });
    expect(jsonDecode(_codec.encode(raw)), raw);
  });

  test('new validation checks saved carrier structure even with an authoritative envelope', () {
    final decoded = _codec.decode(jsonEncode(_wrapper()));
    final raw = decoded.raw;
    _object(_object(raw['extensions'])['dshgo'])['presetEnvelope'] = 'bad carrier';
    expect(
      () => _codec.validate(raw, envelope: decoded.envelope),
      _hasError(r'$.extensions.dshgo.presetEnvelope', 'object-required'),
    );
    expect(jsonDecode(_codec.encode(raw)), raw);
    expect(
      () => _codec.decode(jsonEncode(_wrapper(raw: raw))),
      _hasError(r'$.preset.data.extensions.dshgo.presetEnvelope', 'object-required'),
    );
  });

  test('saved unknown envelope version is still rejected instead of being dropped', () {
    final exported = _object(jsonDecode(_codec.encode(_raw(), envelope: _wrapper())));
    final snapshot = _object(_object(_object(exported['extensions'])['dshgo'])['presetEnvelope']);
    snapshot['version'] = 2;
    expect(
      () => _codec.decode(jsonEncode(exported)),
      _hasError(r'$.extensions.dshgo.presetEnvelope.version', 'unsupported-envelope-version'),
    );
  });

  test('unsupported package features and context assets remain data with warnings', () {
    final wrapped = _wrapper();
    final prompt = _object(_array(_object(_object(wrapped['preset'])['data'])['prompts']).first);
    prompt['contextFiles'] = [
      {'kind': 'file', 'asset': 'opaque-asset', 'future': false},
    ];
    final prefill = _object(wrapped['prefill']);
    prefill['toolCalls'] = true;
    prefill['extractOutput'] = true;
    prefill['postToolPrefix'] = {'mode': 'custom', 'text': '{{run_tool}}', 'future': 7};
    final decoded = _codec.decode(jsonEncode(wrapped));
    expect(_prompt(decoded)['contextFiles'], prompt['contextFiles']);
    expect(
      decoded.issues.map((issue) => issue.code),
      containsAll(['prefill-features-preserved', 'attachments-preserved']),
    );
    expect(_object(decoded.envelope!['prefill'])['postToolPrefix'], prefill['postToolPrefix']);
  });

  test('malformed JSON and non-JSON edits expose located errors without source contents', () {
    expect(() => _codec.decode('[]'), _hasError(r'$', 'object-required'));
    expect(
      () => _codec.decode('{"private":"DO_NOT_ECHO"'),
      throwsA(
        isA<TavernPresetImportError>().having(
          (error) => error.toString(),
          'safe diagnostic',
          isNot(contains('DO_NOT_ECHO')),
        ),
      ),
    );
    expect(() => _codec.validate({'foreign': double.infinity}), _hasError(r'$', 'invalid-json-value'));
    expect(
      () => _codec.decode('{"temperature":1e400}'),
      throwsA(
        isA<TavernPresetImportError>().having(
          (error) => error.issues.any(
            (issue) =>
                issue.path == r'$' &&
                issue.severity == TavernPresetIssueSeverity.error &&
                const ['invalid-json', 'invalid-json-value'].contains(issue.code),
          ),
          'located overflow error',
          isTrue,
        ),
      ),
    );
  });

  test('DTO snapshots preserve exact source and return independent JSON copies', () {
    final raw = _raw();
    final envelope = _wrapper();
    final at = DateTime.utc(2026, 11, 10);
    const source = '\uFEFF{ "original": true }\r\n';
    final preset = TavernPreset(
      id: 'id',
      name: 'name',
      sourceText: source,
      raw: raw,
      envelope: envelope,
      createdAt: at,
      updatedAt: at,
    );
    _object(_array(raw['prompts']).first)['content'] = 'changed';
    envelope['version'] = 999;
    _object(_array(preset.raw['prompts']).first)['content'] = 'changed-again';
    preset.envelope!['version'] = 888;
    expect(_object(_array(preset.raw['prompts']).first)['content'], '{{user}} / {{incvar::n}}');
    expect(preset.envelope!['version'], 1);
    expect(preset.sourceText, source);
    expect(preset.summary.hasEnvelope, isTrue);
    expect(preset.summary.createdAt, at);
    final issue = TavernPresetIssue(path: r'$.p', code: 'note', message: '说明');
    final sourceIssues = [issue];
    final result = TavernPresetImportResult(preset, sourceIssues);
    sourceIssues.clear();
    expect(result.issues, [issue]);
    expect(() => result.issues.clear(), throwsUnsupportedError);
    expect(issue.toJson()['severity'], 'warning');
  });
}

Map<String, Object?> _raw([Map<String, Object?> patch = const {}]) => _object(
  jsonDecode(
    jsonEncode({
      'prompts': [
        {
          'identifier': 'p',
          'role': 'system',
          'content': '{{user}} / {{incvar::n}}',
          'future': [1, null],
        },
      ],
      'prompt_order': [
        {
          'character_id': 100001,
          'order': [
            {'identifier': 'p', 'enabled': true},
          ],
        },
      ],
      ...patch,
    }),
  ),
);

Map<String, Object?> _wrapper({Map<String, Object?>? raw}) => _object(
  jsonDecode(
    jsonEncode({
      'format': 'dsh-preset-enhance',
      'version': 1,
      'preset': {'format': 'sillytavern', 'data': raw ?? _raw()},
      'prefill': {
        'enabled': true,
        'toolCalls': false,
        'removeNonOfficialTools': true,
        'postToolPrefix': {'mode': 'inherit', 'text': ''},
      },
    }),
  ),
);

Map<String, Object?> _object(Object? value) => value! as Map<String, Object?>;
List<Object?> _array(Object? value) => value! as List<Object?>;

Object? _reverseObjectKeys(Object? value) {
  if (value is Map<String, Object?>) {
    return {for (final key in value.keys.toList().reversed) key: _reverseObjectKeys(value[key])};
  }
  if (value is List<Object?>) {
    return value.map(_reverseObjectKeys).toList();
  }
  return value;
}

Map<String, Object?> _prompt(DecodedPreset preset) => _object(_array(preset.raw['prompts']).first);
Map<String, Object?> _prefill(Map<String, Object?> raw) =>
    _object(_object(_object(raw['extensions'])['dshgo'])['prefill']);

Matcher _hasError(String path, String code, {String? id}) => throwsA(
  isA<TavernPresetImportError>().having(
    (error) => error.issues.any(
      (issue) =>
          issue.path == path &&
          issue.code == code &&
          issue.severity == TavernPresetIssueSeverity.error &&
          (id == null || issue.identifier == id),
    ),
    'located diagnostic',
    isTrue,
  ),
);
