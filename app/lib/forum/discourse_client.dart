// The Discourse HTTP API the forum pages use. Signed in, every request carries
// the User API Key (forum_auth.dart) as `User-Api-Key` + `User-Api-Client-Id`,
// the headers the official DiscourseHub app sends; signed out, the same reads
// work for public categories.
//
// Endpoints (Discourse's routes.rb): /site.json, /latest.json, /top.json,
// /c/<slug>/<id>/l/latest.json, /t/<id>.json, /t/<id>/posts.json,
// /search.json, /notifications.json, /notifications/mark-read,
// /session/current.json, /u/<name>/summary.json, /posts.json,
// /post_actions, /bookmarks, /uploads.json, /user-api-key/revoke.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException, HandshakeException;

import 'package:http/http.dart' as http;

import '../l10n/l10n.dart';
import 'forum_models.dart';

/// What went wrong, in the words a person can act on.
enum ForumErrorKind {
  /// No connection, DNS, TLS, timeout.
  network,

  /// The key was revoked or expired (or never valid).
  unauthorized,

  /// Not allowed for this account (trust level, closed topic).
  forbidden,
  notFound,

  /// Too many requests: wait a little.
  rateLimited,

  /// The server refused the content (title too short, duplicate…); the
  /// message is Discourse's own, in the forum's language.
  rejected,
  server,
}

class ForumException implements Exception {
  const ForumException(this.kind, [this.detail]);

  final ForumErrorKind kind;

  /// Discourse's first error message, when it sent one.
  final String? detail;

  /// One short line for the screen.
  String get message => switch (kind) {
    ForumErrorKind.network => appL10n.stateForumUnreachable,
    ForumErrorKind.unauthorized => appL10n.stateSignInExpired,
    ForumErrorKind.forbidden => detail ?? appL10n.stateForbidden,
    ForumErrorKind.notFound => appL10n.stateForumContentMissing,
    ForumErrorKind.rateLimited => appL10n.stateTooManyActions,
    ForumErrorKind.rejected => detail ?? appL10n.stateForumSendFailed,
    ForumErrorKind.server => appL10n.stateForumServerError,
  };

  @override
  String toString() => 'ForumException(${kind.name}${detail == null ? '' : ': $detail'})';
}

/// Which list of topics.
class ForumFeed {
  const ForumFeed.latest() : kind = ForumFeedKind.latest, categoryId = null, categorySlug = null;
  const ForumFeed.top() : kind = ForumFeedKind.top, categoryId = null, categorySlug = null;
  ForumFeed.category(ForumCategory category)
    : kind = ForumFeedKind.category,
      categoryId = category.id,
      categorySlug = category.slug;

  final ForumFeedKind kind;
  final int? categoryId;
  final String? categorySlug;

  @override
  bool operator ==(Object other) => other is ForumFeed && other.kind == kind && other.categoryId == categoryId;

  @override
  int get hashCode => Object.hash(kind, categoryId);

  @override
  String toString() => 'ForumFeed(${kind.name}${categoryId == null ? '' : ' $categoryId'})';
}

enum ForumFeedKind { latest, top, category }

/// A new post: published, or waiting in the review queue (new accounts on a
/// forum that approves first posts).
class ForumPostResult {
  const ForumPostResult({this.post, this.topicId, this.queued = false});

  final ForumPost? post;
  final int? topicId;
  final bool queued;
}

/// Who the requests are made as.
class ForumCredentials {
  const ForumCredentials({required this.key, required this.clientId});

  final String key;
  final String clientId;
}

/// The forum API the pages talk to; the tests use a fake.
abstract interface class ForumApi {
  Uri get baseUrl;
  bool get signedIn;

  Future<ForumSite> site();
  Future<ForumTopicListPage> topics(ForumFeed feed, {int page = 0});
  Future<ForumTopicDetail> topic(int id);
  Future<List<ForumPost>> posts(int topicId, List<int> postIds);
  Future<ForumSearchResult> search(String query, {int page = 1});
  Future<ForumNotificationPage> notifications({int offset = 0});
  Future<void> markNotificationsRead({int? id});
  Future<ForumCurrentUser> currentUser();
  Future<ForumUserSummary> userSummary(String username);
  Future<ForumPostResult> createTopic({required String title, required String raw, int? categoryId});
  Future<ForumPostResult> reply({required int topicId, required String raw, int? replyToPostNumber});
  Future<void> like(int postId);
  Future<void> unlike(int postId);

  /// Returns the bookmark's id (needed to remove it).
  Future<int> bookmark(int postId);
  Future<void> removeBookmark(int bookmarkId);
  Future<ForumUpload> upload(List<int> bytes, String filename);

  /// Revokes the key this client signs with.
  Future<void> revokeKey();
}

/// [ForumApi] over HTTP.
class DiscourseClient implements ForumApi {
  DiscourseClient({
    required this.baseUrl,
    this.credentials,
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
  }) : _http = client ?? http.Client();

