// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'package:flutter/material.dart';

import '../theme/glass.dart';
import '../theme/motion.dart';
import '../theme/shapes.dart';
import '../theme/squircle.dart';
import '../theme/surfaces.dart';
import 'smooth_size.dart';

/// 玻璃小胶囊:**折叠态摘要的通用外壳**(思考块、工具组、"已压缩上下文")。
///
/// 传了 [expandedChild] 时,展开内容长在**胶囊内部**:摘要行保持 ≥ 34dp,
/// 内容接在下面,整颗胶囊自己长高,圆角从胶囊收成 md(14)—— 全圆角配多行
/// 内容会切掉首尾行的两端。
class GlassPill extends StatelessWidget {
  const GlassPill({super.key, required this.child, this.onTap, this.expandedChild, this.fillWidth = true});

  /// 摘要行,始终占一行(≥ 34dp)。
  final Widget child;
  final VoidCallback? onTap;

  /// 外壳是否占满可用宽度。工具组要撑满;思考胶囊只裹住短文案。
  final bool fillWidth;

  /// 展开内容。非空即视为展开态。
  final Widget? expandedChild;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final expanded = expandedChild != null;

    final body = Material(
      type: MaterialType.transparency,
      child: Column(
        crossAxisAlignment: fillWidth ? CrossAxisAlignment.stretch : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 只有摘要行可点:展开内容里有代码块、可滚动输出井、按钮,
          // 整块包进 InkWell 会吃掉它们的手势。
          InkWell(
            onTap: onTap,
            customBorder: expanded
                ? const RoundedSuperellipseBorder(
                    borderRadius: BorderRadius.vertical(top: Radius.circular(AppShape.md)),
                  )
                : const StadiumBorder(),
            child: Container(
              constraints: const BoxConstraints(minHeight: 34),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              // fillWidth=false 时不设 alignment:有 alignment 的 Container
              // 会无视 start 强制扩到最大宽度。
              alignment: fillWidth ? Alignment.centerLeft : null,
              child: child,
            ),
          ),
          if (expandedChild case final content?) ...[
            Divider(height: 0.5, thickness: 0.5, color: colors.outlineVariant.withValues(alpha: 0.6)),
            SmoothSize(
              duration: AppMotion.of(context, AppMotion.collapse),
              curve: AppMotion.collapseCurve,
              alignment: Alignment.topCenter,
              child: content,
            ),
          ],
        ],
      ),
    );

    return GlassSurface(
      tier: GlassTier.pill,
      borderRadius: expanded ? AppShape.radiusMd : null,
      // 展开后内容(代码块、diff)的方角不能戳出圆角。
      child: expanded ? Squircle.clip(radius: AppShape.md, child: body) : body,
    );
  }
}
