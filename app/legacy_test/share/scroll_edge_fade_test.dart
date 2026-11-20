import 'package:dsh_app/ui/common/scroll_edge_fade.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const _frame = ValueKey('frame');

/// Whether the top and bottom pixel rows are faded, mid-width.
Future<(bool, bool)> _faded(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_frame));
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = (await image.toByteData())!;
    bool faded(int y) => data.getUint8((y * image.width + image.width ~/ 2) * 4 + 3) < 128;
    final edges = (faded(0), faded(image.height - 1));
    image.dispose();
    return edges;
  }))!;
}

Widget _app(Widget list) => MaterialApp(
  home: Align(
    alignment: Alignment.topCenter,
    child: RepaintBoundary(
      key: _frame,
      child: SizedBox(height: 240, child: ScrollEdgeFade(child: list)),
    ),
  ),
);

void main() {
  testWidgets('an edge fades only while there is more past it; the child is not rebuilt', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    var builds = 0;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (_) {
            builds++;
            return ListView(
              controller: controller,
              children: const [ColoredBox(color: Colors.white, child: SizedBox(height: 1000))],
            );
          },
        ),
      ),
    );
    await tester.pump();
    final initialBuilds = builds;
    expect(await _faded(tester), (false, true));

    controller.jumpTo(40);
    await tester.pump();
    expect(await _faded(tester), (true, true));

    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    expect(await _faded(tester), (true, false));
    expect(builds, initialBuilds);
  });

  testWidgets('a list that fits is not faded', (tester) async {
    await tester.pumpWidget(
      _app(
        ListView(
          children: const [ColoredBox(color: Colors.white, child: SizedBox(height: 240))],
        ),
      ),
    );
    await tester.pump();
    expect(await _faded(tester), (false, false));
  });
}
