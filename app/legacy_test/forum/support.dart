// Fakes and sample data for the forum tests: an in-memory ForumApi, a fixed
// auth state, and a small Chinese forum to draw goldens from.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/forum/discourse_client.dart';
import 'package:dsh_app/forum/forum_auth.dart';
import 'package:dsh_app/forum/forum_models.dart';
import 'package:dsh_app/forum/forum_state.dart';
import 'package:dsh_app/share_code/share_codec.dart';
import 'package:dsh_app/share_code/share_link.dart';
import 'package:dsh_app/share_code/share_models.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

Object? fixture(String name) => jsonDecode(File('test/forum/fixtures/$name').readAsStringSync());

String fixtureText(String name) => File('test/forum/fixtures/$name').readAsStringSync();

final forumBase = Uri.parse('https://forum.test');

// ── Fake API ─────────────────────────────────────────────────────────────────

class FakeForumApi implements ForumApi {
  FakeForumApi({
    this.signedIn = false,
    ForumSite? site,
    Map<ForumFeed, List<ForumTopicListPage>>? feeds,
    Map<int, ForumTopicDetail>? topicDetails,
    this.morePosts = const {},
    this.notificationPage = const ForumNotificationPage(),
    this.searchResult = const ForumSearchResult(),
    this.summary = const ForumUserSummary(),
    this.user,
  }) : site_ = site ?? sampleSite,
       feeds =
           feeds ??
           {
             const ForumFeed.latest(): [sampleTopicPage()],
           },
       topicDetails = topicDetails ?? {101: sampleTopicDetail()};

  @override
  final bool signedIn;

  @override
  Uri get baseUrl => forumBase;

  final ForumSite site_;
  final Map<ForumFeed, List<ForumTopicListPage>> feeds;
  final Map<int, ForumTopicDetail> topicDetails;

  /// Posts served by [posts], by id.
  final Map<int, ForumPost> morePosts;
  ForumNotificationPage notificationPage;
  ForumSearchResult searchResult;
  ForumUserSummary summary;
  ForumCurrentUser? user;

  /// Thrown by every call when set.
  ForumException? failWith;

  final calls = <String>[];
  final created = <Map<String, Object?>>[];

  void _check(String call) {
    calls.add(call);
    if (failWith case final e?) throw e;
  }

  @override
  Future<ForumSite> site() async {
    _check('site');
    return site_;
  }

  @override
  Future<ForumTopicListPage> topics(ForumFeed feed, {int page = 0}) async {
    _check('topics:${feed.kind.name}${feed.categoryId ?? ''}:$page');
    final pages = feeds[feed] ?? const [];
    return page < pages.length ? pages[page] : const ForumTopicListPage(topics: []);
  }

  @override
  Future<ForumTopicDetail> topic(int id) async {
    _check('topic:$id');
    final detail = topicDetails[id];
    if (detail == null) throw const ForumException(ForumErrorKind.notFound);
    return detail;
  }

  @override
  Future<List<ForumPost>> posts(int topicId, List<int> postIds) async {
    _check('posts:$topicId:${postIds.join(',')}');
    return [for (final id in postIds) ?morePosts[id]];
  }

  @override
  Future<ForumSearchResult> search(String query, {int page = 1}) async {
    _check('search:$query');
    return searchResult;
  }

  @override
  Future<ForumNotificationPage> notifications({int offset = 0}) async {
    _check('notifications:$offset');
    return offset == 0 ? notificationPage : const ForumNotificationPage();
  }

  @override
  Future<void> markNotificationsRead({int? id}) async => _check('markRead:${id ?? 'all'}');

  @override
  Future<ForumCurrentUser> currentUser() async {
    _check('currentUser');
    return user ?? (throw const ForumException(ForumErrorKind.forbidden));
  }

  @override
  Future<ForumUserSummary> userSummary(String username) async {
    _check('summary:$username');
    return summary;
  }

