import 'dart:async';
import 'dart:ui' show Color;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 表格铺不铺底色。
///
/// 只影响回复正文里的管道表格：代码块、引用块和其余正文都不受影响。
enum TableTint {
  /// 表头一浅底、表身跟随正文。默认，也是加这个设置之前的样子。
  follow,

  /// 表头浅底，隔行再淡一档，整张表像一块卡片，行多时好扫。
  fill,

  /// 表头和表身都不铺底色，只剩网格线和文字。
  none,
}

/// 三档各自要的两个填充色。
///
/// [header] 永远非空：`TableStyle.headerBackground` 传 null 会回退到主题色，
/// 所以"不铺"必须显式给透明。[stripe] 为 null 就是不画隔行。
({Color header, Color? stripe}) tableTintFills(
  TableTint tint, {
  required Color headerColor,
  required Color stripeColor,
}) => switch (tint) {
  TableTint.follow => (header: headerColor, stripe: null),
  TableTint.fill => (header: headerColor, stripe: stripeColor),
  TableTint.none => (header: transparentFill, stripe: null),
};

/// 明确的透明色，而不是 `Colors.transparent`：状态层不 import Flutter 的
/// material 包，这个文件在纯 Dart 测试里也能跑。
const transparentFill = Color(0x00000000);

/// 表格底色存本机；设置页写、渲染层读，走同一个 provider。
class TableTintController extends Notifier<TableTint> {
  static const key = 'chat.table_tint';

  @override
  TableTint build() {
    unawaited(_read());
    return TableTint.follow;
  }

  Future<void> _read() async {
    final TableTint? stored;
    try {
      final prefs = await SharedPreferences.getInstance();
      stored = TableTint.values.asNameMap()[prefs.getString(key)];
    } catch (_) {
      // 纯 Dart 测试没有 SharedPreferences:停在默认那一档。
      return;
    }
    if (stored != null && stored != state) state = stored;
  }

  Future<void> set(TableTint tint) async {
    if (tint == state) return;
    state = tint;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, tint.name);
    } catch (_) {
      // 存不下就只在本次会话里生效，不打断设置页。
    }
  }
}

final tableTintProvider = NotifierProvider<TableTintController, TableTint>(TableTintController.new);
