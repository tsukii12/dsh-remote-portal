import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_state.dart';
import 'settings_state.dart';

/// DeepSeek account balance (`GET https://api.deepseek.com/user/balance`).
class DeepSeekBalance {
  const DeepSeekBalance({
    required this.currency,
    required this.total,
    this.granted,
    this.toppedUp,
    this.available = true,
  });

  /// `CNY` or `USD`.
  final String currency;
  final double total;

  /// Promotional credit included in [total].
  final double? granted;

  /// Paid credit included in [total].
  final double? toppedUp;

  /// `is_available`: false when the balance can no longer pay for calls.
  final bool available;

  String get symbol => currency == 'USD' ? r'$' : '¥';
}

/// Wallets of the signed-in DeepSeek account (null when signed out or not yet
/// known). A separate seam so tests and engines without the account service can
/// stub it out without standing up the account stack.
final accountWalletBalanceProvider = Provider<AccountBalance?>((ref) => ref.watch(accountBalanceProvider).value);

/// The signed-in account's wallets as one balance (CNY preferred): recharge is
/// [DeepSeekBalance.toppedUp], bonus is [DeepSeekBalance.granted].
DeepSeekBalance? balanceFromAccount(AccountBalance account) {
  final wallets = [...account.recharge, ...account.bonus];
  if (wallets.isEmpty) return null;
  final currency = wallets.any((w) => w.currency == 'CNY') ? 'CNY' : wallets.first.currency;
  double sum(List<AccountWallet> list) =>
      list.where((w) => w.currency == currency).fold(0.0, (total, w) => total + (double.tryParse(w.balance) ?? 0));
  final recharge = sum(account.recharge);
  final bonus = sum(account.bonus);
  return DeepSeekBalance(currency: currency, total: recharge + bonus, granted: bonus, toppedUp: recharge);
}

/// Outcome of one balance request.
sealed class BalanceResult {
  const BalanceResult();
}

final class BalanceOk extends BalanceResult {
  const BalanceOk(this.balance);
  final DeepSeekBalance balance;
}

/// 401 / 403: the key is wrong or revoked.
final class BalanceInvalidKey extends BalanceResult {
  const BalanceInvalidKey();
}

/// Offline, timeout, 5xx, unexpected body: nothing to tell the person.
final class BalanceUnavailable extends BalanceResult {
  const BalanceUnavailable();
}

/// Parses the `/user/balance` body; prefers the CNY entry (the account
/// currency for mainland users), else the first one.
DeepSeekBalance? parseBalance(Object? json) {
  if (json is! Map) return null;
  final infos = json['balance_infos'];
  if (infos is! List || infos.isEmpty) return null;
  final entries = infos.whereType<Map>().toList();
  if (entries.isEmpty) return null;
  final info = entries.firstWhere((e) => e['currency'] == 'CNY', orElse: () => entries.first);
  double? amount(Object? v) => v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);
  final total = amount(info['total_balance']);
  if (total == null) return null;
  return DeepSeekBalance(
    currency: info['currency'] is String ? info['currency'] as String : 'CNY',
    total: total,
    granted: amount(info['granted_balance']),
    toppedUp: amount(info['topped_up_balance']),
    available: json['is_available'] != false,
  );
}

/// Maps an HTTP status + body to a [BalanceResult].
BalanceResult balanceResultOf(int status, String body) {
  if (status == 401 || status == 403) return const BalanceInvalidKey();
  if (status != 200) return const BalanceUnavailable();
  try {
    final balance = parseBalance(jsonDecode(body));
    return balance == null ? const BalanceUnavailable() : BalanceOk(balance);
  } on FormatException {
    return const BalanceUnavailable();
  }
}

typedef BalanceFetcher = Future<BalanceResult> Function(String apiKey);

const deepSeekBalanceUrl = 'https://api.deepseek.com/user/balance';
const deepSeekTopUpUrl = 'https://platform.deepseek.com/top_up';

/// Real request with `dart:io`. The key only ever goes into the
/// Authorization header; nothing here logs or rethrows (an exception string
/// could end up in a log).
Future<BalanceResult> fetchDeepSeekBalance(String apiKey) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8)
    ..idleTimeout = const Duration(seconds: 2);
  try {
    final request = await client.getUrl(Uri.parse(deepSeekBalanceUrl));
    request.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer $apiKey')
      ..set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close().timeout(const Duration(seconds: 12));
    final body = await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 12));
    return balanceResultOf(response.statusCode, body);
  } catch (_) {
    return const BalanceUnavailable();
  } finally {
    client.close(force: true);
  }
}

/// Swappable for tests.
final balanceFetcherProvider = Provider<BalanceFetcher>((ref) => fetchDeepSeekBalance);

enum BalanceStatus {
  /// No API key saved in the app.
  noKey,

  /// Not asked yet / first request in flight.
  unknown,
  ok,
  invalidKey,

  /// Last request failed quietly; [BalanceState.balance] may still hold an
  /// older value.
  unavailable,
}

class BalanceState {
  const BalanceState({
    this.status = BalanceStatus.unknown,
    this.balance,
    this.checkedAt,
    this.threshold = defaultLowBalanceThreshold,
    this.dismissed = false,
    this.loading = false,
  });

  final BalanceStatus status;

