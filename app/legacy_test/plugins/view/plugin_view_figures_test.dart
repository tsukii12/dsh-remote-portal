// View v2's four new components (docs/design/plugin-ui-v3.md §4.2): emptyState,
// gallery, progress shape "ring", metric trend. Parsing, the geometry (measured,
// not eyeballed), taps, and goldens: light and dark at 390, and 320 at 2× text.
// Regenerate with
// `flutter test --update-goldens test/plugins/view/plugin_view_figures_test.dart`.

import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_blocks.dart';
import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_model.dart';
import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_plugin_figures.dart';
import 'package:dsh_app/ui/chat/media/media_viewer.dart';
import 'package:dsh_app/ui/chat/widgets/image_actions.dart' show GallerySaveButton;
import 'package:dsh_app/ui/plugins/view/plugin_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const _sea =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAGAAAABgCAIAAABt+uBvAAAEd0lEQVR42u3aaztVWxTA8fHt6qR0U6GQy3YLkaQkFbkUJaUL3aOESLZ7ZLvfEqFQKNXJqdPFOV9gnjHX8aI3c/S0tr3WtJ/xPP9P8HuxnjXHGHBj6N/rg/9g1waw5dL+5dK+5ZK+HyW9P65iPd+vYN3fL3d9wy65vhW7vhZ3fr34FPv7QoesqP1L0ZMv57G2z4VY6+dzLX9hZ5uxpYKmpYLGpfzGT/kNn85gzj9P18vyHn/Ecus+5j76kIPVfsiufZ9d8/7UQ2wxq3oxq2oxs+pdZuW7k9iDtycqZMfvL2AZ9xYyyuePYWXz6WVz6Xfnjt7B3qTdNrr1+shN2eEbs1jq9dnUazOHsNKZlNLplJLpg1exV8lXjC6/PHBJllQ8hSVenEq8MLkfK5pMKJpIOD8BrEPoxBcaQKyj0okvfAGsQ+jEn5NArKPUiUMg1iF04s6OA+sQOvsKxoF1CB0DiHXUOrH5Y8A6hI4BxDpqnZgzY8A6hE7M6efAOoSOBGIdQic6zwBiHZVOdN4osA6hE5U7CqxD6ETlIBDrqHUic54B6xA6kdkSaA3oNM8JrOmN0WvROCtrmJE5p4XzlfCQjiN7BHTWaVkQLfPilzr12EvxeEq2ujqOUwaQ1+jUTcpWUceRNQIa6rQijVmdugnx6IVsVXQisobBK3Vqx2Xu60RkDoO36tSMiZrnwk2dcAnkvToPsVHhjk74ySHwgq8yoVM9KtzRCTuBQF6tU/1MVI8I0zoSyOt1qrBhYU4n7Pgg6PCv7GmdSgQypROKQGviJeGmTuWQMKcTmiGBvF/nwaDMhM7eYwNg+xvdGp2KAWFCxwCye4JhjY4E+n2dkPQBsH2+Y41ORb8woROS3g+2T7+s0bnfJ0zohBztB9tng9boYCZ0gtMQyO7JqTU693qFCZ3gtD6wfa5sjY4E+n2doCMGkL1Td2t0ynuECR0JZPtOwhqd8m5hQifocC/YvrGxRgczobMntRd02Gdpq2MAabDt87ROWZcwp7P7UA/osAv1tA5mTscA0mNTrKdOYEoP6LNH11An8GA36HNl4Amduy7hjo4E0uoGQzedgGQJpNeFilY6AcldoOH9jj46/gcQSNfrJru+yj/r+Cd1gc63X7br+Ce5YE1cxnnuJUHr7Ep0wVq8GzQ3GzShYwCxjlpn5/5OYB1CZwWIdVQ6OxM6gXUInR3xT4F1CB0JxDqEjl8cArGOWscvrgNYh9Dx24dArKPW2R7bAaxD6GyPbQfWIXS2xbQD6xA6/wOxjlJnW/QTYB1CZ+sKEOsodLZGIRDrqHW2RLYB6xA6K0Cso9LZ4mgD1iF0NjtagXUInc0RrcA6hI5vOAKxjlrHN7wFWIfQ8Q1DINZR62xCINYhdDaFNgPrEDoSiHUInY17JRDrKHU2hjQB6xA6PitArKPQ8QlGINZR6/gENwLrEDobggwg1lHpSCDWIXQ27GkA1iF0/tjdAKxD6BhArKPWWR/oBNYhdAwg1lHrrA9wAusQOusC6oF1CJ11/vX/Afik/lkoo6XgAAAAAElFTkSuQmCC';
const _sunset =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAGAAAABgCAIAAABt+uBvAAAEEklEQVR42u3aV3cTVxDA8fl2IQECCYSeQkkIhA4ppNGTAIFAQi8PWLZsWe6WZcm9Y0gopiTU0JJQbEu28ftl5krL4cF3OFpZu1fKnPP/BL+HPXtnBsb6To/2ntKdHMF6TmDJnuPJbuxYgjqa6Do63HVEd3io85Dut0Gs41fsWcdBqv3AU+oX7Enbft2+x1jrz9h/rXuplj3/Uruxf5p/0v34CGv6AXvYtEu380Ec24Hdj2+/H8O23aO2Yn83btF9fxeLfofdiX6r++Z2A/Y1dovafCuy+WbkK92XN7D6L7C/6j/XbfqzDtuIXac2XK/dcK12vW7dVaxmLXalZg0GosPoXKlZDaLD6AxoINEx6gxUrwbRYXQGqleB6DA6l1NAomPSuVz9GYgOo6OBRMesc6lqJYgOo0NAosPoXKpaAaLD6FwkINEx6xCQ6DA6F6s+BdFhdC5UEpDoGHUuVC4H0WF0XgKJzsQ6f1R+AqLD6BBQXuio8UbqedSpgRqL6OqxHOn8XvEx2KyjxmO61+iosTo1itVik6uTBioYHTVag02iDgFZqKPG46511AhWjU2KzvmKZVCQOmqkCsteRwMVqI5KVmJZ6pyvWAoFrKOSFVg2OufCBJT3X2VGRyXD2eicCy+BwtahEmHXOgRU8DoqUY650+l3gHz+V861jkqE3On0hxdDXrwkstRxgDLWIaD/g44aLsNc6Jwt/wh8f6N7o6OGS13opIH8nWB4o5MCylTnbPmH4Pt8xxsdzIVOXxrI1+mXNzpqOOhCRwP5PRv0RkcNBV3o9JV/AL5PTr3RUUMlLnR6QwTk81zZG50UUKY6vaH3wfepuzc6aqjYhQ4B+b6T8EbHAcpMp8cB8nNj442OBspYpye0CGzYZ1mrQ0A2bPtyraMGA+50ukMLwYZdaK51NJAbne4yDWTDpthOne6yBWDPHt1CnS4HyIorg1zoqMGibHRSQBbdYNim01U2H2y7ULFKp1MDWXe/Y49OZ+k8sPa6ya+v8qs6BGTz7ZfvOh0ElA+Xcbl7SfA6HaVzIR/vBt3NBl3oEJDoMDrtpXNAdBid9qAGEh2TDgGJDqPTFnwPRIfRSQGJjlGnLTgbRIfRaSUg0THrpIFEx6TTWjILRIfRaXGARGdinZaSd0F0GB0CEh1Gp1kDiY5Rp7nkHRAdRoeARIfRaSqeCaLD6Ggg0THrEJDoMDrx4hkgOoxOCkh0jDrx4rdBdBidGAGJjlknFtBAomPSiQWmg+gwOo0OkOhMrJMCEh2jTmNgGogOoxPVQKJj1IkGpoLoMDrRoqkgOoxOgwYSHaNOQ9FbIDqMDgGJDqMTcYBEZ2KdSNGbIDqMDgGJDqNTf2YKiA6jkwYSHZMOAYkOo1N35g0QHUYHewHfpI2vNJ5OFwAAAABJRU5ErkJggg==';
const _moss =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAGAAAABgCAIAAABt+uBvAAAEBElEQVR42u3a11IUURCA4X47FMWIiChiFsScFXNWcg4KKjlIWpKYc84ZAQVzAsMLjH161ipvTls7y84c1q76n+C7mJrT3VD6q+PIz3bsMPajrYQq/u7DirBhX+FwK1YwhLXkD7XkfcOac7GvzTmqpuwvqqwvjVmfGzOpjE8nsHTsY0MalfoBqz+Eva8/qKo78E61/13t/re1+6i9b2qwPdhgze7BamzXgGrnQNXO11U7qO2vKrFtWH/l1v4KbEufKqWvPKW3fLPdy+ObqI09qg09xza8OLaeWvf8KLYWe3Z0zbMy1dOy1dSqJ6XYSuxx6QrVkeWPVCA6jM4yG0h0dDrLHh4G0WF0CEh09DpLEUh0GJ2lDwhIdHQ6yQgkOoxO8oMSEB1GZ8n9EhAdRoeAREevk4RAosPoJN0jINHR6STdKwbRYXQSCUh0tDqJd4tBdBidxQgkOoyODSQ6Wp1Fd4pAdBgdAhoNOl3WANbp73UH1a561UaFSGfh7SIwWeekNYj9U8dHtVr92Mjq2EDho9NCjaCOAjJQp5tonOlgzVYfNiI6C24RUPjpNFHB6yy4VQjhqtNo9WJB6sxXQOGrc4IKRmf+zUIIg68yo9Ng9QajM88GCmOdBusl5lhHAYW9Tj3lTGfejQIw4V851Dp1CORIZy4CjYqXRJA6dVaPMx0C+g90aikHOnOuF4Dnb3R3dGqsHgc6fiBvJxju6NhAgeokXM8Hz+c77ujUWC8c6CRcU0AeT7/c0akmoEB1FJDns0F3dDAHOrMVkNeTU3d0qv4ABaQz+2o+eD5XdkfHBgpUJ56APJ66u6NTaT13oBN/NQ8830m4o0NAAevEXyEgbzc27uhgDnRmIZAJ+yxjdQjIgG1fqHUqEMiRzszLeWDCLjTUOpgzHT+QCZtiM3XiLueCOXt0A3XiLhGQIVcGodApt4Gc6iggo24wTNOZoYAMu1AxSmfGxVww8H7HHJ3Yizlg7HWTV1/lv3UUkMm3X57rxF4gIPMv40L3kuB1piPQaLwbdDYbdKBDQKKj14k5nwOiw+jEnM8G0WF0FJDoMDrTzhGQ6Oh0FJDoMDrRCkh09DrRZ7NBdBid6LNZIDqMzlQEEh1GZ+oZAhIdnc4UBBIdRoeAREevM+V0FogOozPZDyQ6Gp3JpzNBdBidSacyQXQYHT+Q6Oh0FJDoMDoTuwlIdHQ6Ckh0GJ0J3RkgOozOhJMZIDqMjh9IdHQ6UQgkOoxOVBcBiY5ORwGJDqMzXgGJjl5nfGc6iA6jM84PJDoaHQISHb3OuI50EB1GJ9IGEh2djgISHUYnsj0NRIfRGYtAosPoEJDo6HXGtKWB6DA6NpDoaHUUkOgwOhE+AhIdnU6EL/U3TtnCtuJSuscAAAAASUVORK5CYII=';
const _dusk =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAGAAAABgCAIAAABt+uBvAAAEJElEQVR42u3aWVcUVxDA8fp2xjXuigoazSLuRqMmmsQlxhiXuMY1LzL7PsPAsCgICERNBE3cECXuS9gGlde26nbPOXnwXs/0MN2XSZ3z/wS/hz59qwo6fxvpPJulzmQ7zgx3nKbaTw1RJ7HBSydEvw5gbccH2o71U0f7W4/+23pEdPhVC3YIe9nyy8uL2MEX1IEXzQeeN+8X7XvWhP2MPW3a+/QC9tMTag/2+PyPot2PsMYfsIeNu0Q7/2nAdmB9Ddv76rHvH1DfYffrvhVt66W29ma23st8Y9aT+bqnFttyl9qM3anZJPrqNrXxdnrjrfQGs5vpL29WY+v/ptZhf6XWitbcwIB1FDqp1SYQ60h0UquvA+sodJIIxDoKneQqBGIduU5yVTewjkInubIbWEehkwNiHYlOYkUXsI5CxwRiHalOorILWEehk6i8Bqyj0BFArCPXSSwXQKwj04kv/xNYR6ET/wKBWEeukwNiHYlO/PM/gHUUOgQ0LnRGM8ZbrDZXjfEGS4uqqSLpxD+7CjrrjNYZ1Id03qSM11iSGludmAVUKjqvE9QY6ggg/XRG6w3bOiNYnBoTndinV6AkdUZiVOE6AqhEdbJRqkCd2DICKlmdbIQqRCe27DKUwFdZoZMNG4XoRJdehtLWwYbDhm0dAVTqOsMhyp5OdOnvoMO/crF1hoOGPZ3oJwg0Hl4SBepYQPnrEND/QWcoQNnQiS7pBNff6M7oDPkNGzoRC8jVCYYzOhZQnjqRxQjk9nzHGR0Cyl8nsrgDXJ9+OaMz5DNs6Aggt2eDzugMIlD+OpEKAnJ5cuqMzqDXsKETqWgH1+fKzuhYQHnqhMvbwfWpuzM6gx7Dho4Acnsn4YyOBZSnTrj8Eri+sXFGh4Dy1wkvQiAN9lna6phA7m/7iq0zUGXY0wkvbAMddqHF1sHs6YQsIA02xXrqhBYgkDZ7dA11QgtaQZ8rg2LoDJwzCtEhIK1uMHTTCZURkF4XKlrphMpaQMP7HX10QvNNIC2vm9z6Kv9XJ0hAGt9+ua4TnH8RxsVlXPFeEmqd4DwEGod3g/ZmgzZ0TCDWkeoE5zYD6yh0CIh1FDoBAmIduU5gThOwjkJHALGOXCcwm4BYR6oTmH0BWEehkwNiHYlOYBYCsY5cxz/rPLCOQsc/E4FYR65DQKyj0PHPbATWUej4Z1hArPN+HROIdaQ6/ukNwDoKHR8CsY5CRwCxjlzH93E9sI5CRwCxjlzHN42AWEeq45tWB6yj0MkBsY5ExzsVgVhHruOdmgHWUegIINaR63inZIB1FDreKbXAOgod72QLiHXer2MCsY5UxzO5BlhHoeOZVAOso9ARQKwj1/FMSgPrKHQ8ExGIdeQ6JhDrSHU8H1UD6yh0qiwg1pHoCCDWketUTUgB6yh0sHdnTdXw1psyNAAAAABJRU5ErkJggg==';

