// Providers behind the forum pages (lib/ui/forum).

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import 'discourse_client.dart';
import 'forum_auth.dart';
import 'forum_config.dart';
import 'forum_models.dart';

// ── Where and as whom ────────────────────────────────────────────────────────

const _baseUrlPref = 'forum.baseUrl';

/// The forum's base URL: [forumDefaultBaseUrl], or the address set in
/// 论坛设置.
class ForumBaseUrlController extends Notifier<String> {
  @override
  String build() {
    unawaited(_load());
    return forumDefaultBaseUrl;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = normalizeForumBaseUrl(prefs.getString(_baseUrlPref) ?? '');
      if (saved != null && ref.mounted && saved != state) state = saved;
    } catch (_) {
      // No preferences (tests without a mock): the default stands.
    }
  }

  /// Whether a custom address is in use.
  bool get isCustom => state != forumDefaultBaseUrl;

  /// Sets a custom address; null or the default goes back to the default.
  /// False when [input] isn't a web address.
  Future<bool> set(String? input) async {
    final value = input == null || input.trim().isEmpty ? forumDefaultBaseUrl : normalizeForumBaseUrl(input);
    if (value == null) return false;
    final prefs = await SharedPreferences.getInstance();
    if (value == forumDefaultBaseUrl) {
      await prefs.remove(_baseUrlPref);
    } else {
      await prefs.setString(_baseUrlPref, value);
    }
    if (ref.mounted) state = value;
    return true;
  }
}

final forumBaseUrlProvider = NotifierProvider<ForumBaseUrlController, String>(ForumBaseUrlController.new);

final forumHttpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

/// Builds the API for a forum and (optional) key; tests swap in a fake.
final forumApiFactoryProvider = Provider<ForumApi Function(Uri baseUrl, ForumCredentials? credentials)>((ref) {
  final client = ref.watch(forumHttpClientProvider);
  return (baseUrl, credentials) => DiscourseClient(baseUrl: baseUrl, credentials: credentials, client: client);
});

/// The API as the current user (anonymous while signed out).
final forumApiProvider = Provider<ForumApi>((ref) {
  final base = Uri.parse(ref.watch(forumBaseUrlProvider));
  final credentials = ref.watch(forumAuthProvider.select((s) => s.signedIn ? s.credentials : null));
  return ref.watch(forumApiFactoryProvider)(base, credentials);
});

/// Keeps an auto-dispose provider for [duration] after its last listener
/// leaves (switching category capsules and back doesn't refetch).
void _cacheFor(Ref ref, Duration duration) {
  final link = ref.keepAlive();
  Timer? timer;
  ref.onCancel(() => timer = Timer(duration, link.close));
  ref.onResume(() => timer?.cancel());
  ref.onDispose(() => timer?.cancel());
}

/// A read that fails with "forbidden" while signed in: on `/site.json`
/// (public to every valid user) that means the key is dead.
Future<T> _guard<T>(Ref ref, ForumApi api, Future<T> Function() read) async {
  try {
    return await read();
  } on ForumException catch (e) {
    if (api.signedIn && (e.kind == ForumErrorKind.forbidden || e.kind == ForumErrorKind.unauthorized)) {
      unawaited(ref.read(forumAuthProvider.notifier).refreshUser());
    }
    rethrow;
  }
}

// ── Site ─────────────────────────────────────────────────────────────────────

final forumSiteProvider = FutureProvider<ForumSite>((ref) {
  final api = ref.watch(forumApiProvider);
  return _guard(ref, api, api.site);
});

// ── Topic lists ──────────────────────────────────────────────────────────────

class ForumTopicList {
  const ForumTopicList({
    this.topics = const [],
    this.page = 0,
    this.hasMore = false,
    this.loadingMore = false,
    this.moreError,
    this.canCreateTopic = false,
  });

  final List<ForumTopic> topics;
  final int page;
  final bool hasMore;
  final bool loadingMore;

  /// The last "load more" failure (the list itself stays).
  final String? moreError;
  final bool canCreateTopic;

  ForumTopicList copyWith({
    List<ForumTopic>? topics,
    int? page,
    bool? hasMore,
    bool? loadingMore,
    String? moreError,
    bool clearError = false,
  }) => ForumTopicList(
    topics: topics ?? this.topics,
    page: page ?? this.page,
    hasMore: hasMore ?? this.hasMore,
    loadingMore: loadingMore ?? this.loadingMore,
    moreError: clearError ? null : (moreError ?? this.moreError),
    canCreateTopic: canCreateTopic,
  );
}

class ForumTopicsController extends AsyncNotifier<ForumTopicList> {
  ForumTopicsController(this.feed);

  final ForumFeed feed;

  @override
  Future<ForumTopicList> build() async {
    _cacheFor(ref, const Duration(minutes: 5));
    final api = ref.watch(forumApiProvider);
    final page = await _guard(ref, api, () => api.topics(feed));
    return ForumTopicList(topics: page.topics, hasMore: page.hasMore, canCreateTopic: page.canCreateTopic);
  }

