// Not a check: renders every card the goldens cover at the export's 3× into
// $SHARE_PREVIEW_DIR (for side-by-side review). Skipped unless it is set.
//
//   SHARE_PREVIEW_DIR=/path flutter test test/share/share_preview_render_test.dart

import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_app/ui/share/share_card.dart';
import 'package:dsh_app/ui/share/share_content.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart' show ImageAttachment;
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

final _dir = Platform.environment['SHARE_PREVIEW_DIR'];

Future<void> _save(WidgetTester tester, String name) async {
  {
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(shareCardKey));
    final bytes = await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 3);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data!.buffer.asUint8List();
    });
    await tester.runAsync(() => File('$_dir/$name.png').writeAsBytes(bytes!));
  }
}

void _preview(String name, Future<void> Function(WidgetTester tester) body) =>
    softShadowTest(name, body, skip: _dir == null);

void main() {
  for (final template in ShareTemplate.values) {
    _preview('reply ${template.name}', (tester) async {
      await pumpShareCard(tester, ShareCard(content: sampleReplyContent(), template: template));
      await _save(tester, 'after_reply_${template.name}');
    });
  }

  for (final (template, accent) in [
    (ShareTemplate.light, AppAccent.amber),
    (ShareTemplate.card, AppAccent.dusk),
    (ShareTemplate.glass, AppAccent.turquoise),
    (ShareTemplate.paper, AppAccent.daiqing),
  ]) {
    _preview('accent ${template.name} ${accent.id}', (tester) async {
      await pumpShareCard(
        tester,
        ShareCard(content: sampleReplyContent(), template: template),
        accent: accent,
      );
      await _save(tester, 'after_accent_${template.name}_${accent.id}');
    });
  }

  _preview('pictures', (tester) async {
    final p = await photos(tester);
    final answer = [
      '这两张都是傍晚的逆光：天空过曝，前景偏暗。先看调整后的效果：',
      dataImage(p[2]),
      '曝光降了 0.7 档，阴影提亮 30%，色温往暖调了 300K。其余几种裁切也放在下面，挑一张喜欢的：',
      [dataImage(p[3]), dataImage(p[4]), dataImage(p[5])].join('\n'),
    ].join('\n\n');
    for (final template in ShareTemplate.values) {
      await pumpShareCard(
        tester,
        ShareCard(
          template: template,
          content: ShareContent(
            title: '傍晚照片调色',
            sessionId: 's1',
            blocks: [
              const ShareQuestion(
                '这两张拍得有点灰，帮我调一下',
                images: [
                  ShareAttachmentImage(
                    ImageAttachment(attachmentId: 'p0', mediaType: 'image/png', width: 1200, height: 900),
                  ),
                  ShareAttachmentImage(
                    ImageAttachment(attachmentId: 'p1', mediaType: 'image/png', width: 900, height: 1200),
                  ),
                ],
              ),
              ShareAnswer(shareMarkdown(answer, images: true)),
            ],
            model: 'deepseek-v4-pro',
            stats: '1 分 08 秒 · 6 步',
            process: const [
              ShareProcessItem('运行命令', 3, tool: 'bash'),
              ShareProcessItem('查看文件', 2, tool: 'read_image'),
            ],
          ),
        ),
        overrides: [attachmentsFrom(p)],
      );
      await _save(tester, 'after_images_${template.name}');
    }
  });

  _preview('grid', (tester) async {
    final p = await photos(tester);
    await pumpShareCard(
      tester,
      ShareCard(
        template: ShareTemplate.dark,
        content: ShareContent(
          title: '旅行照片挑选',
          sessionId: 's1',
          blocks: [
            const ShareQuestion(
              '挑几张适合做封面的',
              images: [
                ShareAttachmentImage(
                  ImageAttachment(attachmentId: 'p3', mediaType: 'image/png', width: 1000, height: 1000),
                ),
              ],
            ),
            ShareAnswer(shareMarkdown('这几张构图最稳：\n\n${[for (final b in p) dataImage(b)].join('\n')}', images: true)),
          ],
          model: 'deepseek-v4-pro',
        ),
      ),
      overrides: [attachmentsFrom(p)],
    );
    await _save(tester, 'after_images_grid_dark');
  });

  _preview('rounds', (tester) async {
    final p = await photos(tester);
    for (final template in [ShareTemplate.light, ShareTemplate.paper]) {
      await pumpShareCard(
        tester,
        ShareCard(
          template: template,
          content: ShareContent(
            title: '周末去杭州的安排',
            sessionId: 's1',
            blocks: [
              const ShareQuestion('周六一早出发，帮我排一下西湖一天的路线'),
              ShareAnswer(
                shareMarkdown(
                  '按「北线 → 苏堤 → 南线」走，避开中午的人流：\n\n1. **07:30** 断桥看晨雾，沿白堤到孤山\n2. **10:00** 北山街喝咖啡，坐游船到三潭印月\n3. **13:30** 苏堤骑行，花港观鱼\n4. **17:00** 雷峰塔看日落',
                  images: true,
                ),
              ),
              const ShareQuestion(
                '拍了一张断桥的，帮我看看构图',
                images: [
                  ShareAttachmentImage(
                    ImageAttachment(attachmentId: 'p0', mediaType: 'image/png', width: 1200, height: 900),
                  ),
                ],
              ),
              ShareAnswer(shareMarkdown('地平线压在三分线上，很稳。右侧的树枝可以裁掉一点，让桥成为唯一的主体：\n\n${dataImage(p[2])}', images: true)),
              const ShareQuestion('晚上住哪儿方便？'),
              const ShareAnswer('住**龙翔桥**附近：地铁一号线直达，步行到湖边十分钟，晚上吃饭的选择也多。'),
            ],
            model: 'deepseek-v4-pro',
            stats: '3 分 42 秒 · 17 步',
            process: const [
              ShareProcessItem('联网搜索', 6, tool: 'web_search'),
              ShareProcessItem('打开网页', 4, tool: 'web_fetch'),
              ShareProcessItem('运行命令', 1, tool: 'bash'),
            ],
          ),
        ),
        overrides: [attachmentsFrom(p)],
      );
      await _save(tester, 'after_rounds_${template.name}');
    }
  });

  _preview('long and plugin', (tester) async {
    await pumpShareCard(tester, ShareCard(content: sampleLongContent()));
    await _save(tester, 'after_long_light');
    await pumpShareCard(
      tester,
      const ShareCard(
        content: ShareContent(blocks: [samplePlugin]),
        template: ShareTemplate.card,
      ),
    );
    await _save(tester, 'after_plugin_card');
  });
}
