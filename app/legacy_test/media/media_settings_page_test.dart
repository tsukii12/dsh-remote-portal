// The curated 「图像与视频」 page (media-generation §5.8) against the fake
// Host: the defaults from the catalogue, services added from provider presets
// (one credential per provider), the key written into the credential store,
// and deleting a service clearing the defaults that named it.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/state/media_generation.dart';
import 'package:dsh_app/ui/settings/media_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../engine_settings/support.dart';

final _zh = lookupL10n(AppLocale.zhCN);

/// One catalogue model, only the fields the settings page reads.
Map<String, Object?> _model(String id, String label, String kind, String profile) => {
  'id': id,
  'label': label,
  'kind': kind,
  'profile': profile,
};

Map<String, Object?> _preset({
  required String id,
  required String label,
  required String labelEn,
  required String provider,
  required String profile,
  required String baseUrl,
  String responseFormat = '',
  required String kind,
  required List<String> models,
  required String keyGroup,
}) => {
  'id': id,
  'label': label,
  'labelEn': labelEn,
  'provider': provider,
  'profile': profile,
  'baseUrl': baseUrl,
  'responseFormat': responseFormat,
  'models': models,
  'kind': kind,
  'keyGroup': keyGroup,
};

/// A 0.3.0-style catalogue: Ark (image + video), OpenAI and Gemini, with the
/// presets that name them. No presets (and no video) makes a 0.2.1 one; the
/// app's fallback list then keeps the page usable.
Map<String, Object?> _catalog({bool presets = true, bool video = true}) => {
  'v': 1,
  'contract': 'dsh-go/media/catalog',
  'capabilities': {'image': true, 'video': video},
  'models': [
    _model('doubao-seedream-5-0-pro', 'Seedream 5.0', 'image', 'ark-image'),
    if (video) _model('doubao-seedance-2-0', 'Seedance 2.0', 'video', 'ark-video'),
    _model('gpt-image-2', 'GPT Image 2', 'image', 'openai-gpt-image'),
    _model('gemini-2.5-flash-image', 'Gemini 2.5 Flash Image', 'image', 'openai-compatible'),
  ],
  if (presets)
    'presets': [
      _preset(
        id: 'ark-image',
        label: '火山方舟 · 图片',
        labelEn: 'Volcengine Ark · Image',
        provider: 'ark',
        profile: 'ark-image',
        baseUrl: 'https://ark.cn-beijing.volces.com',
        kind: 'image',
        models: const ['doubao-seedream-5-0-pro'],
        keyGroup: 'ark',
      ),
      if (video)
        _preset(
          id: 'ark-video',
          label: '火山方舟 · 视频',
          labelEn: 'Volcengine Ark · Video',
          provider: 'ark',
          profile: 'ark-video',
          baseUrl: 'https://ark.cn-beijing.volces.com',
          kind: 'video',
          models: const ['doubao-seedance-2-0'],
          keyGroup: 'ark',
        ),
      _preset(
        id: 'openai-image',
        label: 'OpenAI · 图片',
        labelEn: 'OpenAI · Image',
        provider: 'openai',
        profile: 'openai-gpt-image',
        baseUrl: 'https://api.openai.com/v1',
        kind: 'image',
        models: const ['gpt-image-2'],
        keyGroup: 'openai',
      ),
      _preset(
        id: 'gemini-image',
        label: 'Gemini · 图片',
        labelEn: 'Gemini · Image',
        provider: 'gemini',
        profile: 'openai-compatible',
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
        responseFormat: 'b64_json',
        kind: 'image',
        models: const ['gemini-2.5-flash-image'],
        keyGroup: 'gemini',
      ),
    ],
};

