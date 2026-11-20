// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// 动效 token。原则:**安静、短、跟手**。
///
/// - 反馈类(按压、图标切换)≤ 160ms,快到"感觉不到在等";
/// - 结构类(折叠、胶囊变形、抽屉)240–340ms,慢到"看得出从哪来";
/// - 环境类(安装进度的呼吸)2.4s 一个周期,慢到"不打扰"。
///
/// 系统开启"移除动画"时,用 [of] 取时长会得到 0;循环动画用 [reduced]
/// 判断后停在静止帧。
abstract final class AppMotion {
  /// 按压缩放、水波起始;列表里按压显现前的等待,和显现后至少停留的时长。
  static const press = Duration(milliseconds: 90);

  /// 淡入淡出、图标交叉切换、复制成功对勾。
  static const quick = Duration(milliseconds: 160);

  /// 小块展开收起、列表项进出。
  static const standard = Duration(milliseconds: 240);

  /// 思考块 / 工具行的折叠展开(大块高度变化,慢一拍才不"啪"一下)。
  static const collapse = Duration(milliseconds: 280);

  /// 胶囊变形(顶栏展开、模型选择)、抽屉落位。
  static const emphasized = Duration(milliseconds: 340);

  /// 底部弹层进 / 出(showModalBottomSheet 只认时长)。
  static const sheetIn = Duration(milliseconds: 380);
  static const sheetOut = Duration(milliseconds: 260);

  /// 弹层停稳后,模糊透出来。
  static const glassIn = Duration(milliseconds: 120);

  /// 页面级过场、安装步骤切换。
  static const slow = Duration(milliseconds: 480);

  /// 环境呼吸(安装进度光晕、连接中的状态点)。
  static const breath = Duration(milliseconds: 2400);

  /// 标准缓动(M3 standard,DSH Web 的 cubic-bezier(.4,0,.2,1) 同族)。
  static const std = Easing.standard;

  /// 进场:快出慢停。
  static const enter = Easing.emphasizedDecelerate;

  /// 退场:慢起快走。
  static const exit = Easing.emphasizedAccelerate;

  /// 折叠展开。
  static const collapseCurve = Curves.easeInOutCubic;

  /// 滑行:抽屉、胶囊位移这类"跟手后落位"的运动,长尾减速。
  static const glide = Cubic(0.32, 0.72, 0.0, 1.0);

  /// 弹簧,时长 + 回弹,用系统弹簧的默认值:回弹 0 最通用,0.15 几乎看不出在弹,
  /// 超过 0.4 就夸张了。按压落位。
  static final pressSpring = SpringDescription.withDurationAndBounce(duration: const Duration(milliseconds: 150));

  /// 尺寸、位置变化的落位。
  static final layoutSpring = SpringDescription.withDurationAndBounce(duration: const Duration(milliseconds: 350));

  /// 跟手之后的落位:弹层、返回手势。
  static final sheetSpring = SpringDescription.withDurationAndBounce(duration: const Duration(milliseconds: 500));

  /// 甩出去的抽屉:这里才有一点"活"气。
  static final flingSpring = SpringDescription.withDurationAndBounce(
    duration: const Duration(milliseconds: 500),
    bounce: 0.15,
  );

  // ── 灵动档([fluid])才用的弹簧:都带一点回弹,只喂给位移和缩放,不喂透明度 ──

  /// 松手回弹:按压回到 1 时越过一点点。
  static final releaseSpring = SpringDescription.withDurationAndBounce(
    duration: const Duration(milliseconds: 320),
    bounce: 0.45,
  );

  /// 对话框弹出。
  static final popSpring = SpringDescription.withDurationAndBounce(
    duration: const Duration(milliseconds: 380),
    bounce: 0.2,
  );

  /// 分段控件的滑块落位。
  static final thumbSpring = SpringDescription.withDurationAndBounce(
    duration: const Duration(milliseconds: 320),
    bounce: 0.15,
  );

  /// 刚发出的气泡从输入框升起。
  static final riseSpring = SpringDescription.withDurationAndBounce(
    duration: const Duration(milliseconds: 420),
    bounce: 0.18,
  );

  /// 同一批弹簧的曲线版:给只认曲线和时长的接口。
  ///
  /// [popCurve] 只驱动一段 10% 的缩放,差 1% 已经看不出来,路由不用等尾巴。
  static final popCurve = SpringCurve(popSpring, within: 0.01);
  static final thumbCurve = SpringCurve(thumbSpring);
  static final riseCurve = SpringCurve(riseSpring);

