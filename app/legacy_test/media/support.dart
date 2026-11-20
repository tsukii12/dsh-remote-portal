// Shared bits of the media tests: the synthetic fixtures (swap for Pro's live
// ones when they come), pictures drawn here so goldens show real images, a
// workspace reader serving them, the gallery channel, and a host's catalogue
// with the media plugin on.

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/media_generation.dart';
import 'package:dsh_app/state/risk_notice_store.dart';
import 'package:dsh_app/state/session_modes.dart';
import 'package:dsh_app/ui/chat/render/markdown_image.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

/// The fixture's transcript: `synthetic_header_image`, `synthetic_plain_image`,
/// `synthetic_video_running`, `synthetic_failed`.
ChatTranscript fixtureTranscript(String name) {
  final transcript = ChatTranscript();
  for (final line in File('test/media/fixtures/$name.jsonl').readAsLinesSync()) {
    if (line.trim().isEmpty) continue;
    transcript.apply(SessionLogEvent.fromJson(jsonDecode(line)));
  }
  return transcript;
}

/// The one generation call of a fixture.
ToolChatItem fixtureTool(String name) => fixtureTranscript(name).items.whereType<ToolChatItem>().single;

/// A meta as the plugin writes it, for cards drawn without a transcript.
MediaMeta mediaMeta({
  int n = 1,
  int width = 2048,
  int height = 2048,
  String aspect = '1:1',
  double? cost,
  String label = 'Seedream 5.0',
  String prompt = '画一只在窗台上打盹的橘猫',
  bool video = false,
  double? duration,
  int? asked,
}) => MediaMeta.fromJson({
  'v': 1,
  'rid': 'm_$n$aspect',
  'kind': video ? 'video' : 'image',
  'status': 'done',
  'items': [
    for (var i = 0; i < n; i++)
      {
        'path': '/root/workspace/generated/2026-10-28/${video ? 'clip' : 'pic'}-$aspect-$i.${video ? 'mp4' : 'png'}'
            .replaceAll(':', 'x'),
        'mime': video ? 'video/mp4' : 'image/png',
        'width': width,
        'height': height,
        'bytes': 2000000,
        'duration': ?duration,
        if (video) 'poster': '/root/workspace/generated/2026-10-28/clip-$aspect-$i.poster.png'.replaceAll(':', 'x'),
        if (video) 'codec': 'h264',
      },
  ],
  'request': {
    'provider': 'ark',
    'label': label,
    'aspect': aspect,
    'n': asked ?? n,
    if (video) 'seconds': duration ?? 5,
    if (video) 'resolution': '720p',
  },
  'prompt': prompt,
  'cost': ?(cost == null ? null : {'estimate': cost, 'currency': 'CNY'}),
})!;

/// Palettes for the drawn pictures: sky, ground, sun.
const _palettes = [
  (Color(0xFFF4B183), Color(0xFF7A4E3A), Color(0xFFFFE7B0)),
  (Color(0xFF9CC6E8), Color(0xFF3F6E5A), Color(0xFFFFF4C9)),
  (Color(0xFFC9B6E4), Color(0xFF4B3F6B), Color(0xFFFBE3F0)),
  (Color(0xFF8FD3C8), Color(0xFF2F5D62), Color(0xFFFFF1C1)),
];

/// A landscape-ish picture of [width] × [height] (PNG), palette [index].
Future<Uint8List> drawPicture(int width, int height, {int index = 0}) async {
  final (sky, ground, sun) = _palettes[index % _palettes.length];
  final size = Size(width.toDouble(), height.toDouble());
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Offset.zero & size,
    Paint()..shader = ui.Gradient.linear(Offset.zero, Offset(0, size.height), [sky, Color.lerp(sky, ground, 0.35)!]),
  );
  canvas.drawCircle(Offset(size.width * 0.68, size.height * 0.36), size.shortestSide * 0.13, Paint()..color = sun);
  final hill = Path()
    ..moveTo(0, size.height * 0.72)
    ..quadraticBezierTo(size.width * 0.35, size.height * 0.58, size.width, size.height * 0.7)
    ..lineTo(size.width, size.height)
    ..lineTo(0, size.height)
    ..close();
  canvas.drawPath(hill, Paint()..color = ground);
  final image = await recorder.endRecording().toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return bytes!.buffer.asUint8List();
}

/// Serves drawn pictures by file name; anything else is missing.
class FakeMediaReader implements WorkspaceImageReader {
  FakeMediaReader(this.images);

  final Map<String, Uint8List> images;
  final reads = <String>[];

  @override
  Future<LoadedImage> read(String sessionId, String path) async {
    reads.add(path);
    final bytes = images[path.split('/').last];
    if (bytes == null) throw const ArtifactError('missing');
    return RasterImage(MemoryImage(bytes));
  }
}

/// Pictures for every item of [metas] (posters for videos), drawn at a
/// small size of their aspect.
Future<Map<String, Uint8List>> picturesFor(List<MediaMeta> metas) async {
  final out = <String, Uint8List>{};
  var i = 0;
  for (final meta in metas) {
    for (final item in meta.items) {
      final a = item.aspect ?? 1;
      final w = a >= 1 ? 360 : (360 * a).round();
      final h = a >= 1 ? (360 / a).round() : 360;
      out[(item.isVideo ? item.poster! : item.path).split('/').last] = await drawPicture(w, h, index: i++);
    }
  }
  return out;
}