  @override
  Future<ForumPostResult> createTopic({required String title, required String raw, int? categoryId}) async {
    _check('createTopic');
    created.add({'title': title, 'raw': raw, 'category': categoryId});
    return ForumPostResult(post: samplePost(900, 1, raw, topicId: 777), topicId: 777);
  }

  @override
  Future<ForumPostResult> reply({required int topicId, required String raw, int? replyToPostNumber}) async {
    _check('reply:$topicId:${replyToPostNumber ?? '-'}');
    created.add({'topic': topicId, 'raw': raw, 'replyTo': replyToPostNumber});
    return ForumPostResult(
      post: samplePost(901, 9, '<p>${const HtmlEscape().convert(raw)}</p>', topicId: topicId),
      topicId: topicId,
    );
  }

  @override
  Future<void> like(int postId) async => _check('like:$postId');

  @override
  Future<void> unlike(int postId) async => _check('unlike:$postId');

  @override
  Future<int> bookmark(int postId) async {
    _check('bookmark:$postId');
    return 5000 + postId;
  }

  @override
  Future<void> removeBookmark(int bookmarkId) async => _check('unbookmark:$bookmarkId');

  @override
  Future<ForumUpload> upload(List<int> bytes, String filename) async {
    _check('upload:$filename:${bytes.length}');
    return const ForumUpload(
      shortUrl: 'upload://abc123.png',
      url: '/uploads/abc123.png',
      filename: 'shot.png',
      width: 640,
      height: 480,
    );
  }

  @override
  Future<void> revokeKey() async => _check('revoke');
}

/// Auth fixed at [initial]; sign-in calls are recorded, not performed.
class FakeForumAuth extends ForumAuthController {
  FakeForumAuth(this.initial);

  final ForumAuthState initial;
  int signIns = 0;
  int signOuts = 0;

  @override
  ForumAuthState build() => initial;

  @override
  Future<bool> signIn() async {
    signIns++;
    state = state.copyWith(phase: ForumAuthPhase.waiting);
    return true;
  }

  @override
  Future<void> refreshUser() async {}

  @override
  Future<void> signOut() async {
    signOuts++;
    state = const ForumAuthState(phase: ForumAuthPhase.signedOut);
  }
}

const sampleUser = ForumCurrentUser(
  id: 7,
  username: 'chimney',
  name: '烟囱',
  allUnread: 3,
  unreadNotifications: 3,
  trustLevel: 1,
);

const signedInAuth = ForumAuthState(
  phase: ForumAuthPhase.signedIn,
  credentials: ForumCredentials(key: 'k', clientId: 'c'),
  user: sampleUser,
);

const signedOutAuth = ForumAuthState(phase: ForumAuthPhase.signedOut);

List<Override> forumOverrides(
  FakeForumApi api, {
  ForumAuthState auth = signedOutAuth,
  ForumAuthController Function()? authController,
}) => [
  forumApiProvider.overrideWithValue(api),
  forumAuthProvider.overrideWith(authController ?? () => FakeForumAuth(auth)),
];

// ── Sample forum ─────────────────────────────────────────────────────────────

const sampleCategories = [
  ForumCategory(id: 1, name: '公告', slug: 'announcements', color: 'E45735', position: 0, permission: 3),
  ForumCategory(id: 2, name: '插件', slug: 'plugins', color: '0088CC', position: 1, permission: 1),
  ForumCategory(id: 3, name: '配置分享', slug: 'profiles', color: '25AAE2', position: 2, permission: 1),
  ForumCategory(id: 4, name: '玩法', slug: 'ideas', color: 'F7941D', position: 3, permission: 1),
  ForumCategory(id: 5, name: '求助', slug: 'help', color: '12A89D', position: 4, permission: 1),
  ForumCategory(id: 6, name: '反馈', slug: 'feedback', color: '808281', position: 5, permission: 1),
];