  @override
  final Uri baseUrl;
  final ForumCredentials? credentials;
  final Duration timeout;
  final http.Client _http;

  @override
  bool get signedIn => credentials != null;

  void close() => _http.close();

  Map<String, String> get _headers => {
    'Accept': 'application/json',
    if (credentials case final c?) ...{'User-Api-Key': c.key, 'User-Api-Client-Id': c.clientId},
  };

  /// [path] under the forum (which may itself live under a path).
  Uri endpoint(String path, [Map<String, Object>? query]) {
    final base = baseUrl.path.endsWith('/') ? baseUrl.path.substring(0, baseUrl.path.length - 1) : baseUrl.path;
    return baseUrl.replace(
      path: '$base$path',
      queryParameters: query == null || query.isEmpty
          ? null
          : {
              for (final e in query.entries)
                e.key: e.value is List ? [for (final v in e.value as List) '$v'] : '${e.value}',
            },
    );
  }

  Future<Object?> _send(String method, String path, {Map<String, Object>? query, Map<String, String>? form}) async {
    final uri = endpoint(path, query);
    http.Response response;
    try {
      final request = http.Request(method, uri)..headers.addAll(_headers);
      if (form != null) request.bodyFields = form;
      response = await http.Response.fromStream(await _http.send(request).timeout(timeout)).timeout(timeout);
    } on TimeoutException {
      throw const ForumException(ForumErrorKind.network);
    } on SocketException {
      throw const ForumException(ForumErrorKind.network);
    } on HandshakeException {
      throw const ForumException(ForumErrorKind.network);
    } on http.ClientException {
      throw const ForumException(ForumErrorKind.network);
    }
    return _decode(response);
  }

  static Object? _decode(http.Response response) {
    Object? body;
    try {
      body = response.body.isEmpty ? null : jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      body = null;
    }
    final status = response.statusCode;
    if (status >= 200 && status < 300) {
      if (body is Map && body['errors'] is List && (body['errors'] as List).isNotEmpty && body['success'] != true) {
        throw ForumException(ForumErrorKind.rejected, firstError(body));
      }
      return body;
    }
    final detail = firstError(body);
    throw ForumException(switch (status) {
      401 => ForumErrorKind.unauthorized,
      // Also what every request gets with a revoked key: the state layer
      // tells the two apart (forum_state.dart, `/site.json` never refuses a
      // valid user).
      403 => ForumErrorKind.forbidden,
      404 || 410 => ForumErrorKind.notFound,
      429 => ForumErrorKind.rateLimited,
      400 || 409 || 422 => ForumErrorKind.rejected,
      _ => ForumErrorKind.server,
    }, detail);
  }

  /// The first human message in a Discourse error body.
  static String? firstError(Object? body) {
    if (body is! Map) return null;
    final errors = body['errors'];
    if (errors is List && errors.isNotEmpty && errors.first is String) return (errors.first as String).trim();
    final message = body['message'] ?? body['error'];
    return message is String && message.trim().isNotEmpty ? message.trim() : null;
  }

  @override
  Future<ForumSite> site() async => ForumSite.fromJson(await _send('GET', '/site.json'));

  @override
  Future<ForumTopicListPage> topics(ForumFeed feed, {int page = 0}) async {
    final query = <String, Object>{if (page > 0) 'page': page};
    final path = switch (feed.kind) {
      ForumFeedKind.latest => '/latest.json',
      ForumFeedKind.top => '/top.json',
      ForumFeedKind.category => '/c/${Uri.encodeComponent(feed.categorySlug ?? '-')}/${feed.categoryId}/l/latest.json',
    };
    if (feed.kind == ForumFeedKind.top) query['period'] = 'monthly';
    return ForumTopicListPage.fromJson(await _send('GET', path, query: query));
  }

  @override
  Future<ForumTopicDetail> topic(int id) async => ForumTopicDetail.fromJson(await _send('GET', '/t/$id.json'));

  @override
  Future<List<ForumPost>> posts(int topicId, List<int> postIds) async {
    if (postIds.isEmpty) return const [];
    return forumPostsFromJson(await _send('GET', '/t/$topicId/posts.json', query: {'post_ids[]': postIds}));
  }

  @override
  Future<ForumSearchResult> search(String query, {int page = 1}) async =>
      ForumSearchResult.fromJson(await _send('GET', '/search.json', query: {'q': query, if (page > 1) 'page': page}));

  @override
  Future<ForumNotificationPage> notifications({int offset = 0}) async => ForumNotificationPage.fromJson(
    await _send('GET', '/notifications.json', query: {'limit': 30, if (offset > 0) 'offset': offset}),
  );

  @override
  Future<void> markNotificationsRead({int? id}) async {
    await _send('PUT', '/notifications/mark-read.json', form: {if (id != null) 'id': '$id'});
  }