  bool _isCurrent(ForumApi api) => ref.mounted && identical(api, ref.read(forumApiProvider));

  /// Pull to refresh: the first page again, replacing the list.
  Future<void> refresh() async {
    final api = ref.read(forumApiProvider);
    try {
      final page = await api.topics(feed);
      if (!_isCurrent(api)) return;
      state = AsyncData(
        ForumTopicList(topics: page.topics, hasMore: page.hasMore, canCreateTopic: page.canCreateTopic),
      );
    } on ForumException catch (e, stack) {
      if (!_isCurrent(api)) return;
      if (state.hasValue) {
        state = AsyncData(state.requireValue.copyWith(moreError: e.message));
      } else {
        state = AsyncError(e, stack);
      }
    }
  }

  /// The next page, appended (topics already shown are skipped: the list
  /// moves while the user scrolls).
  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore || current.loadingMore) return;
    state = AsyncData(current.copyWith(loadingMore: true, clearError: true));
    final api = ref.read(forumApiProvider);
    try {
      final page = await api.topics(feed, page: current.page + 1);
      if (!_isCurrent(api)) return;
      final seen = {for (final t in current.topics) t.id};
      state = AsyncData(
        current.copyWith(
          topics: [
            ...current.topics,
            for (final t in page.topics)
              if (seen.add(t.id)) t,
          ],
          page: current.page + 1,
          hasMore: page.hasMore,
          loadingMore: false,
          clearError: true,
        ),
      );
    } on ForumException catch (e) {
      if (_isCurrent(api)) state = AsyncData(current.copyWith(loadingMore: false, moreError: e.message));
    }
  }
}

final forumTopicsProvider = AsyncNotifierProvider.autoDispose.family<ForumTopicsController, ForumTopicList, ForumFeed>(
  ForumTopicsController.new,
);

// ── One topic ────────────────────────────────────────────────────────────────

class ForumTopicController extends AsyncNotifier<ForumTopicDetail> {
  ForumTopicController(this.topicId);

  final int topicId;
  bool _loadingMore = false;

  @override
  Future<ForumTopicDetail> build() async {
    _cacheFor(ref, const Duration(minutes: 2));
    final api = ref.watch(forumApiProvider);
    return api.topic(topicId);
  }

  bool get loadingMore => _loadingMore;

  Future<void> refresh() async {
    try {
      final detail = await ref.read(forumApiProvider).topic(topicId);
      if (ref.mounted) state = AsyncData(detail);
    } on ForumException catch (e, stack) {
      if (ref.mounted && !state.hasValue) state = AsyncError(e, stack);
      if (state.hasValue) rethrow;
    }
  }

  /// The next chunk of posts. Throws [ForumException] on failure.
  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore || _loadingMore) return;
    _loadingMore = true;
    try {
      final ids = current.missing.take(current.chunkSize <= 0 ? 20 : current.chunkSize).toList();
      final api = ref.read(forumApiProvider);
      final fresh = await api.posts(topicId, ids);
      if (!ref.mounted || !identical(api, ref.read(forumApiProvider))) return;
      final latest = state.value ?? current;
      final byId = {for (final p in latest.posts) p.id: p, for (final p in fresh) p.id: p};
      // Ids the server didn't return (deleted since) drop out of the stream,
      // so "more" can't spin on them.
      final returned = {for (final p in fresh) p.id};
      final stream = [
        for (final id in latest.stream)
          if (!ids.contains(id) || returned.contains(id)) id,
      ];
      state = AsyncData(latest.copyWith(stream: stream, posts: [for (final id in stream) ?byId[id]]));
    } finally {
      _loadingMore = false;
    }
  }

  void _replace(ForumPost post) {
    final current = state.value;
    if (current == null) return;
    state = AsyncData(current.copyWith(posts: [for (final p in current.posts) p.id == post.id ? post : p]));
  }

  bool _isCurrent(ForumApi api) => ref.mounted && identical(api, ref.read(forumApiProvider));

  /// Likes or unlikes [post] right away; puts it back and rethrows when the
  /// forum says no.
  Future<void> toggleLike(ForumPost post) async {
    final api = ref.read(forumApiProvider);
    final liked = !post.liked;
    _replace(post.copyWith(liked: liked, likeCount: (post.likeCount + (liked ? 1 : -1)).clamp(0, 1 << 30)));
    try {
      liked ? await api.like(post.id) : await api.unlike(post.id);
    } catch (_) {
      if (_isCurrent(api)) _replace(post);
      rethrow;
    }
  }

  Future<void> toggleBookmark(ForumPost post) async {
    final api = ref.read(forumApiProvider);
    if (post.bookmarked) {
      _replace(post.copyWith(bookmarked: false, clearBookmark: true));
      try {
        if (post.bookmarkId case final id?) await api.removeBookmark(id);
      } catch (_) {
        if (_isCurrent(api)) _replace(post);
        rethrow;
      }
    } else {
      _replace(post.copyWith(bookmarked: true));
      try {
        final id = await api.bookmark(post.id);
        if (_isCurrent(api)) _replace(post.copyWith(bookmarked: true, bookmarkId: id));
      } catch (_) {
        if (_isCurrent(api)) _replace(post);
        rethrow;
      }
    }
  }

  /// A reply the user just posted, shown at the end without a reload.
  void addPost(ForumPost post) {
    final current = state.value;
    if (current == null || current.posts.any((p) => p.id == post.id)) return;
    state = AsyncData(
      current.copyWith(
        posts: [...current.posts, post],
        stream: [...current.stream, post.id],
        postsCount: current.postsCount + 1,
      ),
    );
  }
}

