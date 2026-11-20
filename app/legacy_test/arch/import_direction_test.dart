// Dependency direction in lib/: ui/ may import anything; nothing outside ui/
// imports ui/ (the entry points main.dart and app.dart aside). The edges that
// predate this guard are listed below. The list only shrinks: remove an edge
// here when the import goes away, never add one — put the shared type or
// function outside ui/ instead (docs/architecture.md, 目录).
//
// `cd app && dart run tool/import_graph.dart --edges` prints the current edges.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/import_graph.dart';

const _allowed = {
  'diagnostics/redact.dart -> ui/chat/secret_mask.dart',
  'links/app_links.dart -> ui/share_hosted/hosted_link_host.dart',
  'links/page_links.dart -> ui/companion/companion_page.dart',
  'links/page_links.dart -> ui/features/feature_catalog.dart',
  'links/page_links.dart -> ui/settings/index/settings_pages.dart',
  'links/plugin_links.dart -> ui/plugins/plugin_detail_sheet.dart',
  'notify/chat_alerts.dart -> ui/chat/media/media_format.dart',
  'notify/chat_alerts.dart -> ui/chat/secret_mask.dart',
  'notify/chat_alerts.dart -> ui/chat/widgets/turn_failure_text.dart',
  'pets/pet_overlay_bridge.dart -> ui/common/app_dialog.dart',
  'pets/pet_signals.dart -> ui/chat/run_info.dart',
  'pets/pet_voice_dialog.dart -> ui/chat/voice/voice_controller.dart',
  'pets/pet_voice_dialog.dart -> ui/theme/app_icons.dart',
  'plugins/native/native_icons.dart -> ui/theme/app_icons.dart',
  'plugins/native/native_state.dart -> ui/chat/dsh_ui/dsh_ui_model.dart',
  'plugins/seams/adapters/cordis_adapter.dart -> ui/common/list_page_row.dart',
  'plugins/seams/adapters/cordis_adapter.dart -> ui/cordis/cordis_page.dart',
  'plugins/seams/adapters/cordis_adapter.dart -> ui/cordis/cordis_plugin_sheet.dart',
  'plugins/seams/adapters/dsh_ui_panel_adapter.dart -> ui/plugins/native/native_panel.dart',
  'plugins/seams/adapters/schema_config_adapter.dart -> ui/common/list_page_row.dart',
  'plugins/seams/adapters/schema_config_adapter.dart -> ui/engine_settings/engine_settings_page.dart',
  'plugins/seams/adapters/schema_config_adapter.dart -> ui/engine_settings/namespace_copy.dart',
  'plugins/seams/adapters/schema_config_adapter.dart -> ui/engine_settings/schema_form.dart',
  'plugins/seams/adapters/schema_config_adapter.dart -> ui/theme/app_icons.dart',
  'plugins/seams/seat_inventory.dart -> ui/engine_settings/engine_settings_page.dart',
  'plugins/seams/seat_inventory.dart -> ui/engine_settings/schema_form.dart',
  'plugins/seams/seat_state.dart -> ui/plugins/islands/island_host.dart',
  'plugins/seams/seat_state.dart -> ui/plugins/seats/seat_island.dart',
  'plugins/seams/seat_state.dart -> ui/plugins/seats/seat_links.dart',
  'share_code/conversation_export.dart -> ui/chat/dsh_ui/dsh_ui_model.dart',
  'share_code/conversation_export.dart -> ui/chat/tool_view.dart',
  'share_code/conversation_redact.dart -> ui/chat/secret_mask.dart',
  'share_code/settings_sanitizer.dart -> ui/chat/secret_mask.dart',
  'state/access_state.dart -> ui/chat/voice/voice_bridge.dart',
  'state/appearance_state.dart -> ui/theme/accent.dart',
  'state/bots_state.dart -> ui/chat/secret_mask.dart',
  'state/media_catalog.dart -> ui/chat/media/generate_header.dart',
  'state/media_generation.dart -> ui/chat/media/generate_header.dart',
  'state/media_settings.dart -> ui/chat/media/generate_header.dart',
  'state/voice_state.dart -> ui/chat/voice/voice_bridge.dart',
  'ui_config/ui_config_icons.dart -> ui/theme/app_icons.dart',
  'ui_config/ui_config_state.dart -> ui/theme/accent.dart',
  'ui_config/widgets/from_ui_json_badge.dart -> ui/common/app_sheet.dart',
  'ui_config/widgets/from_ui_json_badge.dart -> ui/engine_settings/field_row.dart',
  'ui_config/widgets/from_ui_json_badge.dart -> ui/settings/settings_widgets.dart',
  'ui_config/widgets/ui_config_status.dart -> ui/common/app_sheet.dart',
  'ui_config/widgets/ui_config_status.dart -> ui/common/brief_notice.dart',
  'ui_config/widgets/ui_config_status.dart -> ui/settings/settings_widgets.dart',
  'ui_config/widgets/ui_config_status.dart -> ui/theme/app_icons.dart',
  'ui_config/widgets/ui_config_status.dart -> ui/theme/theme.dart',
  'wallpaper/wallpaper_look.dart -> ui/theme/accent.dart',
  'wallpaper/wallpaper_look.dart -> ui/theme/oklch.dart',
  'wallpaper/wallpaper_look.dart -> ui/theme/palette.dart',
  'wallpaper/wallpaper_look.dart -> ui/theme/semantic_colors.dart',
  'wallpaper/wallpaper_look.dart -> ui/theme/surfaces.dart',
};

void main() {
  final edges = nonUiToUiEdges(scanLib(Directory('lib'))).toSet();

  test('nothing outside ui/ starts importing ui/', () {
    final added = edges.difference(_allowed).toList()..sort();
    expect(added, isEmpty, reason: 'New imports of ui/ from outside it; move what they use out of ui/ instead.');
  });

  test('the allowlist names only edges that still exist', () {
    final gone = _allowed.difference(edges).toList()..sort();
    expect(gone, isEmpty, reason: 'These imports are gone; delete them from _allowed.');
  });

  test('the scanner finds relative, package, conditional and export edges', () {
    final root = Directory.systemTemp.createTempSync('import_direction');
    addTearDown(() => root.deleteSync(recursive: true));
    void write(String path, String source) =>
        (File('${root.path}/lib/$path')..createSync(recursive: true))..writeAsStringSync(source);
    write('ui/a.dart', '');
    write('ui/b.dart', '');
    write('ui/c.dart', '');
    write('ui/d.dart', "import '../state/s.dart';");
    write('state/s.dart', '''
import 'dart:async';
import 'package:flutter/widgets.dart';
import '../ui/a.dart' show A;
import 'package:dsh_app/ui/b.dart'
    if (dart.library.io) '../ui/c.dart';
export 'other.dart';
''');
    write('state/other.dart', "export '../ui/d.dart';");
    write('app.dart', "import 'ui/a.dart';");

    final graph = scanLib(Directory('${root.path}/lib'));
    expect(nonUiToUiEdges(graph), [
      'state/other.dart -> ui/d.dart',
      'state/s.dart -> ui/a.dart',
      'state/s.dart -> ui/b.dart',
      'state/s.dart -> ui/c.dart',
    ]);
    expect(cycles(graph), [
      ['state/other.dart', 'state/s.dart', 'ui/d.dart'],
    ]);
  });
}
