// The spring tokens and how a release lands on them.
//
//   flutter test test/theme/motion_test.dart

import 'package:dsh_app/ui/theme/motion.dart';
import 'package:flutter/physics.dart';
import 'package:flutter_test/flutter_test.dart';

/// Where [simulation] goes, sampled at 240 Hz until it says it is done.
List<double> _path(Simulation simulation) {
  var t = 0.0;
  final path = <double>[];
  while (!simulation.isDone(t)) {
    path.add(simulation.x(t));
    t += 1 / 240;
  }
  return path..add(simulation.x(t));
}

void main() {
  test('the tokens are the published durations and bounces', () {
    expect(AppMotion.pressSpring.duration, const Duration(milliseconds: 150));
    expect(AppMotion.layoutSpring.duration, const Duration(milliseconds: 350));
    expect(AppMotion.sheetSpring.duration, const Duration(milliseconds: 500));
    expect(AppMotion.flingSpring.duration, const Duration(milliseconds: 500));
    for (final spring in [AppMotion.pressSpring, AppMotion.layoutSpring, AppMotion.sheetSpring]) {
      expect(spring.bounce, closeTo(0, 1e-9));
    }
    expect(AppMotion.flingSpring.bounce, closeTo(0.15, 1e-9));
  });

  test('a landing never passes its target, however fast the release', () {
    for (final velocity in [0.0, 0.5, 5.0, 50.0]) {
      final path = _path(AppMotion.settle(AppMotion.sheetSpring, 0.8, 1, velocity));
      expect(path.every((x) => x <= 1), isTrue, reason: 'velocity $velocity');
      expect(path.last, 1, reason: 'stops exactly on the target');
    }
  });

  test('without landing the release keeps all its speed', () {
    final simulation = AppMotion.settle(AppMotion.sheetSpring, 0.2, 0, -5, landing: false);
    expect(simulation.dx(0), closeTo(-5, 1e-6));
    expect(simulation.x(0.1), lessThan(0), reason: 'off screen, passing is fine');
  });

  test('a release towards the target below the limit keeps its speed', () {
    expect(AppMotion.settle(AppMotion.sheetSpring, 0, 1, 2).dx(0), closeTo(2, 1e-6));
  });

  test('the rubber band gives ever less and never reaches its limit', () {
    expect(AppMotion.rubberBand(0), 0);
    expect(AppMotion.rubberBand(100), closeTo(25.6, 0.1));
    expect(AppMotion.rubberBand(200), greaterThan(AppMotion.rubberBand(100)));
    expect(AppMotion.rubberBand(200) - AppMotion.rubberBand(100), lessThan(AppMotion.rubberBand(100)));
    expect(AppMotion.rubberBand(1e6), lessThan(48));
    expect(AppMotion.rubberBand(1e6), closeTo(48, 0.1));
  });

  test('done means close by the extent, in the time the spring promises', () {
    final ratio = AppMotion.settle(AppMotion.sheetSpring, 1, 0, 0);
    final pixels = AppMotion.settle(AppMotion.sheetSpring, 400, 0, 0, extent: 400);
    expect(ratio.isDone(0.8), isTrue);
    expect(ratio.isDone(0.3), isFalse);
    expect(pixels.isDone(0.8), isTrue);
    expect(pixels.isDone(0.3), isFalse);
  });
}
