// What the live stream says about a running turn that the transcript does not
// keep, i.e. how fast tokens are flowing right now (for the whale-tail
// indicator) and whether the context is being compacted. The token estimate
// follows DeepSeek's published rule of thumb (1 Chinese character ≈ 0.6
// token, 1 English character ≈ 0.3 token).

import 'dart:async';
import 'dart:math' as math;

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'notify_state.dart' show appForegroundProvider;

/// 流式文本的 token 估算:中文(含日韩)字 × 0.6,其余非空白字符 × 0.3。
///
/// 系数是 DeepSeek 文档给的经验值;空白不计(分词器把缩进、空格大多并进
/// 相邻 token)。只用来测速,不用来算钱。
double estimateTokens(String text) {
  var cjk = 0;
  var other = 0;
  for (final rune in text.runes) {
    if (rune <= 0x20 || rune == 0x3000) continue;
    if ((rune >= 0x3400 && rune <= 0x9FFF) ||
        (rune >= 0xF900 && rune <= 0xFAFF) ||
        (rune >= 0x3040 && rune <= 0x30FF) ||
        (rune >= 0xAC00 && rune <= 0xD7A3) ||
        (rune >= 0x20000 && rune <= 0x3FFFF)) {
      cjk++;
    } else {
      other++;
    }
  }
  return cjk * 0.6 + other * 0.3;
}

/// 滑动窗口里的输出速度(token/秒)。
///
/// 每个增量带着它产生的时刻进来;速度 = 窗口内的 token ÷ 窗口长度。窗口
/// 刚开始(一段输出的头 [window] 内)按实际经过的时间算,但至少按
/// [minSpan] 算,免得第一块字被除以几毫秒。最后一块之后安静超过
/// [stallAfter] 就算停了(等工具、等你确认),速度为 0。
class TokenRateMeter {
  TokenRateMeter({
    this.window = const Duration(milliseconds: 2500),
    this.minSpan = const Duration(milliseconds: 500),
    this.stallAfter = const Duration(milliseconds: 1200),
  });

  final Duration window;
  final Duration minSpan;
  final Duration stallAfter;

  final _samples = <({DateTime at, double tokens})>[];

  /// 这一段连续输出从什么时候开始(中间停过 [stallAfter] 就重新算)。
  DateTime? _burstStart;

  /// 最后一块到达的时刻;没有为 null。
  DateTime? get lastAt => _samples.isEmpty ? null : _samples.last.at;

  void add(DateTime at, double tokens) {
    if (tokens <= 0) return;
    final last = lastAt;
    if (last == null || at.difference(last) > stallAfter) _burstStart = at;
    // Out-of-order times (clock estimate moved) keep the list sorted enough:
    // a sample is never placed before the newest one.
    final when = last != null && at.isBefore(last) ? last : at;
    _samples.add((at: when, tokens: tokens));
  }

  void clear() {
    _samples.clear();
    _burstStart = null;
  }

  /// [now] 时的速度;停了或没有数据为 0。
  double rateAt(DateTime now) {
    final last = lastAt;
    if (last == null || now.difference(last) > stallAfter) return 0;
    final from = now.subtract(window);
    _samples.removeWhere((s) => s.at.isBefore(from));
    if (_samples.isEmpty) return 0;
    final start = _burstStart != null && _burstStart!.isAfter(from) ? _burstStart! : from;
    final span = now.difference(start);
    final seconds = (span < minSpan ? minSpan : span).inMicroseconds / 1e6;
    final tokens = _samples.fold<double>(0, (sum, s) => sum + s.tokens);
    return tokens / seconds;
  }
}

