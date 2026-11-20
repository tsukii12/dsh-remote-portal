// meta["dsh-go/media"], contract v1 (docs/design/media-generation.md §2.5 ①).

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

void main() {
  const full = {
    'v': 1,
    'rid': 'm_7f3a9c',
    'kind': 'image',
    'status': 'done',
    'items': [
      {
        'path': '/root/proj/generated/2026-10-28/cat-1.png',
        'mime': 'image/png',
        'width': 2048,
        'height': 2048,
        'bytes': 3145728,
      },
    ],
    'request': {
      'provider': 'ark',
      'model': 'doubao-seedream-5-0-pro',
      'label': 'Seedream 5.0',
      'aspect': '1:1',
      'n': 2,
      'quality': '2k',
      'seconds': 5,
      'refs': 1,
    },
    'prompt': '画一只在窗台上打盹的橘猫',
    'revisedPrompt': '午后逆光，一只橘猫蜷在木窗台上打盹……',
    'cost': {'estimate': 0.6, 'currency': 'CNY'},
    'provenance': {'visibleMark': false, 'c2pa': true, 'implicitLabel': true},
  };

  test('every field of the contract example', () {
    final meta = MediaMeta.fromToolMeta({mediaMetaKey: full, 'other': 1})!;
    expect(meta.version, 1);
    expect(meta.rid, 'm_7f3a9c');
    expect(meta.kind, MediaKind.image);
    expect(meta.status, MediaStatus.done);
    final item = meta.items.single;
    expect(item.path, '/root/proj/generated/2026-10-28/cat-1.png');
    expect(item.name, 'cat-1.png');
    expect(item.mime, 'image/png');
    expect(item.aspect, 1);
    expect(item.bytes, 3145728);
    expect(item.isVideo, isFalse);
    expect(meta.request.provider, 'ark');
    expect(meta.request.modelName, 'Seedream 5.0');
    expect(meta.request.aspect, '1:1');
    expect(meta.request.ratio, 1);
    expect(meta.request.n, 2);
    expect(meta.request.quality, '2k');
    expect(meta.request.seconds, 5);
    expect(meta.request.refs, 1);
    expect(meta.prompt, '画一只在窗台上打盹的橘猫');
    expect(meta.promptToCopy, startsWith('午后逆光'));
    expect(meta.cost!.estimate, 0.6);
    expect(meta.cost!.currency, 'CNY');
    expect(meta.provenance!.c2pa, isTrue);
    expect(meta.paths, ['/root/proj/generated/2026-10-28/cat-1.png']);
  });

  test('a video: duration, poster, codec, job', () {
    final meta = MediaMeta.fromJson({
      'v': 1,
      'kind': 'video',
      'status': 'done',
      'job': 'media-1c2d',
      'items': [
        {
          'path': '/w/clip-1.mp4',
          'mime': 'video/mp4',
          'width': 1280,
          'height': 720,
          'duration': 5.0,
          'poster': '/w/clip-1.poster.jpg',
          'codec': 'h264',
        },
      ],
    })!;
    expect(meta.job, 'media-1c2d');
    expect(meta.items.single.isVideo, isTrue);
    expect(meta.items.single.duration, 5);
    expect(meta.items.single.codec, 'h264');
    expect(meta.paths, ['/w/clip-1.mp4', '/w/clip-1.poster.jpg']);
  });

  test('running and failed carry no items; the cost is optional', () {
    final running = MediaMeta.fromJson({'v': 1, 'kind': 'video', 'status': 'running', 'job': 'j'})!;
    expect(running.status, MediaStatus.running);
    expect(running.items, isEmpty);
    expect(running.cost, isNull);
    final failed = MediaMeta.fromJson({
      'v': 1,
      'kind': 'image',
      'status': 'failed',
      'error': {'code': 'policy', 'text': '描述未通过内容审核'},
    })!;
    expect(failed.error!.code, 'policy');
    expect(failed.error!.text, '描述未通过内容审核');
  });

  test('what isn\'t a card', () {
    expect(MediaMeta.fromToolMeta(null), isNull);
    expect(MediaMeta.fromToolMeta({'dsh-go/view': {}}), isNull);
    expect(MediaMeta.fromJson({'v': 0, 'kind': 'image', 'items': full['items']}), isNull);
    expect(MediaMeta.fromJson({'v': 1, 'status': 'done', 'items': []}), isNull);
    expect(MediaMeta.fromJson({'v': 1, 'kind': 'image', 'status': 'done', 'items': []}), isNull);
    // Items without a path are dropped; a negative cost is no cost.
    final meta = MediaMeta.fromJson({
      'v': 1,
      'items': [
        {'path': ''},
        {'path': '/a.png', 'width': -1},
      ],
      'cost': {'estimate': -1},
    })!;
    expect(meta.kind, MediaKind.image);
    expect(meta.items.single.width, isNull);
    expect(meta.cost, isNull);
  });
}
