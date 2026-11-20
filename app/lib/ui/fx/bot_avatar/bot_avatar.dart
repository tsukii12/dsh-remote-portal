// Portions derived from Libraries.dev Bot avatars (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../theme/motion.dart';
import 'bot_avatar_bakery.dart';
import 'bot_avatar_color.dart';
import 'bot_avatar_engine.dart';
import 'bot_avatar_fur.dart';
import 'bot_avatar_paint.dart';
import 'bot_avatar_types.dart';

export 'bot_avatar_engine.dart' show BotAvatarJump, BotAvatarPose, BotAvatarSim;
export 'bot_avatar_fur.dart' show FurStyle;
export 'bot_avatar_types.dart';

/// 机器人头像的配色来源。
enum BotAvatarPalette {
  /// 跟主题走：主色相和左右邻近的几个色相，饱和度压低，浅色深色跟主题。
  theme,

  /// 作者原版调色板：每种形状自带的颜色（偏鲜艳）。
  author,
}

/// 跟主题走的头像配色：主色相左右五个邻近色调，饱和度压低（同 CallPalette 的做法）。
abstract final class BotAvatarColors {
  static List<Color> tones(ColorScheme scheme, Brightness brightness) {
    final base = HSLColor.fromColor(scheme.primary);
    // A grey theme still gets some colour; a loud one is calmed down.
    final sat = (base.saturation * 0.8).clamp(0.34, 0.55);
    final light = brightness == Brightness.light;
    final l = light ? 0.68 : 0.62;
    Color tone(double shift, double s, double lightness) =>
        HSLColor.fromAHSL(1, (base.hue + shift) % 360, s.clamp(0.0, 1.0), lightness.clamp(0.0, 1.0)).toColor();
    return [
      tone(-44, sat * 0.9, l + 0.04),
      tone(-20, sat, l),
      tone(0, sat * 1.1, l - 0.04),
      tone(22, sat, l + 0.02),
      tone(46, sat * 0.85, l + 0.06),
    ];
  }
}

/* FNV-1a over the UTF-16 units, as the author's seed from the React id */
int _fnv(String s) {
  var h = 2166136261;
  for (final c in s.codeUnits) {
    h = ((h ^ c) * 16777619) & 0xFFFFFFFF;
  }
  return h;
}

/* mixed (murmur3's finaliser) for picking a type and a tone: ids that differ
   in their last character differ in FNV's low bits only */
int _mixed(String s) {
  var h = _fnv(s);
  h ^= h >> 16;
  h = (h * 0x7feb352d) & 0xFFFFFFFF;
  h ^= h >> 15;
  h = (h * 0x846ca68b) & 0xFFFFFFFF;
  return h ^ (h >> 16);
}

/// 动态机器人头像（移植自 Libraries.dev Bot avatars）：毛绒或亮面塑料的身体，
/// 会看来看去、眨眼、跳一下的脸；状态跟着 agent 的真实状态走。
///
/// 尺寸与开销：
/// - 布局只占 [size] 见方，画面向四周外扩到 1.5 倍（上方多留一点），跳起和翻转
///   不会被裁；父级别用 ClipRect 之类把它裁掉。
/// - 列表里成排的小头像（24–48）走静止帧：画一次缓存成图片，所有同样外观的头像
///   共享；状态变了、被点了才活过来一会儿，过渡播完又回到静止帧。
/// - 只有 [live]（默认 working 时）才每帧绘制；一屏同时动的最好只有一两个。
/// - 毛绒和塑料第一次出现某种形状时要在后台 isolate 烘一次（形体几毫秒，毛绒的绒毛
///   几十到几百毫秒），烘好之前头像透明，好了淡入；之后同形状共用。
/// - 系统要求减少动画时只画该状态的静止姿势，不循环、点击也不跳。
class BotAvatar extends StatefulWidget {
  const BotAvatar({
    super.key,
    this.id,
    this.type,
    this.state = BotAvatarState.idle,
    this.size = 64,
    this.shading = BotAvatarShading.fabric,
    this.palette = BotAvatarPalette.theme,
    this.color,
    this.ink,
    this.face,
    this.brightness,
    this.saturation,
    this.seed,
    this.speed = 1,
    this.paused = false,
    this.live,
    this.interactive = true,
    this.turn = 1,
    this.whirl = 0,
    this.jump = const BotAvatarJump(),
    this.fur = const FurStyle(),
    this.semanticLabel,
    this.excludeFromSemantics = false,
  });

