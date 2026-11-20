import 'package:dsh_client/dsh_client.dart';

import 'engine_settings_state.dart';
import 'models_state.dart';

const defaultModelProviderField = FieldRef(defaultModelSettingsNs, ['provider']);
const defaultModelIdField = FieldRef(defaultModelSettingsNs, ['model']);
const defaultModelEffortField = FieldRef(defaultModelSettingsNs, ['reasoningEffort']);
const defaultModelRememberField = FieldRef(defaultModelSettingsNs, ['rememberLastSelection']);
const defaultModelSelectionFields = [defaultModelProviderField, defaultModelIdField, defaultModelEffortField];

ModelSelection? defaultModelSelection(EngineSettings settings) {
  final provider = settings.valueOf(defaultModelProviderField);
  final model = settings.valueOf(defaultModelIdField);
  final effort = settings.valueOf(defaultModelEffortField);
  if (provider is! String || provider.isEmpty || model is! String || model.isEmpty) return null;
  return ModelSelection(provider: provider, model: model, reasoningEffort: effort is String ? effort : null);
}

bool supportsDefaultModelMode(EngineSettings settings) =>
    settings.nodeOf(defaultModelRememberField)?.effective.type == 'boolean';

bool canEditDefaultModel(EngineSettings settings) =>
    settings.canWrite(defaultModelSettingsNs) &&
    defaultModelSelectionFields.every(
      (field) =>
          settings.nodeOf(field)?.effective.type == 'string' &&
          !schemaPathDisabled(settings[defaultModelSettingsNs]!.schema, field.path),
    );

bool canEditDefaultModelMode(EngineSettings settings) =>
    canEditDefaultModel(settings) &&
    supportsDefaultModelMode(settings) &&
    !schemaPathDisabled(settings[defaultModelSettingsNs]!.schema, defaultModelRememberField.path);

/// A route and effort are one selection, not independent edits. Unsetting the
/// effort drops the previous user override; the caller verifies the resolved
/// value afterwards, including any inherited deployment effort.
List<SettingsOp> defaultModelOps(ModelSelection selection, {bool? rememberLastSelection}) => [
  SettingsOp.set(defaultModelProviderField.path, selection.provider),
  SettingsOp.set(defaultModelIdField.path, selection.model),
  if (selection.reasoningEffort case final effort?)
    SettingsOp.set(defaultModelEffortField.path, effort)
  else
    SettingsOp.unset(defaultModelEffortField.path),
  if (rememberLastSelection != null) SettingsOp.set(defaultModelRememberField.path, rememberLastSelection),
];
