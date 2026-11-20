// What a reply inside the replay page belongs to, for the actions that would
// otherwise look at the open chat (「分享」).

import 'package:flutter/widgets.dart';

import '../../share_code/conversation_share.dart';
import 'replay_frame.dart';

class ReplayScope extends InheritedWidget {
  const ReplayScope({
    super.key,
    required this.share,
    required this.frames,
    this.assets = const {},
    required super.child,
  });

  final ConversationShare share;
  final ReplayFrames frames;

  /// The file's pictures by asset id.
  final Map<String, ConversationAsset> assets;

  static ReplayScope? maybeOf(BuildContext context) => context.getInheritedWidgetOfExactType<ReplayScope>();

  @override
  bool updateShouldNotify(ReplayScope oldWidget) => !identical(oldWidget.share, share);
}
