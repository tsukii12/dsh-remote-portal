/// The lightweight companion's local host-shaped object (ADDENDUM-02).
/// Pass CompanionPackStore.root. This file uses no Flutter or engine APIs.
library;

import 'dart:io';

import 'package:dsh_client/companion.dart';

/// Owns `<root>/light-state.json`, beside light-chat.json and pack/.
/// Keep one owning isolate; instances sharing root use the core store queue.
class CompanionLocal extends CompanionLocalStore {
  CompanionLocal.at(Directory root, {super.nowMilliseconds}) : super(appDirectory: root);
}
