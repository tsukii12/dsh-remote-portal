// The skill's schema.json, the app's UiSchema, the icon map, the feature
// catalog and the bundled skill files must not drift apart.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/plugins/seams/slot_catalog.dart';
import 'package:dsh_app/ui_config/ui_config.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  final schema = jsonDecode(File('$appDir/assets/skills/dsh-go-ui/schema.json').readAsStringSync()) as Map;
  final defs = schema[r'$defs'] as Map;
  final x = schema['x-dsh-go'] as Map;
  List<Object?> enumOf(String def) => (defs[def] as Map)['enum'] as List;

  test('value lists match UiSchema', () {
    expect(enumOf('headerBuiltin'), UiSchema.headerBuiltins);
    expect(enumOf('icon'), UiSchema.icons);
    expect(enumOf('drawerGroup'), UiSchema.drawerGroups);
    expect(enumOf('drawerSort'), UiSchema.drawerSorts);
    expect(enumOf('drawerFilter'), UiSchema.drawerFilters);
    expect(enumOf('density'), UiSchema.densities);
    expect(enumOf('hideItem'), UiSchema.hideItems);
    expect(enumOf('themeMode'), UiSchema.themeModes);
    expect(enumOf('accentPreset'), UiSchema.accentPresets);
    expect(enumOf('petPosition'), UiSchema.petPositions);
    expect(enumOf('seatMode'), UiSchema.seatModes);
    expect(enumOf('page'), UiSchema.pages);
    expect(enumOf('actionType'), UiSchema.actionTypes);
    expect(x['shortcutKeys'], UiSchema.shortcutKeys);
    expect(x['systemModifiers'], UiSchema.systemModifiers);
    expect(x['reservedShortcuts'], UiSchema.reservedShortcuts);
    expect((schema['properties'] as Map).keys.where((k) => k != r'$schema'), UiSchema.topKeys);
  });

  test('limits match UiSchema', () {
    final limits = x['limits'] as Map;
    expect(x['version'], UiSchema.version);
    expect(x['maxBytes'], UiSchema.maxBytes);
    expect(x['maxDepth'], UiSchema.maxDepth);
    expect(limits, {
      'headerCustomMax': UiSchema.headerCustomMax,
      'headerLabelMax': UiSchema.headerLabelMax,
      'quickActionsMax': UiSchema.quickActionsMax,
      'quickLabelMax': UiSchema.quickLabelMax,
      'suggestionsMax': UiSchema.suggestionsMax,
      'suggestionTitleMax': UiSchema.suggestionTitleMax,
      'suggestionSubtitleMax': UiSchema.suggestionSubtitleMax,
      'shortcutsMax': UiSchema.shortcutsMax,
      'sendTextMax': UiSchema.sendTextMax,
      'commandArgsMax': UiSchema.commandArgsMax,
      'urlMax': UiSchema.urlMax,
    });
  });

  test('enums follow the schema lists in order', () {
    expect(UiHeaderBuiltin.values.map((e) => e.name), UiSchema.headerBuiltins);
    expect(UiDrawerGroup.values.map((e) => e.name), UiSchema.drawerGroups);
    expect(UiDrawerSort.values.map((e) => e.name), UiSchema.drawerSorts);
    expect(UiDrawerFilter.values.map((e) => e.name), UiSchema.drawerFilters);
    expect(UiDensity.values.map((e) => e.name), UiSchema.densities);
    expect(UiHideItem.values.map((e) => e.name), UiSchema.hideItems);
    expect(UiThemeMode.values.map((e) => e.name), UiSchema.themeModes);
    expect(UiPetPosition.values.map((e) => e.wire), UiSchema.petPositions);
    expect(UiSeatMode.values.map((e) => e.name), UiSchema.seatModes);
  });

  test('the slot lists match the slot catalog', () {
    final slots = x['slots'] as Map;
    expect(slots['release'], slotCatalogRelease);
    expect(slots['known'], slotCatalog.keys.toList());
    expect(slots['unseatable'], [
      for (final s in slotCatalog.values)
        if (!s.seatable) s.key,
    ]);
  });

  test('every icon name has a glyph', () {
    expect(uiConfigIcons.keys, UiSchema.icons);
  });

  test('every open target is a feature-catalog id, a settings page link, new-chat or settings', () {
    final catalog = File('$appDir/lib/ui/features/feature_catalog.dart').readAsStringSync();
    final ids = RegExp(r"\bid: '([a-z0-9-]+)'").allMatches(catalog).map((m) => m.group(1)).toSet();
    // Settings that left 全部功能 open through the settings index (native_taps).
    final index = File('$appDir/lib/ui/settings/index/spots.dart').readAsStringSync();
    for (final group in RegExp(r'links: const \[(.*?)\]', dotAll: true).allMatches(index)) {
      ids.addAll(RegExp(r"'([a-z0-9-]+)'").allMatches(group.group(1)!).map((m) => m.group(1)));
    }
    ids.addAll(RegExp(r"\blink: '([a-z0-9-]+)'").allMatches(index).map((m) => m.group(1)));
    for (final page in UiSchema.pages) {
      if (page == 'new-chat' || page == 'settings') continue;
      expect(ids, contains(page), reason: 'neither 全部功能 nor the settings index has "$page"');
    }
  });

  test('accent presets are the app\'s presets', () {
    final accent = File('$appDir/lib/ui/theme/accent.dart').readAsStringSync();
    final match = RegExp(r'static const presets = \[([^\]]*)\]').firstMatch(accent)!;
    expect(match.group(1)!.split(',').map((s) => s.trim()), UiSchema.accentPresets);
  });

  test('the manifest lists every bundled file and SKILL.md is a valid managed skill', () async {
    final dir = Directory('$appDir/assets/skills/dsh-go-ui');
    final manifest = jsonDecode(File('${dir.path}/manifest.json').readAsStringSync()) as Map;
    final files = (manifest['files'] as Map).cast<String, String>();
    final onDisk = {for (final f in dir.listSync()) f.uri.pathSegments.last}..remove('manifest.json');
    expect(files.keys.toSet(), onDisk);
    expect(files.values, containsAll(['SKILL.md', 'schema.json', 'scripts/check.mjs']));

    final bundle = await loadUiSkillBundle(readAssetFromDisk);
    expect(bundle.files.keys, unorderedEquals(files.values));
    final skill = bundle.skillMd;
    expect(skill.split('\n').first, '---', reason: 'DSH ignores a skill whose first line is not ---');
    expect(RegExp(r'^name: dsh-go-ui$', multiLine: true).hasMatch(skill), isTrue);
    expect(RegExp(r'^description: \S', multiLine: true).hasMatch(skill), isTrue);
    expect(isManagedUiSkill(skill), isTrue);
    expect(isManagedUiSkill(skill.replaceFirst(RegExp(r'^# dsh-go:managed.*\n', multiLine: true), '')), isFalse);
  });

  test('the examples apply without issues', () {
    for (final name in ['example-full.json', 'example-header.json', 'example-quiet.json']) {
      final load = parseUiConfig(File('$appDir/assets/skills/dsh-go-ui/$name').readAsStringSync());
      expect(load.issues, isEmpty, reason: name);
    }
  });
}