  /// 稳定映射的来源（bot / agent / 预设的 id）：同一个 id 永远是同一种形状、同一个
  /// 色调、同一套眨眼节奏。[type]、[seed] 显式给了就以显式为准。
  final String? id;

  /// 身体形状；不给就按 [id] 选，都没有时是 clover。
  final BotAvatarType? type;

  /// 状态，见 [BotAvatarState] 的映射说明。切换时有过渡，每个 token 都切也没事。
  final BotAvatarState state;

  /// 布局边长（逻辑像素）。
  final double size;

  /// 材质：fabric（毛绒，作者默认）或 plastic（亮面塑料），以及 crisp/smooth/flat。
  final BotAvatarShading shading;

  /// 不给 [color] 时用哪套配色。
  final BotAvatarPalette palette;

  /// 身体颜色；给了就不用 [palette]。
  final Color? color;

  /// 脸的颜色；默认深色，深色身体上用浅色。
  final Color? ink;

  /// 只有眼睛，或者加一张会随状态变的嘴；默认按形状。
  final BotAvatarFace? face;

  /// 作者的亮度 / 饱和度（饱和度 1.5 以上会更艳），默认按配色来源：主题配色不加工，
  /// 作者配色用形状自带的值。
  final double? brightness;
  final double? saturation;

  /// 0–1，错开眨眼和张望的节奏；默认由 [id]（或实例）算出。
  final double? seed;

  /// 动画速度倍数。
  final double speed;

  /// 冻结成该状态的静止姿势（离线 agent 可以用 sleeping 或 idle + paused）。
  final bool paused;

  /// 是否每帧动起来；null 时 working 才动，其余状态画静止帧（点一下、换状态时会
  /// 临时动起来）。
  final bool? live;

  /// 点一下跳起来转一圈。
  final bool interactive;

  /// idle 时左右转头的幅度，0–2。
  final double turn;

  /// 转圈时的拖尾，0 关（作者默认关）、1 开。
  final double whirl;

  /// 跳跃参数（作者的 Jump 一组）。
  final BotAvatarJump jump;

  /// 毛绒的样式（作者的 fur* 一组）。
  final FurStyle fur;

  /// 读屏文字；默认作者的「Clover bot, idle」这种。名字和状态已经写在旁边时，
  /// 设 [excludeFromSemantics]。
  final String? semanticLabel;
  final bool excludeFromSemantics;

  /// 按 id 选形状（稳定）。
  static BotAvatarType typeFor(String id) => BotAvatarType.values[_mixed(id) % BotAvatarType.values.length];

  /// 按 id 算眨眼节奏的种子，0–1（作者从 React id 算的同一种哈希）。
  static double seedFor(String id) => (_fnv(id) % 1000) / 1000;

  /// 按 id 在主题色调里选一个（稳定）。
  static int toneFor(String id) => (_mixed(id) ~/ BotAvatarType.values.length) % 5;

  @override
  State<BotAvatar> createState() => _BotAvatarState();
}

const _fadeIn = Duration(milliseconds: 300);
/* how long a still avatar stays awake after a switch or a tap: the longest
   switch (1.4 s) and the last hop's landing, or a tap's jump */
const _wakeFor = 2.2;

