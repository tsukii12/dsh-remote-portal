import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_app/share_code/conversation_share.dart';
import 'package:dsh_app/share_code/share_codec.dart';
import 'package:dsh_app/share_code/share_link.dart';
import 'package:dsh_app/share_code/share_models.dart';
import 'package:dsh_app/share_hosted/hosted_client.dart';
import 'package:dsh_app/share_hosted/hosted_crypto.dart';
import 'package:dsh_app/share_hosted/hosted_links_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/share_code/share_code_host.dart';
import 'package:dsh_app/ui/share_hosted/hosted_link_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';

class _Navigation extends NavigatorObserver {
  bool armed = false;
  bool eventDelivered = false;
  bool? eventBeforeReplay;
  late Completer<void> replayPushed;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (!armed) return;
    eventBeforeReplay = eventDelivered;
    replayPushed.complete();
  }
}

class _Downloaded extends HostedShareClient {
  _Downloaded(this.bytes);
  final Uint8List bytes;

  @override
  Future<Uint8List> download(String url) async => bytes;
}

void main() {
  // Valid, bounded synthetic input. No host, account or user conversation.
  final share = ConversationShare(
    title: 'Imported conversation',
    start: DateTime.utc(2026, 11, 11),
    entries: [for (var i = 0; i < 64; i++) UserEntry(t: 0, text: 'message $i ${'x' * 4096}')],
  );
  final code = encodeShareJson(share.toJson());
  final bytes = utf8.encode(encodeConversationFile(share, const [], code: code));

  for (final hosted in [false, true]) {
    testWidgets('${hosted ? 'hosted' : 'inline'} decoding lets a queued UI event run before replay navigation', (
      tester,
    ) async {
      usePhoneView(tester);
      final observer = _Navigation();
      final downloaded = _Downloaded(bytes);
      addTearDown(downloaded.close);
      late BuildContext opener;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(() => TestSettings()),
            hostedShareClientProvider.overrideWithValue(downloaded),
          ],
          child: MaterialApp(
            navigatorObservers: [observer],
            home: Builder(
              builder: (context) {
                opener = context;
                return const Scaffold(body: Text('Home'));
              },
            ),
          ),
        ),
      );
      observer.armed = true;
      await tester.runAsync(() async {
        observer.replayPushed = Completer<void>();
        Timer.run(() => observer.eventDelivered = true);
        if (hosted) {
          final key = encodeHostedKey(Uint8List(32));
          unawaited(openHostedLink(opener, Uri.parse('https://go.dshtui.com/c/M000000001#k=$key')));
        } else {
          unawaited(openShareLink(opener, ShareLink.inline(ShareKind.conversation, code)));
        }
        await observer.replayPushed.future.timeout(const Duration(seconds: 10));
      });
      expect(observer.eventBeforeReplay, isTrue);
      // Navigation is the end of this scheduling check; replay rendering has
      // separate real-widget coverage and is not part of the timing claim.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }
}
