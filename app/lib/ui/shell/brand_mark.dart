import 'package:flutter/material.dart';

import '../../state/app_info.dart';

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 28, this.color, this.tile = false});
  final double size;
  final Color? color;
  final bool tile;
  static const aspect = 1.0;
  static const visualCentre = Offset(0.5, 0.5);
  static Offset opticalShift(double size) => Offset.zero;
  @override
  Widget build(BuildContext context) => Semantics(
    label: AppInfo.wordmark,
    image: true,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.22),
      child: Image.asset('assets/yuremote/logo.png', width: size, height: size),
    ),
  );
}

class BrandLockup extends StatelessWidget {
  const BrandLockup({
    super.key,
    this.height = 20,
    this.fontSize,
    this.label = AppInfo.wordmark,
    this.color,
    this.glyphColor,
  });
  final double height;
  final double? fontSize;
  final String label;
  final Color? color;
  final Color? glyphColor;
  static const glyphScale = 1.75;
  static const gapScale = 0.36;
  static double wordInset(double size) => size * (glyphScale + gapScale);
  @override
  Widget build(BuildContext context) {
    final size = fontSize ?? height * 0.95;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        BrandMark(size: size * glyphScale),
        SizedBox(width: size * gapScale),
        Text(
          label,
          style: TextStyle(fontSize: size, fontWeight: FontWeight.w600, letterSpacing: 1.2, color: color),
        ),
      ],
    );
  }
}
