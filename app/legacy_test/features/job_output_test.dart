import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/engine/log_view.dart';
import 'package:dsh_app/ui/features/jobs_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import '../plugins/support/fake_plugin_host.dart';

class _JobLink extends FakeMuxLink {
  DshMuxFrameHandler? _frames;
  String? _job;
  @override
  void start({required DshMuxFrameHandler onFrame, required DshMuxLossHandler onLost}) {
    _frames = onFrame;
    super.start(onFrame: onFrame, onLost: onLost);
  }

  @override
  void open(String streamId, String endpoint, Map<String, Object?> payload) {
    if (endpoint == 'job/follow') {
      _job = streamId;
    } else {
      super.open(streamId, endpoint, payload);
    }
  }

  void output(String text, {bool gap = false, bool lossy = false}) {
    _frames!({
      'type': 'item',
      'streamId': _job!,
      'value': {
        'type': 'output',
        'lossy': lossy,
        'chunks': [
          {'text': text, 'gapBefore': gap},
        ],
      },
    });
  }
}

class _Carrier extends FakePluginCarrier {
  final jobs = _JobLink();
  @override
  Future<DshMuxLink> openLink(MuxOptions options) async => jobs;
}

void main() {
  test('partial line spans chunks; CR overwrites, split CRLF ends a line', () {
    final output = JobOutputBuffer()
      ..add('hel')
      ..add('lo\n');
    expect(output.lines, ['hello']);
    output.add('a\rb');
    expect(output.lines, ['hello', 'b']);
    output.add('\r');
    output.add('\nnext');
    expect(output.lines, ['hello', 'b', 'next']);
  });
  test('1000 lines include the unfinished line and cap individual lines', () {
    final output = JobOutputBuffer()..add(List.generate(1500, (i) => '$i\n').join());
    expect(output.lines.length, 1000);
    expect(output.lines.first, '500');
    expect(output.lines.last, '1499');
    expect(output.trimmed, isTrue);
    output.add('tail');
    expect(output.lines.length, 1000);
    expect(output.lines.first, '501');
    output.add('x' * 5000);
    expect(output.lines.last.length, 4000);
  });
  test('CSI and OSC including sequences split across chunks are removed', () {
    final output = JobOutputBuffer()
      ..add('\x1b[31mred\x1b[0m\n\x1b]8;;https://example.com')
      ..add('\x07link\x1b]8;;\x1b\\\n');
    expect(output.lines, ['red', 'link']);
    expect(output.lines.join(), isNot(contains('\x1b')));
  });
  testWidgets('live job output reuses bounded reversed log and follows latest line', (tester) async {
    final carrier = _Carrier();
    final client = DshClient.withCarrier(carrier);
    addTearDown(client.close);
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        const JobOutputPage(
          sessionId: 's1',
          job: JobInfo(id: 'j1', kind: 'bash', label: 'run build', status: 'running'),
        ),
        overrides: [activeConnectionProvider.overrideWithValue(AsyncData(fakeHost(client)))],
      ),
    );
    await pumpFrames(tester, 6);
    expect(find.text('等待输出…'), findsOneWidget);
    carrier.jobs.output('hel');
    await tester.pump();
    carrier.jobs.output('lo\n');
    await tester.pump();
    expect(tester.widget<TerminalCard>(find.byType(TerminalCard)).lines, ['hello']);
    carrier.jobs.output('a\rb\n\x1b[31mred\x1b[0m\n');
    await tester.pump();
    expect(tester.widget<TerminalCard>(find.byType(TerminalCard)).lines, ['hello', 'b', 'red']);
    carrier.jobs.output(List.generate(1500, (i) => 'line $i\n').join());
    await pumpFrames(tester);
    final card = tester.widget<TerminalCard>(find.byType(TerminalCard));
    expect(card.lines.length, 1000);
    expect(card.lines.first, 'line 500');
    expect(find.text('最近 1000 行'), findsOneWidget);
    expect(find.text('line 1499'), findsOneWidget);
    expect(find.textContaining('\x1b'), findsNothing);
    expect(tester.widget<ListView>(find.byType(ListView)).reverse, isTrue);
    carrier.jobs.output('newest\n');
    await pumpFrames(tester);
    expect(find.text('newest'), findsOneWidget);
  });
  testWidgets('gap and lossy frames show a bounded-output count', (tester) async {
    final carrier = _Carrier();
    final client = DshClient.withCarrier(carrier);
    addTearDown(client.close);
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        const JobOutputPage(
          sessionId: 's1',
          job: JobInfo(id: 'j1', kind: 'bash', label: 'run', status: 'running'),
        ),
        overrides: [activeConnectionProvider.overrideWithValue(AsyncData(fakeHost(client)))],
      ),
    );
    await pumpFrames(tester, 6);
    carrier.jobs.output('latest\n', gap: true, lossy: true);
    await pumpFrames(tester);
    expect(find.text('最近 1000 行'), findsOneWidget);
  });
}