const sampleSite = ForumSite(
  categories: sampleCategories,
  notificationTypes: {1: 'mentioned', 2: 'replied', 3: 'quoted', 5: 'liked', 12: 'granted_badge'},
);

ForumUser _u(int id, String name, [String? full]) => ForumUser(id: id, username: name, name: full);

final _people = [
  _u(1, 'xiamu', '夏目'),
  _u(2, 'liguobao', '李国宝'),
  _u(3, 'chimney', '烟囱'),
  _u(4, 'mika'),
  _u(5, 'deepblue'),
  _u(6, 'kiwi'),
];

ForumTopic sampleTopic(
  int id,
  String title, {
  int category = 2,
  int posts = 1,
  Duration ago = const Duration(hours: 1),
  List<int> posters = const [1],
  bool pinned = false,
  bool unseen = false,
}) {
  final at = DateTime.now().subtract(ago);
  return ForumTopic(
    id: id,
    title: title,
    slug: 'topic-$id',
    postsCount: posts,
    categoryId: category,
    createdAt: at,
    lastPostedAt: at,
    pinned: pinned,
    unseen: unseen,
    posters: [
      for (final (i, p) in posters.indexed)
        ForumPoster(
          user: _people[p - 1],
          description: i == 0 ? 'Original Poster' : 'Frequent Poster',
          latest: i == posters.length - 1,
        ),
    ],
  );
}

List<ForumTopic> sampleTopics() => [
  sampleTopic(100, '欢迎来到 dsh-go 论坛：新手先看这里', category: 1, posts: 1, ago: const Duration(days: 3), pinned: true),
  sampleTopic(
    101,
    '分享一个联网搜索插件，装上就能查实时资料',
    posts: 13,
    ago: const Duration(minutes: 12),
    posters: [3, 1, 2],
    unseen: true,
  ),
  sampleTopic(102, '手机上跑 DSH 的省电配置（附分享码）', category: 3, posts: 6, ago: const Duration(hours: 2), posters: [4, 5]),
  sampleTopic(103, '让 DSH 每天早上整理一份新闻简报', category: 4, posts: 21, ago: const Duration(hours: 5), posters: [2, 6, 1]),
  sampleTopic(104, '远程连接家里电脑时提示「没能连上引擎」', category: 5, posts: 4, ago: const Duration(hours: 26), posters: [6, 3]),
  sampleTopic(105, '建议：插件市场支持按评分排序', category: 6, posts: 9, ago: const Duration(days: 4), posters: [5, 4, 2]),
  sampleTopic(106, '用 dsh-go 批量改照片文件名的小技巧', category: 4, posts: 2, ago: const Duration(days: 6), posters: [1]),
];

ForumTopicListPage sampleTopicPage({bool more = false}) =>
    ForumTopicListPage(topics: sampleTopics(), moreTopicsUrl: more ? '/latest?page=1' : null, canCreateTopic: true);

/// A plugin share link, as a post would carry it.
ShareLink samplePluginLink() => ShareLink.inline(
  ShareKind.plugin,
  encodeShareCode(
    const PluginShare(
      SharedPlugin(
        name: '@liustack/modsearch',
        source: PluginSourceKind.npm,
        spec: '@liustack/modsearch@1.4.2',
        version: '1.4.2',
        title: 'ModSearch 联网搜索',
        author: 'liustack',
        summary: '免费的联网搜索',
      ),
    ),
  ),
);

ForumPost samplePost(
  int id,
  int number,
  String cooked, {
  int user = 1,
  int topicId = 101,
  int likes = 0,
  bool liked = false,
  Duration ago = const Duration(hours: 1),
  String? replyTo,
}) => ForumPost(
  id: id,
  postNumber: number,
  topicId: topicId,
  user: _people[user - 1],
  cooked: cooked,
  createdAt: DateTime.now().subtract(ago),
  likeCount: likes,
  liked: liked,
  canLike: true,
  replyToUsername: replyTo,
);