final forumTopicProvider = AsyncNotifierProvider.autoDispose.family<ForumTopicController, ForumTopicDetail, int>(
  ForumTopicController.new,
);

// ── Notifications ────────────────────────────────────────────────────────────

class ForumNotifications {
  const ForumNotifications({this.items = const [], this.hasMore = false, this.loadingMore = false, this.moreError});

  final List<ForumNotification> items;
  final bool hasMore;
  final bool loadingMore;
  final String? moreError;

  int get unread => items.where((n) => !n.read).length;
}

class ForumNotificationsController extends AsyncNotifier<ForumNotifications> {
  @override
  Future<ForumNotifications> build() async {
    final api = ref.watch(forumApiProvider);
    if (!api.signedIn) return const ForumNotifications();
    final page = await api.notifications();
    return ForumNotifications(items: page.notifications, hasMore: page.hasMore);
  }

  Future<void> refresh() async {
    final api = ref.read(forumApiProvider);
    if (!api.signedIn) return;
    try {
      final page = await api.notifications();
      if (ref.mounted && identical(api, ref.read(forumApiProvider))) {
        state = AsyncData(ForumNotifications(items: page.notifications, hasMore: page.hasMore));
      }
    } catch (_) {
      if (!ref.mounted || !identical(api, ref.read(forumApiProvider))) return;
      rethrow;
    }
  }

  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore || current.loadingMore) return;
    final api = ref.read(forumApiProvider);
    state = AsyncData(ForumNotifications(items: current.items, hasMore: true, loadingMore: true));
    try {
      final page = await api.notifications(offset: current.items.length);
      if (!ref.mounted || !identical(api, ref.read(forumApiProvider))) return;
      final seen = {for (final n in current.items) n.id};
      state = AsyncData(
        ForumNotifications(
          items: [
            ...current.items,
            for (final n in page.notifications)
              if (seen.add(n.id)) n,
          ],
          hasMore: page.hasMore,
        ),
      );
    } catch (error) {
      if (ref.mounted && identical(api, ref.read(forumApiProvider))) {
        state = AsyncData(
          ForumNotifications(
            items: current.items,
            hasMore: current.hasMore,
            moreError: error is ForumException ? error.message : appL10n.remoteForumErrNotifications,
          ),
        );
      }
    }
  }

  /// Marks one (opened) notification read.
  Future<void> markRead(ForumNotification notification) async {
    final current = state.value;
    if (current == null || notification.read) return;
    state = AsyncData(
      ForumNotifications(
        items: [for (final n in current.items) n.id == notification.id ? n.asRead() : n],
        hasMore: current.hasMore,
        loadingMore: current.loadingMore,
        moreError: current.moreError,
      ),
    );
    final auth = ref.read(forumAuthProvider);
    ref.read(forumAuthProvider.notifier).setUnread(auth.unread - 1);
    try {
      await ref.read(forumApiProvider).markNotificationsRead(id: notification.id);
    } catch (_) {
      // The forum marks it read when the topic is opened anyway.
    }
  }

  Future<void> markAllRead() async {
    final current = state.value;
    if (current == null) return;
    state = AsyncData(
      ForumNotifications(
        items: [for (final n in current.items) n.asRead()],
        hasMore: current.hasMore,
        loadingMore: current.loadingMore,
        moreError: current.moreError,
      ),
    );
    ref.read(forumAuthProvider.notifier).setUnread(0);
    try {
      await ref.read(forumApiProvider).markNotificationsRead();
    } catch (_) {
      // Shown as read here; the server catches up on the next visit.
    }
  }
}

final forumNotificationsProvider = AsyncNotifierProvider.autoDispose<ForumNotificationsController, ForumNotifications>(
  ForumNotificationsController.new,
);

// ── Search and people ────────────────────────────────────────────────────────

final forumSearchProvider = FutureProvider.autoDispose.family<ForumSearchResult, String>((ref, query) async {
  final term = query.trim();
  if (term.isEmpty) return const ForumSearchResult();
  // Typing: wait for a pause before asking (a newer query disposes this one).
  final cancelled = Completer<void>();
  ref.onDispose(() {
    if (!cancelled.isCompleted) cancelled.complete();
  });
  await Future.any([Future<void>.delayed(const Duration(milliseconds: 300)), cancelled.future]);
  if (cancelled.isCompleted) return const ForumSearchResult();
  return ref.read(forumApiProvider).search(term);
});

final forumUserSummaryProvider = FutureProvider.autoDispose.family<ForumUserSummary, String>(
  (ref, username) => ref.watch(forumApiProvider).userSummary(username),
);
