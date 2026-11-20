// The 「图像与视频」 page's pure edits (media-generation §5.8): service rows,
// provider presets, one credential per provider group, per-kind defaults.

import 'package:dsh_app/state/media_catalog.dart';
import 'package:dsh_app/state/media_generation.dart' show GenerateKind;
import 'package:dsh_app/state/media_settings.dart';
import 'package:flutter_test/flutter_test.dart';

MediaPreset _preset({
  String id = 'ark-image',
  String label = '火山方舟 · 图片',
  String labelEn = 'Volcengine Ark · Image',
  String provider = 'ark',
  String profile = 'ark-image',
  List<String> models = const ['seedream'],
  GenerateKind kind = GenerateKind.image,
  String keyGroup = 'ark',
}) => MediaPreset(
  id: id,
  label: label,
  labelEn: labelEn,
  provider: provider,
  profile: profile,
  baseUrl: 'https://ark.cn-beijing.volces.com',
  models: models,
  kind: kind,
  keyGroup: keyGroup,
);

MediaCatalog _catalog() => const MediaCatalog(
  models: {
    'seedream': MediaModel(id: 'seedream', label: 'Seedream 5.0', kind: GenerateKind.image, profile: 'ark-image'),
    'seedance': MediaModel(id: 'seedance', label: 'Seedance 2.5', kind: GenerateKind.video, profile: 'ark-video'),
    'gone': MediaModel(id: 'gone', label: 'Gone', kind: GenerateKind.image, profile: 'other'),
  },
);

