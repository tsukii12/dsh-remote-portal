// A shared skill's files or AGENTS.md, read before choosing to import them.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../share_code/profile_export.dart' show formatShareBytes;
import '../common/app_sheet.dart';
import '../common/list_page_row.dart';
import '../common/sheet_navigator.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../common/brief_notice.dart';

Future<void> showShareContentSheet(BuildContext context, {required String title, required Map<String, String> files}) =>
    showAppSheet<void>(
      context,
      heightFactor: 0.82,
      builder: (_) => SheetNavigator(
        root: (context) {
          if (files.length == 1) {
            final file = files.entries.single;
            return _Content(title: file.key, text: file.value);
          }
          final names = [
            if (files.containsKey('SKILL.md')) 'SKILL.md',
            ...files.keys.where((name) => name != 'SKILL.md'),
          ];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetHeader(title),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    SheetGroup(
                      children: [
                        for (final name in names)
                          ListPageRow(
                            key: ValueKey('share-file-$name'),
                            title: name,
                            value: formatShareBytes(utf8.encode(files[name]!).length),
                            onTap: () =>
                                SheetNavigator.of(context).push((_) => _Content(title: name, text: files[name]!)),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );

class _Content extends StatelessWidget {
  const _Content({required this.title, required this.text});

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(
          title,
          actions: [
            SheetIconButton(
              icon: AppIcons.copy,
              tooltip: l10n.commonCopy,
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: text));
                if (context.mounted) {
                  showBriefNotice(context, l10n.commonCopied);
                }
              },
            ),
          ],
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.05),
                borderRadius: AppShape.radiusMd,
              ),
              child: SelectableText(text, style: AppType.monoSmall()),
            ),
          ),
        ),
      ],
    );
  }
}
