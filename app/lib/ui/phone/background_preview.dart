import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../phone/phone_channel.dart';

/// A fixed, visible dialog surface. It owns decoded images, bypassing ImageCache.
class PhoneBackgroundPreviewDialog extends StatefulWidget {
  const PhoneBackgroundPreviewDialog({required this.channel, required this.taskId, this.enabled = true, super.key});

  final PhoneChannel channel;
  final int taskId;
  final bool enabled;

  @override
  State<PhoneBackgroundPreviewDialog> createState() => _PhoneBackgroundPreviewDialogState();
}

class _PhoneBackgroundPreviewDialogState extends State<PhoneBackgroundPreviewDialog> {
  late final AppLifecycleListener _lifecycle;
  StreamSubscription<PhonePreviewFrame?>? _subscription;
  Future<void> _transition = Future.value();
  bool _resumed = false;
  bool _routeCurrent = false;
  bool _visible = false;
  int _epoch = 0;
  int _imageRevision = 0;
  int _nativeGeneration = -1;
  int _nativeSequence = -1;
  String _state = 'waiting';
  ui.Image? _image;
  PhonePreviewFrame? _pending;
  bool _decoding = false;

  @override
  void initState() {
    super.initState();
    _resumed = WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(onStateChange: (state) {
      _resumed = state == AppLifecycleState.resumed;
      _syncVisibility();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // ModalRoute.of establishes a dependency on isCurrent; a covering route stops capture.
    _routeCurrent = ModalRoute.of(context)?.isCurrent == true;
    _syncVisibility();
  }

  @override
  void didUpdateWidget(PhoneBackgroundPreviewDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) _syncVisibility();
  }

  void _clearImage() {
    _imageRevision++;
    _pending = null;
    final old = _image;
    _image = null;
    old?.dispose();
  }

  Future<void> _cancelSubscription() async {
    final old = _subscription;
    _subscription = null;
    try {
      await old?.cancel();
    } on MissingPluginException {
      // A detached native engine has no remaining consumer to remove.
    } on PlatformException {
      // Native task/engine retirement also clears its preview consumer.
    }
  }

  void _syncVisibility() {
    final visible = widget.enabled && _resumed && _routeCurrent;
    if (_visible == visible) return;
    _visible = visible;
    final epoch = ++_epoch;
    _clearImage();
    _nativeGeneration = -1;
    _nativeSequence = -1;
    setState(() => _state = 'waiting');
    // Wait for the old EventChannel cancel before listening again on the same channel.
    _transition = _transition.then((_) async {
      await _cancelSubscription();
      if (!mounted || !_visible || _epoch != epoch) return;
      _subscription = widget.channel.previewFrames(widget.taskId).listen(
        (frame) { if (mounted && _visible && _epoch == epoch) _receive(frame); },
        onError: (Object _) {
          if (!mounted || !_visible || _epoch != epoch) return;
          _clearImage();
          setState(() => _state = 'unavailable');
        },
      );
    });
  }

  void _receive(PhonePreviewFrame? frame) {
    if (frame == null) {
      _clearImage();
      setState(() => _state = 'unavailable');
      return;
    }
    if (frame.taskId != widget.taskId || frame.generation < _nativeGeneration ||
        frame.generation == _nativeGeneration && frame.sequence <= _nativeSequence) {
      return;
    }
    if (frame.generation != _nativeGeneration) {
      _clearImage();
      setState(() => _state = 'waiting');
    }
    _nativeGeneration = frame.generation;
    _nativeSequence = frame.sequence;
    if (frame.state != 'frame') {
      _clearImage();
      setState(() => _state = frame.state);
      return;
    }
    _pending = frame; // one latest pending frame; a slow decoder never accumulates a queue
    unawaited(_decodeLatest());
  }

  Future<void> _decodeLatest() async {
    if (_decoding) return;
    _decoding = true;
    try {
      while (_pending != null) {
        final frame = _pending!;
        _pending = null;
        final epoch = _epoch;
        final revision = _imageRevision;
        ui.Codec? codec;
        ui.Image? decoded;
        try {
          codec = await ui.instantiateImageCodec(frame.imageBytes!, targetWidth: frame.width,
              targetHeight: frame.height, allowUpscaling: false);
          decoded = (await codec.getNextFrame()).image;
        } catch (_) {
          // No exception details or image bytes enter logs or diagnostics.
          if (mounted && _visible && _epoch == epoch && _imageRevision == revision && _pending == null) {
            _clearImage();
            setState(() => _state = 'unavailable');
          }
        } finally {
          codec?.dispose();
        }
        if (decoded == null) continue;
        if (!mounted || !_visible || _epoch != epoch || _imageRevision != revision) {
          decoded.dispose();
          continue;
        }
        final old = _image;
        setState(() { _image = decoded; _state = 'frame'; });
        old?.dispose();
      }
    } finally {
      _decoding = false;
    }
  }

  @override
  void dispose() {
    _visible = false;
    _epoch++;
    _clearImage();
    _lifecycle.dispose();
    _transition = _transition.then((_) => _cancelSubscription());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.phonePreviewTitle),
      content: SizedBox(
        width: 320,
        height: MediaQuery.sizeOf(context).height * 0.5,
        child: _image != null
            ? IgnorePointer(child: RawImage(image: _image, fit: BoxFit.contain, filterQuality: FilterQuality.low))
            : Center(child: Text(switch (_state) {
                'off' => l10n.phonePreviewOff,
                'inUse' => l10n.phonePreviewInUse,
                'unavailable' || 'protected' => l10n.phonePreviewUnavailable,
                _ => l10n.phonePreviewWaiting,
              }, textAlign: TextAlign.center)),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.commonClose))],
    );
  }
}
