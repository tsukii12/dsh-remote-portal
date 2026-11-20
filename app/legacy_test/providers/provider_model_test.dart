// 模型设置: one custom-provider model's name, context length, max output,
// input type and thinking efforts. Prefilled from the entry with the route's
// defaults behind empty fields; writes only the engine's own fields and keeps
// everything else of the entry; reached from the edit form (saved with it)
// and from the detail page (saved on the spot); the model catalog is re-read
// after a save. Geometry: quick picks and efforts line up with their field
// and switch. Goldens: light, dark, and English.
//
//   flutter test --update-goldens test/providers/provider_model_test.dart

import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/providers_state.dart';
import 'package:dsh_app/ui/common/segmented_pill.dart';
import 'package:dsh_app/ui/providers/provider_detail_page.dart';
import 'package:dsh_app/ui/providers/provider_form_page.dart';
import 'package:dsh_app/ui/providers/provider_model_page.dart';
import 'package:dsh_app/ui/providers/provider_widgets.dart' show FormFieldBlock, FormFieldLabel, SelectionTick;
import 'package:dsh_app/ui/settings/settings_widgets.dart' show SettingsMetrics;
import 'package:dsh_app/ui/theme/glass.dart' show GlassSurface;
import 'package:dsh_client/dsh_client.dart' show DshRemoteException, ModelCatalog, ProviderSettings;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart' show goldenApp, loadGoldenFonts;
import '../support/english_preview.dart';
import 'support.dart';

const _qwen = ProviderModelSpec(
  id: 'qwen3-coder',
  name: 'Qwen3 Coder',
  contextWindow: 262144,
  maxTokens: 65536,
  extra: {
    'reasoningEfforts': {'off': null, 'high': 'high'},
  },
);

/// What a 0.2.1 Host reads back for an entry that set nothing.
const _bare = ProviderModelSpec(
  id: 'kimi-k2-0905',
  input: [],
  extra: {
    'compat': {'chatTemplateKwargs': <String, Object?>{}, 'chatTemplateArgs': <String, Object?>{}},
  },
);

/// Opens the model page from a plain page so the pop result can be read.
class _Opener extends StatefulWidget {
  const _Opener({required this.model, required this.defaults});

  final ProviderModelSpec model;
  final ModelDefaults defaults;

  @override
  State<_Opener> createState() => _OpenerState();
}

class _OpenerState extends State<_Opener> {
  bool returned = false;
  ProviderModelSpec? result;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        onPressed: () async {
          final r = await Navigator.of(context).push(
            MaterialPageRoute<ProviderModelSpec>(
              builder: (_) => ProviderModelPage(model: widget.model, defaults: widget.defaults),
            ),
          );
          setState(() {
            returned = true;
            result = r;
          });
        },
        child: const Text('open'),
      ),
    ),
  );
}

Future<void> _surface(WidgetTester tester, {double height = 1500}) async {
  await tester.runAsync(loadGoldenFonts);
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = Size(390 * 2, height * 2);
  tester.view.padding = const FakeViewPadding(top: 64, bottom: 48);
  tester.view.viewPadding = const FakeViewPadding(top: 64, bottom: 48);
  addTearDown(tester.view.reset);
}

/// Pushes the page for [model]; returns the opener's state for the result.
Future<_OpenerState> _open(
  WidgetTester tester,
  ProviderModelSpec model, {
  ModelDefaults defaults = const ModelDefaults(),
}) async {
  await _surface(tester);
  await tester.pumpWidget(
    goldenApp(
      home: _Opener(model: model, defaults: defaults),
      brightness: Brightness.light,
      overrides: providerOverrides(FakeProviderBackend()),
    ),
  );
  await tester.tap(find.text('open'));
  await settle(tester);
  return tester.state<_OpenerState>(find.byType(_Opener, skipOffstage: false));
}

Finder _block(String label) => find.ancestor(of: find.text(label), matching: find.byType(FormFieldBlock));

Finder _field(String label) => find.descendant(of: _block(label), matching: find.byType(TextField));

Finder _pick(String label, String preset) =>
    find.descendant(of: _block(label), matching: find.widgetWithText(ChoiceCapsule, preset));

Finder _level(String label) => find.widgetWithText(LevelRow, label);

bool _chosen(WidgetTester tester, Finder chip) => tester.widget<ChoiceCapsule>(chip).selected;

/// The levels ticked, in the page's order.
List<String> _ticked(WidgetTester tester) => [
  for (final row in tester.widgetList<LevelRow>(find.byType(LevelRow, skipOffstage: false)))
    if (row.checked) row.label,
];

