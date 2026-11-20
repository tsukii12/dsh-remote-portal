import 'dart:convert';
import 'dart:typed_data';

import 'api.dart' show TavernModelConfig;

enum TavernAuthoringImageWireForm { openAiChatImageUrl }

/// An actual adapter's statement for one selected configuration. The engine
/// binds this value to that client and the run's captured configuration; this
/// descriptor does not establish support by an online provider.
final class TavernAuthoringImageCapability {
  TavernAuthoringImageCapability({
    required this.baseUrl,
    required this.model,
    required this.deepseek,
    required this.thinking,
    required this.profile,
    required this.version,
    required Set<String> formats,
    required this.maxImageBytes,
    required this.maxPixelWidth,
    required this.maxPixelHeight,
    this.wireForm = TavernAuthoringImageWireForm.openAiChatImageUrl,
  }) : formats = Set.unmodifiable(formats);

  final String baseUrl, model, profile, version;
  final bool deepseek, thinking;
  final TavernAuthoringImageWireForm wireForm;
  final Set<String> formats;
  final int maxImageBytes, maxPixelWidth, maxPixelHeight;
}

/// Only engine-accepted, decoded render results reach the image adapter.
/// The image owns its immutable bytes; an encoder cannot change a receipt's
/// capture identity or redirect the next request to another image.
abstract interface class TavernAuthoringAcceptedImage {
  String get requestId;
  String get captureId;
  String get draftId;
  int get draftRevision;
  String get physicalResourceId;
  List<String> get changeIds;
  String get mimeType;
  int get pixelWidth;
  int get pixelHeight;
  Uint8List get bytes;
}

/// Implement on the same TavernModelClient that actually sends the run.
/// The default client makes no image capability claim. Lookup is synchronous,
/// performs no I/O and must not call the configuration's key supplier.
abstract interface class TavernAuthoringImageClient {
  TavernAuthoringImageCapability? imageInputFor(TavernModelConfig config);

  /// Returns one content part for the declared wire form, never a complete
  /// message or request. The engine checks that it encodes this exact image.
  Map<String, Object?> encodeAuthoringImage(
    TavernAuthoringImageCapability capability,
    TavernAuthoringAcceptedImage image,
  );
}

/// Encodes an actual image content part. This helper alone does not declare
/// support by any client, provider or model.
Map<String, Object?> encodeAuthoringOpenAiImage(TavernAuthoringAcceptedImage image, {String? detail}) {
  if (detail != null && detail != 'auto' && detail != 'low' && detail != 'high') {
    throw ArgumentError.value(detail, 'detail', 'Use auto, low or high.');
  }
  return {
    'type': 'image_url',
    'image_url': {'url': 'data:${image.mimeType};base64,${base64Encode(image.bytes)}', 'detail': ?detail},
  };
}