ForumTopicDetail sampleTopicDetail({List<int>? stream, List<ForumPost>? posts}) {
  final link = samplePluginLink();
  final list =
      posts ??
      [
        samplePost(
          1001,
          1,
          '<p>最近一直在用这个插件，<strong>不用 API Key</strong>，装上就能让 DSH 查实时资料 '
          '<img src="/images/emoji/twitter/tada.png?v=12" title=":tada:" class="emoji" alt=":tada:"></p>'
          '<p><a href="${link.webLink}">插件：ModSearch 联网搜索</a></p>'
          '<p>装好后在对话里直接问：</p>'
          '<pre><code class="lang-text">帮我查一下今天的天气，并给出穿衣建议</code></pre>',
          user: 3,
          likes: 12,
          ago: const Duration(hours: 3),
        ),
        samplePost(
          1002,
          2,
          '<aside class="quote" data-username="chimney" data-post="1" data-topic="101">'
          '<div class="title"><img alt="" width="24" height="24" src="/user_avatar/forum.test/chimney/48/1_2.png" class="avatar"> chimney:</div>'
          '<blockquote><p>不用 API Key，装上就能让 DSH 查实时资料</p></blockquote></aside>'
          '<p>试了一下，确实好用 <img src="/images/emoji/twitter/+1.png?v=12" title=":+1:" class="emoji" alt=":+1:"> '
          '<a class="mention" href="/u/chimney">@chimney</a> 搜索结果能带上来源链接吗？</p>',
          user: 1,
          likes: 3,
          liked: true,
          ago: const Duration(hours: 2),
        ),
        samplePost(
          1003,
          3,
          '<p>可以，作者的仓库里有说明：</p>'
          '<aside class="onebox githubrepo" data-onebox-src="https://github.com/liustack/modsearch">'
          '<header class="source"><a href="https://github.com/liustack/modsearch">github.com</a></header>'
          '<article class="onebox-body"><h3><a href="https://github.com/liustack/modsearch">liustack/modsearch</a></h3>'
          '<p>Free web search for DeepSeek Harness, no key needed.</p></article></aside>',
          user: 2,
          likes: 1,
          ago: const Duration(minutes: 40),
          replyTo: 'xiamu',
        ),
      ];
  return ForumTopicDetail(
    id: 101,
    title: '分享一个联网搜索插件，装上就能查实时资料',
    slug: 'topic-101',
    categoryId: 2,
    postsCount: 13,
    views: 1280,
    stream: stream ?? [for (final p in list) p.id],
    posts: list,
    canCreatePost: true,
  );
}

ForumNotificationPage sampleNotifications() {
  final now = DateTime.now();
  ForumNotification n(
    int id,
    int type,
    String actor,
    String title,
    Duration ago, {
    bool read = false,
    Map<String, Object?> extra = const {},
  }) => ForumNotification(
    id: id,
    type: type,
    read: read,
    createdAt: now.subtract(ago),
    topicId: title.isEmpty ? null : 101,
    postNumber: 2,
    title: title.isEmpty ? null : title,
    data: {'display_username': actor, ...extra},
  );
  return ForumNotificationPage(
    notifications: [
      n(1, 2, 'xiamu', '分享一个联网搜索插件，装上就能查实时资料', const Duration(minutes: 5)),
      n(2, 5, 'liguobao', '手机上跑 DSH 的省电配置（附分享码）', const Duration(minutes: 50), extra: {'count': 3}),
      n(3, 1, 'mika', '让 DSH 每天早上整理一份新闻简报', const Duration(hours: 4)),
      n(4, 12, 'system', '', const Duration(days: 1), read: true, extra: {'badge_name': '初来乍到'}),
      n(5, 3, 'kiwi', '远程连接家里电脑时提示「没能连上引擎」', const Duration(days: 2), read: true),
    ],
    total: 5,
  );
}