/// Decodes every picture drawn under [root] so a golden shows them.
Future<void> settlePictures(WidgetTester tester, Finder root) async {
  final images = find.descendant(of: root, matching: find.byType(Image));
  for (final element in images.evaluate().toList()) {
    final image = element.widget as Image;
    await tester.runAsync(() => precacheImage(image.image, element));
  }
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// `dsh/media` (the gallery): records saves.
List<MethodCall> mockGallery() {
  final calls = <MethodCall>[];
  const channel = MethodChannel('dsh/media');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async {
    calls.add(call);
    return 'Pictures/DSH Go/${(call.arguments as Map)['name']}';
  });
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  return calls;
}

class _NoRiskNotices implements RiskNoticeStore {
  @override
  Future<bool> silenced(String id) async => true;

  @override
  Future<void> silence(String id) async {}
}

/// The catalogue as a host publishes it (on the services field's metadata,
/// media-generation §4.3), with prices: the first-wave models, their ids the
/// synthetic transcripts' own.
Map<String, Object?> testCatalogMeta() => {
  'v': 1,
  'contract': 'dsh-go/media/catalog',
  'capabilities': {'image': true, 'video': true},
  'models': [
    {
      'id': 'doubao-seedream-5-0-pro',
      'label': 'Seedream 5.0',
      'kind': 'image',
      'ratios': ['1:1', '3:4', '4:3', '9:16', '16:9'],
      'qualities': ['1k', '2k', '4k'],
      'maxN': 4,
      'maxRefs': 4,
      'edit': true,
      'price': {'unit': 'image', 'amount': 0.3, 'currency': 'CNY'},
    },
    {
      'id': 'qwen-image-3.0-pro',
      'label': '通义千问图像 3.0',
      'kind': 'image',
      'ratios': ['1:1', '16:9'],
      'qualities': ['1k', '2k'],
      'maxN': 2,
    },
    {
      'id': 'doubao-seedance-2-0',
      'label': 'Seedance 2.0',
      'kind': 'video',
      'ratios': ['16:9', '9:16', '1:1'],
      'durations': [5, 10],
      'resolutions': ['720p', '1080p'],
      'maxRefs': 2,
      'frames': {'first': true, 'last': false},
      'price': {'unit': 'second', 'amount': 0.8, 'currency': 'CNY'},
    },
  ],
};

/// A configured service of the plugin's settings value.
Map<String, Object?> testMediaService(String id, String label, String models, {bool enabled = true}) => {
  'id': id,
  'label': label,
  'enabled': enabled,
  'provider': id,
  'models': models,
  'keyRef': '${id.toUpperCase()}_API_KEY',
};

/// 火山方舟 (Seedream, Seedance) and 阿里云百炼 (千问).
List<Map<String, Object?>> testMediaServices() => [
  testMediaService('ark', '火山方舟', 'doubao-seedream-5-0-pro,doubao-seedance-2-0'),
  testMediaService('bailian', '阿里云百炼', 'qwen-image-3.0-pro'),
];

/// The plugin's namespace of settings/describe: [catalog] on the services
/// field, [services] as its value.
SettingsNamespaceView testMediaNamespace({
  String ns = 'dsh-media',
  Object? catalog = const _Default(),
  List<Object?>? services,
}) => SettingsNamespaceView.fromJson({
  'ns': ns,
  'schema': {
    'type': 'object',
    'meta': {},
    'dict': {
      'services': {
        'type': 'transform',
        'meta': {
          'default': <Object?>[],
          // null: no catalogue at all.
          'extra': {'dsh-go/media/catalog': ?(catalog is _Default ? testCatalogMeta() : catalog)},
        },
        'inner': {
          'type': 'array',
          'meta': {},
          'inner': {'type': 'object', 'meta': {}, 'dict': {}},
        },
      },
    },
  },
  'value': {'services': services ?? testMediaServices()},
  'revision': 1,
});

class _Default {
  const _Default();
}

/// Every service's key is there.
const testMediaKeys = {
  'ARK_API_KEY': CredentialStatus(configured: true, writable: true),
  'BAILIAN_API_KEY': CredentialStatus(configured: true, writable: true),
  'HOME_API_KEY': CredentialStatus(configured: true, writable: true),
  'GOOGLE_API_KEY': CredentialStatus(configured: true, writable: true),
};

/// What the host offers with [testMediaNamespace]'s arguments.
MediaCatalog testMediaCatalogWith({Object? catalog = const _Default(), List<Object?>? services}) => mediaCatalogFrom({
  'dsh-media': testMediaNamespace(catalog: catalog, services: services),
}, credentials: testMediaKeys);

/// The usual host: both services, every key.
final testMediaCatalog = testMediaCatalogWith();

List<Override> mediaOverrides({
  MediaPluginState plugin = MediaPluginState.ready,
  SessionModes modes = const SessionModes(preset: 'workspace-write'),
  MediaCatalog? catalog,
}) => [
  mediaPluginProvider.overrideWithValue(plugin),
  mediaCatalogProvider.overrideWithValue(catalog ?? testMediaCatalog),
  sessionModesProvider.overrideWith((ref, id) => modes),
  riskNoticeStoreProvider.overrideWithValue(_NoRiskNotices()),
];
