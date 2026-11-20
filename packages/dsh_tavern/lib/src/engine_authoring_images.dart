part of 'engine.dart';

final class _AcceptedAuthoringImage implements TavernAuthoringAcceptedImage {
  const _AcceptedAuthoringImage(this.value);
  final TavernAuthoringRenderResult value;
  @override
  String get requestId => value.requestId;
  @override
  String get captureId => value.captureId;
  @override
  String get draftId => value.draftId;
  @override
  int get draftRevision => value.draftRevision;
  @override
  String get physicalResourceId => value.physicalResourceId;
  @override
  List<String> get changeIds => value.changeIds;
  @override
  String get mimeType => value.mimeType!;
  @override
  int get pixelWidth => value.pixelWidth!;
  @override
  int get pixelHeight => value.pixelHeight!;
  @override
  Uint8List get bytes => value.bytes!;
}

final class _AuthoringImageBinding {
  const _AuthoringImageBinding(this.client, this.capability);
  final TavernAuthoringImageClient client;
  final TavernAuthoringImageCapability capability;

  Map<String, Object?> get descriptor => {
    'profile': capability.profile,
    'version': capability.version,
    'wireForm': capability.wireForm.name,
  };

  bool accepts(TavernAuthoringAcceptedImage image) =>
      capability.formats.contains(image.mimeType) &&
      image.bytes.length <= capability.maxImageBytes &&
      image.pixelWidth <= capability.maxPixelWidth &&
      image.pixelHeight <= capability.maxPixelHeight;

  Map<String, Object?> encode(TavernAuthoringAcceptedImage image, ModelCancellation cancellation) {
    final encoded = client.encodeAuthoringImage(capability, image);
    cancellation.check();
    final url = encoded['image_url'];
    if (encoded.length != 2 ||
        encoded['type'] != 'image_url' ||
        url is! Map<String, Object?> ||
        url.keys.any((key) => key != 'url' && key != 'detail') ||
        url['url'] != 'data:${image.mimeType};base64,${base64Encode(image.bytes)}' ||
        url.containsKey('detail') && !const ['auto', 'low', 'high'].contains(url['detail'])) {
      throw const TavernAuthoringException(
        'invalid_image_encoding',
        'The selected adapter did not encode this accepted image in its declared content-part format.',
      );
    }
    return {
      'type': 'image_url',
      'image_url': {'url': url['url']! as String, if (url.containsKey('detail')) 'detail': url['detail']! as String},
    };
  }
}

_AuthoringImageBinding? _captureAuthoringImageBinding(
  TavernModelClient client,
  TavernModelConfig config,
  ModelCancellation cancellation,
) {
  if (client is! TavernAuthoringImageClient) {
    return null;
  }
  final imageClient = client as TavernAuthoringImageClient;
  final capability = imageClient.imageInputFor(config);
  cancellation.check();
  if (capability == null) {
    return null;
  }
  if (capability.baseUrl != config.baseUrl ||
      capability.model != config.model ||
      capability.deepseek != config.deepseek ||
      capability.thinking != config.thinking ||
      capability.profile.isEmpty ||
      capability.version.isEmpty ||
      capability.maxImageBytes < 1 ||
      capability.maxPixelWidth < 1 ||
      capability.maxPixelHeight < 1) {
    throw const TavernAuthoringException(
      'unsupported_image_input',
      'The image adapter supplied an invalid capability or one for another model configuration.',
    );
  }
  if (!capability.formats.contains('image/png') && !capability.formats.contains('image/jpeg')) {
    return null;
  }
  return _AuthoringImageBinding(imageClient, capability);
}

TavernAuthoringRenderRequest _authoringRenderToolRequest(
  _AuthoringRunRecord record,
  String receiptId,
  Map<String, Object?> parameters,
) {
  if (!record.canRender) {
    throw const TavernAuthoringException('unsupported_tool', 'This run has no supported image rendering adapter.');
  }
  _authoringToolKeys(parameters, const {'changeIds'});
  final selection = parameters['changeIds'];
  if (selection is! List<Object?> ||
      selection.any((id) => id is! String || id.isEmpty) ||
      selection.toSet().length != selection.length) {
    _authoringInvalid('Supply an explicit list of distinct changeIds.');
  }
  final context = TavernAuthoringRenderContext.fromJson(record.input['renderContext']! as Map<String, Object?>);
  return TavernAuthoringRenderRequest(
    requestId: '${record.runId}:render:$receiptId',
    draftId: record.draftId,
    draftRevision: record.revision,
    physicalResourceId: context.physicalResourceId,
    changeIds: selection.cast<String>().toList(),
    viewportWidth: context.viewportWidth,
    viewportHeight: context.viewportHeight,
    devicePixelRatio: context.devicePixelRatio,
    theme: context.theme,
    mode: context.mode,
    samples: context.samples,
  );
}

Map<String, Object?> _authoringRenderReceipt(TavernAuthoringRenderResult rendered) => {
  'requestId': rendered.requestId,
  'captureId': rendered.captureId,
  'draftId': rendered.draftId,
  'draftRevision': rendered.draftRevision,
  'physicalResourceId': rendered.physicalResourceId,
  'changeIds': rendered.changeIds,
  'mode': rendered.mode.name,
  'status': rendered.status.name,
  'mimeType': ?rendered.mimeType,
  'pixelWidth': ?rendered.pixelWidth,
  'pixelHeight': ?rendered.pixelHeight,
  if (rendered.bytes case final bytes?) 'byteLength': bytes.length,
  'issues': [
    for (final issue in rendered.issues) {'type': issue.type, 'message': issue.message},
  ],
};
