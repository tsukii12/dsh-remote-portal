// A Bot's face in the app: its photo, else its initial on a tint of its DS
// Bot color (the web client draws characters this app does not have), and a
// group's members stacked.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/bots_state.dart';
import '../common/display_image.dart';
import '../common/status_dot.dart';
import '../fx/bot_avatar/bot_avatar.dart' as fx;
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'bot_format.dart';

/// The Bot's color for the current theme.
Color botInk(BuildContext context, String color) =>
    Color(dsBotInkArgb(color, dark: Theme.of(context).brightness == Brightness.dark));

/// Name text in the Bot's color: black reads as a heading, so it goes gray.
Color botNameInk(BuildContext context, String color) => botInk(context, color == 'black' ? 'gray' : color);

/// Round avatar: the Bot's photo, else a little bot of its own (see [mascot]).
/// [working] adds a breathing dot at the lower right of a photo or letter; the
/// little bot hops instead.
class BotAvatar extends ConsumerWidget {
  const BotAvatar({super.key, required this.bot, this.size = 40, this.working = false, this.mascot = true});

  final DsBot bot;
  final double size;
  final bool working;

  /// Without a photo, a Libraries.dev bot rather than the initial. Stacked
  /// group faces keep the initial: two bots overlapping hide each other.
  final bool mascot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ref0 = bot.imageRef;
    final photo = ref0 == null ? null : ref.watch(dsBotPhotoProvider((botId: bot.id, ref: ref0))).value;
    // No photo: a Libraries.dev bot in the Bot's own colour, the same one for
    // this Bot every time; it hops while the Bot works, so no dot is needed.
    final Widget fallback = mascot
        ? fx.BotAvatar(
            id: bot.id,
            size: size,
            color: botInk(context, bot.ink),
            state: working ? fx.BotAvatarState.working : fx.BotAvatarState.idle,
            // Glossy plastic: drawn on the first frame; plush fur bakes in the background.
            shading: fx.BotAvatarShading.plastic,
            excludeFromSemantics: true,
          )
        : BotMonogram(name: bot.name, color: bot.ink, size: size);
    if (photo == null && mascot) return ExcludeSemantics(child: fallback);
    final face = photo == null
        ? fallback
        : ClipOval(
            child: Image(
              image: imageForDisplay(
                MemoryImage(photo),
                width: size,
                height: size,
                pixelRatio: MediaQuery.devicePixelRatioOf(context),
              ),
              width: size,
              height: size,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (context, _, _) => fallback,
            ),
          );
    if (!working) return ExcludeSemantics(child: face);
    final dot = (size * 0.28).clamp(8.0, 12.0);
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            face,
            Positioned(
              right: -1,
              bottom: -1,
              child: DecoratedBox(
                decoration: ShapeDecoration(color: DshSurfaces.of(context).backdropTop, shape: const CircleBorder()),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: StatusDot(tone: StatusTone.busy, size: dot),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The initial on a soft tint of the Bot's color, centered optically.
class BotMonogram extends StatelessWidget {
  const BotMonogram({super.key, required this.name, required this.color, this.size = 40});

  final String name;
  final String color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ink = botInk(context, color);
    final text = botNameInk(context, color);
    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: ink.withValues(alpha: dark ? 0.26 : 0.16),
          shape: const CircleBorder(),
        ),
        child: Center(
          child: Text(
            monogramOf(name),
            textScaler: TextScaler.noScaling,
            textHeightBehavior: const TextHeightBehavior(
              applyHeightToFirstAscent: false,
              applyHeightToLastDescent: false,
            ),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontSize: size * 0.42,
              height: 1,
              fontWeight: FontWeight.w600,
              color: text,
              leadingDistribution: TextLeadingDistribution.even,
            ),
          ),
        ),
      ),
    );
  }
}

/// A group: its first two members, the second over the first's lower right.
class RoomAvatar extends StatelessWidget {
  const RoomAvatar({super.key, required this.room, required this.team, this.size = 40});

  final DsBotRoom room;
  final DsBotTeam team;
  final double size;

  @override
  Widget build(BuildContext context) {
    final members = [
      for (final id in [if (room.admin != null) room.admin!, ...room.members.where((m) => m != room.admin)])
        ?team.bot(id),
    ];
    if (members.isEmpty) {
      return SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.07),
            shape: const CircleBorder(),
          ),
          child: Icon(AppIcons.groupChat, size: size * 0.5, color: DshColors.of(context).textTertiary),
        ),
      );
    }
    if (members.length == 1) return BotAvatar(bot: members.first, size: size);
    final small = size * 0.6;
    final gap = (size * 0.05).clamp(1.5, 3.0);
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              child: ClipPath(
                clipper: _RearClipper(offset: size - small, gap: gap),
                child: BotAvatar(bot: members[0], size: small, mascot: false),
              ),
            ),
            Positioned(
              right: 0,
              bottom: 0,
              child: BotAvatar(bot: members[1], size: small, mascot: false),
            ),
          ],
        ),
      ),
    );
  }
}

/// The rear face minus the front one grown by [gap]: a clear seam between the
/// two, with no backdrop-coloured ring painted over the rear initial.
class _RearClipper extends CustomClipper<Path> {
  const _RearClipper({required this.offset, required this.gap});

  final double offset;
  final double gap;

  @override
  Path getClip(Size size) {
    final front = Rect.fromCircle(center: size.center(Offset(offset, offset)), radius: size.width / 2 + gap);
    return Path.combine(PathOperation.difference, Path()..addOval(Offset.zero & size), Path()..addOval(front));
  }

  @override
  bool shouldReclip(_RearClipper old) => old.offset != offset || old.gap != gap;
}