String _text(WidgetTester tester, Finder field) => tester.widget<TextField>(field).controller!.text;

String? _hint(WidgetTester tester, Finder field) => tester.widget<TextField>(field).decoration!.hintText;

bool _switchOn(WidgetTester tester) => tester.widget<Switch>(find.byType(Switch)).value;

Future<void> _toggleThinking(WidgetTester tester) => _tap(tester, find.byType(Switch));

bool _imagesChosen(WidgetTester tester) =>
    tester.widget<SegmentedPill<bool>>(find.byType(SegmentedPill<bool>)).selected;

Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.tap(target);
  await settle(tester);
}

void main() {
  group('token counts', () {
    test('typed as plain numbers or with K / M (decimal, as capacities are quoted)', () {
      final cases = {
        '131072': 131072,
        '128K': 128000,
        '128k': 128000,
        '1M': 1000000,
        '1.5M': 1500000,
        '0.5K': 500,
        ' 200 000 ': 200000,
        '1,048,576': 1048576,
      };
      for (final MapEntry(:key, :value) in cases.entries) {
        expect(parseTokenCount(key), value, reason: key);
        expect(tokenCountError(key), isNull, reason: key);
      }
      for (final bad in ['', 'K', '0', '1.5', '12k3', '-5', '1e6']) {
        expect(parseTokenCount(bad), isNull, reason: bad);
      }
      expect(tokenCountError(''), isNull, reason: 'empty means the default');
      expect(tokenCountError('12k3'), '填写数字，如 128K');
    });

    test('quick picks read as the sizes models are sold in', () {
      expect(contextPresets.map(formatTokens), ['32K', '64K', '128K', '200K', '256K', '1M']);
      expect(maxOutputPresets.map(formatTokens), ['8K', '16K', '32K', '64K', '128K']);
    });
  });

  group('page', () {
    testWidgets('prefilled from the entry: name, counts, input type, efforts', (tester) async {
      await _open(tester, _qwen);
      expect(find.text('Qwen3 Coder'), findsWidgets);
      expect(find.text('qwen3-coder'), findsWidgets, reason: 'the id under the title, the name field\'s hint');
      expect(_text(tester, _field('名称')), 'Qwen3 Coder');
      expect(_text(tester, _field('上下文长度')), '256K');
      expect(_text(tester, _field('最大输出')), '64K');
      expect(_chosen(tester, _pick('上下文长度', '256K')), isTrue);
      expect(_chosen(tester, _pick('上下文长度', '128K')), isFalse);
      expect(_chosen(tester, _pick('最大输出', '64K')), isTrue);
      expect(_imagesChosen(tester), isFalse);
      expect(_switchOn(tester), isTrue);
      expect(_ticked(tester), ['高'], reason: '不思考 is not a level to tick');
      expect(find.text('不思考'), findsNothing);
    });

    testWidgets('an entry that sets nothing shows the route defaults', (tester) async {
      await _open(
        tester,
        _bare,
        defaults: const ModelDefaults(contextWindow: 131072, maxTokens: 8192, input: ['text', 'image']),
      );
      expect(_text(tester, _field('名称')), '');
      expect(_hint(tester, _field('名称')), 'kimi-k2-0905');
      expect(_text(tester, _field('上下文长度')), '');
      expect(_hint(tester, _field('上下文长度')), '默认 128K');
      expect(_hint(tester, _field('最大输出')), '默认 8K');
      expect(_chosen(tester, _pick('上下文长度', '128K')), isFalse, reason: 'a default is not a choice');
      expect(_imagesChosen(tester), isTrue, reason: 'the route takes images');
      expect(_switchOn(tester), isFalse);
      expect(_level('高').hitTestable(), findsNothing, reason: 'levels fold away while thinking is off');
    });

    testWidgets('完成 with nothing changed hands back the same entry', (tester) async {
      const custom = ProviderModelSpec(
        id: 'gpt-5.2',
        contextWindow: 400000,
        input: [],
        extra: {
          'reasoningEfforts': {'off': 'none', 'medium': 'medium', 'max': 'xhigh'},
          'compat': {'supportsDeveloperRole': false},
        },
      );
      final opener = await _open(tester, custom);
      expect(_text(tester, _field('上下文长度')), '400K');
      await _tap(tester, find.text('完成'));
      expect(opener.returned, isTrue);
      expect(opener.result!.toJson(), custom.toJson());
    });

    testWidgets('edits write the engine\'s fields, the rest of the entry stays', (tester) async {
      final opener = await _open(tester, _qwen);
      await tester.enterText(_field('名称'), '  Qwen Coder  ');
      await _tap(tester, _pick('上下文长度', '128K'));
      expect(_text(tester, _field('上下文长度')), '128K');
      await tester.enterText(_field('最大输出'), '16000');
      await tester.pump();
      expect(_chosen(tester, _pick('最大输出', '64K')), isFalse);
      await _tap(tester, find.text('文本和图片'));
      await _tap(tester, _level('中'));
      await _tap(tester, find.text('完成'));
      expect(opener.result!.toJson(), {
        'reasoningEfforts': {'off': null, 'medium': 'medium', 'high': 'high'},
        'id': 'qwen3-coder',
        'name': 'Qwen Coder',
        'contextWindow': 131072,
        'maxTokens': 16000,
        'input': ['text', 'image'],
      });
    });

    testWidgets('picking the chosen quick pick again empties the field', (tester) async {
      final opener = await _open(tester, _qwen);
      await _tap(tester, _pick('上下文长度', '256K'));
      expect(_text(tester, _field('上下文长度')), '');
      expect(_chosen(tester, _pick('上下文长度', '256K')), isFalse);
      await _tap(tester, find.text('完成'));
      expect(opener.result!.contextWindow, isNull);
      expect(opener.result!.maxTokens, 65536);
    });

    testWidgets('thinking on ticks 低·中·高 and offers 不思考 too; it needs one level', (tester) async {
      final opener = await _open(tester, _bare);
      await _toggleThinking(tester);
      expect(_switchOn(tester), isTrue);
      expect(_ticked(tester), ['低', '中', '高']);
      for (final e in ['低', '中', '高']) {
        await _tap(tester, _level(e));
      }
      expect(_ticked(tester), isEmpty);
      await _tap(tester, find.text('完成'));
      expect(find.text('至少选一个档位'), findsOneWidget);
      expect(opener.returned, isFalse);

      await _tap(tester, _level('超高'));
      expect(find.text('至少选一个档位'), findsNothing, reason: 'a choice clears the error');
      await _tap(tester, find.text('完成'));
      expect(opener.result!.toJson(), {
        'compat': {'chatTemplateKwargs': <String, Object?>{}, 'chatTemplateArgs': <String, Object?>{}},
        'reasoningEfforts': {'off': null, 'xhigh': 'xhigh'},
        'id': 'kimi-k2-0905',
        'input': <String>[],
      });
    });

    testWidgets('a model declared without 不思考 (always thinks) keeps it that way', (tester) async {
      const always = ProviderModelSpec(
        id: 'deepseek-reasoner',
        extra: {
          'reasoningEfforts': {'high': 'high', 'max': 'max'},
        },
      );
      final opener = await _open(tester, always);
      expect(_ticked(tester), ['高', '最高']);
      await _tap(tester, _level('中'));
      await _tap(tester, find.text('完成'));
      expect(opener.result!.reasoningEfforts, {'medium': 'medium', 'high': 'high', 'max': 'max'});
    });

    testWidgets('thinking off drops the levels; on again brings the last ones back', (tester) async {
      final opener = await _open(tester, _qwen);
      await _toggleThinking(tester);
      expect(_switchOn(tester), isFalse);
      await _toggleThinking(tester);
      expect(_ticked(tester), ['高']);
      await _toggleThinking(tester);
      await _tap(tester, find.text('完成'));
      expect(opener.result!.toJson().containsKey('reasoningEfforts'), isFalse);
      expect(opener.result!.thinks, isFalse);
    });

    testWidgets('a count that is not one stays on the page, marked', (tester) async {
      final opener = await _open(tester, _qwen);
      await tester.enterText(_field('上下文长度'), '12k3');
      await tester.pump();
      await _tap(tester, find.text('完成'));
      expect(find.text('填写数字，如 128K'), findsOneWidget);
      expect(opener.returned, isFalse);
      await tester.enterText(_field('上下文长度'), '1.5M');
      await tester.pump();
      expect(find.text('填写数字，如 128K'), findsNothing);
      await _tap(tester, find.text('完成'));
      expect(opener.result!.contextWindow, 1500000);
    });

    testWidgets('leaving with edits asks first', (tester) async {
      final opener = await _open(tester, _qwen);
      await _tap(tester, find.text('文本和图片'));
      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(find.text('放弃修改？'), findsOneWidget);
      await _tap(tester, find.text('放弃'));
      expect(opener.returned, isTrue);
      expect(opener.result, isNull);
    });

    testWidgets('geometry: one label style on one edge; equal card insets; picks span the field', (tester) async {
      await _open(tester, _qwen);
      Rect card(Finder inside) => tester.getRect(find.ancestor(of: inside, matching: find.byType(GlassSurface)).first);

      // Every label of the page: same style, same distance from its card.
      const labels = ['名称', '上下文长度', '最大输出', '输入类型', '思考', '可选档位'];
      final style = tester.widget<Text>(find.text('名称')).style;
      for (final label in labels) {
        final text = find.text(label);
        expect(tester.widget<Text>(text).style, style, reason: label);
        expect(
          tester.getRect(text).left - card(text).left,
          SettingsMetrics.inset + FormFieldLabel.indent,
          reason: label,
        );
      }

      // Fields, capsules, quick picks and the level rows: 16 from both sides.
      final controls = [
        _field('名称'),
        _field('上下文长度'),
        _field('最大输出'),
        find.byType(SegmentedPill<bool>),
        for (final row in ['低', '最高']) _level(row),
      ];
      for (final control in controls) {
        final rect = tester.getRect(control);
        final box = card(control);
        expect(rect.left - box.left, SettingsMetrics.inset, reason: '$control');
        expect(box.right - rect.right, moreOrLessEquals(SettingsMetrics.inset), reason: '$control');
      }
      final field = tester.getRect(_field('上下文长度'));
      expect(tester.getRect(_pick('上下文长度', '32K')).left, field.left);
      expect(tester.getRect(_pick('上下文长度', '1M')).right, moreOrLessEquals(field.right));
      expect(tester.getRect(_pick('最大输出', '8K')).left, tester.getRect(_field('最大输出')).left);
      expect(tester.getRect(_pick('最大输出', '128K')).right, moreOrLessEquals(tester.getRect(_field('最大输出')).right));
      final widths = {
        for (final p in ['32K', '200K', '1M']) tester.getSize(_pick('上下文长度', p)).width.toStringAsFixed(2),
      };
      expect(widths, hasLength(1));

      // The switch's track ends on the field edge; ticks sit on the labels' edge.
      final track = tester.getRect(find.byType(Switch)).right - FieldSwitch.trackInset;
      expect(track, moreOrLessEquals(tester.getRect(find.byType(SegmentedPill<bool>)).right));
      final labelLeft = tester.getRect(find.text('可选档位')).left;
      for (final tick in tester.widgetList<SelectionTick>(find.byType(SelectionTick))) {
        expect(tester.getRect(find.byWidget(tick)).left, labelLeft);
      }
      final heights = {
        for (final row in find.byType(LevelRow).evaluate()) tester.getSize(find.byWidget(row.widget)).height,
      };
      expect(heights, {LevelRow.height});
    });
  });

  group('edit form', () {
    testWidgets('a model row opens its settings; the change is saved with the form', (tester) async {
      final backend = sampleBackend();
      await _surface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: ProviderFormPage(existing: CustomProvider.fromProfile(gateway)),
          brightness: Brightness.light,
          overrides: providerOverrides(backend),
        ),
      );
      await settle(tester);
      await _tap(tester, find.text('glm-4.6'));
      expect(find.byType(ProviderModelPage), findsOneWidget);
      expect(find.text('完成'), findsOneWidget);
      await _tap(tester, find.text('文本和图片'));
      await _toggleThinking(tester);
      await _tap(tester, find.text('完成'));
      expect(find.byType(ProviderModelPage), findsNothing);
      expect(find.text('上下文 200K · 识图 · 思考'), findsOneWidget);
      expect(backend.callNames.where((c) => c != 'read'), isEmpty, reason: 'nothing written before 保存');

      await _tap(tester, find.text('保存'));
      final update = backend.calls.lastWhere((c) => c.$1 == 'update').$2;
      expect(update['models'], [
        gateway.models[0].toJson(),
        {
          'reasoningEfforts': {'off': null, 'low': 'low', 'medium': 'medium', 'high': 'high'},
          'id': 'glm-4.6',
          'contextWindow': 200000,
          'input': ['text', 'image'],
        },
        gateway.models[2].toJson(),
      ]);
    });
  });

  group('detail page', () {
    testWidgets('a model opens its settings; 保存 writes only the models list', (tester) async {
      final backend = sampleBackend();
      await _surface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: const ProviderDetailPage(providerId: 'custom-mygw'),
          brightness: Brightness.light,
          overrides: providerOverrides(backend),
        ),
      );
      await settle(tester);
      expect(find.text('qwen3-coder · 上下文 256K · 思考'), findsOneWidget);
      await _tap(tester, find.text('kimi-k2-0905'));
      expect(find.text('保存'), findsOneWidget);
      await _toggleThinking(tester);
      await _tap(tester, find.text('保存'));
      expect(find.byType(ProviderModelPage), findsNothing);
      final update = backend.calls.lastWhere((c) => c.$1 == 'update').$2;
      expect(update.keys.toSet(), {'id', 'models', 'expectedRevision'});
      expect(update['expectedRevision'], 3);
      expect((update['models']! as List).last, {
        'reasoningEfforts': {'off': null, 'low': 'low', 'medium': 'medium', 'high': 'high'},
        'id': 'kimi-k2-0905',
      });
      expect(find.text('思考'), findsOneWidget, reason: 'the row now says it thinks');
    });

    testWidgets('a save the engine refuses stays on the page and says why', (tester) async {
      final backend = _RefusingBackend();
      await _surface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: const ProviderDetailPage(providerId: 'custom-mygw'),
          brightness: Brightness.light,
          overrides: providerOverrides(backend),
        ),
      );
      await settle(tester);
      await _tap(tester, find.text('glm-4.6'));
      await _tap(tester, find.text('文本和图片'));
      await _tap(tester, find.text('保存'));
      expect(find.byType(ProviderModelPage), findsOneWidget);
      expect(find.textContaining('没能保存：'), findsOneWidget);
    });

    testWidgets('a route set up elsewhere: its models do not open', (tester) async {
      final backend = FakeProviderBackend(
        profiles: const [
          ProviderProfile(route: 'openai', apiKeyEnv: 'OPENAI_API_KEY', models: [_qwen]),
        ],
        credentials: const {'OPENAI_API_KEY': 'sk'},
      );
      await _surface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: const ProviderDetailPage(providerId: 'openai'),
          brightness: Brightness.light,
          overrides: providerOverrides(backend),
        ),
      );
      await settle(tester);
      await _tap(tester, find.text('Qwen3 Coder'));
      expect(find.byType(ProviderModelPage), findsNothing);
    });
  });

  test('saving a model re-reads the model catalog', () async {
    final backend = sampleBackend();
    var reads = 0;
    final container = ProviderContainer(
      overrides: [
        ...providerOverrides(backend),
        modelCatalogProvider.overrideWith((ref) async {
          reads++;
          return const ModelCatalog(defaultSelection: null, routableProviders: [], groups: [], failures: []);
        }),
      ],
    );
    addTearDown(container.dispose);
    container.listen(modelCatalogProvider, (_, _) {});
    container.listen(customProvidersProvider, (_, _) {});
    await container.read(modelCatalogProvider.future);
    final provider = (await container.read(customProvidersProvider.future))!.byId('custom-mygw')!;
    expect(reads, 1);
    await container
        .read(providerActionsProvider)
        .saveModel(provider, provider.models.last.withReasoningEfforts(['high']));
    await container.read(modelCatalogProvider.future);
    expect(reads, 2);
    expect(backend.profiles.first.models.last.thinkingLevels, ['high']);
  });

  group('golden', () {
    goldenTall(
      'provider_model',
      height: 1340,
      () => const ProviderModelPage(model: _qwen),
      overrides: () => providerOverrides(FakeProviderBackend()),
    );

    testWidgets('provider_model (en)', (tester) async {
      useEnglish();
      await tester.runAsync(loadGoldenFonts);
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(390 * 2, 1340 * 2);
      tester.view.padding = const FakeViewPadding(top: 32 * 2, bottom: 24 * 2);
      tester.view.viewPadding = const FakeViewPadding(top: 32 * 2, bottom: 24 * 2);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        goldenApp(
          home: inEnglish(const ProviderModelPage(model: _qwen)),
          brightness: Brightness.light,
          overrides: providerOverrides(FakeProviderBackend()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/en_provider_model_light.png'));
    });
  });
}

/// An engine whose settings refuse the write (someone else saved first).
class _RefusingBackend extends FakeProviderBackend {
  _RefusingBackend() : super(profiles: const [gateway], credentials: const {'CUSTOM_MYGW_API_KEY': 'sk-gw'});

  @override
  Future<ProviderSettings> update(
    String id, {
    String? displayName,
    ProviderApi? api,
    String? baseUrl,
    String? apiKeyEnv,
    List<ProviderModelSpec>? models,
    Map<String, String>? headers,
    int? expectedRevision,
  }) async => throw const DshRemoteException('settings/conflict', 'revision 3 is stale');
}
