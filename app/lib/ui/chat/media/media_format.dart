// Words and numbers of the media card, viewer and details: the metadata line,
// costs, clip lengths, failures. One place, so they all say it the same way.

import 'package:dsh_client/dsh_client.dart';

import '../../../l10n/l10n.dart';
import 'generate_header.dart';

/// The batch's width / height: the first item's when known, else the
/// requested aspect, else square.
double mediaAspectOf(MediaMeta meta) {
  for (final item in meta.items) {
    if (item.aspect case final a? when a > 0) return a;
  }
  return meta.request.ratio ?? (meta.kind == MediaKind.video ? 16 / 9 : 1);
}

/// `0:05`, `1:20`.
String formatClip(double seconds) {
  final total = seconds.round();
  final m = total ~/ 60;
  final s = total % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// `¥0.30`, `¥4`, `$0.05`: two decimals unless whole.
String formatMoney(double amount, String currency) {
  final symbol = switch (currency.toUpperCase()) {
    'CNY' || 'RMB' => '¥',
    'USD' => r'$',
    'EUR' => '€',
    _ => '${currency.toUpperCase()} ',
  };
  final whole = amount == amount.roundToDouble();
  return '$symbol${whole ? amount.toStringAsFixed(0) : amount.toStringAsFixed(2)}';
}

/// 「约 ¥0.30」; null when the plugin gave no reliable price.
String? mediaCostText(MediaCost? cost) =>
    cost == null ? null : appL10n.mediaCostEstimate(formatMoney(cost.estimate, cost.currency));

/// What follows the model on the metadata line: the aspect (or the video's
/// resolution), and the cost when it is known. Before a result, and after a
/// failure, what was asked for: 「2 张」, 「5 秒 · 720p」 (§5.3).
List<String> mediaMetaTail(MediaMeta meta) {
  final request = meta.request;
  final made = meta.items.length;
  final asked = request.n;
  if (meta.status != MediaStatus.done) {
    return [
      if (meta.kind == MediaKind.video) ...[
        if (request.seconds case final s? when s > 0) appL10n.mediaSeconds(s.round()),
        ?request.resolution,
      ] else if (asked != null && asked > 0)
        appL10n.mediaCount(asked)
      else
        ?request.aspect,
    ];
  }
  return [
    if (meta.kind == MediaKind.video) ...[
      if (request.seconds case final s? when s > 0 && meta.items.isEmpty) appL10n.mediaSeconds(s.round()),
      ?request.resolution,
    ] else
      ?request.aspect,
    if (meta.status == MediaStatus.done && asked != null && made < asked) appL10n.mediaPartial(made, asked),
    ?mediaCostText(meta.cost),
  ];
}

/// One sentence for a failure (§5.3); the code stays in 详情.
String mediaErrorText(MediaFailure? error) {
  final code = error?.code ?? '';
  final stage = error?.text ?? '';
  return switch (code) {
    // The plugin may say where it was stopped in the text: input or output.
    'policy' when stage == 'output' => appL10n.mediaErrorPolicyOutput,
    'policy' || 'policy-input' => appL10n.mediaErrorPolicyInput,
    'policy-output' => appL10n.mediaErrorPolicyOutput,
    'auth' || 'unauthorized' => appL10n.mediaErrorAuth,
    'balance' || 'insufficient-balance' => appL10n.mediaErrorBalance,
    'quota' || 'daily-limit' => appL10n.mediaErrorQuota,
    'unavailable' || 'network' || 'timeout' || 'server' => appL10n.mediaErrorUnavailable,
    'expired' => appL10n.mediaErrorExpired,
    _ when stage.isNotEmpty && code.isEmpty => stage,
    _ => appL10n.mediaErrorGeneric,
  };
}

/// 「图像 · 3:4 · 2 张」 / 「视频 · 5 秒 · 720p」: the small line under a
/// generation request and in the mode capsule.
String mediaParamsLine({required bool video, String? aspect, int? count, int? seconds, String? resolution}) => [
  video ? appL10n.mediaKindVideo : appL10n.mediaKindImage,
  if (video) ...[
    if (seconds != null) appL10n.mediaSeconds(seconds),
    ?resolution,
  ] else ...[
    ?aspect,
    if (count != null) appL10n.mediaCount(count),
  ],
].join(' · ');

/// A conversation title as shown: one that begins with a generation
/// request's header shows what follows it, or 「生成图像」 / 「生成视频」 when
/// nothing does.
String chatTitleShown(String title) => switch (GenerateHeader.splitTitle(title)) {
  null => title,
  (:final rest, kind: _) when rest.isNotEmpty => rest,
  (:final kind, rest: _) => kind == GenerateKind.video ? appL10n.mediaTitleVideo : appL10n.mediaTitleImage,
};
