// Which first-time risk notices (ui/common/risk_notice.dart) the person
// confirmed with 「不再提示」 ticked: their ids, kept in SharedPreferences.
// Every-time notices are never stored. A read that fails counts as "not
// silenced", so the notice shows rather than being skipped.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract interface class RiskNoticeStore {
  /// Whether the notice [id] was confirmed with 「不再提示」.
  Future<bool> silenced(String id);

  /// Remembers [id]: the notice no longer shows.
  Future<void> silence(String id);
}

class PrefsRiskNoticeStore implements RiskNoticeStore {
  const PrefsRiskNoticeStore();

  static const key = 'risk_notice.silenced';

  @override
  Future<bool> silenced(String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList(key)?.contains(id) ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> silence(String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ids = {...?prefs.getStringList(key), id}.toList()..sort();
      await prefs.setStringList(key, ids);
    } catch (_) {
      // Unsaved: the notice shows again next time, which is the safe side.
    }
  }
}

final riskNoticeStoreProvider = Provider<RiskNoticeStore>((ref) => const PrefsRiskNoticeStore());
