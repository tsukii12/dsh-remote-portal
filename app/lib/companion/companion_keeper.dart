// Where her state and confirmed memories are kept: the active host's bridge
// (full mode) or this phone's light-state.json (light mode, companion_local.dart).
// Both answer the same calls, with the same revisions and the same conflict
// errors, so the room and the memories page work the same either way.

import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'companion_local.dart';

/// Light mode's keeper for a companion folder (CompanionPackStore.root).
/// Widget tests answer it in memory: real file I/O doesn't run on their clock.
final companionPhoneKeeperProvider = Provider<CompanionKeeper Function(Directory root)>(
  (ref) =>
      (root) => PhoneKeeper(CompanionLocal.at(root)),
);

abstract interface class CompanionKeeper {
  /// Null when this keeper can't keep her state (a host without the bridge).
  Future<CompanionSnapshot?> snapshot();

  Future<CompanionSnapshot> event(CompanionSnapshot read, String type);

  Future<CompanionMemories> memories();

  Future<int> saveMemory(String storeId, int revision, CompanionMemory memory);

  Future<int> deleteMemory(String storeId, int revision, String id);
}

/// Full mode: the host's bridge (`/dsh-go/v1/companion`).
class HostKeeper implements CompanionKeeper {
  HostKeeper(this.client);

  final DshClient client;

  @override
  Future<CompanionSnapshot?> snapshot() => client.companionSnapshot();

  @override
  Future<CompanionSnapshot> event(CompanionSnapshot read, String type) => client.companionEvent(read, type);

  @override
  Future<CompanionMemories> memories() => client.companionMemories();

  @override
  Future<int> saveMemory(String storeId, int revision, CompanionMemory memory) =>
      client.saveCompanionMemory(storeId, revision, memory);

  @override
  Future<int> deleteMemory(String storeId, int revision, String id) =>
      client.deleteCompanionMemory(storeId, revision, id);
}

/// Light mode: this phone, no host and no engine.
class PhoneKeeper implements CompanionKeeper {
  PhoneKeeper(this.local);

  final CompanionLocal local;

  @override
  Future<CompanionSnapshot?> snapshot() => local.companionSnapshot();

  @override
  Future<CompanionSnapshot> event(CompanionSnapshot read, String type) =>
      local.companionEvent(read.storeId, read.revision, type);

  @override
  Future<CompanionMemories> memories() => local.companionMemories();

  @override
  Future<int> saveMemory(String storeId, int revision, CompanionMemory memory) =>
      local.saveCompanionMemory(storeId, revision, memory);

  @override
  Future<int> deleteMemory(String storeId, int revision, String id) =>
      local.deleteCompanionMemory(storeId, revision, id);
}
