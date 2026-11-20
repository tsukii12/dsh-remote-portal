// The bars above the composer as one deck of cards: the todo bar, the goal
// bar, the activity strip and a plugin's status line, folded into the front
// card's row with the others peeking above it, or laid out one above another.
// A tap on the folded deck spreads it; the round fold button beside the
// spread deck's top card folds it again (remembered). Swiped up or down, the folded deck brings another card
// to the front.

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../l10n/l10n.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import 'dock_pill.dart';

/// 「叠起」 or 「展开」 the dock, remembered; folded by default.
class DockFoldController extends Notifier<bool> {
  static const key = 'chat_dock_folded';

  late Future<void> _loaded;

  @override
  bool build() {
    _loaded = _load();
    return true;
  }

  Future<void> _load() async {
    try {
      final stored = (await SharedPreferences.getInstance()).getBool(key);
      if (stored != null && ref.mounted) state = stored;
    } catch (_) {
      // No preferences backend: the default.
    }
  }

  /// Applies after the stored value is in, so a late load can't undo it.
  Future<void> set(bool folded) async {
    await _loaded;
    if (!ref.mounted) return;
    state = folded;
    try {
      await (await SharedPreferences.getInstance()).setBool(key, folded);
    } catch (_) {
      // Kept for this run only.
    }
  }
}

final dockFoldedProvider = NotifierProvider<DockFoldController, bool>(DockFoldController.new);

/// The deck's geometry, shared with its tests.
abstract final class DockStackMetrics {
  /// How much of each card behind shows above the one in front of it.
  static const peek = 6.0;

  /// Cards behind the front one that show; the rest hide behind the last.
  static const peeks = 2;

  /// Each card further back is this much smaller.
  static const shrink = 0.05;

  /// And this much fainter.
  static const fade = 0.18;

  /// Between the front card and [DockStack.accessory].
  static const accessoryGap = 8.0;

  /// The round fold button beside the spread deck's top card (as high as a bar).
  static const foldSize = DockMetrics.height;

  /// A swipe this long brings the next card to the front.
  static const turnDistance = 48.0;

  /// A flick this fast does too, however short.
  static const turnVelocity = 300.0;
}

/// The docked bars, folded or spread ([dockFoldedProvider]).
///
/// [cards] are the bars' slots from the top down, each with
/// [DockMetrics.gap] under it and 0 high while it has nothing to show; the
/// lowest one showing is the front card, until a swipe on the folded deck
/// brings another one forward (down: the next one behind; up: the back one).
/// Cards coming or going put the lowest one in front again. [accessory] sits
/// right of the front card and is as high as it (「自动允许中」 beside the
/// activity strip): it stays tappable on the folded deck. With fewer than two
/// cards showing there is nothing to fold and the deck is the plain column.
/// Spread, a round fold button sits right of the top card: no row of its own.
class DockStack extends ConsumerStatefulWidget {
  const DockStack({super.key, required this.cards, this.accessory});

  final List<Widget> cards;
  final Widget? accessory;

  @override
  ConsumerState<DockStack> createState() => _DockStackState();
}

class _DockStackState extends ConsumerState<DockStack> with TickerProviderStateMixin {
  /// 0 folded, 1 spread. It follows the preference alone: with fewer than two
  /// cards both layouts are the same column.
  late final AnimationController _spread = AnimationController(
    vsync: this,
    value: ref.read(dockFoldedProvider) ? 0 : 1,
  );
  late final CurvedAnimation _curve = CurvedAnimation(parent: _spread, curve: AppMotion.glide);

  /// Cards brought forward by swipes ([RenderDockStack.turn]); between whole
  /// numbers while one moves.
  late final AnimationController _turn = AnimationController.unbounded(vsync: this);
  double _swipeFrom = 0;

  /// The cards showing, by index, after the last layout.
  List<int> _shown = const [];

  @override
  void dispose() {
    _curve.dispose();
    _spread.dispose();
    _turn.dispose();
    super.dispose();
  }

  void _onShown(List<int> shown) {
    if (!mounted || listEquals(shown, _shown)) return;
    setState(() => _shown = shown);
    // Another set of cards: the lowest one is in front again.
    _turn.value = 0;
  }

  void _fold(bool folded) => ref.read(dockFoldedProvider.notifier).set(folded);

  void _swipeStart(DragStartDetails _) {
    _turn.stop();
    _swipeFrom = _turn.value.roundToDouble();
  }

