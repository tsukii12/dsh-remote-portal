// Optional native adapter: absence is unsupported, never simulated success.
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

abstract interface class NativeMediaPlatform {
  Future<Set<String>> capabilities();
  Future<Object?> call(String method, Map<String, Object?> arguments);
  Stream<Object?> get events;
}

class MethodNativeMediaPlatform implements NativeMediaPlatform {
  static const _methods = MethodChannel('dsh/native-media');
  static const _events = EventChannel('dsh/native-media/events');
  @override
  Future<Set<String>> capabilities() async {
    try {
      final result = await _methods.invokeMethod<Object?>('capabilities');
      final features = result is Map ? result['features'] : null;
      if (features is! List) return const {};
      return features.whereType<String>().where({'audio', 'voice', 'overlay'}.contains).toSet();
    } on MissingPluginException {
      return const {};
    } on PlatformException {
      return const {};
    }
  }

  @override
  Future<Object?> call(String method, Map<String, Object?> arguments) =>
      _methods.invokeMethod<Object?>(method, arguments);
  @override
  Stream<Object?> get events => _events.receiveBroadcastStream();
}

final nativeMediaPlatformProvider = Provider<NativeMediaPlatform>((ref) => MethodNativeMediaPlatform());

class NativeFeatureState extends Notifier<List<String>> {
  @override
  List<String> build() => const [];
  void setFeatures(Set<String> features) {
    final sorted = features.toList()..sort();
    if (sorted.join(',') != state.join(',')) state = List.unmodifiable(sorted);
  }
}

final nativeFeatureStateProvider = NotifierProvider<NativeFeatureState, List<String>>(NativeFeatureState.new);
