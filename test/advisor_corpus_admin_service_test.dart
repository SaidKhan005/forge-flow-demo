// Phase 11a.12 — AdvisorCorpusAdminService focused tests.
//
// Pure local validation contract. No network, no SharedPreferences,
// no shell-out. Each test exercises a single seam.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/advisor_corpus_admin_service.dart';

void main() {
  group('AdvisorCorpusAdminService.preview', () {
    test('valid Markdown returns a deterministic local summary', () async {
      final service = AdvisorCorpusAdminService();

      final result = await service.preview(
        fileName: 'sample.md',
        markdown: '# Heading\n\nBody line one.\nBody line two.\n',
      );

      expect(result.isValid, isTrue);
      expect(result.status, CorpusPreviewStatus.valid);
      expect(result.fileName, 'sample.md');
      expect(result.normalizedFileName, 'sample.md');
      expect(result.sourcePathPreview,
          'docs/Knowledge_graph_docs/sample.md');
      expect(result.titlePreview, 'Heading');
      expect(result.headingCount, 1);
      expect(result.lineCount, 5);
      // length 41 chars, ceil(41/4) = 11
      expect(result.estimatedTokens, 11);
      // ceil(11/400) = 1, max(1, 1) = 1
      expect(result.estimatedChunkCount, 1);
      expect(result.localStatus, 'preview_local_only');
      expect(result.errorMessage, isNull);
    });

    test('preview is deterministic across repeated calls with same input',
        () async {
      final service = AdvisorCorpusAdminService();
      const fileName = 'doc.md';
      const markdown = '# A\n\nbody\n';

      final first = await service.preview(
        fileName: fileName,
        markdown: markdown,
      );
      final second = await service.preview(
        fileName: fileName,
        markdown: markdown,
      );

      expect(first.fileName, second.fileName);
      expect(first.normalizedFileName, second.normalizedFileName);
      expect(first.sourcePathPreview, second.sourcePathPreview);
      expect(first.titlePreview, second.titlePreview);
      expect(first.headingCount, second.headingCount);
      expect(first.estimatedChunkCount, second.estimatedChunkCount);
      expect(first.lineCount, second.lineCount);
      expect(first.estimatedTokens, second.estimatedTokens);
      expect(first.localStatus, second.localStatus);
      expect(first.status, second.status);
    });

    test('non-.md filename is rejected with an error message', () async {
      final service = AdvisorCorpusAdminService();

      final result = await service.preview(
        fileName: 'sample.txt',
        markdown: '# Heading\n',
      );

      expect(result.isValid, isFalse);
      expect(result.status, CorpusPreviewStatus.invalidName);
      expect(result.errorMessage, isNotNull);
      expect(result.errorMessage!.toLowerCase(), contains('.md'));
      expect(result.normalizedFileName, isNull);
      expect(result.sourcePathPreview, isNull);
      expect(result.titlePreview, isNull);
      expect(result.headingCount, isNull);
      expect(result.estimatedChunkCount, isNull);
      expect(result.lineCount, isNull);
      expect(result.estimatedTokens, isNull);
      expect(result.localStatus, isNull);
    });

    test('empty filename is rejected with an error message', () async {
      final service = AdvisorCorpusAdminService();

      final result = await service.preview(
        fileName: '   ',
        markdown: '# Heading\n',
      );

      expect(result.isValid, isFalse);
      expect(result.status, CorpusPreviewStatus.invalidName);
    });

    test('bare ".md" with no stem is rejected', () async {
      final service = AdvisorCorpusAdminService();

      final result = await service.preview(
        fileName: '.md',
        markdown: '# Heading\n',
      );

      expect(result.isValid, isFalse);
      expect(result.status, CorpusPreviewStatus.invalidName);
    });

    test('blank Markdown is rejected with an error message', () async {
      final service = AdvisorCorpusAdminService();

      final result = await service.preview(
        fileName: 'sample.md',
        markdown: '   \n  \t\n',
      );

      expect(result.isValid, isFalse);
      expect(result.status, CorpusPreviewStatus.blankMarkdown);
      expect(result.errorMessage, isNotNull);
      expect(result.lineCount, isNull);
      expect(result.estimatedTokens, isNull);
      expect(result.localStatus, isNull);
    });

    test('uppercase .MD extension is accepted (case-insensitive)', () async {
      final service = AdvisorCorpusAdminService();

      final result = await service.preview(
        fileName: 'SAMPLE.MD',
        markdown: '# A\n',
      );

      expect(result.isValid, isTrue);
      // Case is preserved in the normalized name.
      expect(result.normalizedFileName, 'SAMPLE.MD');
      expect(result.sourcePathPreview,
          'docs/Knowledge_graph_docs/SAMPLE.MD');
    });
  });

  group('AdvisorCorpusAdminService.preview — file name normalization', () {
    test('strips backslash-prefixed path segments to the basename',
        () async {
      final service = AdvisorCorpusAdminService();

      final result = await service.preview(
        fileName: r'C:\some\path\Wage_Standards.md',
        markdown: '# Wages\n',
      );

      expect(result.isValid, isTrue);
      expect(result.normalizedFileName, 'Wage_Standards.md');
      expect(result.sourcePathPreview,
          'docs/Knowledge_graph_docs/Wage_Standards.md');
    });

    test('strips forward-slash-prefixed path segments to the basename',
        () async {
      final service = AdvisorCorpusAdminService();

      final result = await service.preview(
        fileName: 'docs/Knowledge_graph_docs/My Doc.md',
        markdown: '# Hi\n',
      );

      expect(result.isValid, isTrue);
      expect(result.normalizedFileName, 'My Doc.md');
      expect(result.sourcePathPreview,
          'docs/Knowledge_graph_docs/My Doc.md');
    });

    test('preserves stem case in the normalized name', () async {
      final service = AdvisorCorpusAdminService();

      final result = await service.preview(
        fileName: 'Mixed_Case_Doc.md',
        markdown: '# Title\n',
      );

      expect(result.isValid, isTrue);
      expect(result.normalizedFileName, 'Mixed_Case_Doc.md');
    });
  });

  group('AdvisorCorpusAdminService.preview — title extraction', () {
    test('extracts the first H1 line as the title preview', () async {
      final service = AdvisorCorpusAdminService();

      final result = await service.preview(
        fileName: 'doc.md',
        markdown: '# My First Title\n\n## Sub\n\nbody\n',
      );

      expect(result.isValid, isTrue);
      expect(result.titlePreview, 'My First Title');
    });

    test('falls back to the file-name stem when no H1 is present',
        () async {
      final service = AdvisorCorpusAdminService();

      final result = await service.preview(
        fileName: 'Wage_Standards.md',
        markdown: '## Only H2\n\nbody\n',
      );

      expect(result.isValid, isTrue);
      expect(result.titlePreview, 'Wage_Standards');
    });

    test('falls back to the file-name stem when only blank H1 is present',
        () async {
      final service = AdvisorCorpusAdminService();

      final result = await service.preview(
        fileName: 'doc.md',
        markdown: '#   \n\n## Real heading\n\nbody\n',
      );

      expect(result.isValid, isTrue);
      // The blank-`#` line does not match the H1 regex (which requires
      // non-whitespace after the space), so we fall back to the stem.
      expect(result.titlePreview, 'doc');
    });

    test('preserves H1 inner whitespace but trims leading/trailing space',
        () async {
      final service = AdvisorCorpusAdminService();

      final result = await service.preview(
        fileName: 'doc.md',
        markdown: '#    Spaced   Title   \n\nbody\n',
      );

      expect(result.isValid, isTrue);
      expect(result.titlePreview, 'Spaced   Title');
    });
  });

  group('AdvisorCorpusAdminService.preview — heading count', () {
    test('counts H1 through H6 lines', () async {
      final service = AdvisorCorpusAdminService();

      final result = await service.preview(
        fileName: 'doc.md',
        markdown: '# H1\n## H2\n### H3\n#### H4\n##### H5\n###### H6\n'
            'plain body line\n',
      );

      expect(result.isValid, isTrue);
      expect(result.headingCount, 6);
    });

    test('does not count seven-or-more `#` runs as headings', () async {
      final service = AdvisorCorpusAdminService();

      final result = await service.preview(
        fileName: 'doc.md',
        markdown: '# H1\n####### Not a heading\nbody\n',
      );

      expect(result.isValid, isTrue);
      expect(result.headingCount, 1);
    });

    test('does not count `#` followed by non-space (URL anchor, etc.)',
        () async {
      final service = AdvisorCorpusAdminService();

      final result = await service.preview(
        fileName: 'doc.md',
        markdown: '# Real H1\n#NotAHeading\nbody\n',
      );

      expect(result.isValid, isTrue);
      expect(result.headingCount, 1);
    });
  });

  group('AdvisorCorpusAdminService.preview — estimated chunk count', () {
    test('short Markdown produces exactly one chunk', () async {
      final service = AdvisorCorpusAdminService();

      final result = await service.preview(
        fileName: 'short.md',
        markdown: '# A\nshort body\n',
      );

      expect(result.isValid, isTrue);
      expect(result.estimatedTokens, lessThan(400));
      expect(result.estimatedChunkCount, 1);
    });

    test('Markdown that crosses the threshold produces multiple chunks',
        () async {
      final service = AdvisorCorpusAdminService();
      // 4000 chars → ceil(4000/4) = 1000 tokens → ceil(1000/400) = 3
      final body = 'x' * 4000;

      final result = await service.preview(
        fileName: 'big.md',
        markdown: '# Title\n\n$body\n',
      );

      expect(result.isValid, isTrue);
      expect(result.estimatedChunkCount, 3);
    });

    test('estimated chunk count is at least 1 for any valid input',
        () async {
      final service = AdvisorCorpusAdminService();

      final result = await service.preview(
        fileName: 'tiny.md',
        markdown: '#A\nx\n',
      );

      expect(result.isValid, isTrue);
      expect(result.estimatedChunkCount, greaterThanOrEqualTo(1));
    });
  });

  group('AdvisorCorpusAdminService.attemptCloudLoad', () {
    test('always returns blocked with the 11a.11b explanation', () async {
      final service = AdvisorCorpusAdminService();

      final result = await service.attemptCloudLoad(
        fileName: 'sample.md',
        markdown: '# A\n',
      );

      expect(result.status, CorpusCloudLoadStatus.blocked);
      expect(result.message.toLowerCase(), contains('blocked'));
      expect(result.message, contains('11a.11b'));
    });

    test('returns blocked even for invalid input — no live call attempted',
        () async {
      final service = AdvisorCorpusAdminService();

      final result = await service.attemptCloudLoad(
        fileName: 'wrong.txt',
        markdown: '',
      );

      // The cloud path is closed regardless of input — there is no
      // surface for a real load to escape from.
      expect(result.status, CorpusCloudLoadStatus.blocked);
    });
  });
}