/// One row of the plugin's `value.services`.
Map<String, Object?> _service({
  String id = 'ark_image',
  String label = '火山方舟',
  bool enabled = true,
  String provider = 'ark',
  String baseUrl = 'https://ark.cn-beijing.volces.com',
  String profile = 'ark-image',
  String responseFormat = '',
  String models = 'doubao-seedream-5-0-pro',
  String keyRef = 'DSH_MEDIA_ARK_API_KEY',
}) => {
  'id': id,
  'label': label,
  'enabled': enabled,
  'provider': provider,
  'baseUrl': baseUrl,
  'profile': profile,
  'responseFormat': responseFormat,
  'models': models,
  'keyRef': keyRef,
};

Map<String, Object?> _string([String? defaultValue]) => {
  'type': 'string',
  'meta': {'default': ?defaultValue},
};

Map<String, Object?> _schema(Map<String, Object?>? catalog, {bool kindDefaults = true}) => {
  'type': 'object',
  'meta': {},
  'dict': {
    'services': {
      'type': 'transform',
      'meta': {
        'default': <Object?>[],
        if (catalog != null) 'extra': {'dsh-go/media/catalog': catalog},
      },
      'inner': {
        'type': 'array',
        'meta': {},
        'inner': {
          'type': 'object',
          'meta': {},
          'dict': {
            for (final key in ['id', 'label', 'provider', 'baseUrl', 'profile', 'responseFormat', 'models', 'keyRef'])
              key: _string(),
            'enabled': {'type': 'boolean', 'meta': {}},
          },
        },
      },
    },
    'defaults': {
      'type': 'object',
      'meta': {},
      'dict': {
        for (final key in ['serviceId', 'modelId']) key: _string(''),
        if (kindDefaults)
          for (final key in ['imageServiceId', 'imageModelId', 'videoServiceId', 'videoModelId']) key: _string(''),
      },
    },
    'budget': {
      'type': 'object',
      'meta': {},
      'dict': {'dailyCny': _string('20'), 'unknownPriceHoldCny': _string('20')},
    },
    'limits': {
      'type': 'object',
      'meta': {},
      'dict': {
        for (final key in ['maxImages', 'maxImageBytes', 'maxResponseBytes', 'maxTotalImageBytes', 'maxVideoBytes'])
          key: {
            'type': 'number',
            'meta': {'step': 1, 'min': 1, 'max': 400000000, 'default': 67108864},
          },
      },
    },
  },
};

/// `settings/describe` with the media plugin's one namespace.
Map<String, Object?> _describe({
  required List<Map<String, Object?>> services,
  Map<String, Object?> defaults = const {},
  Map<String, Object?>? catalog,
  String ns = 'dsh-media',
  bool kindDefaults = true,
}) {
  final baseDefaults = <String, Object?>{
    'serviceId': '',
    'modelId': '',
    if (kindDefaults) ...{'imageServiceId': '', 'imageModelId': '', 'videoServiceId': '', 'videoModelId': ''},
  };
  final value = <String, Object?>{
    'services': services,
    'defaults': {...baseDefaults, ...defaults},
    'budget': {'dailyCny': '20', 'unknownPriceHoldCny': '20'},
    'limits': {
      'maxImages': 4,
      'maxImageBytes': 20971520,
      'maxResponseBytes': 33554432,
      'maxTotalImageBytes': 67108864,
      'maxVideoBytes': 300 * 1024 * 1024,
    },
  };
  return {
    'writable': true,
    'hasDocument': true,
    'namespaces': [
      {
        'ns': ns,
        'autoGenerate': true,
        'schema': _schema(catalog ?? _catalog(), kindDefaults: kindDefaults),
        'value': value,
        'base': value,
        'revision': 1,
      },
    ],
  };
}