class _BotAvatarState extends State<BotAvatar> with SingleTickerProviderStateMixin {
  late final BotAvatarSim _sim;
  late final Ticker _ticker;
  final _frame = _Frame();
  final _rs = BotAvatarRenderState();
  Duration _last = Duration.zero;
  double _wake = 0;
  bool _shown = false;
  bool _listening = false;
  ui.Image? _still;
  String? _stillKey;

  BotAvatarType get _type => widget.type ?? (widget.id != null ? BotAvatar.typeFor(widget.id!) : BotAvatarType.clover);

  @override
  void initState() {
    super.initState();
    final seed = widget.seed ?? BotAvatar.seedFor(widget.id ?? '${identityHashCode(this)}');
    _sim = BotAvatarSim(seed.clamp(0.0, 1.0), widget.state)
      ..setTurn(widget.turn.clamp(0.0, 2.0))
      ..setJump(widget.jump);
    _ticker = createTicker(_tick);
  }

  @override
  void didUpdateWidget(BotAvatar old) {
    super.didUpdateWidget(old);
    if (old.state != widget.state) {
      _sim.setState(widget.state);
      _wake = _wakeFor;
    }
    _sim
      ..setTurn(widget.turn.clamp(0.0, 2.0))
      ..setJump(widget.jump);
  }

  @override
  void dispose() {
    _ticker.dispose();
    if (_listening) BotAvatarBakery.instance.removeListener(_landed);
    _still?.dispose();
    _rs.dispose();
    _frame.dispose();
    super.dispose();
  }

  void _landed() {
    if (mounted) setState(() {});
  }

  void _tick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    _sim.update(dt * widget.speed);
    if (_wake > 0) _wake = math.max(0, _wake - dt);
    // awake only for a switch or a tap: back to the still frame once it settles
    if (_wake == 0 && !_liveByProps && !_sim.jumping) setState(() {});
    _frame.tick();
  }

  bool get _liveByProps => widget.live ?? widget.state == BotAvatarState.working;

  void _poke() {
    _sim.poke();
    setState(() => _wake = _wakeFor);
  }

  BotAvatarLook _look(BuildContext context) {
    final type = _type;
    final preset = type.preset;
    final w = widget;
    Color picked;
    double brightness, saturation;
    if (w.color != null || w.palette == BotAvatarPalette.author) {
      picked = w.color ?? preset.color;
      brightness = w.brightness ?? preset.brightness ?? 1;
      saturation = w.saturation ?? preset.saturation ?? 1.5;
    } else {
      final theme = Theme.of(context);
      final tones = BotAvatarColors.tones(theme.colorScheme, theme.brightness);
      picked = tones[w.id != null ? BotAvatar.toneFor(w.id!) : type.index % tones.length];
      brightness = w.brightness ?? 1;
      saturation = w.saturation ?? 1;
    }
    final body = bodyColor(picked, brightness: brightness, saturation: saturation);
    return BotAvatarLook(
      type: type,
      color: body,
      ink: w.ink,
      face: w.face,
      shading: w.shading,
      vivid: saturation.clamp(1.5, 2.5) - 1.5,
      fur: w.fur,
      whirl: w.whirl.clamp(0.0, 2.0),
    );
  }

  /* the still frame of the state, shared by every avatar that looks the same */
  ui.Image? _stillImage(BotAvatarLook look, double dpr) {
    final key = '${look.id}|${widget.state.name}|${widget.size}|$dpr';
    if (_stillKey == key && _still != null) return _still;
    _still?.dispose();
    _still = _StillCache.get(key, () {
      final box = widget.size, full = box * botAvatarOverscan;
      final rec = ui.PictureRecorder();
      final c = Canvas(rec)..scale(dpr);
      final rs = BotAvatarRenderState();
      paintBotAvatar(c, box, BotAvatarPose.rest(widget.state), look, rs, dpr: dpr, still: true);
      rs.dispose();
      final pic = rec.endRecording();
      final img = pic.toImageSync((full * dpr).ceil(), (full * dpr).ceil());
      pic.dispose();
      return img;
    });
    _stillKey = key;
    return _still;
  }

  @override
  Widget build(BuildContext context) {
    final look = _look(context);
    final reduced = AppMotion.reduced(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final ready = botAvatarReady(look, widget.size, dpr);
    if (ready != !_listening) {
      // listen while a bake this avatar waits on is under way
      if (ready) {
        BotAvatarBakery.instance.removeListener(_landed);
      } else {
        BotAvatarBakery.instance.addListener(_landed);
      }
      _listening = !ready;
    }
    // hidden until its material has baked (a few hundred ms at most), then faded in
    _shown |= ready;
    final live =
        !reduced &&
        !widget.paused &&
        widget.speed > 0 &&
        (_liveByProps || _wake > 0 || (_ticker.isActive && _sim.jumping));
    if (live && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    } else if (!live && _ticker.isActive) {
      _ticker.stop();
      _wake = 0;
    }
    final box = widget.size;
    final CustomPainter painter;
    if (live || !ready) {
      _still?.dispose();
      _still = null;
      _stillKey = null;
      painter = _LivePainter(live ? _sim.pose : BotAvatarPose.rest(widget.state), look, _rs, dpr, !live, _frame);
    } else {
      painter = _StillPainter(_stillImage(look, dpr)!);
    }
    Widget child = RepaintBoundary(
      child: CustomPaint(size: Size.square(box), painter: painter),
    );
    child = AnimatedOpacity(
      opacity: _shown ? 1 : 0,
      duration: AppMotion.of(context, _fadeIn),
      curve: Curves.easeOut,
      child: child,
    );
    if (widget.interactive && !reduced && !widget.paused) {
      child = GestureDetector(behavior: HitTestBehavior.opaque, onTap: _poke, child: child);
    }
    if (widget.excludeFromSemantics) return child;
    return Semantics(
      image: true,
      label: widget.semanticLabel ?? '${_type.preset.label} bot, ${botAvatarStateLabels[widget.state]}',
      child: ExcludeSemantics(child: child),
    );
  }
}