/// 速度 → 鲸尾的四档,带迟滞。
///
/// | 档 | 意思 | 进入 | 退出 |
/// |---|---|---|---|
/// | 1 | 没有 token 在流(等模型首字、跑工具、等你) | — | — |
/// | 2 | 慢慢吐字 | > 0 | 停了 |
/// | 3 | 正常速度 | ≥ 30 tok/s | < 24 |
/// | 4 | 飞快 | ≥ 75 tok/s | < 60 |
///
/// 阈值的依据:DeepSeek 官方 API 的输出大多在每秒几十到一百出头 token
/// (V4 Flash 偏快,Pro 和长思考偏慢),30 以下肉眼就是"一个字一个字往外
/// 蹦",75 以上整段整段地出。退出线是进入线的 0.8 倍,速度在线附近抖动时
/// 不来回跳;另外每档至少停 [minDwell],档位不会一秒内换好几次。
class SpeedGauge {
  SpeedGauge({this.minDwell = const Duration(milliseconds: 900)});

  final Duration minDwell;

  static const enterAt = <int, double>{3: 30, 4: 75};
  static const exitRatio = 0.8;

  int _level = 1;
  DateTime? _changedAt;

  int get level => _level;

  /// 按 [tps] 推进档位并返回;[now] 只用来判断停留时间。
  int update(double tps, DateTime now) {
    final target = targetFor(tps, _level);
    if (target == _level) return _level;
    final changed = _changedAt;
    if (changed != null && now.difference(changed) < minDwell) return _level;
    _level = target;
    _changedAt = now;
    return _level;
  }

  void reset() {
    _level = 1;
    _changedAt = null;
  }

  /// 不考虑停留时间的目标档位(纯函数,测试用)。
  static int targetFor(double tps, int current) {
    if (tps <= 0) return 1;
    var level = math.max(current, 2);
    while (level < 4 && tps >= enterAt[level + 1]!) {
      level++;
    }
    while (level > 2 && tps < enterAt[level]! * exitRatio) {
      level--;
    }
    return level;
  }
}

/// 一个会话的实时脉搏:鲸尾档位、估算速度、是否正在压缩上下文。
///
/// [ChatController] 把每个事件交给 [observe];界面监听它(档位或压缩状态
/// 变了才通知)。有 token 在流时每 [tick] 重算一次,停下来回到 1 档后计时器
/// 自己停掉。
class RunPulse extends ChangeNotifier {
  RunPulse({
    DateTime Function()? clock,
    this.tick = const Duration(milliseconds: 250),
    TokenRateMeter? meter,
    SpeedGauge? gauge,
  }) : _clock = clock ?? DateTime.now,
       meter = meter ?? TokenRateMeter(),
       gauge = gauge ?? SpeedGauge();

  final DateTime Function() _clock;
  final Duration tick;
  final TokenRateMeter meter;
  final SpeedGauge gauge;

  Timer? _timer;
  bool _disposed = false;
  bool _samplingEnabled = true;

  /// 每个 attempt 下一块的序号(重连重放的块不重复计)。
  final _nextIndex = <String, int>{};

  /// 每个 attempt 估出来的 token,等 usage 块来校准。
  final _attemptEstimate = <String, double>{};

  /// usage ÷ 估算 的滑动校准系数(按会话;没有 usage 时为 1)。
  double _scale = 1;

  double _tps = 0;
  DateTime? _compactingSince;

  /// 鲸尾档位 1–4。
  int get level => gauge.level;

  /// 最近一次算出的速度(token/秒,已校准);停着为 0。
  double get tokensPerSecond => _tps;

  /// 正在压缩上下文时为开始时刻(Host 时间)。
  DateTime? get compactingSince => _compactingSince;

  /// [skew] 是设备时钟减 Host 时钟;已知时块按它产生的时刻计(网络攒了一批
  /// 再到也不会被当成一阵猛冲),未知时按到达时刻计。
  void observe(DshEvent event, {Duration? skew}) {
    switch (event) {
      case AssistantChunkEvent(:final attemptId, :final index, :final chunk):
        final next = _nextIndex[attemptId] ?? 0;
        if (index < next) return;
        _nextIndex[attemptId] = index + 1;
        _chunk(attemptId, chunk, event.time, skew);
      case AssistantStreamEnded(:final attemptId):
        _nextIndex.remove(attemptId);
        _attemptEstimate.remove(attemptId);
      case SessionSnapshotEvent(:final events, :final isResync):
        if (!isResync) {
          _nextIndex.clear();
          _attemptEstimate.clear();
        }
        _setCompacting(compactingAfter(events, _compactingSince, isResync));
      case SessionLogEvent():
        _setCompacting(compactingAfter([event], _compactingSince, true));
      default:
        break;
    }
  }

