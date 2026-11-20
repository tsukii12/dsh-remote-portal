import 'dart:async';

import 'package:dsh_app/state/terminal_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final cases = [
    (name: 'legal 120-character title does not split its final emoji', input: '${'a' * 119}🙂', expected: 'a' * 119),
    (name: 'complete emoji at the 120-unit boundary is retained', input: '${'a' * 118}🙂', expected: '${'a' * 118}🙂'),
    (name: 'ASCII title retains the existing 120-unit limit', input: 'a' * 121, expected: 'a' * 120),
  ];
  for (final entry in cases) {
    test(entry.name, () async {
      final backend = FakeTerminalBackend(terminals: [infoJson('a')]);
      final container = ProviderContainer(overrides: terminalOverrides(backend));
      addTearDown(container.dispose);
      final ready = Completer<void>();
      final provider = terminalWorkspaceProvider('s1');
      container.listen(provider, (_, next) {
        if (!next.loading && next.tabs.any((tab) => tab.id == 'a') && !ready.isCompleted) {
          ready.complete();
        }
      });
      await ready.future;
      final workspace = container.read(provider.notifier);
      expect(await workspace.rename('a', entry.input), isTrue);
      expect(backend.host['a']!['title'], entry.expected);
    });
  }
}