/// 2 × 2: many of these still fit a tool card's 8 KiB.
const _dot =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGOI6tkCRAwQCgArfgZpaDia1QAAAABJRU5ErkJggg==';

/// A small album panel: a ring of the quota, a figure with its week, the
/// pictures, and an empty state.
Map<String, Object?> _album({bool empty = false}) => {
  'v': 2,
  'type': 'stack',
  'children': [
    {
      'type': 'row',
      'children': [
        {'type': 'progress', 'shape': 'ring', 'value': 72, 'label': '本月额度'},
        {
          'type': 'metric',
          'label': '今日',
          'value': '¥3.1',
          'tone': 'good',
          'trend': [1.2, 2.0, 1.4, null, 2.6, 3.1],
        },
      ],
    },
    if (empty)
      {
        'type': 'emptyState',
        'icon': 'gallery',
        'title': '还没有贴纸',
        'message': '从相册导入，或让 AI 画一张',
        'action': {'label': '导入', 'action': 'import'},
      }
    else
      {
        'type': 'gallery',
        'items': [
          {'src': _sea, 'alt': '海', 'caption': '海边'},
          {'src': _sunset, 'alt': '日落', 'caption': '日落', 'action': 'pick'},
          {'src': _moss, 'alt': '苔'},
          {'src': _dusk, 'alt': '黄昏', 'caption': '黄昏'},
          {'src': 'https://example.com/x.png', 'alt': '外链'},
        ],
      },
  ],
};

