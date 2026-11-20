import 'dart:convert';

import 'package:dsh_tavern/src/llm/model_client.dart';
import 'package:dsh_tavern/src/llm/tool_calls.dart';
import 'package:test/test.dart';

void main() {
  test('interleaved arguments sort by explicit index and metadata never concatenates', () {
    final accumulator = ModelToolAccumulator();
    accumulator.add(_fragment(9, arguments: '{"name":"'));
    accumulator.add(_fragment(2, arguments: '{"ops":['));
    accumulator.add(
      ModelToolFragment(index: 9, id: 'call-9', type: 'function', name: 'update_state', arguments: '海🐋"}'),
    );
    accumulator.add(ModelToolFragment(index: 2, arguments: '1,2]}'));
    final batch = accumulator.finish();
    expect(batch.eligibleStructure, isTrue);
    expect(batch.calls.map((call) => call.index), [2, 9]);
    expect(batch.calls.every((call) => call.valid), isTrue);
    expect(batch.calls.last.id, 'call-9');
    expect(batch.calls.last.name, 'update_state');
    expect(batch.calls.last.parameters, {'name': '海🐋'});
    expect(batch.calls.first.parameters, {
      'ops': [1, 2],
    });
  });

  test('contradicting each metadata field invalidates only that explicit call', () {
    final accumulator = ModelToolAccumulator();
    accumulator.add(_fragment(0, arguments: '{}'));
    accumulator.add(ModelToolFragment(index: 0, id: 'changed', type: 'other', name: 'different'));
    accumulator.add(_fragment(1, arguments: '{}'));
    final batch = accumulator.finish();
    expect(batch.eligibleStructure, isTrue);
    expect(batch.calls.first.valid, isFalse);
    expect(batch.calls.first.id, 'call-0');
    expect(
      batch.calls.first.issues.where((issue) => issue['code'] == 'conflicting_metadata').map((issue) => issue['field']),
      ['id', 'type', 'function.name'],
    );
    expect(batch.calls.last.valid, isTrue);
  });

  test('missing identity and non-function types remain distinct from unknown function names', () {
    final accumulator = ModelToolAccumulator();
    accumulator.add(ModelToolFragment(index: 0, arguments: '{}'));
    accumulator.add(ModelToolFragment(index: 1, id: '', type: 'custom', name: '', arguments: '{}'));
    accumulator.add(
      ModelToolFragment(index: 2, id: 'future', type: 'function', name: 'a_future_tool', arguments: '{}'),
    );
    final calls = accumulator.finish().calls;
    expect(_codes(calls[0].issues), containsAll(['missing_id', 'missing_type', 'missing_name']));
    expect(_codes(calls[1].issues), containsAll(['missing_id', 'invalid_tool_type', 'missing_name']));
    expect(calls[2].valid, isTrue, reason: 'The engine owns tool authorization.');
  });

  test('missing empty incomplete and non-object arguments have explicit diagnostics', () {
    final accumulator = ModelToolAccumulator();
    accumulator.add(_fragment(0));
    accumulator.add(_fragment(1, arguments: ''));
    accumulator.add(_fragment(2, arguments: '{"ops":['));
    accumulator.add(_fragment(3, arguments: 'null'));
    accumulator.add(_fragment(4, arguments: '[1,2]'));
    accumulator.add(_fragment(5, arguments: 'true'));
    accumulator.add(_fragment(6, arguments: '"text"'));
    final batch = accumulator.finish();
    expect(_codes(batch.calls[0].issues), contains('missing_arguments'));
    for (final call in batch.calls.skip(1).take(2)) {
      expect(_codes(call.issues), contains('invalid_arguments_json'));
    }
    for (final call in batch.calls.skip(3)) {
      expect(_codes(call.issues), contains('arguments_not_object'));
    }
    expect(batch.calls.every((call) => !call.valid && call.parameters == null), isTrue);
    expect(batch.eligibleStructure, isTrue);
  });

  test('duplicate nonempty ids invalidate both calls before any candidate executes', () {
    final accumulator = ModelToolAccumulator();
    accumulator.add(ModelToolFragment(index: 7, id: 'same', type: 'function', name: 'update_state', arguments: '{}'));
    accumulator.add(_fragment(4, arguments: '{}'));
    accumulator.add(ModelToolFragment(index: 1, id: 'same', type: 'function', name: 'update_state', arguments: '{}'));
    final batch = accumulator.finish();
    expect(batch.calls.map((call) => call.index), [1, 4, 7]);
    expect(batch.calls.map((call) => call.valid), [false, true, false]);
    expect(_codes(batch.calls.first.issues), contains('duplicate_id'));
    expect(_codes(batch.calls.last.issues), contains('duplicate_id'));
    expect(batch.eligibleStructure, isTrue);
  });

  test('unassigned errors do not guess an index or poison an independent complete call', () {
    final accumulator = ModelToolAccumulator();
    accumulator.add(
      ModelToolFragment(
        arguments: '{}',
        issues: [
          {'code': 'invalid_tool_call', 'field': 'tool_calls', 'message': 'not an object'},
        ],
      ),
    );
    accumulator.add(ModelToolFragment(index: -1, arguments: '{}'));
    accumulator.add(_fragment(50, arguments: '{}'));
    final batch = accumulator.finish();
    expect(batch.calls.single.index, 50);
    expect(batch.calls.single.valid, isTrue);
    expect(_codes(batch.issues), containsAll(['invalid_tool_call', 'invalid_index']));
    expect(batch.eligibleStructure, isTrue);
  });

  test('explicit parser issues reject their own call even when later JSON is complete', () {
    final accumulator = ModelToolAccumulator();
    accumulator.add(
      ModelToolFragment(
        index: 0,
        issues: [
          {'code': 'invalid_field_type', 'field': 'function.arguments', 'message': 'not a string', 'index': 0},
        ],
      ),
    );
    accumulator.add(_fragment(0, arguments: '{}'));
    accumulator.add(_fragment(1, arguments: '{}'));
    final batch = accumulator.finish();
    expect(batch.calls.first.parameters, <String, Object?>{});
    expect(batch.calls.first.valid, isFalse);
    expect(batch.calls.last.valid, isTrue);
  });

  test('the exact 64 distinct-call boundary accepts sparse indexes without allocating gaps', () {
    final accumulator = ModelToolAccumulator();
    for (var i = 0; i < ModelToolAccumulator.maxCalls; i++) {
      accumulator.add(_fragment(1000000 + i * 100, arguments: '{}'));
    }
    final batch = accumulator.finish();
    expect(batch.calls, hasLength(64));
    expect(batch.calls.every((call) => call.valid), isTrue);
    expect(batch.eligibleStructure, isTrue);
    expect(batch.issues, isEmpty);
  });

  test('a 65th distinct call blocks the whole batch including a complete prefix', () {
    final accumulator = ModelToolAccumulator();
    for (var i = 0; i <= ModelToolAccumulator.maxCalls; i++) {
      accumulator.add(_fragment(i, arguments: '{}'));
    }
    final batch = accumulator.finish();
    expect(batch.calls, hasLength(64));
    expect(batch.eligibleStructure, isFalse);
    expect(_codes(batch.issues), contains('tool_call_limit'));
    expect(batch.calls.every((call) => !call.valid && call.parameters == null), isTrue);
    expect(batch.calls.first.arguments, '{}');
    expect(_codes(batch.calls.first.issues), contains('batch_resource_limit'));
  });

  test('many fragments of one index do not consume additional call slots or duplicate diagnostics', () {
    final accumulator = ModelToolAccumulator();
    accumulator.add(_fragment(0, arguments: '{}'));
    for (var i = 0; i < 200; i++) {
      accumulator.add(ModelToolFragment(index: 0, id: 'different'));
    }
    final batch = accumulator.finish();
    expect(batch.calls, hasLength(1));
    expect(batch.calls.single.issues.where((issue) => issue['code'] == 'conflicting_metadata'), hasLength(1));
    expect(batch.eligibleStructure, isTrue);
  });

  test('exactly 1 MiB of aggregate ASCII arguments is accepted across multiple calls', () {
    final first = '{"first":true}';
    final second = _jsonAtBytes(ModelToolAccumulator.maxArgumentBytes - utf8.encode(first).length);
    final accumulator = ModelToolAccumulator();
    accumulator.add(_fragment(0, arguments: first));
    accumulator.add(_fragment(1, arguments: second));
    final batch = accumulator.finish();
    expect(batch.eligibleStructure, isTrue);
    expect(batch.calls.every((call) => call.valid), isTrue);
    expect(utf8.encode(batch.calls.map((call) => call.arguments).join()).length, ModelToolAccumulator.maxArgumentBytes);
  });

  test('one extra ASCII byte blocks even a previously complete JSON object', () {
    final arguments = _jsonAtBytes(ModelToolAccumulator.maxArgumentBytes);
    final accumulator = ModelToolAccumulator();
    accumulator.add(_fragment(0, arguments: arguments));
    accumulator.add(ModelToolFragment(index: 0, arguments: ' '));
    final batch = accumulator.finish();
    expect(batch.eligibleStructure, isFalse);
    expect(_codes(batch.issues), contains('tool_arguments_limit'));
    expect(batch.calls.single.arguments, arguments);
    expect(batch.calls.single.parameters, isNull);
    expect(batch.calls.single.valid, isFalse);
  });

  test('the arguments limit counts UTF-8 bytes rather than Dart string code units', () {
    final arguments = _jsonAtBytes(ModelToolAccumulator.maxArgumentBytes, unicode: true);
    expect(arguments.length, lessThan(ModelToolAccumulator.maxArgumentBytes));
    final exact = ModelToolAccumulator()..add(_fragment(0, arguments: arguments));
    expect(exact.finish().calls.single.valid, isTrue);
    final exceeded = ModelToolAccumulator()
      ..add(_fragment(0, arguments: arguments))
      ..add(ModelToolFragment(index: 0, arguments: '🐋'));
    expect(exceeded.finish().eligibleStructure, isFalse);
    expect(exceeded.finish().calls.single.valid, isFalse);
  });

  test('unassigned argument bytes also consume the one response budget', () {
    final accumulator = ModelToolAccumulator()..add(_fragment(0, arguments: '{}'));
    accumulator.add(ModelToolFragment(arguments: 'a' * ModelToolAccumulator.maxArgumentBytes));
    final batch = accumulator.finish();
    expect(batch.eligibleStructure, isFalse);
    expect(batch.calls.single.valid, isFalse);
    expect(_codes(batch.issues), contains('tool_arguments_limit'));
  });

  test('diagnostics are deduplicated and capped even for a custom malformed transport', () {
    final accumulator = ModelToolAccumulator()..add(_fragment(0, arguments: '{}'));
    for (var i = 0; i < 200; i++) {
      final issue = {'code': 'custom_$i', 'field': 'field_$i', 'message': 'invalid'};
      accumulator.add(ModelToolFragment(issues: [issue]));
      accumulator.add(ModelToolFragment(index: 0, issues: [issue]));
    }
    final batch = accumulator.finish();
    expect(batch.issues.length, lessThanOrEqualTo(32));
    expect(batch.calls.single.issues.length, lessThanOrEqualTo(32));
    expect(_codes(batch.issues), contains('diagnostic_limit'));
    expect(_codes(batch.calls.single.issues), contains('diagnostic_limit'));
  });

  test('fragment diagnostics and finished parameters expose independent deep copies', () {
    final metadata = <String, Object?>{
      'nested': <Object?>['original'],
    };
    final issue = <String, Object?>{'code': 'custom', 'field': 'id', 'message': 'invalid', 'metadata': metadata};
    final fragment = ModelToolFragment(issues: [issue]);
    (metadata['nested']! as List<Object?>).add('late');
    ((fragment.issues.single['metadata']! as Map<String, Object?>)['nested']! as List<Object?>).clear();
    final accumulator = ModelToolAccumulator()
      ..add(fragment)
      ..add(_fragment(0, arguments: '{"nested":[{"n":1}]}'));
    final batch = accumulator.finish();
    (batch.calls.single.parameters!['nested']! as List<Object?>).clear();
    (batch.issues.single['metadata']! as Map<String, Object?>).clear();
    final snapshot = batch.toJson();
    (snapshot['calls']! as List<Object?>).clear();
    expect(batch.calls.single.parameters, {
      'nested': [
        {'n': 1},
      ],
    });
    expect(batch.issues.single['metadata'], {
      'nested': ['original'],
    });
    expect(accumulator.finish().toJson(), batch.toJson());
    expect(() => batch.calls.clear(), throwsUnsupportedError);
  });

  test('a full diagnostic bag cannot hide the explicit whole-batch resource refusal', () {
    final accumulator = ModelToolAccumulator()..add(_fragment(0, arguments: '{}'));
    for (var i = 0; i < 100; i++) {
      accumulator.add(
        ModelToolFragment(
          issues: [
            {'code': 'custom_$i', 'field': 'tool_calls', 'message': 'invalid'},
          ],
        ),
      );
    }
    accumulator.add(ModelToolFragment(arguments: 'a' * ModelToolAccumulator.maxArgumentBytes));
    final batch = accumulator.finish();
    expect(batch.eligibleStructure, isFalse);
    expect(batch.issues.length, lessThanOrEqualTo(32));
    expect(_codes(batch.issues), containsAll(['tool_arguments_limit', 'diagnostic_limit']));
    expect(batch.calls.single.valid, isFalse);
  });

  test('finish is idempotent and add after finish is explicitly rejected', () {
    final accumulator = ModelToolAccumulator()..add(_fragment(0, arguments: '{}'));
    final first = accumulator.finish();
    expect(identical(first, accumulator.finish()), isTrue);
    expect(() => accumulator.add(_fragment(1, arguments: '{}')), throwsStateError);
    expect(accumulator.finish().calls, hasLength(1));
  });

  test('unrepresentable JSON numbers produce an audit-safe rejection instead of throwing finish', () {
    final accumulator = ModelToolAccumulator()..add(_fragment(0, arguments: '{"value":1e9999}'));
    final batch = accumulator.finish();
    expect(batch.calls.single.valid, isFalse);
    expect(batch.calls.single.parameters, isNull);
    expect(
      _codes(batch.calls.single.issues),
      anyOf(contains('invalid_arguments_json'), contains('invalid_arguments_value')),
    );
    expect(() => jsonEncode(batch.toJson()), returnsNormally);
  });
}

ModelToolFragment _fragment(int index, {String? arguments}) =>
    ModelToolFragment(index: index, id: 'call-$index', type: 'function', name: 'update_state', arguments: arguments);

List<Object?> _codes(List<Map<String, Object?>> issues) => [for (final issue in issues) issue['code']];

String _jsonAtBytes(int bytes, {bool unicode = false}) {
  const prefix = '{"value":"';
  const suffix = '"}';
  final available = bytes - utf8.encode('$prefix$suffix').length;
  final payload = unicode ? '${'🐋' * (available ~/ 4)}${'a' * (available % 4)}' : 'a' * available;
  final result = '$prefix$payload$suffix';
  expect(utf8.encode(result).length, bytes);
  return result;
}
