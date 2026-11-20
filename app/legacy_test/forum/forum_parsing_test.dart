// Reading Discourse JSON (fixtures captured from meta.discourse.org and the
// dsh-go forum, anonymised: user01… usernames, no real names or avatars, filler
// prose; shapes, ids, counts, emoji and code kept) and cooked post HTML.

import 'package:dsh_app/forum/discourse_client.dart';
import 'package:dsh_app/forum/emoji.dart';
import 'package:dsh_app/forum/forum_models.dart';
import 'package:dsh_app/forum/forum_share.dart';
import 'package:dsh_app/forum/render/cooked.dart';
import 'package:dsh_app/share_code/share_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

final meta = Uri.parse('https://meta.discourse.org');

void main() {
  group('JSON', () {
    test('latest: topics with posters resolved, pagination', () {
      final page = ForumTopicListPage.fromJson(fixture('meta_latest.json'));
      expect(page.topics, hasLength(30));
      expect(page.hasMore, isTrue);
      final welcome = page.topics.first;
      expect(welcome.id, 1);
      expect(welcome.title, 'Magna velit Consectetur? Aliqua amet!');
      expect(welcome.pinned, isTrue);
      expect(welcome.categoryId, 67);
      expect(welcome.avatars().single.username, 'Discourse');
      expect(welcome.avatars().single.avatarTemplate, contains('{size}'));
      final tagged = page.topics.firstWhere((t) => t.tags.isNotEmpty);
      expect(tagged.tags.first, isA<String>());
      expect(page.topics.every((t) => t.activityAt != null), isTrue);
    });

    test('site: categories in position order and notification types', () {
      final site = ForumSite.fromJson(fixture('meta_site.json'));
      expect(site.categories, isNotEmpty);
      expect(site.notificationTypes[2], 'replied');
      expect(site.notificationTypes[5], 'liked');
      final positions = [for (final c in site.categories) c.position];
      expect(positions, orderedEquals([...positions]..sort()));
      expect(site.topLevel.every((c) => c.parentId == null), isTrue);
      expect(site.topLevel.any((c) => c.id == site.uncategorizedId), isFalse);
      expect(site.categories.first.colorValue >> 24, 0xFF);
    });

    test('topic: first chunk, the full stream, likes from actions_summary', () {
      final topic = ForumTopicDetail.fromJson(fixture('meta_topic_322376.json'));
      expect(topic.posts, hasLength(20));
      expect(topic.stream.length, greaterThan(100));
      expect(topic.hasMore, isTrue);
      expect(topic.missing.first, topic.stream[20]);
      final spooky = ForumTopicDetail.fromJson(fixture('meta_topic_414890.json'));
      expect(spooky.posts.first.likeCount, 18);
      expect(spooky.participants, isNotEmpty);
      expect(spooky.posts.first.user.username, 'user09');
    });

    test('posts chunk', () {
      final posts = forumPostsFromJson(fixture('meta_posts_322376.json'));
      expect(posts, hasLength(20));
      expect(posts.first.cooked, isNotEmpty);
    });

    test('search: hits joined to their topics, plain-text blurbs', () {
      final result = ForumSearchResult.fromJson(fixture('meta_search.json'));
      expect(result.hits, isNotEmpty);
      expect(result.hits.first.topic.title, isNotEmpty);
      expect(result.hits.every((h) => !h.blurb.contains('<')), isTrue);
    });

    test('user summary', () {
      final summary = ForumUserSummary.fromJson(fixture('meta_user_summary.json'));
      expect(summary.postCount, 4635);
      expect(summary.likesReceived, 20262);
      expect(summary.daysVisited, 4071);
    });

    test('current user and notifications (shapes from the serializers)', () {
      final user = ForumCurrentUser.fromJson({
        'current_user': {
          'id': 3,
          'username': 'chimney',
          'name': '烟囱',
          'avatar_template': '/letter_avatar_proxy/v4/letter/c/{size}.png',
          'unread_notifications': 2,
          'unread_high_priority_notifications': 1,
          'all_unread_notifications_count': 4,
          'trust_level': 1,
          'can_create_topic': true,
        },
      });
      expect(user.username, 'chimney');
      expect(user.displayName, '烟囱');
      expect(user.allUnread, 4);
      final page = ForumNotificationPage.fromJson({
        'notifications': [
          {
            'id': 9,
            'notification_type': 2,
            'read': false,
            'created_at': '2026-10-24T01:02:03.000Z',
            'post_number': 3,
            'topic_id': 5,
            'fancy_title': '欢迎来到 dsh-go 社区 :wave:',
            'slug': 'dsh-go',
            'data': {'display_username': 'xiamu', 'topic_title': '欢迎来到 dsh-go 社区'},
          },
        ],
        'total_rows_notifications': 1,
        'load_more_notifications': '/notifications?offset=60',
      });
      final n = page.notifications.single;
      expect(n.actor, 'xiamu');
      expect(n.title, '欢迎来到 dsh-go 社区 👋');
      expect(n.read, isFalse);
      expect(page.hasMore, isTrue);
    });

    test('a queued post and an upload', () {
      final upload = ForumUpload.fromJson({
        'short_url': 'upload://a1b2.png',
        'url': '/uploads/default/original/1X/a1b2.png',
        'original_filename': '截图 [1].png',
        'thumbnail_width': 690,
        'thumbnail_height': 388,
      });
      expect(upload.markdown, '![截图 1|690x388](upload://a1b2.png)');
    });

    test('entities and emoji in titles', () {
      expect(forumPlainText('Tom &amp; Jerry &ldquo;hi&rdquo; &#x1F600; :rocket:'), 'Tom & Jerry “hi” 😀 🚀');
    });
  });

  group('emoji', () {
    test('names, aliases, tones; unknown stays', () {
      expect(emojiFor('smile'), '😄');
      expect(emojiFor(':+1:'), '👍');
      expect(emojiFor('thumbsup'), '👍');
      expect(emojiFor('+1:t3'), '👍🏼');
      expect(emojiFor('heart'), isNotNull);
      expect(emojiFor('dsh_custom_emoji'), isNull);
      expect(replaceEmojiShortcodes('好 :tada: 了 :nope_not_one: 10:30:45'), '好 🎉 了 :nope_not_one: 10:30:45');
    });
  });

  group('cooked HTML', () {
    test('a quote with its author, emoji as text, mentions as links', () {
      final topic = ForumTopicDetail.fromJson(fixture('meta_topic_414890.json'));
      final blocks = parseCooked(topic.posts[4].cooked, base: meta);
      final quote = blocks.whereType<CookedQuote>().single;
      expect(quote.username, 'user09');
      expect(quote.avatarUrl.toString(), startsWith('https://'));
      expect(quote.postNumber, 1);
      expect((quote.body.single as CookedMarkdown).markdown, contains('😜'));
      final mention = parseCooked(topic.posts[3].cooked, base: meta).whereType<CookedMarkdown>().first.markdown;
      expect(mention, contains('[@user09](https://meta.discourse.org/u/user09)'));
      expect(mention, contains('👏'));
      expect(mention, isNot(contains('<img')));
    });

    test('lightbox images keep their size and the original; a table becomes Markdown', () {
      final topic = ForumTopicDetail.fromJson(fixture('meta_topic_414890.json'));
      final blocks = parseCooked(topic.posts.first.cooked, base: meta);
      final image = blocks.whereType<CookedImage>().first;
      expect(image.width, 690);
      expect(image.height, 396);
      expect(image.fullSrc.toString(), contains('/original/'));
      final markdown = blocks.whereType<CookedMarkdown>().map((b) => b.markdown).join('\n\n');
      expect(markdown, contains('| Non | Qui cillum ullamco |'));
      expect(markdown, contains('| `serif_text` |'));
      // Heading anchors are dropped, the heading text stays.
      expect(markdown, contains('### Do sit'));
      expect(markdown, isNot(contains('#p-2052276')));
    });

    test('a protocol-relative image resolves to https', () {
      final topic = ForumTopicDetail.fromJson(fixture('meta_topic_414890.json'));
      final image = parseCooked(topic.posts[3].cooked, base: meta).whereType<CookedImage>().single;
      expect(image.src.scheme, 'https');
      expect(image.src.host, contains('amazonaws.com'));
    });

    test('a onebox becomes a link card', () {
      final topic = ForumTopicDetail.fromJson(fixture('meta_topic_264559.json'));
      final box = topic.posts
          .expand((p) => parseCooked(p.cooked, base: meta))
          .whereType<CookedOnebox>()
          .firstWhere((b) => b.url.host == 'github.com');
      expect(box.title, contains('Duis officia nisi'));
      expect(box.source, 'github.com/discourse/discourse');
    });

    test('code fences keep the language and the text verbatim', () {
      final blocks = parseCooked(
        '<pre><code class="lang-dart">final a = b * c; // `x`\n</code></pre><p>a_b *c* `d`</p>',
        base: forumBase,
      );
      final md = (blocks.single as CookedMarkdown).markdown;
      expect(md, startsWith('```dart\nfinal a = b * c; // `x`\n```'));
      expect(md, endsWith(r'a\_b \*c\* \`d\`'));
    });

    test('emphasis, code spans, line breaks, lists, plain quotes', () {
      final md = parseCooked(
        '<p><strong>粗</strong> 和 <em>斜</em>，<code>a|b</code><br>第二行</p>'
        '<ul><li>一</li><li>二<ul><li>二点一</li></ul></li></ul>'
        '<ol start="3"><li>三</li></ol>'
        '<blockquote><p>引用的话</p></blockquote>',
        base: forumBase,
      ).whereType<CookedMarkdown>().map((b) => b.markdown).join('\n\n');
      expect(md, contains('**粗** 和 *斜*，`a|b`\\\n第二行'));
      expect(md, contains('- 一\n- 二\n   - 二点一'));
      expect(md, contains('3. 三'));
      expect(md, contains('> 引用的话'));
    });

    test('text that looks like Markdown stays text', () {
      final md = (parseCooked('<p>1. 不是列表 # 也不是标题 [x](y) \$5</p>', base: forumBase).single as CookedMarkdown).markdown;
      expect(md, r'1\. 不是列表 \# 也不是标题 \[x\](y) \$5');
    });

    test('share links become install cards (link, plain text, onebox)', () {
      final link = samplePluginLink();
      final cooked =
          '<p>看这个：<a href="${link.webLink}">插件：ModSearch</a></p>'
          '<p>${link.appLink}</p>'
          '<aside class="onebox" data-onebox-src="${link.webLink}"><header class="source"><a href="${link.webLink}">x</a></header></aside>';
      final blocks = parseCooked(cooked, base: forumBase);
      final shares = blocks.whereType<CookedShare>().toList();
      expect(shares, hasLength(3));
      expect(shares.first.label, '插件：ModSearch');
      expect((blocks.first as CookedMarkdown).markdown, '看这个：');
      final summary = summarizeShareLink(shares.first.link);
      expect(summary.kind, ShareKind.plugin);
      expect(summary.title, 'ModSearch 联网搜索');
      expect(summary.kindLabel, '插件');
      expect(shareLinkMarkdown(link), '[插件：ModSearch 联网搜索](${link.webLink})');
    });

    test('polls, videos and details', () {
      final blocks = parseCooked(
        '<div class="poll" data-poll-name="poll"><div class="poll-container"><div class="poll-title">选哪个？</div></div></div>'
        '<div class="youtube-onebox lazy-video-container" data-video-id="abc" data-video-title="演示" data-provider-name="youtube"></div>'
        '<details><summary>展开看日志</summary><p>很长的日志</p></details>',
        base: forumBase,
      );
      expect(blocks[0], isA<CookedEmbed>().having((e) => e.kind, 'kind', CookedEmbedKind.poll));
      expect((blocks[0] as CookedEmbed).label, '选哪个？');
      expect((blocks[1] as CookedEmbed).url.toString(), 'https://www.youtube.com/watch?v=abc');
      final details = blocks[2] as CookedDetails;
      expect(details.summary, '展开看日志');
      expect((details.body.single as CookedMarkdown).markdown, '很长的日志');
    });

    test('the dsh-go welcome topic (captured from the live forum)', () {
      const cooked =
          '<p>dsh-go 是在 Android 手机上运行 DeepSeek Harness（DSH）的客户端。</p>\n<div class="md-table">\n<table>\n'
          '<thead>\n<tr>\n<th>分类</th>\n<th>发什么</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td><a href="/c/plugins">插件</a></td>\n'
          '<td>插件发布、推荐与评测</td>\n</tr>\n</tbody>\n</table>\n</div><p><strong>提问前</strong>先搜一下。</p>\n'
          '<p>请友善交流，详见<a href="/guidelines">社区准则</a>。</p>';
      final md = (parseCooked(cooked, base: Uri.parse('https://forum.example')).single as CookedMarkdown).markdown;
      expect(
        md,
        'dsh-go 是在 Android 手机上运行 DeepSeek Harness（DSH）的客户端。\n\n'
        '| 分类 | 发什么 |\n| --- | --- |\n| [插件](https://forum.example/c/plugins) | 插件发布、推荐与评测 |\n\n'
        '**提问前**先搜一下。\n\n请友善交流，详见[社区准则](https://forum.example/guidelines)。',
      );
    });
  });

  group('addresses', () {
    test('avatars, topics, a forum under a path', () {
      expect(
        forumAvatarUrl(forumBase, '/user_avatar/forum.test/a/{size}/1_2.png', size: 32).toString(),
        'https://forum.test/user_avatar/forum.test/a/64/1_2.png',
      );
      expect(forumResolve(forumBase, '//cdn.test/x.png').toString(), 'https://cdn.test/x.png');
      expect(
        forumTopicUrl(forumBase, topicId: 5, slug: 'dsh-go', postNumber: 3).toString(),
        'https://forum.test/t/dsh-go/5/3',
      );
      final sub = Uri.parse('https://example.com/forum');
      expect(forumResolve(sub, '/t/x/1').toString(), 'https://example.com/forum/t/x/1');
    });
  });
}