void main() {
  late FakeSettingsHost host;

  Future<void> open(
    WidgetTester tester, {
    required Map<String, Object?> describe,
    Map<String, String> credentials = const {},
    Set<String> envCredentials = const {},
  }) async {
    host = FakeSettingsHost(describe: describe);
    host.credentials.addAll(credentials);
    host.envCredentials.addAll(envCredentials);
    await pumpPage(
      tester,
      const MediaSettingsPage(),
      overrides: [
        ...engineOverrides(await fakeClient(host)),
        mediaPluginProvider.overrideWithValue(MediaPluginState.ready),
      ],
      height: 1400,
    );
  }

  Map<String, Object?> lastOp() => (host.mutates().last['ops']! as List).single as Map<String, Object?>;

  testWidgets('the curated page: defaults, services with models and key state, cost guard', (tester) async {
    await open(
      tester,
      describe: _describe(services: [_service()]),
      credentials: const {'DSH_MEDIA_ARK_API_KEY': 'sk-ark'},
    );
    expect(find.text(_zh.mediaSettingsDefaults), findsOneWidget);
    expect(find.text(_zh.mediaKindImage), findsOneWidget);
    expect(find.text(_zh.mediaKindVideo), findsOneWidget);
    expect(find.text(_zh.mediaSettingsServices), findsOneWidget);
    // The one service: its preset name, its models, and its key is set.
    expect(find.text('火山方舟'), findsOneWidget);
    expect(find.textContaining('Seedream 5.0'), findsWidgets);
    expect(find.textContaining(_zh.mediaSettingsKeyMissing), findsNothing);
    // There is a video model in the catalogue but no ready video service:
    // the video default row says which half is missing.
    expect(find.text(_zh.mediaSettingsNoVideoService), findsOneWidget);
    // Cost protection reuses the native form's fields.
    expect(find.text(_zh.mediaSettingsBudget), findsOneWidget);
    expect(find.text(_zh.mediaSettingsDailyBudget), findsOneWidget);
    expect(find.text(_zh.mediaSettingsUnknownPriceHold), findsOneWidget);
  });

  testWidgets('no service: a note and the add row', (tester) async {
    await open(tester, describe: _describe(services: []));
    expect(find.text(_zh.mediaSettingsNoServices), findsOneWidget);
    expect(find.text(_zh.mediaSettingsAddService), findsOneWidget);
    // Models exist but nothing is ready to use them: say that, not "no model".
    expect(find.text(_zh.mediaSettingsNoImageService), findsOneWidget);
    expect(find.text(_zh.mediaSettingsNoVideoService), findsOneWidget);
  });

  testWidgets('a catalogue without video models says that instead', (tester) async {
    await open(
      tester,
      describe: _describe(services: [_service()], catalog: _catalog(video: false)),
    );
    expect(find.text(_zh.mediaSettingsNoVideoModels), findsOneWidget);
  });

  testWidgets('adding the Ark image service writes the nine fields and opens the service page', (tester) async {
    await open(tester, describe: _describe(services: []));
    await tester.tap(find.text(_zh.mediaSettingsAddService));
    await settle(tester);
    await tester.tap(find.text('火山方舟 · 图片'));
    await flush(tester);

    expect(host.mutates().last['ns'], 'dsh-media');
    final op = lastOp();
    expect(op['op'], 'set');
    expect(op['path'], ['services']);
    final rows = op['value']! as List;
    expect(rows, hasLength(1));
    final row = rows.single as Map;
    expect(
      row.keys,
      containsAll(<String>[
        'id',
        'label',
        'enabled',
        'provider',
        'baseUrl',
        'profile',
        'responseFormat',
        'models',
        'keyRef',
      ]),
    );
    expect(row['id'], 'ark_image');
    expect(row['enabled'], isTrue);
    expect(row['provider'], 'ark');
    expect(row['baseUrl'], 'https://ark.cn-beijing.volces.com');
    expect(row['profile'], 'ark-image');
    expect(row['models'], 'doubao-seedream-5-0-pro');
    expect(row['keyRef'], 'DSH_MEDIA_ARK_API_KEY');
    // The preset's own page opened, ready for its key.
    expect(find.text('火山方舟 · 图片'), findsWidgets);
    expect(find.text(_zh.mediaSettingsApiKey), findsOneWidget);
  });

  testWidgets('a second Ark service (video) reuses the image key instead of asking again', (tester) async {
    await open(tester, describe: _describe(services: [_service()]));
    await tester.tap(find.text(_zh.mediaSettingsAddService));
    await settle(tester);
    await tester.tap(find.text('火山方舟 · 视频'));
    await flush(tester);

    final rows = lastOp()['value']! as List;
    expect(rows, hasLength(2));
    final image = rows[0] as Map;
    final video = rows[1] as Map;
    expect(image['id'], 'ark_image');
    expect(video['id'], 'ark_video');
    expect(video['profile'], 'ark-video');
    expect(video['models'], 'doubao-seedance-2-0');
    expect(video['keyRef'], image['keyRef']);
    expect(video['keyRef'], 'DSH_MEDIA_ARK_API_KEY');
    // The service page's key row reads that shared credential, not a new one.
    expect(find.text(_zh.mediaSettingsApiKey), findsOneWidget);
    expect(find.text('DSH_MEDIA_ARK_API_KEY'), findsWidgets);
  });

  testWidgets('the service page writes its key through credentials/set', (tester) async {
    await open(tester, describe: _describe(services: [_service()]));
    await tester.tap(find.text('火山方舟'));
    await flush(tester);
    expect(find.text(_zh.mediaSettingsApiKey), findsOneWidget);
    expect(find.text(_zh.engineFieldNotConfigured), findsOneWidget);

    await tester.tap(find.text(_zh.mediaSettingsApiKey));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('secret-input')), 'sk-ark-1');
    await tester.pump();
    await tester.tap(find.text(_zh.commonDone));
    await flush(tester);

    final calls = [
      for (final (endpoint, args) in host.calls)
        if (endpoint == 'credentials/set') args,
    ];
    expect(calls, hasLength(1));
    expect(calls.single, {'ref': 'DSH_MEDIA_ARK_API_KEY', 'value': 'sk-ark-1'});
    expect(host.credentials['DSH_MEDIA_ARK_API_KEY'], 'sk-ark-1');
    expect(find.text(_zh.mediaConfigKeySaved), findsOneWidget);
  });

  testWidgets('saved key is not verification and local checks never call the host', (tester) async {
    await open(
      tester,
      describe: _describe(
        services: [
          _service(),
          _service(id: 'other', label: 'Shared media'),
        ],
      ),
      credentials: const {'DSH_MEDIA_ARK_API_KEY': 'fake-key'},
    );
    await tester.tap(find.text('火山方舟'));
    await flush(tester);
    expect(find.text(_zh.mediaConfigKeySaved), findsOneWidget);
    expect(find.textContaining('Shared media (dsh-media/other)'), findsOneWidget);
    final calls = host.calls.length;
    await tester.tap(find.text(_zh.mediaConfigCheck));
    await settle(tester);
    expect(find.textContaining(_zh.mediaConfigCheckReady), findsOneWidget);
    expect(find.text(_zh.mediaConfigCheckNote), findsWidgets);
    expect(host.calls.length, calls, reason: 'only the saved snapshot is inspected');
    expect(find.text('fake-key'), findsNothing);
  });

  testWidgets('URL editor previews root and rejects an endpoint without saving', (tester) async {
    await open(
      tester,
      describe: _describe(
        services: [_service(profile: 'openai-compatible', baseUrl: 'https://example.test/v1')],
      ),
    );
    await tester.tap(find.text('火山方舟'));
    await flush(tester);
    await tester.scrollUntilVisible(find.text(_zh.mediaSettingsBaseUrl), 250);
    await tester.tap(find.text(_zh.mediaSettingsBaseUrl));
    await settle(tester);
    expect(find.text('POST https://example.test/v1/images/generations'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('media-url-input')), 'https://example.test/v1/images/generations');
    await tester.pump();
    expect(find.text(_zh.mediaConfigUrlEndpoint), findsOneWidget);
    final done = tester.widget<FilledButton>(find.widgetWithText(FilledButton, _zh.commonDone));
    expect(done.onPressed, isNull);
    expect(host.mutates(), isEmpty);
  });

  testWidgets('target-origin change requires confirmation before host mutation', (tester) async {
    await open(
      tester,
      describe: _describe(
        services: [_service(profile: 'openai-compatible', baseUrl: 'https://old.test/v1')],
      ),
      credentials: const {'DSH_MEDIA_ARK_API_KEY': 'fake-key'},
    );
    await tester.tap(find.text('火山方舟'));
    await flush(tester);
    await tester.scrollUntilVisible(find.text(_zh.mediaSettingsBaseUrl), 250);
    await tester.tap(find.text(_zh.mediaSettingsBaseUrl));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('media-url-input')), 'https://new.test/v1');
    await tester.pump();
    await tester.tap(find.text(_zh.commonDone));
    await settle(tester);
    expect(find.text(_zh.mediaConfigTargetTitle), findsOneWidget);
    expect(host.mutates(), isEmpty);
    await tester.tap(find.text(_zh.commonCancel));
    await settle(tester);
    expect(host.mutates(), isEmpty);
    expect(find.byKey(const ValueKey('media-url-input')), findsOneWidget);
    await tester.tap(find.text(_zh.commonDone));
    await settle(tester);
    await tester.tap(find.text(_zh.mediaConfigTargetConfirm));
    await flush(tester);
    final rows = lastOp()['value']! as List;
    expect((rows.first as Map)['baseUrl'], 'https://new.test/v1');
  });

  testWidgets('URL host rejection stays a failure, not a successful local check', (tester) async {
    await open(
      tester,
      describe: _describe(
        services: [_service(profile: 'openai-compatible', baseUrl: 'https://example.test/v1')],
      ),
    );
    await tester.tap(find.text('火山方舟'));
    await flush(tester);
    await tester.scrollUntilVisible(find.text(_zh.mediaSettingsBaseUrl), 250);
    await tester.tap(find.text(_zh.mediaSettingsBaseUrl));
    await settle(tester);
    host.writable = false;
    await tester.enterText(find.byKey(const ValueKey('media-url-input')), 'https://example.test/v2');
    await tester.pump();
    await tester.tap(find.text(_zh.commonDone));
    await flush(tester);
    expect(find.text(_zh.commonSaveFailed), findsOneWidget);
    expect(find.byKey(const ValueKey('media-url-input')), findsOneWidget);
    expect((host.namespaces['dsh-media']!.value['services']! as List).first['baseUrl'], 'https://example.test/v1');
  });

  testWidgets('local checks report missing key and disabled service without claiming verification', (tester) async {
    await open(tester, describe: _describe(services: [_service(enabled: false)]));
    await tester.tap(find.text('火山方舟'));
    await flush(tester);
    await tester.tap(find.text(_zh.mediaConfigCheck));
    await settle(tester);
    expect(find.textContaining(_zh.mediaConfigCheckMissingKey), findsOneWidget);
    expect(find.textContaining(_zh.mediaConfigCheckDisabled), findsOneWidget);
    expect(find.textContaining(_zh.mediaConfigCheckReady), findsNothing);
    expect(host.mutates(), isEmpty);
  });

  testWidgets('a reused credential owned by another setting is reference-only', (tester) async {
    await open(
      tester,
      describe: _describe(
        services: [_service(keyRef: 'OPENAI_API_KEY')],
        catalog: _catalog(),
      ),
      credentials: const {'OPENAI_API_KEY': 'sk-openai'},
    );
    await tester.tap(find.text('火山方舟'));
    await flush(tester);
    expect(find.textContaining(_zh.mediaSettingsKeyExternal), findsOneWidget);
    await tester.tap(find.text(_zh.mediaSettingsApiKey));
    await settle(tester);
    expect(
      find.byKey(const ValueKey('secret-input')),
      findsNothing,
      reason: 'not the media plugin\'s key to overwrite',
    );
  });

  testWidgets('a key the launch environment supplies cannot be edited', (tester) async {
    await open(
      tester,
      describe: _describe(services: [_service()]),
      envCredentials: const {'DSH_MEDIA_ARK_API_KEY'},
    );
    await tester.tap(find.text('火山方舟'));
    await flush(tester);
    expect(find.text(_zh.engineFieldFromEnvironment), findsOneWidget);
    await tester.tap(find.text(_zh.mediaSettingsApiKey));
    await settle(tester);
    expect(find.byKey(const ValueKey('secret-input')), findsNothing, reason: 'the row is not tappable');
  });

  testWidgets('the reuse row switches to the other service\'s key', (tester) async {
    await open(
      tester,
      describe: _describe(
        services: [
          _service(),
          _service(
            id: 'ark_video',
            label: '火山方舟 · 视频',
            profile: 'ark-video',
            models: 'doubao-seedance-2-0',
            keyRef: 'DSH_MEDIA_ARK_VIDEO_API_KEY',
          ),
        ],
      ),
      credentials: const {'DSH_MEDIA_ARK_API_KEY': 'sk-image', 'DSH_MEDIA_ARK_VIDEO_API_KEY': 'sk-video'},
    );
    await tester.tap(find.text('火山方舟'));
    await flush(tester);
    expect(find.text(_zh.mediaSettingsReuseKey), findsOneWidget);
    await tester.tap(find.text(_zh.mediaSettingsReuseKey));
    await settle(tester);
    await tester.tap(find.textContaining('DSH_MEDIA_ARK_VIDEO_API_KEY ·'));
    await flush(tester);
    final rows = lastOp()['value']! as List;
    expect((rows.first as Map)['keyRef'], 'DSH_MEDIA_ARK_VIDEO_API_KEY');
  });

  testWidgets('clearing the key calls credentials/unset for that reference', (tester) async {
    await open(
      tester,
      describe: _describe(services: [_service()]),
      credentials: const {'DSH_MEDIA_ARK_API_KEY': 'sk-ark'},
    );
    await tester.tap(find.text('火山方舟'));
    await flush(tester);
    await tester.tap(find.text(_zh.mediaSettingsApiKey));
    await settle(tester);
    await tester.tap(find.text(_zh.engineFieldRemove));
    await flush(tester);
    final calls = [
      for (final (endpoint, args) in host.calls)
        if (endpoint == 'credentials/unset') args,
    ];
    expect(calls, [
      {'ref': 'DSH_MEDIA_ARK_API_KEY'},
    ]);
    expect(host.credentials.containsKey('DSH_MEDIA_ARK_API_KEY'), isFalse);
  });

  testWidgets('picking the default image model writes the image pair', (tester) async {
    await open(
      tester,
      describe: _describe(services: [_service()]),
      credentials: const {'DSH_MEDIA_ARK_API_KEY': 'sk-ark'},
    );
    await tester.tap(find.text(_zh.mediaKindImage));
    await settle(tester);
    expect(find.text(_zh.engineFieldAuto), findsWidgets);
    await tester.tap(find.text('Seedream 5.0 · 火山方舟'));
    await flush(tester);

    final op = lastOp();
    expect(op['path'], ['defaults']);
    final value = op['value']! as Map;
    expect(value['imageServiceId'], 'ark_image');
    expect(value['imageModelId'], 'doubao-seedream-5-0-pro');
    expect(value['videoServiceId'], '');
    expect(value['serviceId'], '');
    expect((host.namespaces['dsh-media']!.value['defaults']! as Map)['imageServiceId'], 'ark_image');
  });

  testWidgets('a 0.3.0 legacy pair stays visible and can be cleared', (tester) async {
    await open(
      tester,
      describe: _describe(
        services: [_service()],
        defaults: const {'serviceId': 'gone', 'modelId': 'doubao-seedream-5-0-pro'},
      ),
      credentials: const {'DSH_MEDIA_ARK_API_KEY': 'sk-ark'},
    );
    expect(find.text(_zh.mediaSettingsLegacyDefault), findsOneWidget);
    expect(find.text(_zh.mediaSettingsLegacyDefaultStale), findsOneWidget);
    await tester.tap(find.text(_zh.mediaSettingsLegacyDefault));
    await settle(tester);
    await tester.tap(find.text(_zh.mediaSettingsLegacyDefaultClear));
    await flush(tester);
    final value = lastOp()['value']! as Map;
    expect((value['serviceId'], value['modelId']), ('', ''));
  });

  testWidgets('deleting a service clears the defaults that named it and keeps the key', (tester) async {
    await open(
      tester,
      describe: _describe(
        services: [
          _service(),
          _service(id: 'ark_video', label: '火山方舟 · 视频', profile: 'ark-video', models: 'doubao-seedance-2-0'),
        ],
        defaults: const {
          'serviceId': 'ark_image',
          'modelId': 'doubao-seedream-5-0-pro',
          'imageServiceId': 'ark_image',
          'imageModelId': 'doubao-seedream-5-0-pro',
          'videoServiceId': 'ark_video',
          'videoModelId': 'doubao-seedance-2-0',
        },
      ),
      credentials: const {'DSH_MEDIA_ARK_API_KEY': 'sk-keep'},
    );
    await tester.tap(find.text('火山方舟'));
    await flush(tester);
    await tester.tap(find.text(_zh.mediaSettingsDelete));
    await settle(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text(_zh.commonDelete));
    await flush(tester);

    final ops = host.mutates().last['ops']! as List;
    expect(ops, hasLength(2));
    final servicesOp = ops.firstWhere((op) => ((op as Map)['path']! as List).join('.') == 'services') as Map;
    final remaining = servicesOp['value']! as List;
    expect((remaining.single as Map)['id'], 'ark_video');
    final defaultsOp = ops.firstWhere((op) => ((op as Map)['path']! as List).join('.') == 'defaults') as Map;
    final defaults = defaultsOp['value']! as Map;
    expect(defaults['imageServiceId'], '');
    expect(defaults['imageModelId'], '');
    expect(defaults['serviceId'], '');
    expect(defaults['modelId'], '');
    expect(defaults['videoServiceId'], 'ark_video');
    expect(defaults['videoModelId'], 'doubao-seedance-2-0');
    expect(host.credentials['DSH_MEDIA_ARK_API_KEY'], 'sk-keep', reason: 'the key is not deleted with the service');
  });

  testWidgets('plugin 0.2.1 (no presets): the fallback presets still add a service', (tester) async {
    await open(
      tester,
      describe: _describe(services: [], catalog: _catalog(presets: false, video: false)),
    );
    await tester.tap(find.text(_zh.mediaSettingsAddService));
    await settle(tester);
    await tester.tap(find.text('OpenAI · 图片'));
    await flush(tester);

    final row = (lastOp()['value']! as List).single as Map;
    expect(row['id'], 'openai_image');
    expect(row['provider'], 'openai');
    expect(row['profile'], 'openai-gpt-image');
    expect(row['baseUrl'], 'https://api.openai.com/v1');
    expect(row['models'], 'gpt-image-2');
    expect(row['keyRef'], 'DSH_MEDIA_OPENAI_API_KEY');
  });

  testWidgets('plugin 0.2.1 fixed key slots still read and write', (tester) async {
    await open(
      tester,
      describe: _describe(
        services: [
          _service(
            id: 'office',
            label: '办公室',
            profile: 'openai-gpt-image',
            models: 'gpt-image-2',
            keyRef: 'DSH_MEDIA_SLOT_1_API_KEY',
          ),
        ],
        catalog: _catalog(presets: false, video: false),
      ),
    );
    await tester.tap(find.text('办公室'));
    await flush(tester);
    await tester.tap(find.text(_zh.mediaSettingsApiKey));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('secret-input')), 'sk-slot');
    await tester.pump();
    await tester.tap(find.text(_zh.commonDone));
    await flush(tester);
    expect(host.credentials['DSH_MEDIA_SLOT_1_API_KEY'], 'sk-slot');
  });

  testWidgets('plugin 0.2.1 (general default only): one row, the legacy pair is written', (tester) async {
    await open(
      tester,
      describe: _describe(services: [_service()], catalog: _catalog(presets: false, video: false), kindDefaults: false),
      credentials: const {'DSH_MEDIA_ARK_API_KEY': 'sk-ark'},
    );
    expect(find.text(_zh.mediaSettingsDefaultModel), findsOneWidget);
    expect(find.text(_zh.mediaSettingsNoVideoModels), findsNothing, reason: 'no per-kind rows on 0.2.1');
    await tester.tap(find.text(_zh.mediaSettingsDefaultModel));
    await settle(tester);
    await tester.tap(find.text('Seedream 5.0 · 火山方舟'));
    await flush(tester);

    final op = lastOp();
    expect(op['path'], ['defaults']);
    final value = op['value']! as Map;
    expect(value['serviceId'], 'ark_image');
    expect(value['modelId'], 'doubao-seedream-5-0-pro');
    expect(value.containsKey('imageServiceId'), isFalse, reason: 'an older plugin has no such field');
  });

  testWidgets('at the plugin\'s 8-service bound the add row says so and is disabled', (tester) async {
    await open(
      tester,
      describe: _describe(
        services: [for (var i = 0; i < 8; i++) _service(id: 'ark_$i', label: '火山方舟 $i')],
      ),
    );
    expect(find.text(_zh.mediaSettingsServiceLimit(8)), findsOneWidget);
    await tester.tap(find.text(_zh.mediaSettingsAddService));
    await settle(tester);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('a service deleted elsewhere leaves its page with a word, not a crash', (tester) async {
    await open(tester, describe: _describe(services: [_service()]));
    await tester.tap(find.text('火山方舟'));
    await flush(tester);
    expect(find.text(_zh.mediaSettingsApiKey), findsOneWidget);
    host.externalSet('dsh-media', const ['services'], const <Object?>[], notify: false);
    final container = ProviderScope.containerOf(tester.element(find.text(_zh.mediaSettingsApiKey)));
    await container.read(engineSettingsProvider.notifier).refresh();
    await flush(tester);
    expect(find.text(_zh.mediaSettingsServiceGone), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('request limits stay reachable (the old form exposed them)', (tester) async {
    await open(
      tester,
      describe: _describe(services: [_service()], catalog: _catalog(presets: false, video: false)),
    );
    await tester.scrollUntilVisible(find.text(_zh.mediaSettingsLimits), 300);
    await tester.tap(find.text(_zh.mediaSettingsLimits));
    await flush(tester);
    expect(find.text(_zh.mediaSettingsMaxImages), findsOneWidget);
    expect(find.text(_zh.mediaSettingsMaxVideoBytes), findsOneWidget);
  });

  testWidgets('a damaged catalogue: existing services stay, nothing is added or defaulted', (tester) async {
    await open(
      tester,
      describe: _describe(services: [_service()], catalog: {'v': 2, 'models': <Object?>[]}),
    );
    expect(find.text(_zh.mediaSettingsCatalogBroken), findsOneWidget);
    expect(find.text('火山方舟'), findsOneWidget);
    await tester.tap(find.text(_zh.mediaSettingsAddService));
    await settle(tester);
    expect(find.byType(BottomSheet), findsNothing, reason: 'the add row is disabled');
    await tester.tap(find.text(_zh.mediaKindImage));
    await settle(tester);
    expect(find.byType(BottomSheet), findsNothing, reason: 'the default row is disabled');
  });
}