  void _swipe(DragUpdateDetails details) {
    // Down pulls the next card forward; one card a swipe.
    final next = _turn.value + details.primaryDelta! / DockStackMetrics.turnDistance;
    _turn.value = next.clamp(_swipeFrom - 1, _swipeFrom + 1);
  }

  void _swipeEnd(DragEndDetails details) {
    final v = details.primaryVelocity ?? 0;
    final moved = _turn.value - _swipeFrom;
    final target = v > DockStackMetrics.turnVelocity || moved > 0.35
        ? _swipeFrom + 1
        : v < -DockStackMetrics.turnVelocity || moved < -0.35
        ? _swipeFrom - 1
        : _swipeFrom;
    if (target != _swipeFrom) HapticFeedback.selectionClick();
    _turnTo(target);
  }

  void _turnTo(double target) => _turn.animateTo(
    target,
    duration: AppMotion.of(context, AppMotion.standard),
    curve: AppMotion.glide,
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final deck = _shown.length >= 2;
    final preference = ref.watch(dockFoldedProvider);
    final folded = deck && preference;
    _spread.duration = AppMotion.of(context, AppMotion.emphasized);
    if (preference && _spread.status != AnimationStatus.reverse && _spread.value > 0) {
      _spread.reverse();
    } else if (!preference && _spread.status != AnimationStatus.forward && _spread.value < 1) {
      _spread.forward();
    }
    final accessory = widget.accessory;
    final layout = AnimatedBuilder(
      animation: Listenable.merge([_curve, _turn]),
      builder: (context, _) => _DockStackLayout(
        spread: _curve.value,
        turn: _turn.value,
        hasAccessory: accessory != null,
        onShown: _onShown,
        children: [
          // Folded, the deck takes the tap: the cards neither answer it nor read out.
          for (final card in widget.cards)
            IgnorePointer(
              ignoring: folded,
              child: ExcludeSemantics(excluding: folded, child: card),
            ),
          ?accessory,
          ExcludeSemantics(
            excluding: !deck || folded,
            child: _FoldButton(onTap: () => _fold(true)),
          ),
        ],
      ),
    );
    // One shape folded or spread, only the callbacks change: a different
    // parent would mount the cards afresh and replay their rise.
    return Semantics(
      button: folded ? true : null,
      label: folded ? l10n.chatDockFolded(_shown.length) : null,
      onTapHint: folded ? l10n.chatDockSpread : null,
      onTap: folded ? () => _fold(false) : null,
      customSemanticsActions: folded
          ? {
              CustomSemanticsAction(label: l10n.chatDockNext): () => _turnTo(_turn.value.roundToDouble() + 1),
              CustomSemanticsAction(label: l10n.chatDockPrevious): () => _turnTo(_turn.value.roundToDouble() - 1),
            }
          : null,
      child: GestureDetector(
        behavior: folded ? HitTestBehavior.opaque : HitTestBehavior.deferToChild,
        onTap: folded ? () => _fold(false) : null,
        onVerticalDragStart: folded ? _swipeStart : null,
        onVerticalDragUpdate: folded ? _swipe : null,
        onVerticalDragEnd: folded ? _swipeEnd : null,
        child: layout,
      ),
    );
  }
}

/// The round fold button beside the spread deck's top card.
class _FoldButton extends StatelessWidget {
  const _FoldButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: context.l10n.chatDockFold,
      excludeSemantics: true,
      onTap: onTap,
      child: GlassSurface(
        key: const ValueKey('dock-fold'),
        tier: GlassTier.chrome,
        stadium: true,
        // One backdrop sample with the deck's bars.
        grouped: true,
        onTap: onTap,
        child: SizedBox.square(
          dimension: DockStackMetrics.foldSize,
          child: Icon(AppIcons.foldTurns, size: DockGlyph.iconSize, color: colors.onSurfaceVariant),
        ),
      ),
    );
  }
}

class _DockStackLayout extends MultiChildRenderObjectWidget {
  const _DockStackLayout({
    required this.spread,
    required this.turn,
    required this.hasAccessory,
    required this.onShown,
    required super.children,
  });

  final double spread;
  final double turn;
  final bool hasAccessory;
  final ValueChanged<List<int>> onShown;

  @override
  RenderDockStack createRenderObject(BuildContext context) =>
      RenderDockStack(spread: spread, turn: turn, hasAccessory: hasAccessory, onShown: onShown);