  /// 弹簧从 [from] 带着速度 [velocity] 落到 [to],准确停在 [to] 上。
  ///
  /// [landing]:落点看得见。朝落点冲得太快时,回弹为 0 的弹簧也会越过去再回来,
  /// 所以速度封顶在刚好不越过的那一档(只对回弹为 0 的弹簧成立)。落点在屏幕外
  /// (页面离场、弹层落下)或控制器边界会截住时传 false,手指多快就多快。
  ///
  /// [extent]:这段运动一共多少单位(比例控制器是 1,按像素算的传像素数)。差 0.1%
  /// 就算到位,不等速度归零:默认容差下肉眼早停了,路由和手势还在等。
  static SpringSimulation settle(
    SpringDescription spring,
    double from,
    double to,
    double velocity, {
    bool landing = true,
    double extent = 1,
  }) {
    var start = velocity;
    if (landing) {
      final limit = (to - from) * spring.damping / (2 * spring.mass);
      start = limit > 0 ? math.min(velocity, limit) : math.max(velocity, limit);
    }
    return SpringSimulation(
      spring,
      from,
      to,
      start,
      snapToEnd: true,
      tolerance: Tolerance(distance: 0.001 * extent, velocity: double.infinity),
    );
  }

  /// 拉过头时的橡皮筋:手指拉出 [x],东西只走这么多,越拉越沉,不会超过 [limit]。
  static double rubberBand(double x, {double limit = 48}) => (1 - 1 / (x * 0.55 / limit + 1)) * limit;

  /// 页面级的步骤切换(引导各步、启动页 → 主页)。
  static const page = Duration(milliseconds: 300);

  /// 二级页推入 / 推出(iOS 式水平推入)。
  static const push = Duration(milliseconds: 300);

  /// 灵动档的二级页:卡片展开成页面要走得更远。
  static const pushFluid = Duration(milliseconds: 360);

  /// 首次出现的列表逐项错开(≤ 30ms,只错开前 [staggerLimit] 项)。
  static const stagger = Duration(milliseconds: 30);
  static const staggerLimit = 8;

  /// 首次出现时上移的距离(逻辑像素)。
  static const rise = 8.0;

  /// 按压缩放:按下缩到 [pressScale],松手回到 1(不越过),都走 [pressSpring]。
  static const pressScale = 0.97;

  /// 弹层升起:快出、长尾减速,像有一点阻尼;不回弹。
  static const sheetRise = Cubic(0.2, 0.9, 0.25, 1.0);

  /// 弹层收起(作为 reverseCurve 使用:反向播放时先慢后快)。
  static const sheetFall = Curves.easeOutCubic;

  /// 灵动档:设置 → 性能 → 灵动动效([AppMotionScope]),系统移除动画时一定是否。
  ///
  /// 这一档只加位移、缩放和按压光晕这类便宜的效果,不加模糊和离屏层;关掉时界面
  /// 和没有这一档时完全一样。
  static bool fluid(BuildContext context) =>
      !reduced(context) && (context.dependOnInheritedWidgetOfExactType<AppMotionScope>()?.fluid ?? false);

  /// 灵动档下列表拉过头时回弹;否则交给平台默认(null)。别用在聊天列表和它里面的
  /// 滚动区:回弹不发 OverscrollNotification,`OverscrollForwarder` 会失效。
  static ScrollPhysics? scrollPhysics(BuildContext context) =>
      fluid(context) ? const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()) : null;

  /// 系统是否要求减少动画。
  static bool reduced(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// 按系统设置取时长:要求减少动画时返回 0。
  static Duration of(BuildContext context, Duration duration) => reduced(context) ? Duration.zero : duration;
}

/// 告诉子树当前是不是灵动档([AppMotion.fluid])。挂在 `MaterialApp.builder` 里;
/// 树上没有它(测试、独立预览)就是标准档。
class AppMotionScope extends InheritedWidget {
  const AppMotionScope({super.key, required this.fluid, required super.child});

  final bool fluid;

  @override
  bool updateShouldNotify(AppMotionScope oldWidget) => fluid != oldWidget.fluid;
}

/// 把弹簧换算成曲线,给只认「曲线 + 时长」的接口([AnimatedSwitcher]、
/// [AnimationStyle]、隐式动画)。[duration] 是弹簧肉眼停稳要多久,配套传给接口。
///
/// 回弹时取值会超过 1:只能用于位移、缩放,不能用于透明度。需要接住手指速度或
/// 中途改目标的,用 [AppMotion.settle],别用这个。
class SpringCurve extends Curve {
  /// [within]:离终点多近算停稳。
  SpringCurve(SpringDescription spring, {double within = 0.002}) : this._(SpringSimulation(spring, 0, 1, 0), within);

  SpringCurve._(this._simulation, double within) : _seconds = _settleSeconds(_simulation, within);

  final SpringSimulation _simulation;
  final double _seconds;

  /// 配套的动画时长。
  Duration get duration => Duration(microseconds: (_seconds * Duration.microsecondsPerSecond).round());

  /// 进入 [within] 之内且不再离开的时刻。
  static double _settleSeconds(SpringSimulation simulation, double within) {
    const step = 0.004;
    var last = step;
    for (var t = step; t < 4; t += step) {
      if ((simulation.x(t) - 1).abs() > within) last = t + step;
    }
    return last;
  }

  @override
  double transformInternal(double t) => _simulation.x(t * _seconds);
}
