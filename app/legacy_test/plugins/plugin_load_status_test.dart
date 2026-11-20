import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/state/plugin_load_status.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

const _row = PluginBundleRow(rowId: 'worker', moduleName: 'shared-worker', entryId: 'include:worker');
const _bundle = PluginBundle(name: 'example', enabled: true, installed: true, rows: [_row]);

PluginInventoryEntry _entry({
  String id = 'include:worker',
  String module = 'shared-worker',
  bool enabled = true,
  String? phase = 'active',
  PluginDisplayMeta? meta,
}) => PluginInventoryEntry(entryId: id, moduleName: module, enabled: enabled, fiberPhase: phase, meta: meta);

void main() {
  test('an enabled bundle is not proof its component is running', () {
    final rows = bundleLoadRows(_bundle, PluginInventory(entries: [_entry(phase: 'failed')]));
    expect(rows.single.status, InventoryStatus.failed);
    expect(rows.single.hasIssue, isTrue);
  });

  for (final (phase, enabled, status, issue) in <(String?, bool, InventoryStatus, bool)>[
    ('active', true, InventoryStatus.running, false),
    ('failed', true, InventoryStatus.failed, true),
    ('loading', true, InventoryStatus.loading, true),
    ('unloading', true, InventoryStatus.loading, true),
    ('pending', true, InventoryStatus.waiting, true),
    (null, true, InventoryStatus.idle, true),
    (null, false, InventoryStatus.off, false),
  ]) {
    test('reported phase $phase with enabled=$enabled stays $status', () {
      final row = bundleLoadRows(
        _bundle,
        PluginInventory(
          entries: [_entry(phase: phase, enabled: enabled)],
        ),
      ).single;
      expect(row.status, status);
      expect(row.hasIssue, issue);
    });
  }

  test('the same module in another bundle cannot make this row healthy', () {
    final rows = bundleLoadRows(_bundle, PluginInventory(entries: [_entry(id: 'include:other')]));
    expect(rows.single.entry, isNull);
    expect(rows.single.status, isNull);
    expect(rows.single.hasIssue, isTrue);
  });

  test('a missing row id does not fall back to rowId or moduleName', () {
    const noId = PluginBundle(
      name: 'example',
      enabled: true,
      rows: [PluginBundleRow(rowId: 'worker', moduleName: 'shared-worker')],
    );
    final row = bundleLoadRows(noId, PluginInventory(entries: [_entry()])).single;
    expect(row.entry, isNull);
    expect(row.hasIssue, isTrue);
  });

  test('an ambiguous entry id cannot establish a load result', () {
    final row = bundleLoadRows(
      _bundle,
      PluginInventory(
        entries: [
          _entry(),
          _entry(phase: 'failed'),
        ],
      ),
    ).single;
    expect(row.status, isNull);
    expect(row.hasIssue, isTrue);
  });

  test('disabled bundles and bundles without Loader rows do not report a failure', () {
    final inventory = PluginInventory(entries: [_entry(phase: 'failed')]);
    expect(bundleLoadRows(const PluginBundle(name: 'off', rows: [_row]), inventory), isEmpty);
    expect(bundleLoadRows(const PluginBundle(name: 'client-only', enabled: true), inventory), isEmpty);
  });

  test('metadata diagnostics are retained without changing the runtime phase', () {
    const meta = PluginDisplayMeta(error: ' Invalid title map ');
    const bundle = PluginBundle(
      name: 'example',
      enabled: true,
      rows: [PluginBundleRow(rowId: 'worker', moduleName: 'shared-worker', entryId: 'include:worker', meta: meta)],
    );
    final row = bundleLoadRows(bundle, PluginInventory(entries: [_entry(meta: meta)])).single;
    expect(row.status, InventoryStatus.running);
    expect(row.incomplete, isFalse);
    expect(row.hasIssue, isTrue);
    expect(row.metadataErrors, ['Invalid title map']);
  });

  test('a preset composition does not stand in for a global Loader entry', () {
    const inventory = PluginInventory(
      entries: [],
      presets: [
        PresetPlugins(
          id: 'writer',
          rows: [PresetPluginRow(moduleName: 'shared-worker', entryId: 'worker', enabled: true, fiberPhase: 'active')],
        ),
      ],
    );
    expect(bundleLoadRows(_bundle, inventory).single.status, isNull);
  });

  test('the old-host listPlugins fallback keeps the exact state evidence', () {
    final inventory = PluginInventory.fromEntries([
      const PluginEntry(entryId: 'include:worker', moduleName: 'shared-worker', enabled: true, fiberPhase: 'pending'),
    ]);
    final row = bundleLoadRows(_bundle, inventory).single;
    expect(row.status, InventoryStatus.waiting);
    expect(row.hasIssue, isTrue);
  });
}