void main() {
  group('service rows', () {
    test('a plugin row reads its comma-separated models and writes them back', () {
      final service = MediaServiceConfig.tryFrom({
        'id': 'ark_image',
        'label': '火山方舟',
        'enabled': true,
        'provider': 'ark',
        'baseUrl': 'https://ark.cn-beijing.volces.com',
        'profile': 'ark-image',
        'responseFormat': '',
        'models': 'seedream, seedance',
        'keyRef': 'DSH_MEDIA_ARK_API_KEY',
      });
      expect(service, isNotNull);
      expect(service!.models, ['seedream', 'seedance']);
      expect(service.modelsValue, 'seedream, seedance');
      expect(service.toJson(), {
        'id': 'ark_image',
        'label': '火山方舟',
        'enabled': true,
        'provider': 'ark',
        'baseUrl': 'https://ark.cn-beijing.volces.com',
        'profile': 'ark-image',
        'responseFormat': '',
        'models': 'seedream, seedance',
        'keyRef': 'DSH_MEDIA_ARK_API_KEY',
      });
      expect(MediaServiceConfig.tryFrom({'id': 'no-profile'}), isNull);
      expect(
        mediaServicesOf([
          service.toJson(),
          {'nope': true},
        ]),
        hasLength(1),
      );
    });

    test('replace by id, delete by id, insensitive to order', () {
      const a = MediaServiceConfig(
        id: 'a',
        provider: 'ark',
        baseUrl: 'https://ark.cn-beijing.volces.com',
        profile: 'ark-image',
        models: ['seedream'],
        keyRef: 'DSH_MEDIA_ARK_API_KEY',
      );
      const b = MediaServiceConfig(
        id: 'b',
        provider: 'aliyun',
        baseUrl: 'https://dashscope.aliyuncs.com',
        profile: 'ali-wan-image',
        models: ['wan'],
        keyRef: 'DSH_MEDIA_ALIYUN_API_KEY',
      );
      final replaced = withMediaService([a, b], a.copyWith(enabled: true));
      expect(replaced.map((s) => s.id), ['a', 'b']);
      expect(replaced.first.enabled, isTrue);
      expect(withMediaService([a], b).map((s) => s.id), ['a', 'b']);
      expect(withoutMediaService([a, b], 'a').map((s) => s.id), ['b']);
      expect(mediaServiceById([a, b], 'b')?.provider, 'aliyun');
    });

    test('a model switch adds and removes without reordering the rest', () {
      const service = MediaServiceConfig(
        id: 'a',
        provider: 'ark',
        baseUrl: 'https://ark.cn-beijing.volces.com',
        profile: 'ark-image',
        models: ['one', 'two'],
        keyRef: 'DSH_MEDIA_ARK_API_KEY',
      );
      expect(service.withModel('two', on: false).models, ['one']);
      expect(service.withModel('two', on: false).withModel('two', on: true).models, ['one', 'two']);
    });
  });

  group('new services from presets', () {
    test('the preset fills everything; the key gets its own reference', () {
      final service = mediaServiceFromPreset(preset: _preset(), catalog: _catalog(), existing: const []);
      expect(service, isNotNull);
      expect(
        (service!.id, service.provider, service.profile, service.enabled),
        ('ark_image', 'ark', 'ark-image', true),
      );
      expect(service.models, ['seedream']);
      expect(service.keyRef, 'DSH_MEDIA_ARK_API_KEY');
      expect(service.baseUrl, 'https://ark.cn-beijing.volces.com');
    });

    test('a second service of the same provider reuses its key, not a second entry', () {
      final image = mediaServiceFromPreset(preset: _preset(), catalog: _catalog(), existing: const [])!;
      final video = mediaServiceFromPreset(
        preset: _preset(
          id: 'ark-video',
          label: '火山方舟 · 视频',
          labelEn: 'Volcengine Ark · Video',
          profile: 'ark-video',
          models: const ['seedance'],
          kind: GenerateKind.video,
        ),
        catalog: _catalog(),
        existing: [image],
      )!;
      expect(video.keyRef, image.keyRef);
      expect(video.id, 'ark_video');
      expect(video.models, ['seedance']);
    });

    test('automatic key sharing never crosses origins even for the same provider', () {
      final image = mediaServiceFromPreset(preset: _preset(), catalog: _catalog(), existing: const [])!;
      final next = mediaServiceFromPreset(
        preset: _preset(),
        catalog: _catalog(),
        existing: [image.copyWith(baseUrl: 'https://other.example.test')],
      )!;
      expect(next.keyRef, isNot(image.keyRef));
      expect(mediaKeyDonor([image.copyWith(baseUrl: 'https://other.example.test')], _preset()), isNull);
    });

    test('asking for a separate account gets a distinct reference', () {
      final image = mediaServiceFromPreset(preset: _preset(), catalog: _catalog(), existing: const [])!;
      final second = mediaServiceFromPreset(
        preset: _preset(id: 'ark-image-2', provider: 'ark'),
        catalog: _catalog(),
        existing: [image],
        reuseKey: false,
      )!;
      expect(second.keyRef, 'DSH_MEDIA_ARK_2_API_KEY');
      expect(second.id, 'ark_image_2');
    });

    test('a preset whose models the catalogue no longer knows is not offered', () {
      expect(
        mediaServiceFromPreset(
          preset: _preset(models: const ['gone'], profile: 'no-such-profile'),
          catalog: _catalog(),
          existing: const [],
        ),
        isNull,
      );
    });

    test('the preset list is the plugin\'s, with the app list as fallback', () {
      expect(_preset().catalogModels(_catalog()).map((m) => m.id), ['seedream']);
      final service = mediaServiceFromPreset(preset: _preset(), catalog: _catalog(), existing: const [])!;
      expect(mediaServiceTitle(service, [_preset()], english: true), 'Volcengine Ark · Image');
      expect(mediaServiceTitle(service, [_preset()], english: false), '火山方舟 · 图片');
      expect(
        mediaServiceTitle(
          const MediaServiceConfig(
            id: 'x',
            label: '家里',
            provider: 'ark',
            baseUrl: 'https://ark.cn-beijing.volces.com',
            profile: 'ark-image',
            keyRef: 'DSH_MEDIA_ARK_API_KEY',
          ),
          [_preset()],
          english: true,
        ),
        '家里',
      );
    });
  });

  group('defaults', () {
    test('an image default leaves video and the legacy pair alone', () {
      final before = {'serviceId': 'office', 'modelId': 'gpt-image-2', 'videoServiceId': 'v', 'videoModelId': 'vid'};
      final after = mediaDefaultsWith(before, kind: GenerateKind.image, serviceId: 'ark_image', modelId: 'seedream');
      expect(after['serviceId'], 'office');
      expect(after['videoServiceId'], 'v');
      expect((after['imageServiceId'], after['imageModelId']), ('ark_image', 'seedream'));
    });

    test('null kind edits the legacy pair', () {
      final after = mediaDefaultsWith(const {'serviceId': 'old'}, serviceId: 'new', modelId: 'm');
      expect((after['serviceId'], after['modelId']), ('new', 'm'));
    });
  });
}
