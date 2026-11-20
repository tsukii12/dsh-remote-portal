import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dsh_portal/dsh_portal.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import '../remote/secret_store.dart';
import 'read_list_epoch.dart';
import 'sessions_state.dart';

export '../remote/link_status.dart' show HostLinkStatus, HostLinkPhase, HostLinkStep, HostLinkError, HostLinkErrorKind;

enum HostKind { portal }

class HostRef {
  const HostRef.portal(this.id, {this.name});
  static const none = HostRef.portal('');
  final String id;
  final String? name;
  HostKind get kind => HostKind.portal;
  bool get isLocal => false;
  String encode() => jsonEncode({'kind': 'portal', 'id': id, if (name != null) 'name': name});
  static HostRef decode(String? raw) {
    try {
      final value = jsonDecode(raw ?? '{}');
      return value['kind'] == 'portal' && value['id'] is String
          ? HostRef.portal(value['id'] as String, name: value['name'] as String?)
          : none;
    } on Object {
      return none;
    }
  }

  @override
  bool operator ==(Object other) => other is HostRef && id == other.id;
  @override
  int get hashCode => id.hashCode;
}

String hostLabel(HostKind kind, String? name) => name ?? appL10n.commonRemoteHost;

class PortalHostConfig {
  const PortalHostConfig({required this.id, required this.name, required this.base});
  final String id;
  final String name;
  final Uri base;
  String get cookieKey => 'portal.cookies.${sha256.convert(utf8.encode(base.toString()))}';
  Map<String, String> toJson() => {'id': id, 'name': name, 'base': base.toString()};
  factory PortalHostConfig.fromJson(Map<String, dynamic> json) => PortalHostConfig(
    id: json['id'] as String,
    name: json['name'] as String,
    base: normalizePortalUrl(json['base'] as String),
  );
}

final secretStoreProvider = Provider<SecretStore>((ref) => SecureSecretStore());

class HostsState {
  const HostsState({this.portals = const [], this.loaded = false});
  final List<PortalHostConfig> portals;
  final bool loaded;
  PortalHostConfig? portalById(String id) {
    for (final host in portals) {
      if (host.id == id) return host;
    }
    return null;
  }
}

class HostsController extends Notifier<HostsState> {
  static const prefsKey = 'portal_hosts';
  late Future<void> _loaded;
  Future<void> get ready => _loaded;
  @override
  HostsState build() {
    _loaded = _load();
    return const HostsState();
  }

  Future<void> _load() async {
    var hosts = <PortalHostConfig>[];
    try {
      final prefs = await SharedPreferences.getInstance();
      hosts = (jsonDecode(prefs.getString(prefsKey) ?? '[]') as List)
          .map((v) => PortalHostConfig.fromJson(v as Map<String, dynamic>))
          .toList();
    } on Object {
      /* Corrupt profiles never enable a different host. */
    }
    if (ref.mounted) state = HostsState(portals: hosts, loaded: true);
  }

  Future<void> save(PortalHostConfig host) async {
    await ready;
    state = HostsState(portals: [...state.portals.where((h) => h.id != host.id), host], loaded: true);
    await (await SharedPreferences.getInstance()).setString(
      prefsKey,
      jsonEncode(state.portals.map((h) => h.toJson()).toList()),
    );
  }

  Future<void> remove(String id) async {
    await ready;
    final host = state.portalById(id);
    if (host == null) return;
    await ref.read(secretStoreProvider).delete(host.cookieKey);
    state = HostsState(portals: state.portals.where((h) => h.id != id).toList(), loaded: true);
    await (await SharedPreferences.getInstance()).setString(
      prefsKey,
      jsonEncode(state.portals.map((h) => h.toJson()).toList()),
    );
    if (ref.read(activeHostProvider).id == id) ref.read(activeHostProvider.notifier).select(HostRef.none);
  }
}

final hostsProvider = NotifierProvider<HostsController, HostsState>(HostsController.new);

class ActiveHostController extends Notifier<HostRef> {
  static const prefsKey = 'active_host';
  late Future<void> _loaded;
  bool _touched = false;
  Future<void> get ready => _loaded;
  @override
  HostRef build() {
    _loaded = _restore();
    return HostRef.none;
  }

  Future<void> _restore() async {
    final raw = (await SharedPreferences.getInstance()).getString(prefsKey);
    await ref.read(hostsProvider.notifier).ready;
    if (!ref.mounted || _touched) return;
    final host = HostRef.decode(raw);
    if (ref.read(hostsProvider).portalById(host.id) != null) state = host;
  }

  void select(HostRef host) {
    _touched = true;
    if (host == state) return;
    state = host;
    ref.read(readListCredentialEpochProvider.notifier).advance();
    ref.read(currentSessionProvider.notifier).select(null);
    unawaited(SharedPreferences.getInstance().then((prefs) => prefs.setString(prefsKey, host.encode())));
  }

  Future<void> forget(bool Function(HostRef) predicate) async {
    await ready;
    if (predicate(state)) select(HostRef.none);
  }
}

final activeHostProvider = NotifierProvider<ActiveHostController, HostRef>(ActiveHostController.new);
