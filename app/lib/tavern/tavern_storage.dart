// 酒馆设置 › 数据 › 存储占用 (docs/design/roleplay-roadmap.md P1, 设置重组):
// how much room `<app support>/tavern` takes, by what is in it.

import 'dart:io';
import 'dart:isolate';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// What the tavern's folder holds, in bytes.
class TavernStorage {
  const TavernStorage({this.characters = 0, this.chats = 0, this.live2d = 0, this.other = 0});

  /// Cards, portraits and their import reports (`characters/`, `character-index/`).
  final int characters;

  /// The database: chats, presets, personas, variables (`tavern.sqlite3*`).
  final int chats;

  /// Live2D figures (`live2d/`).
  final int live2d;

  /// Chat backgrounds, lorebooks, regex, settings, anything else.
  final int other;

  int get total => characters + chats + live2d + other;
}

/// Measures [directory] off the UI isolate; a missing folder is empty.
Future<TavernStorage> measureTavernStorage(String directory) => Isolate.run(() => _measure(directory));

TavernStorage _measure(String directory) {
  final root = Directory(directory);
  if (!root.existsSync()) return const TavernStorage();
  var characters = 0, chats = 0, live2d = 0, other = 0;
  for (final entity in root.listSync(followLinks: false)) {
    final name = entity.uri.pathSegments.lastWhere((s) => s.isNotEmpty, orElse: () => '');
    final size = _size(entity);
    if (name == 'characters' || name == 'character-index') {
      characters += size;
    } else if (name.startsWith('tavern.sqlite3')) {
      chats += size;
    } else if (name == 'live2d') {
      live2d += size;
    } else {
      other += size;
    }
  }
  return TavernStorage(characters: characters, chats: chats, live2d: live2d, other: other);
}

/// [entity]'s bytes, a folder's all the way down; what can't be read counts nothing.
int _size(FileSystemEntity entity) {
  try {
    if (entity is File) return entity.lengthSync();
    if (entity is! Directory) return 0;
    var sum = 0;
    for (final inner in entity.listSync(recursive: true, followLinks: false)) {
      if (inner is File) {
        try {
          sum += inner.lengthSync();
        } on FileSystemException {
          // Gone or locked while counting.
        }
      }
    }
    return sum;
  } on FileSystemException {
    return 0;
  }
}

/// The tavern's folder measured; refreshed each time 酒馆设置 is opened.
final tavernStorageProvider = FutureProvider.autoDispose<TavernStorage>((ref) async {
  final support = await getApplicationSupportDirectory();
  return measureTavernStorage('${support.path}/tavern');
}, retry: (_, _) => null);
