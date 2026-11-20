// A plugin's own page: one seat at page size (docs/design/plugin-seams.md §3):
// a settings form drawn natively, a web island, or, when neither can come up,
// the way to DSH Web.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../plugins/seams/seams.dart';
import '../../common/empty_view.dart';
import '../../shell/page_frame.dart';
import '../../theme/app_icons.dart';

class PluginSeatPage extends ConsumerWidget {
  const PluginSeatPage({super.key, required this.title, required this.request});

  final String title;

  /// A [SeatPlacement.page] seat, usually narrowed to one package and cell.
  final SeatRequest request;

  static Route<void> route({required String title, required SeatRequest request}) => MaterialPageRoute<void>(
    builder: (_) => PluginSeatPage(title: title, request: request),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(seatPlanProvider(request)).visible;
    Widget seat({SeatLayout? layout}) => PluginSeat(
      slot: request.slot,
      placement: SeatPlacement.page,
      sessionId: request.sessionId,
      package: request.package,
      cell: request.cell,
      layout: layout,
    );
    // A form reads like any settings page.
    if (items.isNotEmpty && items.every((i) => i.mode == SeatMode.native)) {
      return AppPage.list(title: title, children: [seat()]);
    }
    // An island (or the way to DSH Web) takes the page under the bar.
    return AppPage(
      title: title,
      showLargeTitle: false,
      padBottom: false,
      slivers: [
        SliverFillRemaining(hasScrollBody: true, child: items.isEmpty ? const _Gone() : seat(layout: fillSeatLayout)),
      ],
    );
  }
}

/// Lays out a seat's items by [PluginSeat.layout].
typedef SeatLayout = Widget Function(BuildContext context, List<Widget> children);

/// A seat that fills its box: one item takes all of it, several share it.
Widget fillSeatLayout(BuildContext context, List<Widget> children) => children.length == 1
    ? children.single
    : Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [for (final child in children) Expanded(child: child)],
      );

/// The plugin went away (turned off, removed) while its page was open.
class _Gone extends StatelessWidget {
  const _Gone();

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: EmptyView(icon: AppIcons.plugin, title: context.l10n.catalogSeatGone),
    ),
  );
}