class _Frame extends ChangeNotifier {
  void tick() => notifyListeners();
}

/* the canvas overscans the box: 1.5 times its size, a little more above */
Offset _origin(double box) =>
    Offset(-box * (botAvatarOverscan - 1) / 2, -box * ((botAvatarOverscan - 1) / 2 + botAvatarRise));

class _LivePainter extends CustomPainter {
  _LivePainter(this.pose, this.look, this.rs, this.dpr, this.still, Listenable frame) : super(repaint: frame);

  final BotAvatarPose pose;
  final BotAvatarLook look;
  final BotAvatarRenderState rs;
  final double dpr;
  final bool still;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.translate(_origin(size.width).dx, _origin(size.width).dy);
    paintBotAvatar(canvas, size.width, pose, look, rs, dpr: dpr, still: still);
  }

  @override
  bool shouldRepaint(_LivePainter old) =>
      old.look.id != look.id || old.dpr != dpr || !identical(old.pose, pose) || old.still != still;
}

class _StillPainter extends CustomPainter {
  _StillPainter(this.image);

  final ui.Image image;

  @override
  void paint(Canvas canvas, Size size) {
    final o = _origin(size.width), full = size.width * botAvatarOverscan;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(o.dx, o.dy, full, full),
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_StillPainter old) => !old.image.isCloneOf(image);
}

/// Still frames shared by every avatar that looks the same (a handle each).
abstract final class _StillCache {
  static final _images = <String, ui.Image>{};

  static ui.Image get(String key, ui.Image Function() make) {
    var img = _images.remove(key);
    img ??= make();
    _images[key] = img;
    while (_images.length > 96) {
      _images.remove(_images.keys.first)!.dispose();
    }
    return img.clone();
  }
}
