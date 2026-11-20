import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:dsh_tavern/src/tool_policy.dart';
import 'package:test/test.dart';

void main() {
  test('new tools require the actual wire mode, names and selector and reject any prefix key', () {
    final policy = _policy();
    final config = TavernModelConfig(apiKey: () async => 'fixture', deepseek: true, thinking: false);
    Map<String, Object?> body() => {
      'messages': [
        {'role': 'user', 'content': 'Q'},
      ],
      'tools': ordinaryToolDefinitions(policy),
      'thinking': {'type': 'disabled'},
    };
    ToolWireAuthorization check(Map<String, Object?> request, {TavernModelConfig? mode}) =>
        toolWireAuthorization(config: mode ?? config, body: request, policy: policy);
    final normal = check(body());
    expect(normal.offeredTools, ['roll', 'remember']);
    expect((normal.rollAllowed, normal.rememberAllowed), (true, true));
    for (final value in <Object?>[false, null, 0, 'unexpected']) {
      final request = body();
      request['messages'] = [
        {'role': 'assistant', 'content': '', 'prefix': value},
      ];
      final denied = check(request);
      expect((denied.rollAllowed, denied.rememberAllowed), (false, false), reason: 'prefix presence: $value');
      expect(denied.diagnostics.map((issue) => issue['code']), contains('tool_wire_prefix_present'));
    }
    for (final choice in <Object?>[null, 'auto', 'required']) {
      final allowed = check(body()..['tool_choice'] = choice);
      expect((allowed.rollAllowed, allowed.rememberAllowed), (true, true));
    }
    final forced = check(
      body()
        ..['tool_choice'] = {
          'type': 'function',
          'function': {'name': 'roll'},
        },
    );
    expect((forced.rollAllowed, forced.rememberAllowed), (true, false));
    final none = check(body()..['tool_choice'] = 'none');
    expect((none.rollAllowed, none.rememberAllowed), (false, false));
    final notOffered = check(body()..remove('tools'));
    expect((notOffered.rollAllowed, notOffered.rememberAllowed), (false, false));
    for (final request in <Map<String, Object?>>[
      body()..['thinking'] = {'type': 'enabled'},
      body()..['thinking'] = false,
      body()..['messages'] = [null],
    ]) {
      final denied = check(request);
      expect((denied.rollAllowed, denied.rememberAllowed), (false, false));
    }
    final generic = check(
      body(),
      mode: TavernModelConfig(apiKey: () async => 'fixture', deepseek: false, thinking: false),
    );
    final thinking = check(
      body(),
      mode: TavernModelConfig(apiKey: () async => 'fixture', deepseek: true, thinking: true),
    );
    expect((generic.rollAllowed, generic.rememberAllowed), (false, false));
    expect((thinking.rollAllowed, thinking.rememberAllowed), (false, false));
  });

  test('scope restrictions cannot be relaxed by chat or card settings and malformed tool domains stay scoped', () {
    final denied = toolPolicySnapshot(
      globalSettings: {
        'toolPolicy': {
          'roll': {'allow': false},
        },
      },
      chatSettings: {
        'toolPolicy': {
          'roll': {'enabled': true},
          'remember': {'enabled': true},
        },
      },
    );
    final card = captureToolCardPolicy({
      'extensions': {
        'dshgo': {
          'v': 1,
          'tools': {
            'roll': {'disabled': false},
            'remember': {'disabled': false},
          },
        },
      },
    }, characterId: 'host');
    final restricted = captureToolPolicy(scope: denied, host: card);
    expect((restricted.rollAllowed, restricted.rememberAllowed), (false, false));

    final enabled = toolPolicySnapshot(
      globalSettings: {
        'toolPolicy': {
          'remember': {'allow': true},
        },
      },
    );
    final actor = captureToolCardPolicy({
      'extensions': {
        'dshgo': {
          'v': 1,
          'tools': {
            'roll': {'disabled': 'bad'},
            'remember': {'disabled': false},
          },
        },
      },
    }, characterId: 'actor');
    final partlyInvalid = captureToolPolicy(scope: enabled, host: card, actor: actor);
    expect((partlyInvalid.rollAllowed, partlyInvalid.rememberAllowed), (false, true));
    expect(partlyInvalid.diagnostics.single['fieldPath'], 'extensions.dshgo.tools.roll.disabled');
    final malformedParent = captureToolCardPolicy({'extensions': null}, characterId: 'bad-host');
    final unavailable = captureToolPolicy(scope: enabled, host: malformedParent, actor: card);
    expect((unavailable.rollAllowed, unavailable.rememberAllowed), (false, false));
    expect(unavailable.diagnostics.single['raw'], isNull);
    expect(unavailable.diagnostics.single['fieldPath'], 'extensions');
  });

  test('policy capture is detached and contains only tool-domain evidence', () {
    final rawTool = <String, Object?>{
      'disabled': false,
      'vendor': {'kept': 7},
    };
    final dshgo = <String, Object?>{
      'v': 1,
      'tools': {'roll': rawTool},
      'state': {'secret': 'HIDDEN_STATE_MUST_NOT_BE_CAPTURED'},
    };
    final data = <String, Object?>{
      'description': 'PROMPT_MUST_NOT_BE_CAPTURED',
      'extensions': {'dshgo': dshgo},
    };
    final host = captureToolCardPolicy(data, characterId: 'host');
    final policy = captureToolPolicy(
      scope: toolPolicySnapshot(globalSettings: const {}),
      host: host,
    );
    rawTool['disabled'] = true;
    dshgo.clear();
    data.clear();
    expect(policy.rollAllowed, isTrue);
    final encoded = jsonEncode(policy.toJson());
    expect(encoded, contains('vendor'));
    expect(encoded, isNot(contains('HIDDEN_STATE_MUST_NOT_BE_CAPTURED')));
    expect(encoded, isNot(contains('PROMPT_MUST_NOT_BE_CAPTURED')));
    final copy = policy.toJson();
    copy['rollAllowed'] = false;
    expect(policy.rollAllowed, isTrue);
    expect(jsonEncode(policy.toJson()), encoded);
  });
}

ToolCapturedPolicy _policy() => captureToolPolicy(
  scope: toolPolicySnapshot(
    globalSettings: {
      'toolPolicy': {
        'remember': {'allow': true},
      },
    },
  ),
  host: captureToolCardPolicy(const {}, characterId: 'host'),
);
