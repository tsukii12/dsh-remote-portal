// How well she knows the person, in the few steps the room shows (docs/design/
// companion.md §6.5). Closeness itself is her state's (C303: at most +0.01 per
// six hours); these are only where the room starts to show it. Pro's rule layer
// (ADDENDUM-06 #3) may move the lines. stage.js `bondStep` keeps the same ones.

/// Closeness at which each step after the first begins.
const companionBondSteps = [0.03, 0.10, 0.30];

/// 0 just met, 1 getting to know each other, 2 close, 3 very close.
int companionBond(double closeness) => companionBondSteps.where((step) => closeness >= step).length;
