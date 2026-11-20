import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/read_list_epoch.dart';
import 'package:dsh_app/state/subscriptions_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _QuotaCarrier extends DshCarrier {
  _QuotaCarrier(this.percent);

  final double percent;
  int calls = 0;

  @override
  String get kind => 'memory';

  @override
  DshTracer? get tracer => null;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    expect(endpoint, 'appAuth/usage');
    expect(args, {'provider': 'openai-codex'});
    calls++;
    return RpcOk({
      'provider': 'openai-codex',
      'status': 'ok',
      'windows': [
        {'id': 'primary', 'usedPercent': percent},
      ],
    });
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw UnsupportedError('no streams');

  @override
  Future<void> close() async {}
}

void main() {
  test('quota never uses retained connections while loading or failed', () async {
    final firstCarrier = _QuotaCarrier(75);
    final secondCarrier = _QuotaCarrier(10);
    final first = HostConnection(hostId: '', client: DshClient.withCarrier(firstCarrier), isLocal: true);
    final second = HostConnection(hostId: '', client: DshClient.withCarrier(secondCarrier), isLocal: false);
    AsyncValue<HostConnection?> active = AsyncData(first);
    final container = ProviderContainer(overrides: [activeConnectionProvider.overrideWith((ref) => active)]);
    final provider = subscriptionUsageProvider(Subscription.chatgpt);
    final subscription = container.listen(provider, (_, _) {});
    addTearDown(() async {
      subscription.close();
      container.dispose();
      await first.client.close();
      await second.client.close();
    });

    expect((await container.read(provider.future))!.windows.single.usedPercent, 75);
    expect(firstCarrier.calls, 1);

    // Deliberately model the retained data produced by a Riverpod host rebuild.
    // ignore: invalid_use_of_internal_member
    active = const AsyncLoading<HostConnection?>().copyWithPrevious(AsyncData(first));
    container.invalidate(activeConnectionProvider);
    expect(await container.read(provider.future), isNull);
    expect(firstCarrier.calls, 1);

    // Exercise the same retained-data guard after a failed rebuild.
    // ignore: invalid_use_of_internal_member
    active = AsyncError<HostConnection?>(StateError('offline'), StackTrace.current).copyWithPrevious(AsyncData(first));
    container.invalidate(activeConnectionProvider);
    expect(await container.read(provider.future), isNull);
    expect(firstCarrier.calls, 1);

    active = AsyncData(second);
    container.invalidate(activeConnectionProvider);
    expect((await container.read(provider.future))!.windows.single.usedPercent, 10);
    expect(firstCarrier.calls, 1);
    expect(secondCarrier.calls, 1);

    container.read(readListCredentialEpochProvider.notifier).advance();
    expect((await container.read(provider.future))!.windows.single.usedPercent, 10);
    expect(secondCarrier.calls, 2);
  });
}