  @override
  Future<ForumCurrentUser> currentUser() async {
    final json = await _send('GET', '/session/current.json');
    final user = ForumCurrentUser.fromJson(json);
    if (user.username.isEmpty) throw const ForumException(ForumErrorKind.unauthorized);
    return user;
  }

  @override
  Future<ForumUserSummary> userSummary(String username) async =>
      ForumUserSummary.fromJson(await _send('GET', '/u/${Uri.encodeComponent(username)}/summary.json'));

  @override
  Future<ForumPostResult> createTopic({required String title, required String raw, int? categoryId}) async =>
      _postResult(
        await _send(
          'POST',
          '/posts.json',
          form: {'title': title, 'raw': raw, if (categoryId != null) 'category': '$categoryId', 'archetype': 'regular'},
        ),
      );

  @override
  Future<ForumPostResult> reply({required int topicId, required String raw, int? replyToPostNumber}) async =>
      _postResult(
        await _send(
          'POST',
          '/posts.json',
          form: {
            'topic_id': '$topicId',
            'raw': raw,
            if (replyToPostNumber != null) 'reply_to_post_number': '$replyToPostNumber',
          },
        ),
      );

  static ForumPostResult _postResult(Object? json) {
    if (json is Map && json['action'] == 'enqueued') return const ForumPostResult(queued: true);
    if (json is Map && json['post'] is Map) json = json['post'];
    final post = ForumPost.fromJson(json);
    return ForumPostResult(post: post, topicId: post.topicId == 0 ? null : post.topicId);
  }

  @override
  Future<void> like(int postId) async {
    await _send(
      'POST',
      '/post_actions.json',
      form: {'id': '$postId', 'post_action_type_id': '2', 'flag_topic': 'false'},
    );
  }

  @override
  Future<void> unlike(int postId) async {
    await _send('DELETE', '/post_actions/$postId.json', query: {'post_action_type_id': 2});
  }

  @override
  Future<int> bookmark(int postId) async {
    final json = await _send(
      'POST',
      '/bookmarks.json',
      form: {'bookmarkable_id': '$postId', 'bookmarkable_type': 'Post'},
    );
    final id = json is Map ? json['id'] : null;
    if (id is! int) throw const ForumException(ForumErrorKind.server);
    return id;
  }

  @override
  Future<void> removeBookmark(int bookmarkId) async {
    await _send('DELETE', '/bookmarks/$bookmarkId.json');
  }

  @override
  Future<ForumUpload> upload(List<int> bytes, String filename) async {
    final request = http.MultipartRequest('POST', endpoint('/uploads.json'))
      ..headers.addAll(_headers)
      ..fields['type'] = 'composer'
      ..fields['synchronous'] = 'true'
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    http.Response response;
    try {
      response = await http.Response.fromStream(await _http.send(request).timeout(const Duration(seconds: 90)))
          .timeout(const Duration(seconds: 90));
    } on TimeoutException {
      throw const ForumException(ForumErrorKind.network);
    } on SocketException {
      throw const ForumException(ForumErrorKind.network);
    } on http.ClientException {
      throw const ForumException(ForumErrorKind.network);
    }
    final upload = ForumUpload.fromJson(_decode(response));
    if (upload.shortUrl.isEmpty && upload.url.isEmpty) throw const ForumException(ForumErrorKind.server);
    return upload;
  }

  @override
  Future<void> revokeKey() async {
    if (credentials == null) return;
    await _send('POST', '/user-api-key/revoke');
  }
}

// ── Addresses ────────────────────────────────────────────────────────────────

/// [path] (relative, protocol-relative or absolute) against [base].
Uri forumResolve(Uri base, String path) {
  final text = path.trim();
  if (text.startsWith('//')) return Uri.parse('${base.scheme}:$text');
  final uri = Uri.tryParse(text);
  if (uri == null) return base;
  if (uri.hasScheme) return uri;
  if (text.startsWith('/') && base.path.isNotEmpty && base.path != '/' && !text.startsWith(base.path)) {
    return base.replace(path: '${base.path}$text', query: uri.hasQuery ? uri.query : null);
  }
  return base.resolveUri(uri);
}

/// An avatar template with its `{size}` filled in (logical [size] × 2 for
/// sharp avatars), resolved against [base].
Uri? forumAvatarUrl(Uri base, String? template, {int size = 48}) {
  if (template == null || template.isEmpty) return null;
  return forumResolve(base, template.replaceAll('{size}', '${size * 2}'));
}

/// The web address of a topic (or one post in it).
Uri forumTopicUrl(Uri base, {required int topicId, String slug = '', int? postNumber}) => forumResolve(
  base,
  '/t/${slug.isEmpty ? 'topic' : slug}/$topicId${postNumber != null && postNumber > 1 ? '/$postNumber' : ''}',
);
