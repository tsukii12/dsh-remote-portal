// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'package:flutter/material.dart';

import 'squircle.dart';

/// 圆角词汇:**五档 + 胶囊**,全部连续曲率。
///
/// 相邻两档之间约 1.4 倍,肉眼分得开,且每档用途固定:
///
/// | 档 | 半径 | 用途 |
/// |---|---|---|
/// | xs | 6 | 行内代码、角标、进度条端头 |
/// | sm | 10 | Chip、工具图标块、小按钮、菜单项高亮 |
/// | md | 14 | 卡片、代码井、输入框、菜单、主按钮 |
/// | lg | 20 | 用户气泡、审批卡、设置分组卡 |
/// | xl | 28 | 输入条(composer)、底部弹层、对话框 |
/// | pill | — | 顶栏胶囊、模型胶囊、发送键、思考胶囊(StadiumBorder) |
///
/// DSH 官方 Web 的阶梯是 4/8/12/16/20/28(panel = 28),这里在触屏上整体
/// 放大一点,但保留 28 作为最外层容器半径,与官方 composer 一致。
abstract final class AppShape {
  static const xs = 6.0;
  static const sm = 10.0;
  static const md = 14.0;
  static const lg = 20.0;
  static const xl = 28.0;

  static const radiusXs = BorderRadius.all(Radius.circular(xs));
  static const radiusSm = BorderRadius.all(Radius.circular(sm));
  static const radiusMd = BorderRadius.all(Radius.circular(md));
  static const radiusLg = BorderRadius.all(Radius.circular(lg));
  static const radiusXl = BorderRadius.all(Radius.circular(xl));

  /// 卡片 / 代码井 / 菜单。
  static const card = SquircleBorder(borderRadius: radiusMd);

  /// 用户气泡 / 审批卡。
  static const bubble = SquircleBorder(borderRadius: radiusLg);

  /// 对话框 / 输入条。
  static const dialog = SquircleBorder(borderRadius: radiusXl);

  /// 底部弹层:只有顶部两个角。
  static const sheet = SquircleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(xl)));

  /// 胶囊(半径随高度,永远是半圆端头)。
  static const pill = StadiumBorder();

  /// 带细线的连续圆角。
  static SquircleBorder outlined(Color color, {double radius = md, double width = 1}) => SquircleBorder(
    borderRadius: BorderRadius.all(Radius.circular(radius)),
    side: BorderSide(color: color, width: width),
  );
}

/// 间距阶梯(4 的倍数为主,2/6 用于紧凑行内)。
///
/// 页面左右留白 16(手机),消息之间同一轮 8、换轮 24;卡片内边距 14–16。
abstract final class AppSpace {
  static const xxs = 2.0;
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 20.0;
  static const xxl = 24.0;
  static const xxxl = 32.0;

  /// 页面水平留白。
  static const gutter = 16.0;

  /// 同一轮内部(工具行 ↔ 正文)的竖向间距。
  static const inTurn = 8.0;

  /// 换轮(上一轮回答 → 下一条用户消息)的竖向间距。
  static const betweenTurns = 24.0;

  /// 正文最大阅读宽度(平板 / 横屏 / 折叠屏展开时居中)。与 DSH 官方
  /// `--dsh-chat-content-width: 748px` 同档。
  static const readingWidth = 720.0;

  /// 浮在阅读列上的控件(输入条、待办 / 目标条、斜杠面板、空状态的建议)
  /// 离阅读列两边的距离:和手机上离屏幕两边一样 12,所以比正文两边各宽 4。
  static const floatInset = 12.0;

  /// 那些控件的最大宽度:阅读列减两边 [floatInset]。
  static const floatingWidth = readingWidth - 2 * floatInset;
}
