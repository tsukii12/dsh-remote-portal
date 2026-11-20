import 'package:dsh_portal/dsh_portal.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../l10n/l10n.dart';

class RemotePairingPage extends StatefulWidget {
  const RemotePairingPage({super.key});
  @override
  State<RemotePairingPage> createState() => _RemotePairingPageState();
}

class _RemotePairingPageState extends State<RemotePairingPage> {
  final _scanner = MobileScannerController();
  bool _done = false;
  String? _error;
  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.l10n.portalScan)),
    body: Column(
      children: [
        Expanded(
          child: MobileScanner(
            controller: _scanner,
            onDetect: (capture) {
              if (_done) return;
              final raw = capture.barcodes.firstOrNull?.rawValue;
              if (raw == null) return;
              try {
                PortalScan.parse(raw);
                _done = true;
                Navigator.of(context).pop(raw);
              } on FormatException catch (error) {
                setState(() => _error = error.message);
              }
            },
          ),
        ),
        if (_error != null) Padding(padding: const EdgeInsets.all(16), child: Text(_error!)),
      ],
    ),
  );
}
