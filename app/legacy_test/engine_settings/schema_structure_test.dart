import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/ui/engine_settings/schema_form.dart';
import 'package:flutter_test/flutter_test.dart';

SettingsNamespaceView view(Object schema) =>
    SettingsNamespaceView(ns: 'structure', schema: SchemaNode.fromJson(schema), value: const {}, revision: 0);

void main() {
  for (final name in ['dsh-ears-0.4.3', 'goodandready-dsh-voice-0.9.42', 'official-speech-to-text-0.2.1-rc.2']) {
    test('real published plugin schema remains a native form: $name', () {
      final schema = view(jsonDecode(File('test/engine_settings/fixtures/$name.json').readAsStringSync()));
      final fields = schemaSections(schema).expand((s) => s.fields).toList();
      expect(fields, isNotEmpty);
      expect(fields.every((f) => f.fallbackNode == null), isTrue);
      for (final field in fields) {
        expect(schemaAt(schema.schema, field.path), isNotNull, reason: field.path.join('.'));
      }
    });
  }

  test('deep objects preserve leaves rather than dropping the third group', () {
    final schema = view({
      'type': 'object',
      'dict': {
        'a': {
          'type': 'object',
          'dict': {
            'b': {
              'type': 'object',
              'dict': {
                'c': {
                  'type': 'object',
                  'dict': {
                    'enabled': {'type': 'boolean'},
                  },
                },
              },
            },
          },
        },
      },
    });
    final fields = schemaSections(schema).expand((s) => s.fields).toList();
    expect(fields.single.path, ['a', 'b', 'c', 'enabled']);
    expect(schemaAt(schema.schema, fields.single.path)?.type, 'boolean');
  });

  test('an unsupported intersection member is a local fallback', () {
    final schema = view({
      'type': 'intersect',
      'list': [
        {
          'type': 'object',
          'dict': {
            'enabled': {'type': 'boolean'},
          },
        },
        {'type': 'custom-dynamic'},
      ],
    });
    final fields = schemaSections(schema).expand((s) => s.fields).toList();
    expect(fields, hasLength(2));
    expect(fields.first.path, ['enabled']);
    expect(fields.last.fallbackNode?.type, 'custom-dynamic');
    expect(hasFormFields(schema), isTrue);
    expect(schemaAt(schema.schema, ['enabled'])?.type, 'boolean');
  });

  test('recursive refs terminate locally without hiding their siblings', () {
    final schema = view({
      'uid': 1,
      'refs': {
        '1': {
          'type': 'object',
          'dict': {'enabled': 2, 'child': 1},
        },
        '2': {'type': 'boolean'},
      },
    });
    final fields = schemaSections(schema).expand((s) => s.fields).toList();
    expect(fields, hasLength(2));
    expect(fields.first.path, ['enabled']);
    expect(fields.last.path, ['child']);
    expect(fields.last.fallbackNode, isNotNull);
  });

  test('disabled intersection member locks only the fields it owns', () {
    final schema = view({
      'type': 'intersect', 'list': [
        {'type': 'object', 'meta': {'disabled': true}, 'dict': {'locked': {'type': 'boolean'}}},
        {'type': 'object', 'dict': {'free': {'type': 'boolean'}}},
      ],
    });
    expect(schemaPathDisabled(schema.schema, ['locked']), isTrue);
    expect(schemaPathDisabled(schema.schema, ['free']), isFalse);
  });

  test('hidden groups disappear and disabled ancestors lock child controls', () {
    final schema = view({
      'type': 'object',
      'dict': {
        'hidden': {
          'type': 'object',
          'meta': {'hidden': true},
          'dict': {
            'token': {'type': 'string'},
          },
        },
        'locked': {
          'type': 'object',
          'meta': {'disabled': true},
          'dict': {
            'enabled': {'type': 'boolean'},
          },
        },
      },
    });
    expect(schemaSections(schema).expand((s) => s.fields).single.path, ['locked', 'enabled']);
    expect(schemaPathDisabled(schema.schema, ['locked', 'enabled']), isTrue);
  });
}
