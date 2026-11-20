// Anonymous usage statistics, the part without Flutter: what one local day
// counts, which past days are due, and the request body of contracts v1–v3
// (`POST /api/usage/v1`, services/share-worker/src/usage.ts; the rules are in
// docs/design/share-links.md §15). Nothing here leaves the phone except
// through [usagePayload], whose keys are fixed.

import 'dart:convert';
import 'dart:math';

/// What a day counts. The names are the request's `counts` keys.
enum UsageCount {
  /// Messages sent in a conversation (only how many).
  turns,

  /// Dictations that put words in the composer (speech typed for you, not a
  /// voice call).
  voice,

  /// Phone control tasks started.
  phone,

  /// Shares that went out: an image, a link, text or a file.
  share,

  /// Generation requests sent.
  gen,

  /// v3: messages the person sent in the tavern (typed, a quick reply, or
  /// calling on a character in a group). Regenerating, continuing and
  /// 帮我写 are not messages.
  tavern,

  /// v3: times the companion room was opened.
  room,

  /// v3: voice calls that got through (the microphone was on).
  call,
}

/// The counts contract v3 added; v1 and v2 bodies leave them out.
const usageCountsV3 = {UsageCount.tavern, UsageCount.room, UsageCount.call};

/// The newest contract this app speaks.
const usageContract = 3;

/// The request body's top-level keys, all of them.
const usagePayloadKeys = {'v', 'iid', 'day', 'app', 'build', 'sdk', 'abi', 'maker', 'lang', 'engine', 'counts'};

/// Contract v2 (1.0.15 on): v1's keys and the model and the maker's system.
/// A host that refuses it (400) gets the v1 body instead. v3 has the same
/// keys and more `counts`.
const usagePayloadKeysV2 = {...usagePayloadKeys, 'model', 'rom'};

/// The keys of its `counts` in v1 and v2: [UsageCount] before v3 and the
/// plugin gauge.
final usageCountKeys = {
  for (final c in UsageCount.values)
    if (!usageCountsV3.contains(c)) c.name,
  'plugins',
};

/// The keys of its `counts` in v3: all of [UsageCount], the plugin gauge,
/// and the day's input and output tokens.
final usageCountKeysV3 = {...usageCountKeys, for (final c in usageCountsV3) c.name, 'tok_in', 'tok_out'};

/// The share host's ceiling per day and key; a count above it is sent as it.
const usageCountLimits = {'turns': 5000, 'voice': 2000, 'phone': 2000, 'share': 1000, 'gen': 1000, 'plugins': 500};

/// v3's further ceilings. Tokens run high: a long chat sends its whole
/// context with every call.
const usageCountLimitsV3 = {'tavern': 5000, 'room': 1000, 'call': 500, 'tok_in': 2000000000, 'tok_out': 200000000};

/// ABIs the share host takes.
const usageAbis = {'arm64-v8a', 'armeabi-v7a', 'x86_64', 'x86'};

/// How the on-device engine was launched (`engine`), when it ran that day.
const usageEngineModes = {'direct', 'proot'};

/// Past days reported at most this far back; older ones are dropped.
const usageBackfillDays = 7;

/// Tries per day before it is given up.
const usageMaxTries = 3;

/// How long one install id is used before a new one is drawn.
const usageIidLifetime = Duration(days: 90);

/// A local date as the request writes it: `2026-10-30`.
String usageDay(DateTime t) =>
    '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

DateTime? _parseDay(String day) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(day);
  if (m == null) return null;
  final date = DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  // 2026-02-30 is no day.
  return usageDay(date) == day ? date : null;
}

/// Today in UTC+8, whatever the phone's zone: the share host takes days from
/// 7 before it to the one after it.
DateTime _hostToday(DateTime now) {
  final t = now.toUtc().add(const Duration(hours: 8));
  return DateTime(t.year, t.month, t.day);
}

