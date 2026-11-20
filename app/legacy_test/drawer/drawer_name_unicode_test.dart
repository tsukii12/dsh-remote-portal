import 'dart:convert';

import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final cases = [
    (
      name: 'create retains a legal 20-character folder name',
      rename: false,
      value: '${'a' * 19}🙂',
      expected: '${'a' * 19}🙂',
    ),
    (
      name: 'rename retains a legal 20-character folder name',
      rename: true,
      value: '${'a' * 19}🙂',
      expected: '${'a' * 19}🙂',
    ),
    (name: 'exactly 20 ASCII characters still persist unchanged', rename: false, value: 'a' * 20, expected: 'a' * 20),
    (
      name: 'trim preserves the combining sequence in the twentieth character',
      rename: false,
      value: '  ${'a' * 19}e\u0301  ',
      expected: '${'a' * 19}e\u0301',
    ),
    (
      name: 'rename preserves the twentieth ZWJ character',
      rename: true,
      value: '${'a' * 19}👩‍💻',
      expected: '${'a' * 19}👩‍💻',
    ),
    (
      name: '21 characters retain exactly the first 20 complete characters',
      rename: false,
      value: '${'a' * 19}🙂z',
      expected: '${'a' * 19}🙂',
    ),
  ];
  for (final entry in cases) {
    test(entry.name, () async {
      final first = ProviderContainer();
      final view = first.read(drawerViewProvider.notifier);
      await view.ready();
      final id = (await view.createFolder(entry.rename ? 'original' : entry.value))!;
      if (entry.rename) await view.updateFolder(id, name: entry.value);
      final inMemory = first.read(drawerViewProvider).byId(id)!.name;
      final prefs = await SharedPreferences.getInstance();
      final saved = DrawerView.fromJson(jsonDecode(prefs.getString('drawer.view.local.local')!)).byId(id)!.name;
      first.dispose();
      final second = ProviderContainer();
      addTearDown(second.dispose);
      await second.read(drawerViewProvider.notifier).ready();
      final restored = second.read(drawerViewProvider).byId(id)!.name;
      debugPrintSynchronously(
        jsonEncode({
          'case': entry.name,
          'inputUnits': entry.value.codeUnits,
          'memoryUnits': inMemory.codeUnits,
          'savedUnits': saved.codeUnits,
          'restoredUnits': restored.codeUnits,
        }),
      );
      expect([inMemory, saved, restored], [entry.expected, entry.expected, entry.expected]);
    });
  }
}
