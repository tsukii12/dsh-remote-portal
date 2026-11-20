// What the host can generate with (media-generation §4.3, §4.6.5;
// CR-722ae3f must-fix 1): the catalogue from the plugin's settings/describe
// metadata — services.meta.extra["dsh-go/media/catalog"], under whatever
// namespace — crossed with the services really configured and keys really
// there. Missing, broken or unknown catalogues give no generation mode; there
// is no built-in model table to fall back on.
//
// fixtures/settings_describe_media_m0.json is the M0 candidate's namespace as
// settings/describe serves it (schemastery {uid, refs}, the catalogue on the
// services transform's meta), derived from its source, not recorded live.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/engine_settings_state.dart' show credentialRefsOf;
import 'package:dsh_app/state/media_generation.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _m0() =>
    jsonDecode(File('test/media/fixtures/settings_describe_media_m0.json').readAsStringSync()) as Map<String, Object?>;

/// The fixture's media namespace, editable.
Map<String, Object?> _ns(Map<String, Object?> describe) =>
    (describe['namespaces']! as List).single as Map<String, Object?>;

Map<String, Object?> _value(Map<String, Object?> describe) => _ns(describe)['value']! as Map<String, Object?>;

/// The catalogue inside the schema graph.
Map<String, Object?> _catalog(Map<String, Object?> describe) {
  final refs = (_ns(describe)['schema']! as Map)['refs']! as Map;
  for (final node in refs.values) {
    final extra = ((node as Map)['meta'] as Map?)?['extra'] as Map?;
    if (extra?['dsh-go/media/catalog'] case final Map<String, Object?> catalog) return catalog;
  }
  throw StateError('no catalogue in the fixture');
}

void _setCatalog(Map<String, Object?> describe, Object? catalog) {
  final refs = (_ns(describe)['schema']! as Map)['refs']! as Map;
  for (final node in refs.values) {
    final meta = (node as Map)['meta'] as Map?;
    if (meta?['extra'] case final Map extra when extra.containsKey('dsh-go/media/catalog')) {
      extra['dsh-go/media/catalog'] = catalog;
      return;
    }
  }
}

Map<String, Object?> _service(String id, {String models = 'gpt-image-2', bool enabled = true, String? keyRef}) => {
  'id': id,
  'label': id,
  'enabled': enabled,
  'provider': 'openai',
  'baseUrl': 'https://api.openai.com/v1',
  'profile': 'openai-gpt-image',
  'responseFormat': '',
  'models': models,
  'keyRef': keyRef ?? 'DSH_MEDIA_SLOT_1_API_KEY',
};

const _keys = {
  'DSH_MEDIA_SLOT_1_API_KEY': CredentialStatus(configured: true, writable: true),
  'DSH_MEDIA_SLOT_2_API_KEY': CredentialStatus(configured: true, writable: true),
};

MediaCatalog _read(Map<String, Object?> describe, {Map<String, CredentialStatus> keys = _keys}) =>
    mediaCatalogFrom(SettingsDescription.fromJson(describe).namespaces, credentials: keys);

