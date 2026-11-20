import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../shell/page_frame.dart';
import '../index/settings_pages.dart';
import '../settings_widgets.dart';

class SettingsSearchPage extends StatefulWidget {
  const SettingsSearchPage({super.key});
  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const SettingsSearchPage());
  @override
  State<SettingsSearchPage> createState() => _SettingsSearchPageState();
}

class _SettingsSearchPageState extends State<SettingsSearchPage> {
  final _query = TextEditingController();
  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final query = _query.text.trim().toLowerCase();
    final pages = remoteSettingsPages.where(
      (id) => id != SettingsPageId.hub && SettingsIndex.page(id).title(l10n).toLowerCase().contains(query),
    );
    return AppPage.list(
      title: l10n.searchSettingsHint,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: _query,
            autofocus: true,
            decoration: InputDecoration(hintText: l10n.searchSettingsHint),
            onChanged: (_) => setState(() {}),
          ),
        ),
        if (pages.isEmpty) Padding(padding: const EdgeInsets.all(24), child: Text(l10n.searchNoResults)),
        if (pages.isNotEmpty)
          SettingsSection(
            children: [
              for (final id in pages)
                SettingsTile(
                  spot: SettingsIndex.entry(id),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => settingsPage(id))),
                ),
            ],
          ),
      ],
    );
  }
}
