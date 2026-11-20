import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../shell/page_frame.dart';

class MermaidPreviewPage extends StatelessWidget {
  const MermaidPreviewPage({super.key, required this.source});
  final String source;
  static Route<void> route({required String source}) =>
      MaterialPageRoute<void>(builder: (_) => MermaidPreviewPage(source: source));
  @override
  Widget build(BuildContext context) => AppPage.list(
    title: 'Mermaid',
    children: [
      Padding(padding: const EdgeInsets.all(20), child: Text(context.l10n.portalWebRemoved)),
      Padding(padding: const EdgeInsets.all(20), child: SelectableText(source)),
    ],
  );
}