void main() {
  group('where the catalogue is', () {
    test('M0 as described: from the services field\'s metadata, image only, the configured service\'s models', () {
      final describe = _m0();
      expect(_value(describe).containsKey('catalog'), isFalse, reason: 'no catalogue value to read');
      final catalog = _read(describe);
      expect(catalog.status, MediaCatalogStatus.ready);
      expect(catalog.configured, isTrue);
      expect(catalog.kinds, [GenerateKind.image]);
      expect(
        [for (final e in catalog.of(GenerateKind.image)) '${e.namespace}/${e.service.id}/${e.model.id}'],
        ['dsh-media/office/gpt-image-2', 'dsh-media/office/gpt-image-2.5-flare'],
      );
      final gpt = catalog.of(GenerateKind.image).first;
      expect(gpt.model.label, 'GPT Image 2');
      expect(gpt.model.ratios, ['1:1', '3:2', '2:3']);
      expect(gpt.model.qualities, ['low', 'medium', 'high']);
      expect(gpt.model.maxN, 4);
      expect(gpt.service.label, '办公室');
      expect(catalog.of(GenerateKind.video), isEmpty);
    });

    test('found by its metadata under any namespace; the name is kept', () {
      final describe = _m0();
      _ns(describe)['ns'] = 'media-lab';
      final catalog = _read(describe);
      expect(catalog.status, MediaCatalogStatus.ready);
      expect(catalog.of(GenerateKind.image).map((e) => e.namespace).toSet(), {'media-lab'});
      expect(mediaNamespacesOf(SettingsDescription.fromJson(describe).namespaces), ['media-lab']);
    });

    test('a catalogue value without the metadata is not a catalogue', () {
      final describe = _m0();
      _setCatalog(describe, null);
      _value(describe)['catalog'] = [
        {'id': 'seedream', 'label': 'Seedream 5.0', 'kind': 'image'},
      ];
      final catalog = _read(describe);
      expect(catalog.status, MediaCatalogStatus.missing);
      expect(catalog.usable, isFalse);
      expect(catalog.of(GenerateKind.image), isEmpty);
    });

    test('settings not read yet: loading, nothing to offer', () {
      final catalog = mediaCatalogFrom(null);
      expect(catalog.status, MediaCatalogStatus.loading);
      expect(catalog.usable, isFalse);
      expect(catalog.kinds, isEmpty);
    });
  });

  group('versions and damage', () {
    test('an unknown version: unsupported, no generation mode', () {
      final describe = _m0();
      _catalog(describe)['v'] = 2;
      final catalog = _read(describe);
      expect(catalog.status, MediaCatalogStatus.unsupported);
      expect(catalog.usable, isFalse);
      expect(catalog.configured, isFalse);
    });

    test('another contract name: unsupported', () {
      final describe = _m0();
      _catalog(describe)['contract'] = 'someone-else/catalog';
      expect(_read(describe).status, MediaCatalogStatus.unsupported);
    });

    for (final (name, damage) in <(String, void Function(Map<String, Object?>))>[
      ('not an object', (d) => _setCatalog(d, 'gpt-image-2')),
      ('no version', (d) => _catalog(d).remove('v')),
      ('models not a list', (d) => _catalog(d)['models'] = {'gpt-image-2': {}}),
      ('a model without an id', (d) => ((_catalog(d)['models']! as List).first as Map).remove('id')),
      ('a model without a label', (d) => ((_catalog(d)['models']! as List).first as Map)['label'] = 7),
      ('two models with one id', (d) => (_catalog(d)['models']! as List).add((_catalog(d)['models']! as List).first)),
      ('ratios not strings', (d) => ((_catalog(d)['models']! as List).first as Map)['ratios'] = [1, 2]),
      ('maxN not a number', (d) => ((_catalog(d)['models']! as List).first as Map)['maxN'] = 'four'),
      ('capabilities not an object', (d) => _catalog(d)['capabilities'] = true),
    ]) {
      test('broken ($name): no generation mode', () {
        final describe = _m0();
        damage(describe);
        final catalog = _read(describe);
        expect(catalog.status, MediaCatalogStatus.broken);
        expect(catalog.usable, isFalse);
        expect(catalog.of(GenerateKind.image), isEmpty);
      });
    }

    test('a model of a kind this app doesn\'t know is skipped, not fatal', () {
      final describe = _m0();
      (_catalog(describe)['models']! as List).add({'id': 'song-1', 'label': 'Song', 'kind': 'audio'});
      final catalog = _read(describe);
      expect(catalog.status, MediaCatalogStatus.ready);
      expect(catalog.kinds, [GenerateKind.image]);
    });
  });

  group('what can generate', () {
    test('no service yet: the catalogue is fine, nothing to generate with', () {
      final describe = _m0();
      _value(describe)['services'] = <Object?>[];
      final catalog = _read(describe);
      expect(catalog.status, MediaCatalogStatus.ready);
      expect(catalog.usable, isTrue);
      expect(catalog.configured, isFalse);
    });

    test('a switched-off service offers nothing', () {
      final describe = _m0();
      _value(describe)['services'] = [_service('office', enabled: false)];
      expect(_read(describe).configured, isFalse);
    });

    test('a service whose key is missing, or not known to be there, offers nothing', () {
      final describe = _m0();
      expect(
        _read(
          describe,
          keys: const {'DSH_MEDIA_SLOT_1_API_KEY': CredentialStatus(configured: false, writable: true)},
        ).configured,
        isFalse,
      );
      expect(_read(describe, keys: const {}).configured, isFalse);
    });

    test('the key a service names is read with the rest', () {
      final describe = _m0();
      _value(describe)['services'] = [_service('office', keyRef: 'OPENAI_API_KEY')];
      final namespaces = SettingsDescription.fromJson(describe).namespaces;
      expect(mediaKeyRefsOf(namespaces), {'OPENAI_API_KEY'});
      expect(credentialRefsOf(namespaces), containsAll(['OPENAI_API_KEY', 'DSH_MEDIA_SLOT_1_API_KEY']));
      final catalog = mediaCatalogFrom(
        namespaces,
        credentials: const {'OPENAI_API_KEY': CredentialStatus(configured: true, writable: true)},
      );
      expect(catalog.of(GenerateKind.image).single.model.id, 'gpt-image-2');
    });

    test('a model not in the catalogue, or on the wrong protocol, is left out', () {
      final describe = _m0();
      _value(describe)['services'] = [_service('office', models: 'gpt-image-2, made-up-model, gemini-2.5-flash-image')];
      expect(_read(describe).of(GenerateKind.image).map((e) => e.model.id), ['gpt-image-2']);
    });

    test('M0 is pictures only: a video model is not offered while capabilities.video is false', () {
      final describe = _m0();
      (_catalog(describe)['models']! as List).add({
        'id': 'seedance-2',
        'label': 'Seedance 2.0',
        'kind': 'video',
        'profile': 'openai-gpt-image',
        'durations': [5, 10],
        'resolutions': ['720p'],
      });
      _value(describe)['services'] = [_service('office', models: 'gpt-image-2,seedance-2')];
      final catalog = _read(describe);
      expect(catalog.kinds, [GenerateKind.image]);
      (_catalog(describe)['capabilities']! as Map)['video'] = true;
      expect(_read(describe).kinds, [GenerateKind.image, GenerateKind.video]);
    });

    test('one model on two services: two choices, told apart by service', () {
      final describe = _m0();
      _value(describe)['services'] = [_service('office'), _service('home', keyRef: 'DSH_MEDIA_SLOT_2_API_KEY')];
      final entries = _read(describe).of(GenerateKind.image);
      expect([for (final e in entries) '${e.service.id}/${e.model.id}'], ['office/gpt-image-2', 'home/gpt-image-2']);
      expect(entries.map((e) => e.model.label).toSet(), {'GPT Image 2'});
    });

    test('the same service and model under two namespaces: the header can\'t tell them apart, so neither', () {
      final describe = _m0();
      final twin = jsonDecode(jsonEncode(_ns(describe))) as Map<String, Object?>;
      twin['ns'] = 'dsh-media-2';
      (twin['value']! as Map)['services'] = [_service('office', models: 'gpt-image-2,gpt-image-2.5-sunburst')];
      (describe['namespaces']! as List).add(twin);
      final catalog = _read(describe);
      expect(
        [for (final e in catalog.of(GenerateKind.image)) '${e.namespace}/${e.service.id}/${e.model.id}'],
        ['dsh-media/office/gpt-image-2.5-flare', 'dsh-media-2/office/gpt-image-2.5-sunburst'],
      );
    });

    test('empty option sets stay empty: nothing made up', () {
      final describe = _m0();
      _value(describe)['services'] = [
        {
          ..._service('google', models: 'gemini-2.5-flash-image'),
          'profile': 'openai-compatible',
          'responseFormat': 'b64_json',
        },
      ];
      final catalog = _read(describe);
      final gemini = catalog.of(GenerateKind.image).single;
      expect(gemini.model.ratios, isEmpty);
      expect(gemini.model.qualities, isEmpty);
      expect(gemini.model.maxN, 1);
      final params = const GenerateParams(count: 3, aspect: '1:1', quality: '2k').fitTo(catalog);
      expect((params.aspect, params.quality, params.count), (null, null, 1));
      expect(params.tryMessage('猫').text, '〔生成图像 · 1 张 · Gemini 2.5 Flash Image〈google/gemini-2.5-flash-image〉〕\n猫');
    });

    test('pictures at once: the model\'s, the catalogue\'s and the host\'s limit, the lowest', () {
      final describe = _m0();
      (_value(describe)['limits']! as Map)['maxImages'] = 2;
      expect(_read(describe).of(GenerateKind.image).first.model.maxN, 2);
    });

    test('the default: what the plugin\'s defaults name, else the first', () {
      final describe = _m0();
      expect(_read(describe).defaultFor(GenerateKind.image)?.model.id, 'gpt-image-2');
      _value(describe)['defaults'] = {'serviceId': 'office', 'modelId': 'gpt-image-2.5-flare'};
      expect(_read(describe).defaultFor(GenerateKind.image)?.model.id, 'gpt-image-2.5-flare');
      expect(_read(describe).defaultFor(GenerateKind.video), isNull);
    });
  });

  group('identity', () {
    late MediaCatalog twoServices;
    setUp(() {
      final describe = _m0();
      _value(describe)['services'] = [
        _service('office', models: 'gpt-image-2,gpt-image-2.5-flare'),
        _service('home', keyRef: 'DSH_MEDIA_SLOT_2_API_KEY'),
      ];
      twoServices = _read(describe);
    });

    test('a fresh mode takes the default and writes it with its marker', () {
      final params = const GenerateParams().fitTo(twoServices);
      expect(
        params.model,
        const MediaModelRef(namespace: 'dsh-media', service: 'office', id: 'gpt-image-2', label: 'GPT Image 2'),
      );
      expect((params.aspect, params.count, params.quality), ('1:1', 1, null));
      expect(params.tryMessage('猫').text, '〔生成图像 · 1:1 · 1 张 · GPT Image 2〈office/gpt-image-2〉〕\n猫');
      final high = params.copyWith(quality: 'high', aspect: '3:2', count: 2);
      expect(high.tryMessage('猫').text, '〔生成图像 · 3:2 · 2 张 · 质量=high · GPT Image 2〈office/gpt-image-2〉〕\n猫');
    });

    test('a header with a marker comes back as that service\'s model', () {
      final header = GenerateHeader.parse('〔生成图像 · 2:3 · 2 张 · 质量=medium · GPT Image 2〈home/gpt-image-2〉〕\n猫')!.header;
      final params = GenerateParams.fromHeader(header, twoServices);
      expect(twoServices.resolve(params.model, GenerateKind.image)?.service.id, 'home');
      expect((params.aspect, params.count, params.quality), ('2:3', 2, 'medium'));
      // Round trip: the same header again.
      expect(params.tryMessage('猫').text, '〔生成图像 · 2:3 · 2 张 · 质量=medium · GPT Image 2〈home/gpt-image-2〉〕\n猫');
    });

    test('a name two services share is not guessed: the mode asks for a model', () {
      final header = GenerateHeader.parse('〔生成图像 · 3:2 · GPT Image 2〕\n猫')!.header;
      final params = GenerateParams.fromHeader(header, twoServices);
      expect(twoServices.resolve(params.model, GenerateKind.image), isNull);
      expect(params.model?.label, 'GPT Image 2');
      expect(params.aspect, '3:2');
      // fitTo leaves an unresolved choice alone; it does not pick the first.
      expect(twoServices.resolve(params.fitTo(twoServices).model, GenerateKind.image), isNull);
    });

    test('a name only one service has is taken', () {
      final header = GenerateHeader.parse('〔生成图像 · GPT Image 2.5 Flare〕\n猫')!.header;
      final params = GenerateParams.fromHeader(header, twoServices);
      expect(twoServices.resolve(params.model, GenerateKind.image)?.service.id, 'office');
    });

    test('a header without a model takes the default', () {
      final params = GenerateParams.fromHeader(GenerateHeader.parse('〔生成图像 · 2 张〕\n猫')!.header, twoServices);
      expect(params.model?.id, 'gpt-image-2');
      expect(params.count, 2);
    });

    test('from a card: provider and model id, when only one service fits', () {
      final meta = MediaMeta.fromJson({
        'v': 1,
        'kind': 'image',
        'status': 'failed',
        'request': {'provider': 'openai', 'model': 'gpt-image-2.5-flare', 'label': 'GPT Image 2.5 Flare', 'n': 1},
        'prompt': '猫',
      })!;
      expect(
        twoServices.resolve(GenerateParams.fromMeta(meta, twoServices).model, GenerateKind.image)?.service.id,
        'office',
      );
      final shared = MediaMeta.fromJson({
        'v': 1,
        'kind': 'image',
        'status': 'failed',
        'request': {'provider': 'openai', 'model': 'gpt-image-2', 'label': 'GPT Image 2', 'n': 2, 'quality': 'high'},
        'prompt': '猫',
      })!;
      final params = GenerateParams.fromMeta(shared, twoServices);
      expect(twoServices.resolve(params.model, GenerateKind.image), isNull);
      expect((params.count, params.quality), (2, 'high'));
    });

    test('the mode keeps namespace, service, model and name across launches', () {
      final params = const GenerateParams().fitTo(twoServices).copyWith(count: 3);
      final back = GenerateParams.fromJson(jsonDecode(jsonEncode(params.toJson())));
      expect(back, params);
      expect(
        back.model,
        const MediaModelRef(namespace: 'dsh-media', service: 'office', id: 'gpt-image-2', label: 'GPT Image 2'),
      );
    });

    test('a mode saved by the old app (no service) starts over on the default', () {
      final old = GenerateParams.fromJson({
        'kind': 'image',
        'model': 'doubao-seedream-5-0-pro',
        'modelLabel': 'Seedream 5.0',
        'aspect': '3:4',
        'count': 2,
        'quality': '2k',
      });
      expect(old.model, isNull);
      final fitted = old.fitTo(twoServices);
      expect(fitted.model?.id, 'gpt-image-2');
      // 3:4 and 2k aren't this model's: its own first ratio, quality left to the host.
      expect((fitted.aspect, fitted.count, fitted.quality), ('1:1', 2, null));
    });
  });

  group('provider presets and per-kind defaults', () {
    SettingsNamespaceView viewOf(Map<String, Object?> describe) =>
        SettingsDescription.fromJson(describe).namespaces['dsh-media']!;

    test('an older catalogue without presets uses the app\'s fallback list', () {
      final presets = mediaPresetsOf(viewOf(_m0()));
      expect(presets.map((p) => p.id), containsAll(['ark-image', 'openai-image', 'gemini-image']));
      expect(presets.firstWhere((p) => p.id == 'gemini-image').responseFormat, 'b64_json');
      expect(presets.firstWhere((p) => p.id == 'ark-image').keyGroup, 'ark');
    });

    test('a 0.3 catalogue\'s presets win; an unreadable row is skipped', () {
      final describe = _m0();
      _catalog(describe)['presets'] = [
        {
          'id': 'ark-image',
          'label': '火山方舟 · 图片',
          'labelEn': 'Volcengine Ark · Image',
          'provider': 'ark',
          'profile': 'ark-image',
          'baseUrl': 'https://ark.cn-beijing.volces.com',
          'responseFormat': '',
          'models': ['doubao-seedream-5-0-pro-260628'],
          'kind': 'image',
          'keyGroup': 'ark',
        },
        {
          'id': 'bad',
          'label': '',
          'provider': 'x',
          'profile': 'p',
          'baseUrl': 'http://not-https',
          'models': <Object?>[],
          'kind': 'image',
        },
      ];
      final presets = mediaPresetsOf(viewOf(describe));
      expect(presets, hasLength(1));
      expect(presets.single.id, 'ark-image');
      expect(presets.single.title(true), 'Volcengine Ark · Image');
    });

    test('an empty preset list means none, not the app fallback', () {
      final describe = _m0();
      _catalog(describe)['presets'] = <Object?>[];
      expect(mediaPresetsOf(viewOf(describe)), isEmpty);
    });

    test('a catalog without the key at all uses the app fallback', () {
      final describe = _m0();
      _catalog(describe).remove('presets');
      expect(mediaPresetsOf(viewOf(describe)), fallbackMediaPresets);
    });

    test('all catalogue models are known, even ones no service serves yet', () {
      final catalog = _read(_m0());
      expect(catalog.modelOf('gpt-image-2')?.label, 'GPT Image 2');
      expect(catalog.modelOf('gpt-image-2.5-sunburst')?.label, 'GPT Image 2.5 Sunburst');
      expect(catalog.modelOf('not-a-model'), isNull);
    });

    test('image and video defaults are separate; the legacy pair still works', () {
      final describe = _m0();
      _value(describe)['defaults'] = {'serviceId': 'office', 'modelId': 'gpt-image-2'};
      expect(_read(describe).defaultFor(GenerateKind.image)?.model.id, 'gpt-image-2');

      _value(describe)['defaults'] = {
        'serviceId': 'office',
        'modelId': 'gpt-image-2',
        'imageServiceId': 'office',
        'imageModelId': 'gpt-image-2.5-flare',
        'videoServiceId': 'office',
        'videoModelId': 'gpt-image-2',
      };
      expect(_read(describe).defaultFor(GenerateKind.image)?.model.id, 'gpt-image-2.5-flare');
      expect(_read(describe).defaultFor(GenerateKind.video), isNull);

      _value(describe)['defaults'] = {
        'serviceId': 'office',
        'modelId': 'gpt-image-2',
        'imageServiceId': 'gone',
        'imageModelId': 'gpt-image-2.5-sunburst',
      };
      expect(_read(describe).defaultFor(GenerateKind.image)?.model.id, 'gpt-image-2');
    });

    test('the kind service wins even when its model went away, like the plugin', () {
      final describe = _m0();
      _value(describe)['services'] = [
        _service('office', models: 'gpt-image-2'),
        _service('home', models: 'gpt-image-2.5-flare', keyRef: 'DSH_MEDIA_SLOT_2_API_KEY'),
      ];
      _value(describe)['defaults'] = {'imageServiceId': 'home', 'imageModelId': 'gone-model'};
      final chosen = _read(describe).defaultFor(GenerateKind.image);
      expect(chosen?.service.id, 'home');
      expect(chosen?.model.id, 'gpt-image-2.5-flare');

      _value(describe)['defaults'] = {
        'serviceId': 'office',
        'modelId': 'gpt-image-2',
        'imageModelId': 'gpt-image-2.5-flare',
      };
      // No kind service: the legacy service stays; a kind model it can't
      // serve falls back to the legacy model, as in the plugin.
      final legacy = _read(describe).defaultFor(GenerateKind.image);
      expect((legacy?.service.id, legacy?.model.id), ('office', 'gpt-image-2'));
    });
  });
}
