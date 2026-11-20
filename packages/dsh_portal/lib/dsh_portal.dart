library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';

export 'src/filesystem.dart';

Uri normalizePortalUrl(String input) {
  final value = Uri.tryParse(input.trim());
  if (value == null || !['http', 'https'].contains(value.scheme.toLowerCase()) ||
      value.host.isEmpty || value.userInfo.isNotEmpty) {
    throw const FormatException('Enter a valid HTTP(S) address. / 请输入有效的 HTTP(S) 地址。');
  }
  var path = value.normalizePath().path;
  if (!path.endsWith('/')) path += '/';
  return Uri(scheme: value.scheme.toLowerCase(), host: value.host.toLowerCase(),
      port: value.hasPort ? value.port : null, path: path);
}

class PortalScan {
  const PortalScan(this.base, {this.token});
  final Uri base;
  final String? token;

  factory PortalScan.parse(String input) {
    final base = normalizePortalUrl(input);
    final uri = Uri.parse(input.trim());
    if (!uri.path.endsWith('/__portal/pair')) return PortalScan(base);
    final token = uri.queryParameters['t'];
    if (token == null || token.isEmpty) {
      throw const FormatException('Pairing link has no token. / 配对链接缺少令牌。');
    }
    return PortalScan(normalizePortalUrl(uri.replace(
      path: uri.path.substring(0, uri.path.length - '__portal/pair'.length),
    ).toString()), token: token);
  }
}

typedef PortalCookieWriter = Future<void> Function(String? value);

/// One cookie jar per normalized portal base, not per public relay authority.
class PortalSession implements DshHttpAuthPolicy {
  PortalSession(Uri base, {this.saveCookies, DateTime Function()? now})
      : base = normalizePortalUrl(base.toString()), _now = now ?? DateTime.now;

  static const userAgent = 'DSHRemotePortal/2.0';
  final Uri base;
  final PortalCookieWriter? saveCookies;
  final DateTime Function() _now;
  final _cookies = <Cookie>[];
  final _expired = StreamController<void>.broadcast(sync: true);
  Future<void> _writes = Future.value();
  bool _unauthorized = false;
  late final connection = DshConnection(base, authPolicy: this);

  Stream<void> get expired => _expired.stream;
  bool get hasCookies => _cookies.any((c) => c.expires == null || c.expires!.isAfter(_now()));

  void restoreCookies(String? encoded) {
    _cookies.clear();
    if (encoded == null) return;
    final value = jsonDecode(encoded);
    if (value is! Map || value['base'] != base.toString()) return;
    for (final raw in value['cookies'] as List) {
      final cookie = Cookie.fromSetCookieValue(raw as String);
      if (_accept(cookie) && (cookie.expires == null || cookie.expires!.isAfter(_now()))) {
        _cookies.add(cookie);
      }
    }
  }

  bool _accept(Cookie cookie) {
    final domain = cookie.domain?.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
    return domain == null || domain.isEmpty || domain == base.host ||
        base.host.endsWith('.$domain');
  }

  bool _owns(Uri uri) {
    final scheme = switch (uri.scheme) { 'ws' => 'http', 'wss' => 'https', _ => uri.scheme };
    final path = uri.normalizePath().path;
    return scheme == base.scheme && uri.host == base.host && uri.port == base.port &&
        uri.userInfo.isEmpty && (path == base.path || path.startsWith(base.path));
  }

  @override
  Map<String, String> headersFor(Uri uri) {
    if (!_owns(uri)) throw ArgumentError('Portal credentials cannot leave their base.');
    final now = _now();
    final cookies = _cookies.where((cookie) {
      final path = cookie.path ?? '/';
      return (cookie.expires == null || cookie.expires!.isAfter(now)) &&
          (!cookie.secure || uri.scheme == 'https' || uri.scheme == 'wss') &&
          (uri.path == path || uri.path.startsWith(path.endsWith('/') ? path : '$path/'));
    }).toList()..sort((a, b) => (b.path ?? '/').length.compareTo((a.path ?? '/').length));
    return {
      'User-Agent': userAgent,
      'Origin': base.origin,
      if (cookies.isNotEmpty) 'Cookie': cookies.map((c) => '${c.name}=${c.value}').join('; '),
    };
  }

  Future<void> _persist() {
    final writer = saveCookies;
    if (writer == null) return Future.value();
    final value = _cookies.isEmpty ? null : jsonEncode({
      'base': base.toString(), 'cookies': _cookies.map((c) => c.toString()).toList(),
    });
    return _writes = _writes.then((_) => writer(value));
  }

  @override
  Future<void> receiveCookies(Uri uri, List<String> cookies) async {
    if (!_owns(uri)) throw ArgumentError('Unexpected portal cookie origin.');
    for (final raw in cookies) {
      Cookie cookie;
      try { cookie = Cookie.fromSetCookieValue(raw); } on FormatException { continue; }
      if (!_accept(cookie)) continue;
      cookie.path ??= uri.path.substring(0, uri.path.lastIndexOf('/') + 1);
      if (cookie.maxAge case final age?) cookie.expires = _now().add(Duration(seconds: age));
      _cookies.removeWhere((c) => c.name == cookie.name && c.domain == cookie.domain && c.path == cookie.path);
      if (cookie.expires == null || cookie.expires!.isAfter(_now())) _cookies.add(cookie);
    }
    if (cookies.isNotEmpty) await _persist();
  }

  @override
  void unauthorized() {
    if (_unauthorized) return;
    _unauthorized = true;
    _cookies.clear();
    unawaited(_persist().catchError((Object _) {}));
    if (!_expired.isClosed) _expired.add(null);
  }

  Future<void> login(String secret, {bool pairing = false}) async {
    final body = '${pairing ? 'token' : 'password'}=${Uri.encodeQueryComponent(secret)}';
    final response = await connection.postBytes('/__portal/login', utf8.encode(body),
      contentType: 'application/x-www-form-urlencoded', followRedirects: false,
      maxResponseBytes: 65536, timeout: const Duration(seconds: 15));
    if (response.statusCode == 429) {
      throw const DshHttpException(429, 'Too many attempts. Try again later. / 尝试次数过多，请稍后重试。');
    }
    if (response.statusCode != 303 || !hasCookies) {
      throw DshHttpException(response.statusCode, 'Sign-in failed. Check your password or pairing link. / 登录失败，请检查密码或配对链接。');
    }
    _unauthorized = false;
  }

  Future<void> logout() async {
    final response = await connection.postBytes('/__portal/logout', const [],
      contentType: 'application/x-www-form-urlencoded', followRedirects: false,
      maxResponseBytes: 65536);
    if (response.statusCode != 303 && (response.statusCode < 200 || response.statusCode >= 300)) {
      throw DshHttpException(response.statusCode, 'Sign-out failed. / 退出登录失败。');
    }
    _cookies.clear();
    await _persist();
  }

  Future<void> close() async {
    connection.close(force: true);
    await _expired.close();
    await _writes;
  }
}