  @override
  void updateRenderObject(BuildContext context, RenderDockStack renderObject) {
    renderObject
      ..spread = spread
      ..turn = turn
      ..hasAccessory = hasAccessory
      ..onShown = onShown;
  }
}

class DockStackParentData extends ContainerBoxParentData<RenderBox> {
  /// Uniform scale about the card's top centre.
  double scale = 1;
  double opacity = 1;

  /// How much of the card shows, from its top (the rest is behind the front card).
  double? clipHeight;

  /// Paint order: the higher, the further back. Null: not drawn (0 high).
  double? depth;

  final clipHandle = LayerHandle<ClipRectLayer>();
  final transformHandle = LayerHandle<TransformLayer>();
  final opacityHandle = LayerHandle<OpacityLayer>();

  Matrix4 transformFor(Size size) {
    final o = offset;
    if (scale == 1) return Matrix4.translationValues(o.dx, o.dy, 0);
    final cx = size.width / 2;
    return Matrix4.translationValues(o.dx + cx * (1 - scale), o.dy, 0)..scaleByDouble(scale, scale, 1, 1);
  }
}

/// Where a card goes in one arrangement of the deck.
typedef _Place = ({double y, double scale, double opacity, double clip, double depth});

/// Lays the cards out between folded ([spread] 0) and spread (1).
///
/// Spread, the cards stand one above another as a column. Folded, the front
/// card sits at the bottom and each card behind it rises
/// [DockStackMetrics.peek] above the next one in, [DockStackMetrics.shrink]
/// smaller and [DockStackMetrics.fade] fainter, cut off where the card in
/// front of it begins. Every card moves straight between its places; the
/// deck's height follows.
///
/// The front card is the lowest one showing, [turn] cards further round: each
/// whole turn brings the next card behind it to the front and sends it to the
/// back. Between two whole turns the folded deck is between those two
/// arrangements, the card changing places passing behind the others halfway.
///
/// The bars grow in and out on their own ([DockSlot], the activity strip's
/// rise): a card counts by how much of a bar's height it has, so a card
/// rising to the front slides over the one it replaces instead of the deck
/// jumping.
class RenderDockStack extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, DockStackParentData>, RenderBoxContainerDefaultsMixin<RenderBox, DockStackParentData> {
  RenderDockStack({required this._spread, required this._turn, required this._hasAccessory, required this.onShown});

  double get spread => _spread;
  double _spread;
  set spread(double value) {
    if (value == _spread) return;
    _spread = value;
    markNeedsLayout();
  }

  double get turn => _turn;
  double _turn;
  set turn(double value) {
    if (value == _turn) return;
    _turn = value;
    markNeedsLayout();
  }

  bool get hasAccessory => _hasAccessory;
  bool _hasAccessory;
  set hasAccessory(bool value) {
    if (value == _hasAccessory) return;
    _hasAccessory = value;
    markNeedsLayout();
  }

