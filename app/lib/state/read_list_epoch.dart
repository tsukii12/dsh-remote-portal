import 'package:flutter_riverpod/flutter_riverpod.dart';

/// An in-process invalidation token, never a hash or copy of a credential.
/// Advancing before a credential write also covers a failed/partial write.
class ReadListCredentialEpoch extends Notifier<int> {
  @override
  int build() => 0;

  void advance() => state++;
}

final readListCredentialEpochProvider = NotifierProvider<ReadListCredentialEpoch, int>(ReadListCredentialEpoch.new);