/// A fresh install id: 128 random bits, base64url without padding (22
/// characters).
String newUsageIid([Random? random]) {
  final r = random ?? Random.secure();
  return base64Url.encode([for (var i = 0; i < 16; i++) r.nextInt(256)]).replaceAll('=', '');
}

/// One day's numbers.
class UsageDayRecord {
  UsageDayRecord({
    Map<UsageCount, int>? counts,
    this.plugins = 0,
    this.engine,
    this.tries = 0,
    this.tokensIn = 0,
    this.tokensOut = 0,
  }) : counts = counts ?? {};

  factory UsageDayRecord.fromJson(Map<String, Object?> json) {
    int n(Object? v) => v is int && v >= 0 ? v : 0;
    final engine = json['engine'];
    return UsageDayRecord(
      counts: {for (final c in UsageCount.values) c: n(json[c.name])},
      plugins: n(json['plugins']),
      engine: engine is String && usageEngineModes.contains(engine) ? engine : null,
      tries: n(json['tries']),
      tokensIn: n(json['tok_in']),
      tokensOut: n(json['tok_out']),
    );
  }

  final Map<UsageCount, int> counts;

  /// Input tokens model replies reported that day (cached input included).
  int tokensIn;

  /// Output tokens model replies reported that day.
  int tokensOut;

  /// Plugins installed on the host, as last seen that day.
  int plugins;

  /// The on-device engine's launch, as last seen running that day.
  String? engine;

  /// Sends that failed so far.
  int tries;

  int operator [](UsageCount c) => counts[c] ?? 0;

  Map<String, Object?> toJson() => {
    for (final c in UsageCount.values) c.name: this[c],
    'plugins': plugins,
    'tok_in': tokensIn,
    'tok_out': tokensOut,
    'engine': ?engine,
    'tries': tries,
  };
}

/// The days kept on the phone until each has gone out (or is given up).
class UsageLedger {
  UsageLedger({Map<String, UsageDayRecord>? days, this.lastPlugins = 0}) : days = days ?? {};

  /// From [encode]; empty for anything unreadable.
  factory UsageLedger.decode(String? text) {
    if (text == null || text.isEmpty) return UsageLedger();
    try {
      final json = jsonDecode(text);
      if (json is! Map<String, Object?>) return UsageLedger();
      final days = json['days'];
      final plugins = json['lastPlugins'];
      return UsageLedger(
        days: {
          if (days is Map<String, Object?>)
            for (final MapEntry(:key, :value) in days.entries)
              if (_parseDay(key) != null && value is Map<String, Object?>) key: UsageDayRecord.fromJson(value),
        },
        lastPlugins: plugins is int && plugins >= 0 ? plugins : 0,
      );
    } on FormatException {
      return UsageLedger();
    }
  }

  final Map<String, UsageDayRecord> days;

  /// The plugin count last seen: a day that never reads the list starts
  /// from it.
  int lastPlugins;

  String encode() => jsonEncode({
    'days': {for (final MapEntry(:key, :value) in days.entries) key: value.toJson()},
    'lastPlugins': lastPlugins,
  });

  UsageDayRecord _today(DateTime now) => days.putIfAbsent(usageDay(now), () => UsageDayRecord(plugins: lastPlugins));

  /// The app was in use today, counted or not.
  void touch(DateTime now) => _today(now);

  /// Tokens a model reply reported: [input] (cached input included) and
  /// [output]. Never an estimate.
  void tokens(int input, int output, DateTime now) {
    if (input <= 0 && output <= 0) return;
    final day = _today(now);
    // Far past any ceiling: the sum can't overflow, and is sent as the ceiling.
    const cap = 1 << 50;
    day.tokensIn = min(cap, day.tokensIn + max(0, input));
    day.tokensOut = min(cap, day.tokensOut + max(0, output));
  }

  void count(UsageCount c, DateTime now) {
    final day = _today(now);
    day.counts[c] = day[c] + 1;
  }

