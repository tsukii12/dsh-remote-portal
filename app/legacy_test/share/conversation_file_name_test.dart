import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/artifacts.dart' show FilesChannel;
import 'package:dsh_app/ui/replay/conversation_out.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final cases = [
    (label: 'pair crossing the 40-code-unit boundary', title: '${'a' * 39}😀', stem: 'a' * 39),
    (label: 'complete pair ending at 40 code units', title: '${'a' * 38}😀', stem: '${'a' * 38}😀'),
    (label: 'complete pair retained when longer title is truncated', title: '${'a' * 38}😀b', stem: '${'a' * 38}😀'),
    (label: 'pair after the limit is excluded', title: '${'a' * 40}😀', stem: 'a' * 40),
    (label: 'ordinary BMP still uses the 40-code-unit budget', title: '字' * 45, stem: '字' * 40),
    (label: 'path characters and whitespace are still cleaned', title: '  a/b:*?"<>|\x00\t c  ', stem: 'a b c'),
  ];
  for (final sample in cases) {
    test('conversation filename: ${sample.label}', () async {
      // All titles are valid Unicode and fit the existing 120-code-unit title budget.
      expect(utf8.decode(utf8.encode(sample.title)), sample.title);
      expect(sample.title.length, lessThan(120));
      final dir = await Directory.systemTemp.createTemp('conversation-file-name-');
      try {
        final out = ConversationOut(files: const FilesChannel(), cacheRoot: () async => dir);
        final observations = <({ConversationFormat format, String name, File file, String listedName})>[];
        for (final format in ConversationFormat.values) {
          final name = ConversationOut.fileName(sample.title, format);
          final file = await out.write(name, 'content:${format.name}');
          final listed = (await file.parent.list().toList()).whereType<File>().singleWhere(
            (entry) => entry.uri.pathSegments.last.endsWith('.${format.extension}'),
          );
          expect(await file.readAsString(), 'content:${format.name}');
          expect(await listed.readAsString(), 'content:${format.name}');
          observations.add((format: format, name: name, file: file, listedName: listed.uri.pathSegments.last));
        }
        // Measure the real writes before asserting the name invariant; no fileStem copy is used.
        for (final observation in observations) {
          final (:format, :name, :file, :listedName) = observation;
          expect(utf8.decode(utf8.encode(name)), name, reason: 'a legal title must not create an unpaired surrogate');
          expect(name, '${sample.stem}.${format.extension}');
          expect(fileStem(sample.title).length, lessThanOrEqualTo(40));
          expect(file.uri.pathSegments.last, name);
          expect(listedName, name);
        }
      } finally {
        await dir.delete(recursive: true);
      }
    });
  }
}