  /// Last good answer (kept through later offline failures).
  final DeepSeekBalance? balance;
  final DateTime? checkedAt;

  /// Warn below this amount; 0 turns the warning off.
  final double threshold;

  /// The low-balance banner was closed in this app run.
  final bool dismissed;
  final bool loading;

  bool get isLow {
    final b = balance;
    if (b == null || status == BalanceStatus.noKey) return false;
    if (!b.available) return true;
    return threshold > 0 && b.total < threshold;
  }

  /// Threshold 0 (「不提醒」) turns the banner off entirely, also when the balance
  /// can no longer pay: someone on other providers' models doesn't need it.
  bool get showBanner => threshold > 0 && isLow && !dismissed;

  BalanceState copyWith({
    BalanceStatus? status,
    DeepSeekBalance? balance,
    bool clearBalance = false,
    DateTime? checkedAt,
    double? threshold,
    bool? dismissed,
    bool? loading,
  }) => BalanceState(
    status: status ?? this.status,
    balance: clearBalance ? null : (balance ?? this.balance),
    checkedAt: checkedAt ?? this.checkedAt,
    threshold: threshold ?? this.threshold,
    dismissed: dismissed ?? this.dismissed,
    loading: loading ?? this.loading,
  );
}

const defaultLowBalanceThreshold = 5.0;

/// Choices offered for the low-balance line (0 = 不提醒).
const lowBalanceThresholds = [0.0, 1.0, 5.0, 10.0, 20.0, 50.0];

/// Balance of the key saved in the app.
///
/// [refresh] is called when the chat or settings opens, when the usage sheet
/// opens and after each turn; it asks the API at most once a minute (a key
/// change resets that). Offline and server errors are silent.
class BalanceController extends Notifier<BalanceState> {
  static const _thresholdKey = 'low_balance_threshold';
  static const minInterval = Duration(minutes: 1);

  /// Overridable clock for tests.
  static DateTime Function() now = DateTime.now;

  String _key = '';
  DateTime? _lastAttempt;
  Future<void>? _inflight;
  double? _threshold;
  var _generation = 0;

  @override
  BalanceState build() {
    final key = ref.watch(settingsProvider.select((s) => s.apiKey.trim()));
    if (key != _key) {
      _key = key;
      _lastAttempt = null;
      _inflight = null;
      _generation++;
    }
    if (_threshold == null) unawaited(_loadThreshold());
    final threshold = _threshold ?? defaultLowBalanceThreshold;
    if (key.isEmpty) {
      // Signed in with a DeepSeek account instead of a key: use the account's wallets.
      final account = ref.watch(accountWalletBalanceProvider);
      final fromAccount = account == null ? null : balanceFromAccount(account);
      if (fromAccount != null) {
        return BalanceState(status: BalanceStatus.ok, balance: fromAccount, checkedAt: now(), threshold: threshold);
      }
      return BalanceState(status: BalanceStatus.noKey, threshold: threshold);
    }
    Future.microtask(refresh);
    return BalanceState(threshold: threshold, loading: true);
  }

  Future<void> _loadThreshold() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getDouble(_thresholdKey);
      _threshold = saved ?? defaultLowBalanceThreshold;
    } catch (_) {
      _threshold = defaultLowBalanceThreshold;
    }
    if (ref.mounted && state.threshold != _threshold) {
      state = state.copyWith(threshold: _threshold);
    }
  }

  /// Asks the API unless it was asked less than a minute ago.
  Future<void> refresh() {
    if (!ref.mounted) return Future.value();
    final key = _key;
    if (key.isEmpty) {
      final last = _lastAttempt;
      if (ref.read(accountProvider).signedIn && (last == null || now().difference(last) >= minInterval)) {
        _lastAttempt = now();
        ref.invalidate(accountBalanceProvider);
      }
      return Future.value();
    }
    if (_inflight case final pending?) return pending;
    final last = _lastAttempt;
    if (last != null && now().difference(last) < minInterval) {
      return Future.value();
    }
    _lastAttempt = now();
    final generation = _generation;
    final fetch = ref.read(balanceFetcherProvider);
    if (!state.loading) state = state.copyWith(loading: true);
    return _inflight = () async {
      try {
        final result = await fetch(key);
        if (!ref.mounted || generation != _generation) return;
        state = switch (result) {
          BalanceOk(:final balance) => state.copyWith(
            status: BalanceStatus.ok,
            balance: balance,
            checkedAt: now(),
            loading: false,
          ),
          BalanceInvalidKey() => state.copyWith(
            status: BalanceStatus.invalidKey,
            clearBalance: true,
            checkedAt: now(),
            loading: false,
          ),
          BalanceUnavailable() => state.copyWith(status: BalanceStatus.unavailable, loading: false),
        };
      } finally {
        if (generation == _generation) _inflight = null;
      }
    }();
  }

  Future<void> setThreshold(double value) async {
    _threshold = value;
    state = state.copyWith(threshold: value, dismissed: false);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_thresholdKey, value);
    } catch (_) {
      // Kept for this run.
    }
  }

  /// Hides the low-balance banner until the app restarts.
  void dismissBanner() => state = state.copyWith(dismissed: true);
}

final balanceProvider = NotifierProvider<BalanceController, BalanceState>(BalanceController.new);
