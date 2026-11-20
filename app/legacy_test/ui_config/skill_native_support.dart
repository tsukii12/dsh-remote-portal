// File-transaction reference for Dart-only tests. The runtime channel is the
// seam here; actual native worker/activation ordering is tested in Kotlin.
import 'dart:io';

import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/ui_config/ui_skill.dart';

class SkillFileBridge extends RuntimeBridge {
  @override
  Future<ManagedSkillInstallResponse> installManagedSkill({
    required String requestId,
    required String expectedRoot,
    required String expectedToken,
    required int? expectedGeneration,
    required String name,
    required Map<String, String> files,
  }) async => ManagedSkillInstallResponse(
    result: (await installUiSkill(Directory(expectedRoot), UiSkillBundle(files, name: name))).name,
    current: true,
  );

  @override
  Future<void> cancelManagedSkill(String requestId) async {}
}

class SkillRuntime extends LocalRuntimeController {
  SkillRuntime(this.initial);
  final RuntimePhase initial;
  LocalRuntimeState value(RuntimePhase phase) => LocalRuntimeState(
    loaded: true,
    status: RuntimeStatus(
      phase: phase,
      baseUrl: 'http://127.0.0.1:1',
      token: 'fixture-skill-run',
      managedSkillGeneration: 1,
    ),
  );

  @override
  LocalRuntimeState build() => value(initial);
  void setPhase(RuntimePhase phase) => state = value(phase);
}