  void _chunk(String attempt, StreamChunk chunk, DateTime time, Duration? skew) {
    final text = switch (chunk) {
      TextDeltaChunk(:final text) => text,
      ReasoningDeltaChunk(:final text) => text,
      ToolCallDeltaChunk(:final argumentsDelta) => argumentsDelta,
      _ => null,
    };
    if (chunk is UsageChunk) {
      _calibrate(_attemptEstimate[attempt], chunk.usage.outputTokens);
      return;
    }
    if (text == null || text.isEmpty) return;
    final tokens = estimateTokens(text);
    if (tokens <= 0) return;
    _attemptEstimate[attempt] = (_attemptEstimate[attempt] ?? 0) + tokens;
    final now = _clock();
    final local = skew == null ? now : time.add(skew);
    meter.add(local.isAfter(now) ? now : local, tokens);
    _update();
    _ensureTimer();
  }

  /// 估算和真实 usage 差得太远时慢慢拉过去(只信足够长的一段)。
  void _calibrate(double? estimated, int actual) {
    if (estimated == null || estimated < 40 || actual <= 0) return;
    final ratio = (actual / estimated).clamp(0.4, 2.5);
    _scale = _scale * 0.5 + ratio * 0.5;
  }

  void _update() {
    final now = _clock();
    _tps = meter.rateAt(now) * _scale;
    final before = gauge.level;
    if (gauge.update(_tps, now) != before) _notify();
    if (gauge.level == 1 && meter.lastAt == null) _stopTimer();
  }

  /// 计时器的一拍(测试直接调用)。
  @visibleForTesting
  void tickNow() {
    _update();
    final last = meter.lastAt;
    final idle = gauge.level == 1 && (last == null || _clock().difference(last) > meter.stallAfter);
    if (idle) {
      meter.clear();
      _stopTimer();
    }
  }

  /// Pause only the display clock; event ingestion and usage calibration remain
  /// live. On resume, discard a stale rate before scheduling another tick.
  void setSamplingEnabled(bool enabled) {
    if (_disposed || enabled == _samplingEnabled) return;
    _samplingEnabled = enabled;
    if (!enabled) {
      _stopTimer();
      return;
    }
    tickNow();
    if (meter.lastAt != null) _ensureTimer();
  }

  void _ensureTimer() {
    if (_timer != null || _disposed || !_samplingEnabled) return;
    _timer = Timer.periodic(tick, (_) => tickNow());
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _setCompacting(DateTime? since) {
    if (since == _compactingSince) return;
    _compactingSince = since;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopTimer();
    super.dispose();
  }
}

/// 读过 [events] 之后是否还在压缩上下文:最后一个 `compaction/start` 之后
/// 既没有 `compaction/end`,也没有 `turn/end`(崩溃留下的半截括号会被下一个
/// 结束的轮次收掉)。[merge] 为 false 时从头算(新快照),否则接着 [current]。
@visibleForTesting
DateTime? compactingAfter(Iterable<SessionLogEvent> events, DateTime? current, bool merge) {
  var since = merge ? current : null;
  for (final event in events) {
    switch (event.type) {
      case 'compaction/start':
        since = event.time;
      case 'compaction/end' || 'turn/end':
        since = null;
    }
  }
  return since;
}

/// 每个会话一个 [RunPulse];[ChatController] 喂数据,活动条读。
final runPulseProvider = Provider.autoDispose.family<RunPulse, String>((ref, sessionId) {
  final pulse = RunPulse();
  ref.listen(appForegroundProvider, (_, foreground) {
    pulse.setSamplingEnabled(foreground);
  }, fireImmediately: true);
  ref.onDispose(pulse.dispose);
  return pulse;
});