DshUiView _parse(Object view, {PluginViewBudget budget = PluginViewBudget.panel}) =>
    (parsePluginView(view, budget: budget) as DshUiParsed).view;

Future<void> _pump(
  WidgetTester tester,
  Object view, {
  double width = 390,
  double scale = 1,
  PluginActionHandler? onAction,
  Brightness brightness = Brightness.light,
  double height = 900,
}) async {
  usePhoneView(tester);
  tester.view.physicalSize = Size(width * 2, height * 2);
  final body = PluginFrame(
    pluginName: '相册',
    icon: 'gallery',
    child: PluginView(view: view, onAction: onAction),
  );
  await tester.pumpWidget(
    testApp(
      MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: ListView(padding: const EdgeInsets.fromLTRB(16, 56, 16, 24), children: [body]),
        ),
      ),
      brightness: brightness,
    ),
  );
  await pumpFrames(tester);
}

/// Decodes the pictures on screen, so a golden shows them.
Future<void> _settle(WidgetTester tester) async {
  for (final element in find.byType(Image).evaluate().toList()) {
    final image = element.widget as Image;
    await tester.runAsync(() => precacheImage(image.image, element));
  }
  await pumpFrames(tester);
}

void main() {
  group('parsing', () {
    test('the four take their shape; nothing new reaches a v1 view', () {
      final view = _parse(_album());
      final ring = view.nodes.whereType<DshUiProgress>().single;
      expect(ring.ring, isTrue);
      final metric = view.nodes.whereType<DshUiMetric>().single;
      expect(metric.trend, [1.2, 2.0, 1.4, null, 2.6, 3.1]);
      final gallery = view.nodes.whereType<DshUiGallery>().single;
      expect(gallery.items, hasLength(5));
      expect(gallery.items[1].action?.id, 'pick');
      expect(gallery.items[4].image.source, isNull, reason: 'a web address is no source: a quiet placeholder cell');
      expect(view.issues.map((i) => i.path), contains('view.children[1].items[4].src'));

      final v1 = _parse({..._album(), 'v': 1});
      expect(v1.nodes.whereType<DshUiProgress>().single.ring, isFalse);
      expect(v1.nodes.whereType<DshUiMetric>().single.trend, isNull);
      expect(v1.nodes.whereType<DshUiGallery>(), isEmpty, reason: 'v2 only: a v1 view draws a placeholder');
    });

    test('emptyState: title required; one button made of label + action', () {
      final view = _parse(_album(empty: true));
      final empty = view.nodes.whereType<DshUiEmptyState>().single;
      expect(empty.title, '还没有贴纸');
      expect(empty.icon, 'gallery');
      expect(empty.actions!.items.single.label, '导入');
      expect(empty.actions!.items.single.action.id, 'import');
      final broken = _parse({
        'v': 2,
        'type': 'stack',
        'children': [
          {'type': 'emptyState', 'message': '没有标题'},
          {'type': 'text', 'text': 'x'},
        ],
      });
      expect(broken.nodes.whereType<DshUiPlaceholder>(), hasLength(1));
    });

    test('limits: 24 pictures in a panel, 8 in a tool card; columns 2–4; aspect 0.5–2; trend 2–30', () {
      Map<String, Object?> many(int n, {Object? columns, Object? aspect}) => {
        'v': 2,
        'type': 'gallery',
        'columns': ?columns,
        'aspect': ?aspect,
        'items': [
          for (var i = 0; i < n; i++) {'src': _dot},
        ],
      };
      expect((_parse(many(30)).root as DshUiGallery).items, hasLength(24));
      expect((_parse(many(30), budget: PluginViewBudget.toolCard).root as DshUiGallery).items, hasLength(8));
      final odd = _parse(many(3, columns: 7, aspect: 9));
      expect((odd.root as DshUiGallery).columns, isNull);
      expect((odd.root as DshUiGallery).aspect, 1);
      expect(odd.issues.map((i) => i.path), containsAll(['view.columns', 'view.aspect']));
      final tooLong = _parse({
        'v': 2,
        'type': 'metric',
        'label': 'a',
        'value': '1',
        'trend': [for (var i = 0; i < 31; i++) i],
      });
      expect((tooLong.root as DshUiMetric).trend, isNull);
      expect(tooLong.issues.map((i) => i.path), contains('view.trend'));
    });

    test('the gallery count is in a column count, not a guess: width decides when none is asked', () {
      expect(dshUiGalleryColumns(326, null), 3);
      expect(dshUiGalleryColumns(300, null), 2);
      expect(dshUiGalleryColumns(326, 4), 4);
      expect(dshUiGalleryColumns(300, 4), 3, reason: 'four would be under 72 each');
      expect(dshUiGalleryColumns(140, null), 1);
    });
  });

  group('geometry', () {
    setUpAll(loadTestFonts);

    testWidgets('gallery: equal cells, 8 apart both ways, flush with the content edges, rows as tall as each other', (
      tester,
    ) async {
      for (final (width, columns) in [(390.0, 2), (520.0, 3)]) {
        await _pump(tester, _album(), width: width);
        final block = tester.getRect(find.byKey(const ValueKey('dsh-ui-gallery')));
        expect(dshUiGalleryColumns(block.width, null), columns, reason: 'at $width');
        final rects = [for (var i = 0; i < 5; i++) tester.getRect(find.byKey(ValueKey('dsh-ui-gallery-cell-$i')))];
        for (final r in rects) {
          expect(r.width, moreOrLessEquals(rects.first.width, epsilon: 0.5));
        }
        // Flush with both content edges: equal room left and right of the set.
        expect(rects[0].left, moreOrLessEquals(block.left, epsilon: 0.5));
        expect(rects[columns - 1].right, moreOrLessEquals(block.right, epsilon: 0.5));
        for (var c = 1; c < columns; c++) {
          expect(rects[c].left - rects[c - 1].right, moreOrLessEquals(DshUiGalleryMetrics.gap, epsilon: 0.5));
        }
        // The row's height is its tallest cell's: the caption room is kept in
        // every cell of a row with any caption (海 and 日落 have one, 苔 not).
        expect(rects[columns].top - rects[0].bottom, moreOrLessEquals(DshUiGalleryMetrics.gap, epsilon: 0.5));
        for (var start = 0; start + columns <= rects.length; start += columns) {
          for (var c = 1; c < columns; c++) {
            expect(rects[start + c].height, moreOrLessEquals(rects[start].height, epsilon: 0.5));
          }
        }
        expect(
          rects[columns].left,
          moreOrLessEquals(rects[0].left, epsilon: 0.5),
          reason: 'the next row keeps the columns',
        );
        expect(rects[4].width, moreOrLessEquals(rects[0].width, epsilon: 0.5), reason: 'the last row is not stretched');
      }
    });

    testWidgets('emptyState: badge, title, line and button share one centre; equal room either side', (tester) async {
      await _pump(tester, _album(empty: true), onAction: (_) async => true);
      final box = tester.getRect(find.byKey(const ValueKey('dsh-ui-empty-state')));
      final badge = tester.getRect(find.byKey(const ValueKey('dsh-ui-empty-badge')));
      final title = tester.getRect(find.text('还没有贴纸'));
      final line = tester.getRect(find.text('从相册导入，或让 AI 画一张'));
      final button = tester.getRect(find.byKey(const ValueKey('dsh-ui-empty-button')));
      for (final r in [badge, title, line]) {
        expect(r.center.dx, moreOrLessEquals(box.center.dx, epsilon: 0.5));
      }
      expect(button.center.dx, moreOrLessEquals(box.center.dx, epsilon: 0.5));
      expect(badge.width, DshUiGalleryMetrics.emptyBadge);
      expect(button.height, greaterThanOrEqualTo(48));
      expect(button.width, lessThan(box.width), reason: 'as wide as its words, like EmptyView');
      expect(button.width, greaterThanOrEqualTo(DshUiGalleryMetrics.emptyButtonMinWidth));
      expect(title.top - badge.bottom, moreOrLessEquals(DshUiGalleryMetrics.emptyGap, epsilon: 0.5));
      expect(button.top - line.bottom, moreOrLessEquals(DshUiGalleryMetrics.emptyGap, epsilon: 0.5));
    });

    testWidgets('emptyState: its button invokes the action at the emptyState\'s own path', (tester) async {
      final actions = <PluginAction>[];
      await _pump(
        tester,
        _album(empty: true),
        onAction: (a) async {
          actions.add(a);
          return true;
        },
      );
      await tester.tap(find.text('导入'));
      await pumpFrames(tester);
      expect(actions.single.id, 'import');
      expect(actions.single.path, 'view.children[1].action');
    });

    testWidgets('ring: the figure sits in the ring\'s centre; a trend runs the metric\'s width, 24 high', (
      tester,
    ) async {
      await _pump(tester, _album());
      final ring = tester.getRect(find.byKey(const ValueKey('dsh-ui-ring')));
      expect(ring.width, DshUiFigureMetrics.ringSize);
      final figure = tester.getRect(find.text('72%'));
      expect(figure.center.dx, moreOrLessEquals(ring.center.dx, epsilon: 0.5));
      expect(figure.center.dy, moreOrLessEquals(ring.center.dy, epsilon: 1));
      final trend = tester.getRect(find.byKey(const ValueKey('dsh-ui-trend')));
      expect(trend.height, DshUiFigureMetrics.trendHeight);
      final label = tester.getRect(find.text('今日'));
      expect(trend.left, moreOrLessEquals(label.left, epsilon: 0.5));
    });

    testWidgets('320 wide at 2× text: no overflow, the ring and the figure stack', (tester) async {
      await _pump(tester, _album(), width: 320, scale: 2, height: 1600);
      expect(tester.takeException(), isNull);
      final ring = tester.getRect(find.byKey(const ValueKey('dsh-ui-ring')));
      expect(tester.getRect(find.text('今日')).top, greaterThan(ring.bottom));
      // The figure shrinks to the ring's hole rather than over its stroke.
      final figure = tester.getRect(find.text('72%'));
      final hole = ring.deflate(DshUiFigureMetrics.ringStroke);
      expect(figure.left, greaterThanOrEqualTo(hole.left));
      expect(figure.right, lessThanOrEqualTo(hole.right));
    });
  });

  group('taps', () {
    setUpAll(loadTestFonts);

    testWidgets('a cell with an action invokes it; another opens the viewer on the set (web cells left out)', (
      tester,
    ) async {
      final actions = <PluginAction>[];
      await _pump(
        tester,
        _album(),
        onAction: (a) async {
          actions.add(a);
          return true;
        },
      );
      await tester.tap(find.bySemanticsLabel('日落'));
      await pumpFrames(tester);
      expect(actions.single.id, 'pick');
      expect(actions.single.path, 'view.children[1].items[1]');
      expect(find.byType(MediaViewerPage), findsNothing);
      await tester.tap(find.bySemanticsLabel('黄昏'));
      await pumpFrames(tester);
      final page = tester.widget<MediaViewerPage>(find.byType(MediaViewerPage));
      expect(page.pictures!.map((p) => p.name), ['海', '日落', '苔', '黄昏']);
      expect(page.initial, 3);
      expect(page.source, '相册');
      expect(find.text('4 / 4'), findsOneWidget);
      expect(
        await page.pictures!.first.bytes!(),
        (_parse(_album()).nodes.whereType<DshUiGallery>().single.items.first.image.source! as DshUiDataImage).bytes,
      );
    });

    testWidgets('read-only (a tool card): no button on the empty state; a cell with an action opens the viewer', (
      tester,
    ) async {
      await _pump(tester, _album(empty: true));
      expect(find.text('导入'), findsNothing);
      expect(find.byKey(const ValueKey('dsh-ui-empty-badge')), findsOneWidget);
      await _pump(tester, _album());
      await tester.tap(find.bySemanticsLabel('日落'));
      await pumpFrames(tester);
      expect(find.text('2 / 4'), findsOneWidget);
    });

    testWidgets('a long press opens the viewer even on a cell with an action', (tester) async {
      final actions = <PluginAction>[];
      await _pump(
        tester,
        _album(),
        onAction: (a) async {
          actions.add(a);
          return true;
        },
      );
      await tester.longPress(find.bySemanticsLabel('日落'));
      await pumpFrames(tester);
      expect(actions, isEmpty);
      expect(find.text('2 / 4'), findsOneWidget);
    });

    testWidgets('the viewer shows a plugin\'s pictures with its name, no capsule', (tester) async {
      final view = _parse(_album());
      final gallery = view.nodes.whereType<DshUiGallery>().single;
      final first = gallery.items.first.image.source! as DshUiDataImage;
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          MediaViewerPage.pictures(
            pictures: [ViewerPicture(image: MemoryImage(first.bytes), name: '海', bytes: () async => first.bytes)],
            source: '相册',
          ),
        ),
      );
      await pumpFrames(tester);
      expect(find.text('海'), findsOneWidget, reason: 'one picture: its name is the title');
      expect(find.text('相册'), findsOneWidget);
      expect(find.byType(GallerySaveButton), findsOneWidget);

      await tester.pumpWidget(
        testApp(
          MediaViewerPage.pictures(
            pictures: [ViewerPicture(image: MemoryImage(first.bytes), name: '海')],
          ),
        ),
      );
      await pumpFrames(tester);
      expect(find.byType(GallerySaveButton), findsNothing, reason: 'no bytes at hand: no 保存, no 分享');

      // A plugin's own (asset) picture is saved as the PNG of what it draws.
      final png = (await tester.runAsync(() => dshUiImageBytes(MemoryImage(first.bytes))))!;
      expect(png.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    });
  });

  group('golden', () {
    setUpAll(loadTestFonts);
    for (final brightness in Brightness.values) {
      testWidgets('figures ${brightness.name}', (tester) async {
        await _pump(tester, _album(), brightness: brightness, onAction: (_) async => true, height: 760);
        await _settle(tester);
        await expectLater(
          find.byType(Scaffold),
          matchesGoldenFile('goldens/plugin_view_figures_${brightness.name}.png'),
        );
      });
      testWidgets('empty ${brightness.name}', (tester) async {
        await _pump(tester, _album(empty: true), brightness: brightness, onAction: (_) async => true, height: 640);
        await expectLater(find.byType(Scaffold), matchesGoldenFile('goldens/plugin_view_empty_${brightness.name}.png'));
      });
    }
    testWidgets('figures 320 at 2× text', (tester) async {
      await _pump(tester, _album(), width: 320, scale: 2, onAction: (_) async => true, height: 1500);
      await _settle(tester);
      await expectLater(find.byType(Scaffold), matchesGoldenFile('goldens/plugin_view_figures_narrow_large.png'));
    });
  });
}
