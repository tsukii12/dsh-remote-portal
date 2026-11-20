// What the app shows of the bridge's contributions: ready entries only,
// its own second line of limits, non-native plugins empty, issue codes in
// the app's words.

import 'package:dsh_app/plugins/native/native_icons.dart';
import 'package:dsh_app/plugins/native/native_model.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  test('the example plugins as the app shows them', () {
    final c = nativeContributionsFrom(
      contributions([
        quickPlugin(wants: ['clipboard', 'bogus']),
        usagePlugin(),
      ]),
    );
    expect(c.rev, 'r1');
    final quick = c.plugin('dsh-go-example-quick')!;
    expect(quick.native, isTrue);
    expect(quick.title, '快捷指令');
    expect(quick.wants, {'clipboard'}, reason: 'unknown wants are dropped');
    expect(quick.composerActions.map((a) => a.id), ['translate', 'hello']);
    expect(quick.composerActions.first.icon, AppIcons.translate);
    expect(quick.composerActions.last.effects.single, {'type': 'insert', 'text': '你好'});
    expect(quick.messageActions.first.icon, AppIcons.readText, reason: '`speaker` is one of the extra names');
    expect(quick.declared, {NativeSurface.composerActions, NativeSurface.messageActions});
    final usage = c.plugin('dsh-go-example-usage')!;
    expect(usage.strips.single.panel, 'usage');
    expect(usage.strips.single.live, isTrue);
    expect(usage.panels.single.placement, {'session.tab', 'features'});
    expect(usage.declared, {NativeSurface.composerStrip, NativeSurface.panel});
  });

  test('entries that are not ready, over the limits, or nowhere to go are left out', () {
    final c = nativeContributionsFrom(
      contributions([
        plugin(
          'p',
          composer: [
            {'id': 'a', 'label': '一二三四五六七八九十十一'},
            {'id': 'b', 'label': 'B', 'ready': false},
            {'id': 'c', 'label': 'C'},
            {'id': 'd', 'label': 'D'},
          ],
          menu: [
            {'id': 'm', 'label': '一二三四五六七八九十十一十二十三'},
          ],
          strip: [
            {'id': 's1'},
            {'id': 's2'},
          ],
          panels: [
            {
              'id': 'chat',
              'title': '只在聊天页',
              'placement': ['chat.panel'],
            },
            {'id': 'long', 'title': '一个特别特别特别特别长的面板标题啊啊', 'icon': 'nope'},
          ],
        ),
      ]),
    );
    final p = c.plugin('p')!;
    expect(p.composerActions.map((a) => a.id), ['a', 'c'], reason: 'not ready skipped, two at most');
    expect(p.composerActions.first.label.runes.length, 10);
    expect(p.messageActions.single.label.runes.length, 12);
    expect(p.strips.map((s) => s.id), ['s1'], reason: 'one status line a plugin');
    expect(p.panels.map((x) => x.id), ['chat', 'long'], reason: 'chat.panel: the chat page\'s 插件 sheet');
    expect(p.panels.first.placement, ['chat.panel']);
    expect(p.panels.last.title.runes.length, 16);
    expect(nativeIcon(p.panels.last.icon), isNull, reason: 'unknown names draw the generic glyph');
  });

  test('a plugin that is not native shows nothing but keeps its issues', () {
    final c = nativeContributionsFrom(
      contributions([
        plugin(
          'old',
          state: 'needs-app',
          composer: [
            {'id': 'x', 'label': 'X'},
          ],
          issues: [
            {'path': '/dshGo/minApp', 'code': 'needs-app', 'severity': 'error'},
          ],
        ),
      ]),
    );
    final p = c.plugin('old')!;
    expect(p.native, isFalse);
    expect(p.isEmpty, isTrue);
    expect(p.declared, isEmpty);
    expect(p.issues.single.pointer, '/dshGo/minApp');
    expect(p.issues.single.message, '需要更新 App');
    expect(p.issues.single.error, isTrue);
  });

  test('issue codes in the app words; unknown ones too', () {
    expect(nativeIssueText('too-long'), '文字太长，已截断');
    expect(nativeIssueText('no-handler'), '插件还没处理这一项，暂不显示');
    expect(nativeIssueText('violation', count: 3), '出错 3 次');
    expect(nativeIssueText('timeout'), '插件没有及时响应');
    expect(nativeIssueText('something-new'), '其他问题');
  });

  test('equal answers compare equal (an unchanged read rebuilds nothing)', () {
    final a = nativeContributionsFrom(contributions([quickPlugin(), usagePlugin()]));
    final b = nativeContributionsFrom(contributions([quickPlugin(), usagePlugin()]));
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    final c = nativeContributionsFrom(contributions([quickPlugin()]));
    expect(a == c, isFalse);
  });

  test('a plugin listed twice counts once', () {
    final c = nativeContributionsFrom(contributions([quickPlugin(), quickPlugin()]));
    expect(c.plugins, hasLength(1));
  });
}
