/// Decimal arithmetic for UI-generated steps. Schemastery validates separately;
/// generating a grid point must not add a binary-float rounding tail first.
num? decimalStepValue(num base, num step, int count) {
  if (!base.isFinite || !step.isFinite) return null;
  (BigInt, int) parts(num value) {
    final text = value.toString().toLowerCase().split('e');
    final mantissa = text.first;
    final dot = mantissa.indexOf('.');
    final fraction = dot < 0 ? 0 : mantissa.length - dot - 1;
    return (BigInt.parse(mantissa.replaceAll('.', '')), (text.length == 1 ? 0 : int.parse(text.last)) - fraction);
  }

  final a = parts(base);
  final b = parts(step);
  final exponent = a.$2 < b.$2 ? a.$2 : b.$2;
  final ten = BigInt.from(10);
  final coefficient = a.$1 * ten.pow(a.$2 - exponent) + b.$1 * ten.pow(b.$2 - exponent) * BigInt.from(count);
  final result = num.tryParse('${coefficient}e$exponent');
  return result != null && result.isFinite ? result : null;
}

/// A Material slider divides the entire range evenly. If the declared schema
/// step does not divide it, a free text/stepper editor is the honest control.
int? schemaSliderDivisions(num? min, num? max, num step) {
  if (min == null || max == null || !min.isFinite || !max.isFinite || !step.isFinite || step == 0 || max <= min) {
    return null;
  }
  final divisions = (max - min) / step.abs();
  if (!divisions.isFinite || divisions < 1 || divisions > 200 || divisions != divisions.roundToDouble()) return null;
  return divisions.toInt();
}
