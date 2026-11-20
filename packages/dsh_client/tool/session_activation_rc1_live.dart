import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';

Future<void> main() async {
  final launch = DshLaunchUrl.tryParse(Platform.environment['OWN_LAUNCH']!)!;
  final client = await DshClient.connect(baseUri: launch.baseUri, token: launch.token);
  StreamSubscription<DshEvent>? passive;
  StreamSubscription<HostEvent>? host;
  try {
    Future<bool> available() async =>
        (await client.listSessions()).singleWhere((s) => s.sessionId == 'own-cold-activation').agentAvailable;
    final before = await available();
    final snapshot = Completer<SessionSnapshotEvent>();
    passive = client.watch('own-cold-activation').listen((e) {
      if (e is SessionSnapshotEvent && !snapshot.isCompleted) {
        snapshot.complete(e);
      }
    }, onError: snapshot.completeError);
    final first = await snapshot.future.timeout(const Duration(seconds: 10));
    final afterPassive = await available();
    final promoted = Completer<void>();
    host = client.hostEvents.listen((event) {
      if (event is SessionAddedEvent &&
          event.summary.sessionId == 'own-cold-activation' &&
          event.summary.agentAvailable &&
          !promoted.isCompleted) {
        promoted.complete();
      }
    });
    bool? checked;
    final accepted = await client.activateSessionForInteraction(
      'own-cold-activation',
      epoch: first.followEpoch!,
      allowed: () => true,
      onActivationChecked: (value) => checked = value,
    );
    if (accepted) await promoted.future.timeout(const Duration(seconds: 10));
    final afterSdk = await available();
    final direct = client.mux.open('session/follow', {
      'request': {
        'address': {'kind': 'session', 'sessionId': 'own-cold-activation'},
        'activate': true,
        'maxMessages': 1,
      },
    });
    final opening = await direct.items.first.timeout(const Duration(seconds: 10));
    await promoted.future.timeout(const Duration(seconds: 10));
    final afterDirect = await available();
    await direct.cancel();
    final result = {
      'before': before,
      'afterPassive': afterPassive,
      'sdkAccepted': accepted,
      'sdkSupported': checked,
      'afterSdk': afterSdk,
      'directSnapshot': opening is Map && opening['type'] == 'snapshot',
      'afterDirect': afterDirect,
      'primaryEpochCurrent': first.followEpoch!.isCurrent,
    };
    print(jsonEncode(result));
    final expected = Platform.environment['EXPECT_ACTIVATION'] != 'false';
    if (before ||
        afterPassive ||
        accepted != expected ||
        checked != expected ||
        afterSdk != expected ||
        !afterDirect ||
        result['directSnapshot'] != true ||
        result['primaryEpochCurrent'] != true) {
      throw StateError('Unexpected activation experiment outcome');
    }
  } finally {
    await passive?.cancel();
    await host?.cancel();
    await client.close();
  }
}
