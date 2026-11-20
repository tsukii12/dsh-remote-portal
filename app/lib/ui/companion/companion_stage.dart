
import 'package:flutter/material.dart';
import '../../companion/companion_adapt.dart';
import '../../companion/companion_moves.dart';
import '../../companion/companion_pack.dart';
import '../../l10n/l10n.dart';

const companionStageRendererGone = 'renderer gone';
const companionStagePackChanged = 'pack changed';
class CompanionStageController {
  CompanionStageController({this.sink});
  final void Function(String type, Map<String, Object?> args)? sink;
  void command(String type, [Map<String, Object?> args = const {}]) {}
}
class CompanionStageEvents {
  const CompanionStageEvents({
    required this.onReady,
    required this.onFailed,
    required this.onTouch,
    required this.onWake,
    required this.onMood,
    required this.onObject,
    required this.onActivity,
    this.onModel,
    this.onProbe,
  });

  final VoidCallback onReady;

  /// What the model is (stage.js `probeReport`), when it loads and whenever
  /// an adapter is worn or taken off (companion_adapt.dart).
  final ValueChanged<CompanionProbe>? onProbe;

  /// What the model brings of its own, as it finishes loading (before [onReady]).
  final ValueChanged<CompanionModelInfo>? onModel;
  final ValueChanged<String> onFailed;
  final void Function(String zone, String kind) onTouch;
  final VoidCallback onWake;
  final ValueChanged<String> onMood;

  /// One of her things was tapped: `snack`, `play` or `rest`.
  final ValueChanged<String> onObject;

  /// What she's doing changed (also when it ran out): `idle` / `snack` / `play` / `rest`.
  final ValueChanged<String> onActivity;
}


class CompanionStage extends StatelessWidget {
  const CompanionStage({super.key, required this.store, required this.controller,
    required this.events, this.bare = false});
  final CompanionPackStore store;
  final CompanionStageController controller;
  final CompanionStageEvents events;
  final bool bare;
  @override
  Widget build(BuildContext context) => Center(child: Text(context.l10n.portalWebRemoved));
}
