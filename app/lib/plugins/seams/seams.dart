// Plugin seams: where web plugins show up in the native UI
// (docs/design/plugin-seams.md §2–§5). Native adapter first, web island
// second, "open in DSH Web" last.

export 'adapters/cordis_adapter.dart' show CordisAdapter, CordisSeat;
export 'adapters/dsh_ui_panel_adapter.dart' show DshUiPanelAdapter;
export 'adapters/pet_adapter.dart' show PetAdapter;
export 'adapters/schema_config_adapter.dart' show SchemaConfigAdapter, SchemaConfigSeat;
export 'plugin_seat.dart';
export 'seat_inventory.dart';
export 'seat_models.dart';
export 'seat_planner.dart';
export 'seat_state.dart';
export 'slot_catalog.dart';