  void plugins(int installed, DateTime now) {
    lastPlugins = max(0, installed);
    _today(now).plugins = lastPlugins;
  }

  void engine(String mode, DateTime now) {
    if (usageEngineModes.contains(mode)) _today(now).engine = mode;
  }

  /// The days to send now, oldest first: before today, at most
  /// [usageBackfillDays] back (and no further back than the share host takes,
  /// on a phone behind UTC+8), not yet given up. Older days are dropped.
  List<String> due(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final local = DateTime(now.year, now.month, now.day - usageBackfillDays);
    final host = _hostToday(now);
    final hostOldest = DateTime(host.year, host.month, host.day - usageBackfillDays);
    final oldest = hostOldest.isAfter(local) ? hostOldest : local;
    days.removeWhere((key, record) {
      final day = _parseDay(key);
      return day == null || day.isBefore(oldest) || record.tries >= usageMaxTries;
    });
    return [
      for (final key in days.keys)
        if (_parseDay(key)!.isBefore(today)) key,
    ]..sort();
  }

  /// It went out: never again.
  void sent(String day) => days.remove(day);

  /// The share host won't take it (or it would refuse it): never tried again.
  void drop(String day) => days.remove(day);

  /// It didn't: one try used, the day given up after [usageMaxTries].
  void failed(String day) {
    final record = days[day];
    if (record == null) return;
    record.tries++;
    if (record.tries >= usageMaxTries) days.remove(day);
  }
}

/// What the phone says about itself, nothing that tells one phone from
/// another: the build, the Android level, the CPU, and in lower case the
/// maker, the model and the maker's system with its version.
class UsageDevice {
  const UsageDevice({
    this.app = '',
    this.build = 0,
    this.sdk = 0,
    this.abi = '',
    this.maker = '',
    this.model = '',
    this.rom = '',
  });

  /// Version name, `0.9.9`.
  final String app;

  /// Version code, `10301000`.
  final int build;
  final int sdk;

  /// `arm64-v8a`, `x86_64`.
  final String abi;

  /// `Build.MANUFACTURER` in lower case: `vivo`.
  final String maker;

  /// `Build.MODEL` in lower case: `v2405a`. Empty without the native side.
  final String model;

  /// The maker's system and its version: `originos 5.0`, `android` when it
  /// isn't one we know. Empty without the native side.
  final String rom;
}

/// `Build.MANUFACTURER` the way the share host takes it: lower case, ASCII
/// letters, digits, spaces and `. _ -`, starting with a letter or digit, 32
/// at most, `unknown` when nothing is left (as usage/UsagePlugin.kt does it).
String usageMaker(String raw) {
  final kept = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ._-]'), '').replaceFirst(RegExp(r'^[^a-z0-9]+'), '');
  final cut = (kept.length > 32 ? kept.substring(0, 32) : kept).trim();
  return cut.isEmpty ? 'unknown' : cut;
}

/// The request body for [day] in contract [version] at most: exactly
/// [usagePayloadKeys], and in `counts` exactly [usageCountKeys], each at
/// most its [usageCountLimits].
///
/// v2 adds the model and system ([usagePayloadKeysV2]); v3 also the counts
/// in [usageCountKeysV3]. Without the model and system from the native side
/// the body stays v1.
Map<String, Object> usagePayload({
  required String iid,
  required String day,
  required UsageDayRecord record,
  required UsageDevice device,
  required String lang,
  int version = usageContract,
}) {
  final v = device.model.isNotEmpty && device.rom.isNotEmpty ? version.clamp(1, usageContract) : 1;
  int capped(String key, int n) => min(n, usageCountLimits[key] ?? usageCountLimitsV3[key]!);
  return {
    'v': v,
    'iid': iid,
    'day': day,
    'app': device.app,
    'build': device.build,
    'sdk': device.sdk,
    'abi': device.abi,
    'maker': device.maker,
    if (v >= 2) ...{'model': device.model, 'rom': device.rom},
    'lang': lang,
    'engine': record.engine ?? 'none',
    'counts': {
      for (final c in UsageCount.values)
        if (v >= 3 || !usageCountsV3.contains(c)) c.name: capped(c.name, record[c]),
      'plugins': capped('plugins', record.plugins),
      if (v >= 3) ...{'tok_in': capped('tok_in', record.tokensIn), 'tok_out': capped('tok_out', record.tokensOut)},
    },
  };
}

