import 'package:dsh_app/state/media_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('API root feedback', () {
    test('compatible roots preserve legitimate path prefixes', () {
      for (final root in [
        'https://api.example.test/v1',
        'https://api.example.test/v1beta/openai/',
        ' https://api.example.test/v1/ ',
      ]) {
        expect(mediaBaseUrlIssue(root, 'openai-compatible'), isNull);
      }
      expect(
        mediaRequestPreview(' https://api.example.test/v1/// ', 'openai-compatible', null),
        'https://api.example.test/v1/images/generations',
      );
    });
    test('rejects malformed or credential-bearing URLs before mutation', () {
      for (final root in [
        '',
        'http://api.example.test',
        'https://',
        'api.example.test',
        'https://user:password@api.example.test/v1',
        'https://api.example.test/v1?key=secret',
        'https://api.example.test/v1#fragment',
        'https://api.example.test/a b',
        'https://api.example.test:99999',
        r'https://api.example.test\v1',
      ]) {
        expect(mediaBaseUrlIssue(root, 'openai-compatible'), MediaUrlIssue.invalid, reason: root);
        expect(mediaRequestPreview(root, 'openai-compatible', null), isNull);
      }
    });
    test('rejects accidentally pasted generation, edit, chat or video endpoints', () {
      for (final path in [
        '/v1/images/generations',
        '/v1/images/edits/',
        '/v1/chat/completions',
        '/v1/responses',
        '/api/v3/contents/generations/tasks/task-1',
        '/api/v1/services/aigc/video-generation/video-synthesis',
        '/api/v1/services/aigc/multimodal-generation/generation',
      ]) {
        expect(mediaBaseUrlIssue('https://api.example.test$path', 'openai-compatible'), MediaUrlIssue.endpoint);
      }
      expect(mediaBaseUrlIssue('https://api.example.test/api/v3', 'ark-image'), MediaUrlIssue.rootRequired);
      expect(mediaBaseUrlIssue('https://api.example.test/', 'ark-image'), isNull);
    });
    test('native preview comes from host metadata and does not invent missing paths', () {
      const root = 'https://ark.example.test';
      expect(mediaRequestPreview(root, 'ark-image', null), isNull);
      expect(
        mediaRequestPreview(root, 'ark-image', {
          'profiles': {
            'ark-image': {'path': '/api/v3/images/generations'},
          },
        }),
        '$root/api/v3/images/generations',
      );
      for (final path in ['//other.test/path', '/path?key=secret', 'relative', '/bad path']) {
        expect(
          mediaRequestPreview(root, 'ark-image', {
            'profiles': {
              'ark-image': {'path': path},
            },
          }),
          isNull,
        );
      }
      expect(mediaRequestPreview(root, 'unknown-protocol', null), isNull);
    });
    test('origin comparison includes port but not path or host case', () {
      expect(mediaTargetOriginChanged('https://API.example.test/v1', 'https://api.example.test:443/v2/'), isFalse);
      expect(mediaTargetOriginChanged('https://api.example.test/v1', 'https://other.test/v1'), isTrue);
      expect(mediaTargetOriginChanged('https://api.example.test', 'https://api.example.test:8443'), isTrue);
      expect(mediaTargetOriginChanged('broken', 'https://api.example.test'), isTrue);
      expect(mediaTargetOriginChanged('ftp://api.example.test', 'https://api.example.test'), isTrue);
    });
  });
}
