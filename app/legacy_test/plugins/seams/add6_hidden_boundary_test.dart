// First two cases reproduce independent reviewer R1 regressions.
// The additional cases check hidden ancestors and visible sibling preservation.
// ignore_for_file: depend_on_referenced_packages
import 'package:dsh_app/plugins/seams/seams.dart';
import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/ui/engine_settings/schema_form.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'wave7_schema_routing_boundaries_test.dart' as f;

void main() {
  for (final earlier in ['paragraph', 'callable', 'object']) {
    test('hidden override suppresses earlier $earlier branch but preserves visible sibling', () {
      final schema = f.factorySchema(['paragraph', 'hidden', 'callable']) as Map;
      final refs = schema['refs'] as Map;
      final root = refs['${schema['uid']}'] as Map;
      final fields = Map.of(root['dict'] as Map);
      refs['1003'] = {
        'type': 'object',
        'dict': {'child': fields['paragraph']},
      };
      refs['1001'] = {
        'type': 'object',
        'dict': {'secretArea': earlier == 'object' ? 1003 : fields[earlier]},
      };
      refs['1002'] = {
        'type': 'object',
        'dict': {'secretArea': fields['hidden'], 'visible': fields['paragraph']},
      };
      root.remove('dict');
      root['type'] = 'intersect';
      root['list'] = [1001, 1002];
      final settings = EngineSettings(
        namespaces: SettingsDescription.fromJson({
          'namespaces': [
            {'ns': f.primary, 'autoGenerate': true, 'schema': schema, 'value': {}, 'base': {}, 'user': {}},
          ],
        }).namespaces,
      );
      final sections = schemaSections(settings[f.primary]!);
      final visible = sections.expand((section) => section.fields).toList();
      expect(visible, hasLength(1));
      expect(visible.single.path, ['visible']);
      expect(visible.single.fallbackNode, isNull);
      expect(f.planFor(settings, Slots.bundleConfig, SeatPlacement.page).single.mode, SeatMode.native);
    });
  }

  test('hidden-only sibling does not become an explicit visible schema fallback', () {
    final settings = f.settingsFor({
      f.primary: ['paragraph'],
      f.secondary: ['hidden'],
    });
    expect(schemaSections(settings[f.secondary]!), isEmpty);
    final plan = f.planFor(settings, Slots.bundleConfig, SeatPlacement.page);
    expect(plan, hasLength(1));
    expect(plan.single.mode, SeatMode.native);
  });
  test('last-wins hidden child does not acquire fallback through an earlier visible branch', () {
    final schema = f.factorySchema(['paragraph', 'hidden']) as Map;
    final refs = schema['refs'] as Map;
    final root = refs['${schema['uid']}'] as Map;
    final fields = Map.of(root['dict'] as Map);
    refs['1001'] = {
      'type': 'object',
      'dict': {'secretArea': fields['paragraph']},
    };
    refs['1002'] = {
      'type': 'object',
      'dict': {'secretArea': fields['hidden']},
    };
    root.remove('dict');
    root['type'] = 'intersect';
    root['list'] = [1001, 1002];
    final settings = EngineSettings(
      namespaces: SettingsDescription.fromJson({
        'namespaces': [
          {'ns': f.primary, 'autoGenerate': true, 'schema': schema, 'value': {}, 'base': {}, 'user': {}},
        ],
      }).namespaces,
    );
    expect(schemaFormGroups(schemaSections(settings[f.primary]!), settings: settings), isEmpty);
  });
}
