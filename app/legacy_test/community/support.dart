// A community.json with every kind of entry, a matching market index and a
// scripted HTTP fake for the 社区 tests.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/update/update_http.dart';

/// Everything filled in (example values, not the shipped ones).
String sampleFeed({int revision = 7, String tagline = '开源项目，欢迎点星'}) => jsonEncode({
  'schema': 1,
  'revision': revision,
  'updatedAt': '2026-10-24T00:00:00Z',
  'tagline': tagline,
  'plugins': [
    {'name': 'novel-writer', 'note': '五个子代理一起写长篇'},
    {'name': 'dsh-approval-gate', 'note': '危险命令先问一句'},
    {'name': 'not-in-the-index'},
  ],
  'prompts': [
    {'title': '整理周报', 'summary': '按提交记录写一份周报', 'icon': 'doc', 'prompt': '看看最近一周的 Git 提交，整理成周报。'},
    {'title': '读懂报错', 'summary': '原因、修法和验证', 'icon': 'bug', 'prompt': '帮我解释这段报错：\n\n'},
    {'title': '数据做成图表', 'summary': '表格、合计和一张图', 'icon': 'chart', 'prompt': '把数据做成图表。'},
    {'title': '两周入门一门语言', 'summary': '按天的计划和练习', 'icon': 'school', 'prompt': '两周入门 Rust。'},
  ],
  'groups': [
    {
      'kind': 'qq',
      'title': 'QQ 交流群',
      'subtitle': '群号 123456789',
      'url': 'https://qm.qq.com/q/example',
      'copy': '123456789',
    },
    {'kind': 'wechat', 'title': '微信公众号', 'subtitle': '搜索「dsh-go」', 'qr': 'https://example.com/wechat'},
    {'kind': 'telegram', 'title': 'Telegram', 'subtitle': 't.me/example', 'url': 'https://t.me/example'},
    {'kind': 'qq', 'title': '没填的群', 'url': '', 'qr': '', 'copy': ''},
    {'kind': 'forum', 'title': '不安全的链接', 'url': 'http://example.com/forum'},
  ],
  'updates': [
    {'date': '2026-10-20', 'title': '插件广场', 'summary': '一键装进本机或远程主机。'},
    {
      'date': '2026-10-24',
      'title': 'dsh-go 1.0',
      'summary': '本机运行 DSH、远程主机、插件广场。',
      'url': 'https://example.com/releases',
    },
  ],
});

/// Serves [bodies] by URL; a missing URL is a dead host.
class ScriptedHttp implements UpdateHttp {
  ScriptedHttp(this.bodies, {this.statuses = const {}});

  final Map<String, String> bodies;
  final Map<String, int> statuses;
  final asked = <Uri>[];

  @override
  Future<UpdateHttpResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 15),
  }) async {
    asked.add(url);
    final body = bodies[url.toString()];
    if (body == null) throw const SocketException('unreachable');
    return UpdateHttpResponse(status: statuses[url.toString()] ?? 200, body: Stream.value(utf8.encode(body)));
  }
}