  ValueChanged<List<int>> onShown;
  List<int>? _reported;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! DockStackParentData) child.parentData = DockStackParentData();
  }

  @override
  bool get isRepaintBoundary => false;

  List<RenderBox> get _children {
    final all = <RenderBox>[];
    var child = firstChild;
    while (child != null) {
      all.add(child);
      child = childAfter(child);
    }
    return all;
  }

  /// The cards showing front to back after [turns] whole turns.
  static List<int> order(List<int> shown, int turns) {
    final n = shown.length;
    if (n == 0) return const [];
    final lowestFirst = shown.reversed.toList();
    return [for (var j = 0; j < n; j++) lowestFirst[(j + turns) % n]];
  }

  @override
  void performLayout() {
    final width = constraints.maxWidth;
    final all = _children;
    final fold = all.isNotEmpty ? all.removeLast() : null;
    final accessory = hasAccessory && all.isNotEmpty ? all.removeLast() : null;
    final cards = all;
    for (final card in cards) {
      // Probe visibility at the last settled width. A full-width probe can
      // unwrap todo rows and clamp their scroll offset before we narrow again.
      final probeWidth = card.hasSize ? card.size.width.clamp(0.0, width) : width;
      card.layout(BoxConstraints.tightFor(width: probeWidth), parentUsesSize: true);
    }
    final shown = [
      for (final (i, card) in cards.indexed)
        if (card.size.height > 0.5) i,
    ];
    final t = spread;
    final whole = turn.floor();
    final f = turn - whole;
    final from = order(shown, whole);
    final to = order(shown, whole + 1);
    final spreadFront = shown.lastOrNull;
    final spreadTop = shown.firstOrNull;
    // Spread, a deck has its fold button beside the top card.
    final folding = shown.length >= 2 ? t : 0.0;

    // Beside the accessory: the front card folded, the lowest one spread.
    Size? side;
    var accessoryRoom = 0.0;
    if (accessory != null) {
      accessory.layout(BoxConstraints(maxWidth: width / 2), parentUsesSize: true);
      side = accessory.size;
      accessoryRoom = side.width + DockStackMetrics.accessoryGap;
    }
    var foldRoom = 0.0;
    if (fold != null) {
      fold.layout(const BoxConstraints(), parentUsesSize: true);
      foldRoom = fold.size.width + DockStackMetrics.accessoryGap;
    }
    for (final i in shown) {
      final front = (from.first == i ? 1 - f : 0.0) + (to.first == i ? f : 0.0);
      final beside = front + ((i == spreadFront ? 1.0 : 0.0) - front) * t;
      final room = accessoryRoom * beside + (i == spreadTop ? foldRoom * folding : 0);
      cards[i].layout(BoxConstraints.tightFor(width: (width - room).clamp(0.0, width)), parentUsesSize: true);
    }
    double height(int i) => cards[i].size.height;

    // Spread: a column.
    final spreadY = <double>[];
    var y = 0.0;
    for (final card in cards) {
      spreadY.add(y);
      y += card.size.height;
    }
    final spreadHeight = y;

    final a = _fold(from, height);
    final b = _fold(to, height);
    double mix(double x, double z, double by) => x + (z - x) * by;
    final foldedHeight = mix(a.height, b.height, f);
    final deckHeight = mix(foldedHeight, spreadHeight, t);
    for (final (i, card) in cards.indexed) {
      final data = card.parentData! as DockStackParentData;
      final pa = a.places[i];
      final pb = b.places[i];
      if (pa == null || pb == null) {
        data
          ..offset = Offset(0, spreadY[i])
          ..scale = 1
          ..opacity = 1
          ..clipHeight = null
          ..depth = null;
        continue;
      }
      final clip = mix(mix(pa.clip, pb.clip, f), height(i), t);
      data
        ..offset = Offset(0, mix(mix(pa.y, pb.y, f), spreadY[i], t))
        ..scale = mix(mix(pa.scale, pb.scale, f), 1, t)
        ..opacity = mix(mix(pa.opacity, pb.opacity, f), 1, t)
        ..clipHeight = clip >= height(i) - 0.01 ? null : clip
        ..depth = mix(pa.depth, pb.depth, f);
    }
    if (accessory != null && side != null) {
      final data = accessory.parentData! as DockStackParentData;
      final top = spreadFront == null
          ? 0.0
          : mix(mix(a.frontTop, b.frontTop, f), spreadY[spreadFront], t);
      data
        ..offset = Offset(width - side.width, top)
        ..scale = 1
        ..opacity = mix(mix(a.frontWeight, b.frontWeight, f), spreadFront == null ? 0 : _weight(height(spreadFront)), t)
        // Rising with the front card, not below the deck.
        ..clipHeight = (deckHeight - top).clamp(0.0, side.height)
        ..depth = spreadFront == null ? null : -1;
    }

    if (fold != null) {
      final data = fold.parentData! as DockStackParentData;
      data
        ..offset = Offset(
          width - fold.size.width,
          spreadTop == null ? 0 : (cards[spreadTop].parentData! as DockStackParentData).offset.dy,
        )
        ..scale = 1
        ..opacity = folding
        ..clipHeight = null
        ..depth = folding > 0 ? -2 : null;
    }

    size = constraints.constrain(Size(width, deckHeight));
    if (!listEquals(_reported, shown)) {
      _reported = shown;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (attached) onShown(shown);
      });
    }
  }

  /// How much of a bar's slot a card has grown to.
  static double _weight(double height) => (height / (DockMetrics.height + DockMetrics.gap)).clamp(0.0, 1.0);

  /// The folded deck with [order]'s first card in front.
  static ({Map<int, _Place> places, double height, double frontTop, double frontWeight}) _fold(
    List<int> order,
    double Function(int) height,
  ) {
    if (order.isEmpty) return (places: const {}, height: 0, frontTop: 0, frontWeight: 0);
    const bar = DockMetrics.height + DockMetrics.gap;
    final front = order.first;
    final behind = order.skip(1).toList();
    final frontWeight = _weight(height(front));
    final rises = <double>[];
    var rise = 0.0;
    for (final (k, i) in behind.indexed) {
      if (k < DockStackMetrics.peeks) rise += DockStackMetrics.peek * _weight(height(i)) * frontWeight;
      rises.add(rise);
    }
    // Under the peeks: a bar's height at least while one is behind, so a
    // front card still growing in rises over it from the bottom.
    var base = height(front);
    for (final i in behind) {
      final h = height(i).clamp(0.0, bar);
      if (h > base) base = h;
    }
    final deckHeight = rise + base;
    final frontTop = deckHeight - height(front);
    final places = <int, _Place>{
      front: (y: frontTop, scale: 1.0, opacity: 1.0, clip: height(front), depth: 0.0),
    };
    for (final (k, i) in behind.indexed) {
      final step = (k + 1).clamp(0, DockStackMetrics.peeks) * frontWeight;
      final cardY = rise - rises[k];
      final scale = 1 - DockStackMetrics.shrink * step;
      // Only its own peek shows: the glass in front is see-through and
      // samples the chat behind the deck, not the cards under it.
      final nextTop = k == 0 ? frontTop : rise - rises[k - 1];
      places[i] = (
        y: cardY,
        scale: scale,
        // Beyond the last peek a card hides behind the one before it.
        opacity: k >= DockStackMetrics.peeks ? 1 - frontWeight : 1 - DockStackMetrics.fade * step,
        clip: ((nextTop - cardY) / scale).clamp(0.0, height(i)),
        depth: k + 1.0,
      );
    }
    return (places: places, height: deckHeight, frontTop: frontTop, frontWeight: frontWeight);
  }

  /// Back to front: the furthest card first, the accessory last.
  List<RenderBox> get _paintOrder {
    final drawn = [
      for (final child in _children)
        if ((child.parentData! as DockStackParentData).depth != null) child,
    ];
    double depth(RenderBox c) => (c.parentData! as DockStackParentData).depth!;
    drawn.sort((a, b) => depth(b).compareTo(depth(a)));
    return drawn;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    for (final child in _paintOrder) {
      final data = child.parentData! as DockStackParentData;
      void draw(PaintingContext context, Offset offset) {
        if (data.opacity >= 1) {
          data.opacityHandle.layer = null;
          context.paintChild(child, offset);
        } else if (data.opacity > 0) {
          data.opacityHandle.layer = context.pushOpacity(
            offset,
            (data.opacity * 255).round(),
            (context, offset) => context.paintChild(child, offset),
            oldLayer: data.opacityHandle.layer,
          );
        }
      }

      void place(PaintingContext context, Offset offset) {
        data.transformHandle.layer = context.pushTransform(
          needsCompositing,
          offset,
          data.transformFor(child.size),
          draw,
          oldLayer: data.transformHandle.layer,
        );
      }

      final clip = data.clipHeight;
      if (clip == null) {
        data.clipHandle.layer = null;
        place(context, offset);
      } else {
        final o = data.offset;
        data.clipHandle.layer = context.pushClipRect(
          needsCompositing,
          offset,
          // Sideways the glass's shadow may spill; downwards nothing passes the front card.
          Rect.fromLTRB(-size.width, o.dy - size.height, size.width * 2, o.dy + clip * data.scale),
          place,
          oldLayer: data.clipHandle.layer,
        );
      }
    }
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final data = child.parentData! as DockStackParentData;
    transform.multiply(data.transformFor(child.size));
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    for (final child in _paintOrder.reversed) {
      final data = child.parentData! as DockStackParentData;
      if (data.opacity <= 0) continue;
      final hit = result.addWithPaintTransform(
        transform: data.transformFor(child.size),
        position: position,
        hitTest: (result, position) => child.hitTest(result, position: position),
      );
      if (hit) return true;
    }
    return false;
  }

  @override
  void detach() {
    for (final child in _children) {
      final data = child.parentData! as DockStackParentData;
      data.clipHandle.layer = null;
      data.transformHandle.layer = null;
      data.opacityHandle.layer = null;
    }
    super.detach();
  }
}
