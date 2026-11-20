// Pieces of the composer while listening: the live level bars and the cancel
// key that takes the ＋ key's place.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/l10n.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';

/// 听写中的音量条:5 根圆头竖条,最新的音量从右边进来。最高 24,比两侧
/// 的 36 圆键矮;占发送键左边那个 36 高的小件位。
class VoiceWaveform extends StatefulWidget {
  const VoiceWaveform({super.key, required this.level, this.active = true});

  final ValueListenable<double> level;

  /// False while transcribing: the bars rest flat.
  final bool active;

  static const bars = 5;
  static const barWidth = 3.0;
  static const gap = 3.5;
  static const minHeight = 4.0;
  static const maxHeight = 24.0;
  static const width = bars * barWidth + (bars - 1) * gap + 8;

  @override
  State<VoiceWaveform> createState() => _VoiceWaveformState();
}

class _VoiceWaveformState extends State<VoiceWaveform> {
  final List<double> _history = List.filled(VoiceWaveform.bars, 0, growable: true);

  @override
  void initState() {
    super.initState();
    widget.level.addListener(_onLevel);
  }

  @override
  void didUpdateWidget(VoiceWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.level != widget.level) {
      oldWidget.level.removeListener(_onLevel);
      widget.level.addListener(_onLevel);
    }
  }

  @override
  void dispose() {
    widget.level.removeListener(_onLevel);
    super.dispose();
  }

  void _onLevel() {
    setState(() {
      _history
        ..removeAt(0)
        ..add(widget.level.value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final color = colors.onSurface.withValues(alpha: widget.active ? 0.6 : 0.25);
    final duration = AppMotion.of(context, AppMotion.press);
    return Semantics(
      label: widget.active ? l10n.chatListening : l10n.chatTranscribing,
      child: SizedBox(
        width: VoiceWaveform.width,
        height: 36,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < VoiceWaveform.bars; i++) ...[
              if (i > 0) const SizedBox(width: VoiceWaveform.gap),
              AnimatedContainer(
                duration: duration,
                curve: AppMotion.std,
                width: VoiceWaveform.barWidth,
                height: widget.active
                    ? VoiceWaveform.minHeight + _history[i] * (VoiceWaveform.maxHeight - VoiceWaveform.minHeight)
                    : VoiceWaveform.minHeight,
                decoration: ShapeDecoration(color: color, shape: const StadiumBorder()),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 听写中替换 ＋ 键的 ✕:同样 36 的圆、同样的淡底,镜像右边的停止键。
class VoiceCancelKey extends StatelessWidget {
  const VoiceCancelKey({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: l10n.chatCancelVoiceInput,
      child: InkResponse(
        onTap: () {
          HapticFeedback.selectionClick();
          onPressed();
        },
        radius: 22,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(color: scheme.onSurface.withValues(alpha: 0.06), shape: BoxShape.circle),
          child: Icon(AppIcons.close, size: 22, color: scheme.onSurface),
        ),
      ),
    );
  }
}
