import 'package:dsh_app/plugins/seams/seams.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_app/ui/plugins/seats/plugin_overlay_layer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _first = SlotOccupant(slot: Slots.shellOverlay, package: 'first', cell: 'pet');
const _second = SlotOccupant(slot: Slots.shellOverlay, package: 'second', cell: 'pet');
const _seat = SeatContext(host: HostRef.none, placement: SeatPlacement.overlay);
const _spec = IslandSpec(
  host: HostRef.none,
  form: IslandForm.overlay,
  slot: Slots.shellOverlay,
  package: 'first',
  cell: 'pet',
  maskOfficial: true,
);
const _inventory = SeatInventory(
  webReachable: true,
  packages: {'first': PluginClientInfo(package: 'first', enabled: true)},
);

class StateProviderForTest extends Notifier<List<SeatItem>> {
  @override
  List<SeatItem> build() => const [];
  void set(List<SeatItem> items) => state = items;
}

final _itemsProvider = NotifierProvider<StateProviderForTest, List<SeatItem>>(StateProviderForTest.new);

class _Chat extends ChatController {
  _Chat(super.sessionId);
  @override
  ChatState build() => const ChatState();
  void emit(ChatState next) => state = next;
}

void main() {
  test('same cell from different packages cannot reuse a WebView', () {
    const other = IslandSpec(
      host: HostRef.none,
      form: IslandForm.overlay,
      slot: Slots.shellOverlay,
      package: 'second',
      cell: 'pet',
      maskOfficial: true,
    );
    expect(_spec.key, isNot(other.key));
  });

  testWidgets('only islands draw; disabling removes it and empty space passes touches', (tester) async {
    var taps = 0;
    final container = ProviderContainer(
      overrides: [
        seatInventoryProvider.overrideWith((ref) => _inventory),
        seatPlanProvider(PluginOverlayLayer.request).overrideWith((ref) => SeatPlan(_seat, ref.watch(_itemsProvider))),
        seatRenderersProvider.overrideWithValue(
          SeatRenderers(
            island: (context, spec, items, fallback) => Align(
              alignment: Alignment.bottomRight,
              child: SizedBox(width: 40, height: 40, child: Text(spec.package!)),
            ),
            webLink: (context, seat, item) => const Text('must not cover the chat'),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => taps++),
              const PluginOverlayLayer(),
            ],
          ),
        ),
      ),
    );
    expect(find.text('first'), findsNothing);
    container.read(_itemsProvider.notifier).set([
      const SeatItem.island(_first, _spec),
      const SeatItem.webLink(_second),
    ]);
    await tester.pump();
    expect(find.text('first'), findsOneWidget);
    expect(find.text('must not cover the chat'), findsNothing);
    await tester.tapAt(const Offset(30, 30));
    expect(taps, 1);
    container.read(_itemsProvider.notifier).set([]);
    await tester.pump();
    expect(find.text('first'), findsNothing);
    await tester.tapAt(const Offset(30, 30));
    expect(taps, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('native approval and question hide the overlay until answered', (tester) async {
    final container = ProviderContainer(
      overrides: [
        chatProvider('s').overrideWith(() => _Chat('s')),
        seatInventoryProvider.overrideWith((ref) => _inventory),
        seatPlanProvider(PluginOverlayLayer.request)
            .overrideWith((ref) => const SeatPlan(_seat, [SeatItem.island(_first, _spec)])),
        seatRenderersProvider.overrideWithValue(
          SeatRenderers(island: (_, spec, items, fallback) => const Text('web overlay')),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: PluginOverlayLayer(sessionId: 's')),
      ),
    );
    expect(find.text('web overlay'), findsOneWidget);
    final chat = container.read(chatProvider('s').notifier) as _Chat;
    const approval = ApprovalRequest(eventId: 'a', sessionId: 's', toolName: 'bash');
    chat.emit(const ChatState(approvals: [approval]));
    await tester.pump();
    expect(find.text('web overlay'), findsNothing);
    chat.emit(const ChatState(approvals: [approval], autoAnswered: {'a'}));
    await tester.pump();
    expect(find.text('web overlay'), findsOneWidget);
    chat.emit(
      const ChatState(
        questions: [UserQuestionRequest(eventId: 'q', sessionId: 's', questions: [])],
      ),
    );
    await tester.pump();
    expect(find.text('web overlay'), findsNothing);
    chat.emit(const ChatState());
    await tester.pump();
    expect(find.text('web overlay'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a disabled package in the last inventory is not rendered', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          seatInventoryProvider.overrideWith(
            (ref) => const SeatInventory(packages: {'first': PluginClientInfo(package: 'first', enabled: false)}),
          ),
          seatPlanProvider(PluginOverlayLayer.request)
              .overrideWithValue(const SeatPlan(_seat, [SeatItem.island(_first, _spec)])),
          seatRenderersProvider.overrideWithValue(
            SeatRenderers(island: (_, spec, items, fallback) => const Text('disabled pet')),
          ),
        ],
        child: const MaterialApp(home: PluginOverlayLayer()),
      ),
    );
    expect(find.text('disabled pet'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
