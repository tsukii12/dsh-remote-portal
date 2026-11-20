import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/bots_state.dart';
import '../../state/hosts_state.dart';

/// Keeps a group approval and its pending UI on the connection that showed it.
class RoomApprovalAction extends ConsumerStatefulWidget {
  const RoomApprovalAction({
    super.key,
    required this.api,
    required this.origin,
    required this.approval,
    required this.builder,
  });
  final DsBotApi api;
  final DsBotStatus origin;
  final DsBotApproval approval;
  final Widget Function(Future<void> Function(bool)? answer) builder;

  @override
  ConsumerState<RoomApprovalAction> createState() => _RoomApprovalActionState();
}

class _RoomApprovalActionState extends ConsumerState<RoomApprovalAction> {
  bool _retired = false;
  int _epoch = 0;
  late final ProviderSubscription<DsBotStatus> _status;
  late final ProviderSubscription<HostRef> _host;
  StreamSubscription<DsBotFeedEvent>? _feed;

  bool _current() => !_retired && _matches();

  bool _matches() {
    if (!mounted) return false;
    final status = ref.read(dsBotProvider);
    final observedBoot = ref.read(dsBotProvider.notifier).observedFeedBoot;
    final originalBoot = widget.origin.hello?.boot;
    if (observedBoot != null && originalBoot != null && originalBoot.isNotEmpty && observedBoot != originalBoot) {
      return false;
    }
    if (!status.ready ||
        status.host != widget.origin.host ||
        ref.read(activeHostProvider) != widget.origin.host ||
        status.hello?.boot != widget.origin.hello?.boot ||
        !identical(ref.read(dsBotProvider.notifier).api, widget.api) ||
        status.team?.room(widget.approval.roomId ?? '') == null) {
      return false;
    }
    return status.live.approvals.any(
      (a) =>
          a.id == widget.approval.id &&
          a.sessionId == widget.approval.sessionId &&
          a.botId == widget.approval.botId &&
          a.roomId == widget.approval.roomId &&
          a.answerable,
    );
  }

  void _retire() {
    if (_retired) return;
    _retired = true;
    _epoch++;
  }

  @override
  void didUpdateWidget(RoomApprovalAction oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A fresh rendering may show the same pending ID again after a transient
    // absence. Old closures keep their epoch and cannot become live again.
    if (_retired && _matches()) _retired = false;
  }

  @override
  void initState() {
    super.initState();
    _status = ref.listenManual(dsBotProvider, (_, _) {
      if (!_current()) _retire();
    });
    _host = ref.listenManual(activeHostProvider, (_, next) {
      if (next != widget.origin.host) _retire();
    });
    final boot = widget.origin.hello?.boot;
    _feed = ref.read(dsBotProvider.notifier).events.listen((event) {
      if (event case DsBotFeedHello(boot: final next?)
          when boot != null && boot.isNotEmpty && next.isNotEmpty && next != boot) {
        _retire();
      }
    });
  }

  Future<void> _answer(int epoch, bool allow) async {
    if (epoch != _epoch || !_current() || ref.read(dsBotProvider).readOnly != null) return;
    try {
      await widget.api.answerApproval(widget.approval.id, allow: allow);
      if (epoch == _epoch && _current()) await ref.read(dsBotProvider.notifier).refresh();
    } catch (error) {
      if (mounted && epoch == _epoch && _current()) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(describeDsBotError(error))));
      }
    }
  }

  @override
  void dispose() {
    _status.close();
    _host.close();
    unawaited(_feed?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final epoch = _epoch;
    return KeyedSubtree(
      key: ValueKey(epoch),
      child: widget.builder(
        _current() && ref.read(dsBotProvider).readOnly == null ? (allow) => _answer(epoch, allow) : null,
      ),
    );
  }
}