/// What the share host would object to in [body] at [now], by the rules of
/// docs/design/share-links.md §15: the field's name, or null when it takes
/// it. A body it would refuse is never sent.
String? usageProblem(Map<String, Object?> body, DateTime now) {
  bool matches(Object? v, String pattern) => v is String && RegExp(pattern).hasMatch(v);
  bool within(Object? v, int low, int high) => v is int && v >= low && v <= high;
  final v = body['v'];
  if (v != 1 && v != 2 && v != 3) return 'v';
  final keys = v == 1 ? usagePayloadKeys : usagePayloadKeysV2;
  for (final key in body.keys) {
    if (!keys.contains(key)) return key;
  }
  for (final key in keys) {
    if (!body.containsKey(key)) return key;
  }
  if (!matches(body['iid'], r'^[A-Za-z0-9_-]{21}[AQgw]$')) return 'iid';
  final day = body['day'];
  final date = day is String ? _parseDay(day) : null;
  final host = _hostToday(now);
  if (date == null ||
      date.isBefore(DateTime(host.year, host.month, host.day - usageBackfillDays)) ||
      date.isAfter(DateTime(host.year, host.month, host.day + 1))) {
    return 'day';
  }
  if (!matches(body['app'], r'^\d{1,3}\.\d{1,3}\.\d{1,3}(?:-[0-9A-Za-z.]{1,20})?$')) return 'app';
  if (!within(body['build'], 1, 2100000000)) return 'build';
  if (!within(body['sdk'], 26, 60)) return 'sdk';
  if (!usageAbis.contains(body['abi'])) return 'abi';
  if (!matches(body['maker'], r'^[A-Za-z0-9][A-Za-z0-9 ._-]{0,31}$')) return 'maker';
  if (v != 1 && !matches(body['model'], r'^[A-Za-z0-9][A-Za-z0-9 ._-]{0,31}$')) return 'model';
  if (v != 1 && !matches(body['rom'], r'^[A-Za-z0-9][A-Za-z0-9 ._-]{0,31}$')) return 'rom';
  if (!matches(body['lang'], r'^[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})?$')) return 'lang';
  if (!{...usageEngineModes, 'none'}.contains(body['engine'])) return 'engine';
  final counts = body['counts'];
  if (counts is! Map<String, Object?>) return 'counts';
  final countKeys = v == 3 ? usageCountKeysV3 : usageCountKeys;
  for (final key in counts.keys) {
    if (!countKeys.contains(key)) return 'counts.$key';
  }
  final limits = {...usageCountLimits, if (v == 3) ...usageCountLimitsV3};
  for (final MapEntry(:key, value: limit) in limits.entries) {
    if (!within(counts[key], 0, limit)) return 'counts.$key';
  }
  return null;
}

/// What the share host's answer means for the day it was about.
enum UsageReply {
  /// 2xx: done with that day.
  sent,

  /// 400, 413, 415: it won't ever take it; the day is given up.
  refused,

  /// 404: the host collects nothing now; nothing more is tried today.
  closed,

  /// 429, 5xx, anything else, or no answer: tried again later, as one of
  /// the day's [usageMaxTries].
  later;

  static UsageReply of(int? status) => switch (status) {
    final int s when s >= 200 && s < 300 => sent,
    400 || 413 || 415 => refused,
    404 => closed,
    _ => later,
  };
}
