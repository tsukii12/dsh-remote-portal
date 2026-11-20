// v1.3 system selection adapter. Missing native code is unsupported, never a fake success.
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'native_effects.dart';

class NativeSelectedFile {
  const NativeSelectedFile({
    required this.name,
    required this.length,
    required this.openRead,
    this.mediaType = 'application/octet-stream',
  });
  final String name;
  final int? length;
  final String mediaType;
  final Stream<List<int>> Function() openRead;
}

abstract interface class NativeFilePlatform {
  Future<bool> supported();
  Future<List<NativeSelectedFile>> pick(PickFileEffect effect);
  Future<void> cancel(String owner);
}

class MethodNativeFilePlatform implements NativeFilePlatform {
  static const channel = MethodChannel('dsh/native-files');

  @override
  Future<bool> supported() async {
    try {
      final value = await channel.invokeMethod<Object?>('capabilities');
      return value is Map && value['files'] == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<List<NativeSelectedFile>> pick(PickFileEffect effect) async {
    final value = await channel.invokeMethod<Object?>('pick', {
      'owner': effect.request,
      'images': effect.images,
      if (effect.visual) 'visual': true,
      if (effect.own) 'own': true,
      'maxFiles': effect.maxFiles,
      'maxBytes': effect.maxBytes,
      'maxTotalBytes': effect.maxTotalBytes,
      'userGesture': true,
    });
    if (value == null) return const [];
    if (value is! List || value.length > effect.maxFiles) throw const FormatException('invalid selection');
    final files = <NativeSelectedFile>[];
    for (final raw in value) {
      if (raw is! Map ||
          raw['handle'] is! String ||
          raw['name'] is! String ||
          (raw['bytes'] != null && raw['bytes'] is! int)) {
        throw const FormatException('invalid selected file');
      }
      final handle = raw['handle'] as String;
      files.add(
        NativeSelectedFile(
          name: raw['name'] as String,
          length: raw['bytes'] as int?,
          mediaType: raw['mediaType'] is String ? raw['mediaType'] as String : 'application/octet-stream',
          openRead: () => _read(effect.request, handle),
        ),
      );
    }
    return files;
  }

  Stream<List<int>> _read(String owner, String handle) async* {
    while (true) {
      final value = await channel.invokeMethod<Object?>('read', {'owner': owner, 'handle': handle});
      if (value == null) return;
      if (value is! Uint8List || value.isEmpty || value.length > 64 * 1024) {
        throw const FormatException('invalid file chunk');
      }
      yield value;
    }
  }

  @override
  Future<void> cancel(String owner) async {
    try {
      await channel.invokeMethod<void>('cancel', {'owner': owner});
    } on MissingPluginException {
      // Unsupported platforms hold no selected resource.
    } on PlatformException {
      // Native ownership is also revoked on detach and expiry.
    }
  }
}

final nativeFilePlatformProvider = Provider<NativeFilePlatform>((ref) => MethodNativeFilePlatform());
final nativeFileSupportedProvider = FutureProvider<bool>((ref) => ref.watch(nativeFilePlatformProvider).supported());
