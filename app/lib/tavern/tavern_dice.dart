// 骰子 (docs/design/roleplay-ui.md §6, §11): the usual tabletop dice, rolled
// on the phone. What came up goes into the composer as one line the character
// reads like the rest of your message (as ST's /roll does in the chat).

import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The dice on offer.
const tavernDiceSides = [4, 6, 8, 10, 12, 20, 100];

const tavernDiceMaxCount = 10;
const tavernDiceMaxModifier = 20;

/// What to roll: [count] dice of [sides], plus [modifier].
class TavernDice {
  const TavernDice({this.count = 1, this.sides = 20, this.modifier = 0});

  final int count;
  final int sides;
  final int modifier;

  /// Tabletop notation: 1d20, 2d6+1, 3d8-2.
  String get notation =>
      '${count}d$sides${switch (modifier) {
        0 => '',
        > 0 => '+$modifier',
        _ => '$modifier',
      }}';

  int get lowest => count + modifier;
  int get highest => count * sides + modifier;

  TavernDice copyWith({int? count, int? sides, int? modifier}) => TavernDice(
    count: (count ?? this.count).clamp(1, tavernDiceMaxCount),
    sides: sides ?? this.sides,
    modifier: (modifier ?? this.modifier).clamp(-tavernDiceMaxModifier, tavernDiceMaxModifier),
  );

  TavernRoll roll(math.Random random) => TavernRoll(this, [for (var i = 0; i < count; i++) 1 + random.nextInt(sides)]);

  /// [notation] (1d20, 2d6+1, d8-2) back to the dice; null when it is not
  /// that.
  static TavernDice? parse(String notation) {
    final m = RegExp(r'^(\d*)d(\d+)([+-]\d+)?$').firstMatch(notation);
    if (m == null) return null;
    return TavernDice(
      count: m.group(1)!.isEmpty ? 1 : int.parse(m.group(1)!),
      sides: int.parse(m.group(2)!),
      modifier: m.group(3) == null ? 0 : int.parse(m.group(3)!),
    );
  }
}

/// One throw: each die's face, and the total with the modifier.
class TavernRoll {
  const TavernRoll(this.dice, this.faces);

  final TavernDice dice;
  final List<int> faces;

  int get total => faces.fold(0, (a, b) => a + b) + dice.modifier;

  /// How the total came about (3 + 5 + 1); null when one die says it all.
  String? get working {
    if (faces.length == 1 && dice.modifier == 0) return null;
    final modifier = switch (dice.modifier) {
      0 => '',
      > 0 => ' + ${dice.modifier}',
      _ => ' − ${-dice.modifier}',
    };
    return '${faces.join(' + ')}$modifier';
  }
}

/// The dice last chosen, for as long as the app is open.
class TavernDiceChoice extends Notifier<TavernDice> {
  @override
  TavernDice build() => const TavernDice();

  void set(TavernDice dice) => state = dice;
}

final tavernDiceProvider = NotifierProvider<TavernDiceChoice, TavernDice>(TavernDiceChoice.new);

/// Where the faces come from (seeded in tests).
final tavernDiceRandomProvider = Provider<math.Random>((ref) => math.Random());
