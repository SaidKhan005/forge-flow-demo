import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:forge_and_flow/services/voyage_embedding_provider.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

const defaultManifestPath = 'docs/Knowledge_graph_docs/corpus_manifest.yaml';
const excludedEmptyApronFileName = 'The Empty Apron - 2026.md';
const advisorEmbeddingProvider = 'voyage';
const advisorEmbeddingModel = 'voyage-4-large';
const advisorEmbeddingDimensions = 1024;
const advisorEmbeddingMaxInputTokens = 32000;
const advisorEmbeddingDistanceMetric = 'cosine';
const advisorEmbeddingTokenizer = 'voyage';
const advisorRerankProvider = 'voyage';
const advisorRerankModel = 'rerank-2.5';
const advisorAnswerRuntimeFamily = 'claude';
const advisorEmbeddingInputType = 'document';
const advisorEmbeddingOutputDtype = 'float';
const advisorVoyageEmbeddingsEndpoint =
    'https://api.voyageai.com/v1/embeddings';
const advisorEmbeddingBatchItemLimit = 1000;
const advisorEmbeddingBatchEstimatedTokenLimit = 100000;

class CorpusManifest {
  CorpusManifest({
    required this.path,
    required this.corpusRoot,
    required this.documents,
    required this.excludedSources,
  });

  final String path;
  final String corpusRoot;
  final List<CorpusDocument> documents;
  final List<ExcludedSource> excludedSources;

  static Future<CorpusManifest> load(File manifestFile) async {
    final content = await manifestFile.readAsString();
    final parsed = loadYaml(content);
    final root = _asMap(_plainYaml(parsed), 'manifest');

    return CorpusManifest(
      path: manifestFile.path,
      corpusRoot: _requiredString(root, 'corpus_root', 'manifest'),
      documents: _requiredMapList(
        root,
        'documents',
        'manifest',
      ).map(CorpusDocument.fromMap).toList(growable: false),
      excludedSources: _optionalMapList(
        root,
        'excluded_sources',
        'manifest',
      ).map(ExcludedSource.fromMap).toList(growable: false),
    );
  }
}

class CorpusDocument {
  CorpusDocument({
    required this.docId,
    required this.fileName,
    required this.sourcePath,
    required this.title,
    required this.status,
    required this.scope,
    required this.restaurantId,
    required this.brandContext,
    required this.contentRole,
    required this.authorityTier,
    required this.riskLevel,
    required this.audience,
    required this.chunkProfile,
    required this.graphProfiles,
    required this.tags,
    required this.wordCountEstimate,
    required this.headingCount,
    required this.lineCount,
    required this.sha256Hash,
  });

  final String docId;
  final String fileName;
  final String sourcePath;
  final String title;
  final String status;
  final String scope;
  final String? restaurantId;
  final String brandContext;
  final String contentRole;
  final String authorityTier;
  final String riskLevel;
  final List<String> audience;
  final String chunkProfile;
  final List<String> graphProfiles;
  final List<String> tags;
  final int wordCountEstimate;
  final int headingCount;
  final int lineCount;
  final String sha256Hash;

  factory CorpusDocument.fromMap(Map<String, Object?> map) {
    final context = 'document';
    return CorpusDocument(
      docId: _requiredString(map, 'doc_id', context),
      fileName: _requiredString(map, 'file_name', context),
      sourcePath: _requiredString(map, 'source_path', context),
      title: _requiredString(map, 'title', context),
      status: _requiredString(map, 'status', context),
      scope: _requiredString(map, 'scope', context),
      restaurantId: _optionalString(map, 'restaurant_id', context),
      brandContext: _requiredString(map, 'brand_context', context),
      contentRole: _requiredString(map, 'content_role', context),
      authorityTier: _requiredString(map, 'authority_tier', context),
      riskLevel: _requiredString(map, 'risk_level', context),
      audience: _requiredStringList(map, 'audience', context),
      chunkProfile: _requiredString(map, 'chunk_profile', context),
      graphProfiles: _requiredStringList(map, 'graph_profiles', context),
      tags: _requiredStringList(map, 'tags', context),
      wordCountEstimate: _requiredInt(map, 'word_count_estimate', context),
      headingCount: _requiredInt(map, 'heading_count', context),
      lineCount: _requiredInt(map, 'line_count', context),
      sha256Hash: _requiredString(map, 'sha256', context).toLowerCase(),
    );
  }

  bool get isIncluded => status == 'included';
}

class ExcludedSource {
  ExcludedSource({
    required this.fileName,
    required this.status,
    required this.reason,
  });

  final String fileName;
  final String status;
  final String reason;

  factory ExcludedSource.fromMap(Map<String, Object?> map) {
    const context = 'excluded source';
    return ExcludedSource(
      fileName: _requiredString(map, 'file_name', context),
      status: _requiredString(map, 'status', context),
      reason: _requiredString(map, 'reason', context),
    );
  }
}

class CorpusValidationResult {
  CorpusValidationResult({
    required this.manifest,
    required this.errors,
    required this.activeMarkdownFiles,
  });

  final CorpusManifest manifest;
  final List<String> errors;
  final List<String> activeMarkdownFiles;

  bool get isValid => errors.isEmpty;
}

class CorpusValidator {
  CorpusValidator({required Directory repoRoot}) : _repoRoot = repoRoot;

  final Directory _repoRoot;

  Future<CorpusValidationResult> validate({
    String manifestPath = defaultManifestPath,
  }) async {
    final manifestFile = File(_resolveRepoPath(manifestPath));
    final errors = <String>[];

    if (!manifestFile.existsSync()) {
      throw CorpusManifestException('Manifest not found: $manifestPath');
    }

    final manifest = await CorpusManifest.load(manifestFile);
    final corpusDirectory = Directory(_resolveRepoPath(manifest.corpusRoot));
    if (!corpusDirectory.existsSync()) {
      errors.add('Corpus root does not exist: ${manifest.corpusRoot}');
    }

    _validateRequiredManifestShape(manifest, errors);
    await _validateDocuments(manifest, errors);

    final activeMarkdownFiles = corpusDirectory.existsSync()
        ? corpusDirectory
              .listSync()
              .whereType<File>()
              .where((file) => p.extension(file.path).toLowerCase() == '.md')
              .map((file) => p.basename(file.path))
              .toList()
        : <String>[];
    activeMarkdownFiles.sort();

    _validateDirectoryCoverage(manifest, activeMarkdownFiles, errors);

    return CorpusValidationResult(
      manifest: manifest,
      errors: errors,
      activeMarkdownFiles: activeMarkdownFiles,
    );
  }

  void _validateRequiredManifestShape(
    CorpusManifest manifest,
    List<String> errors,
  ) {
    if (manifest.documents.isEmpty) {
      errors.add('Manifest has no documents.');
    }

    final excludedFileNames = manifest.excludedSources
        .map((source) => source.fileName)
        .toSet();
    if (!excludedFileNames.contains(excludedEmptyApronFileName)) {
      errors.add('$excludedEmptyApronFileName must be listed as excluded.');
    }
  }

  Future<void> _validateDocuments(
    CorpusManifest manifest,
    List<String> errors,
  ) async {
    final seenDocIds = <String>{};
    final seenSourcePaths = <String>{};
    final seenFileNames = <String>{};

    for (final document in manifest.documents) {
      final label = document.docId.isEmpty ? document.fileName : document.docId;
      _validateNonEmptyDocumentFields(document, errors);

      if (!document.isIncluded) {
        errors.add('$label has unsupported status "${document.status}".');
      }
      if (document.fileName == excludedEmptyApronFileName) {
        errors.add(
          '$excludedEmptyApronFileName must not be an included document.',
        );
      }
      if (!seenDocIds.add(document.docId)) {
        errors.add('Duplicate doc_id: ${document.docId}');
      }
      if (!seenSourcePaths.add(document.sourcePath)) {
        errors.add('Duplicate source_path: ${document.sourcePath}');
      }
      if (!seenFileNames.add(document.fileName)) {
        errors.add('Duplicate file_name: ${document.fileName}');
      }
      if (p.basename(document.sourcePath) != document.fileName) {
        errors.add(
          '${document.docId} source_path basename does not match file_name.',
        );
      }

      final sourceFile = File(_resolveRepoPath(document.sourcePath));
      if (!sourceFile.existsSync()) {
        errors.add(
          'Missing source file for ${document.docId}: ${document.sourcePath}',
        );
        continue;
      }

      final actualHash = await sha256ForFile(sourceFile);
      if (actualHash != document.sha256Hash) {
        errors.add(
          'SHA-256 mismatch for ${document.docId}: expected '
          '${document.sha256Hash}, actual $actualHash',
        );
      }
    }
  }

  void _validateNonEmptyDocumentFields(
    CorpusDocument document,
    List<String> errors,
  ) {
    final requiredValues = <String, String>{
      'doc_id': document.docId,
      'file_name': document.fileName,
      'source_path': document.sourcePath,
      'title': document.title,
      'status': document.status,
      'scope': document.scope,
      'brand_context': document.brandContext,
      'content_role': document.contentRole,
      'authority_tier': document.authorityTier,
      'risk_level': document.riskLevel,
      'chunk_profile': document.chunkProfile,
      'sha256': document.sha256Hash,
    };

    for (final entry in requiredValues.entries) {
      if (entry.value.trim().isEmpty) {
        errors.add('${document.docId} has empty ${entry.key}.');
      }
    }
    if (document.audience.isEmpty) {
      errors.add('${document.docId} audience must not be empty.');
    }
    if (document.graphProfiles.isEmpty) {
      errors.add('${document.docId} graph_profiles must not be empty.');
    }
    if (document.tags.isEmpty) {
      errors.add('${document.docId} tags must not be empty.');
    }
  }

  void _validateDirectoryCoverage(
    CorpusManifest manifest,
    List<String> activeMarkdownFiles,
    List<String> errors,
  ) {
    final includedFileNames = manifest.documents
        .where((document) => document.isIncluded)
        .map((document) => document.fileName)
        .toSet();

    final unmanifestedFiles = activeMarkdownFiles
        .where((fileName) => !includedFileNames.contains(fileName))
        .toList();
    if (unmanifestedFiles.isNotEmpty) {
      errors.add(
        'Unmanifested Markdown files in corpus root: '
        '${unmanifestedFiles.join(', ')}',
      );
    }

    final missingFiles = includedFileNames
        .where((fileName) => !activeMarkdownFiles.contains(fileName))
        .toList();
    if (missingFiles.isNotEmpty) {
      errors.add(
        'Manifested files missing from corpus root: ${missingFiles.join(', ')}',
      );
    }

    if (activeMarkdownFiles.contains(excludedEmptyApronFileName)) {
      errors.add(
        '$excludedEmptyApronFileName must not be present in active corpus root.',
      );
    }
  }

  String _resolveRepoPath(String relativePath) =>
      p.normalize(p.join(_repoRoot.path, relativePath));
}

class CorpusChunkPlanner {
  CorpusChunkPlanner({required Directory repoRoot}) : _repoRoot = repoRoot;

  final Directory _repoRoot;

  Future<CorpusChunkPlan> plan(CorpusManifest manifest) async {
    final chunks = <PlannedChunk>[];

    for (final document in manifest.documents.where((doc) => doc.isIncluded)) {
      final sourceFile = File(p.join(_repoRoot.path, document.sourcePath));
      final text = await sourceFile.readAsString();
      final documentChunks = document.chunkProfile == 'glossary_entry_per_term'
          ? _planGlossaryChunks(document, text)
          : _planHeadingAwareChunks(document, text);
      chunks.addAll(documentChunks);
    }

    return CorpusChunkPlan(chunks: chunks);
  }

  List<PlannedChunk> _planGlossaryChunks(CorpusDocument document, String text) {
    final chunks = <PlannedChunk>[];
    final lines = text.split('\n');
    final termPattern = RegExp(r'^-\s+\*\*(.+?):\*\*\s*(.+)$');
    var termIndex = 0;

    for (var index = 0; index < lines.length; index += 1) {
      final match = termPattern.firstMatch(lines[index].trim());
      if (match == null) {
        continue;
      }
      termIndex += 1;
      final term = match.group(1)!.trim();
      final definition = match.group(2)!.trim();
      chunks.add(
        PlannedChunk(
          chunkId:
              '${document.docId}__term_${termIndex.toString().padLeft(3, '0')}',
          docId: document.docId,
          sourcePath: document.sourcePath,
          chunkProfile: document.chunkProfile,
          chunkKind: 'glossary_term',
          headingPath: <String>[document.title, term],
          startLine: index + 1,
          endLine: index + 1,
          estimatedTokens: _estimateTokens('$term $definition'),
          riskLevel: document.riskLevel,
          contentHash: _sha256ForString('$term\n$definition'),
          text: definition,
        ),
      );
    }

    if (chunks.isNotEmpty) {
      return chunks;
    }
    return _planHeadingAwareChunks(document, text);
  }

  List<PlannedChunk> _planHeadingAwareChunks(
    CorpusDocument document,
    String text,
  ) {
    final lines = text.split('\n');
    final sections = _markdownSections(document, lines);
    final chunks = <PlannedChunk>[];
    final countersBySection = <String, int>{};

    for (final section in sections) {
      if (section.body.trim().isEmpty) {
        continue;
      }

      final sectionKey = section.headingPath.join(' > ');
      final estimatedTokens = _estimateTokens(section.body);
      if (estimatedTokens <= 900) {
        final index = (countersBySection[sectionKey] ?? 0) + 1;
        countersBySection[sectionKey] = index;
        chunks.add(
          _plannedSectionChunk(
            document: document,
            section: section,
            index: index,
            startLine: section.startLine,
            endLine: section.endLine,
            text: section.body,
          ),
        );
        continue;
      }

      for (final split in _splitLargeSection(section)) {
        final index = (countersBySection[sectionKey] ?? 0) + 1;
        countersBySection[sectionKey] = index;
        chunks.add(
          _plannedSectionChunk(
            document: document,
            section: section,
            index: index,
            startLine: split.startLine,
            endLine: split.endLine,
            text: split.text,
          ),
        );
      }
    }

    return chunks;
  }

  PlannedChunk _plannedSectionChunk({
    required CorpusDocument document,
    required _MarkdownSection section,
    required int index,
    required int startLine,
    required int endLine,
    required String text,
  }) {
    final sectionSlug = _slug(section.headingPath.join('_'));
    return PlannedChunk(
      chunkId:
          '${document.docId}__${sectionSlug}_${index.toString().padLeft(3, '0')}',
      docId: document.docId,
      sourcePath: document.sourcePath,
      chunkProfile: document.chunkProfile,
      chunkKind: 'heading_section',
      headingPath: section.headingPath,
      startLine: startLine,
      endLine: endLine,
      estimatedTokens: _estimateTokens(text),
      riskLevel: document.riskLevel,
      contentHash: _sha256ForString(text),
      text: text,
    );
  }

  List<_MarkdownSection> _markdownSections(
    CorpusDocument document,
    List<String> lines,
  ) {
    final sections = <_MarkdownSection>[];
    final headingPattern = RegExp(r'^(#{1,6})\s+(.+)$');
    final headingPath = <int, String>{};
    var currentHeadingPath = <String>[document.title];
    var currentStartLine = 1;
    var currentBody = StringBuffer();
    var inFrontMatter = false;

    for (var index = 0; index < lines.length; index += 1) {
      final lineNumber = index + 1;
      final line = lines[index];

      if (lineNumber == 1 && line.trim() == '---') {
        inFrontMatter = true;
        continue;
      }
      if (inFrontMatter) {
        if (line.trim() == '---') {
          inFrontMatter = false;
          currentStartLine = lineNumber + 1;
        }
        continue;
      }

      final headingMatch = headingPattern.firstMatch(line);
      if (headingMatch != null) {
        _addSectionIfUseful(
          sections: sections,
          headingPath: currentHeadingPath,
          startLine: currentStartLine,
          endLine: lineNumber - 1,
          body: currentBody.toString(),
        );
        currentBody = StringBuffer();

        final level = headingMatch.group(1)!.length;
        final title = _stripMarkdownInline(headingMatch.group(2)!.trim());
        headingPath
          ..removeWhere((key, _) => key >= level)
          ..[level] = title;
        currentHeadingPath = [
          for (final key in headingPath.keys.toList()..sort())
            headingPath[key]!,
        ];
        currentStartLine = lineNumber;
      }

      currentBody.writeln(line);
    }

    _addSectionIfUseful(
      sections: sections,
      headingPath: currentHeadingPath,
      startLine: currentStartLine,
      endLine: lines.length,
      body: currentBody.toString(),
    );

    return sections;
  }

  void _addSectionIfUseful({
    required List<_MarkdownSection> sections,
    required List<String> headingPath,
    required int startLine,
    required int endLine,
    required String body,
  }) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) {
      return;
    }
    sections.add(
      _MarkdownSection(
        headingPath: List<String>.unmodifiable(headingPath),
        startLine: startLine,
        endLine: endLine,
        body: trimmed,
      ),
    );
  }

  List<_SectionSplit> _splitLargeSection(_MarkdownSection section) {
    final lines = section.body.split('\n');
    final splits = <_SectionSplit>[];
    final buffer = StringBuffer();
    var chunkStartLine = section.startLine;
    var lineCursor = section.startLine;

    void flush(int endLine) {
      final text = buffer.toString().trim();
      if (text.isEmpty) {
        return;
      }
      splits.add(
        _SectionSplit(startLine: chunkStartLine, endLine: endLine, text: text),
      );
      buffer.clear();
      chunkStartLine = endLine + 1;
    }

    for (final line in lines) {
      final projected = buffer.isEmpty ? line : '${buffer.toString()}\n$line';
      if (buffer.isNotEmpty && _estimateTokens(projected) > 800) {
        flush(lineCursor - 1);
      }
      buffer.writeln(line);
      lineCursor += 1;
    }
    flush(section.endLine);

    return splits;
  }
}

class CorpusChunkPlan {
  CorpusChunkPlan({required this.chunks});

  final List<PlannedChunk> chunks;

  int get documentCount => chunks.map((chunk) => chunk.docId).toSet().length;
  int get chunkCount => chunks.length;

  Map<String, int> get chunkCountsByDocument {
    final counts = <String, int>{};
    for (final chunk in chunks) {
      counts[chunk.docId] = (counts[chunk.docId] ?? 0) + 1;
    }
    return counts;
  }
}

class PlannedChunk {
  PlannedChunk({
    required this.chunkId,
    required this.docId,
    required this.sourcePath,
    required this.chunkProfile,
    required this.chunkKind,
    required this.headingPath,
    required this.startLine,
    required this.endLine,
    required this.estimatedTokens,
    required this.riskLevel,
    required this.contentHash,
    required this.text,
  });

  final String chunkId;
  final String docId;
  final String sourcePath;
  final String chunkProfile;
  final String chunkKind;
  final List<String> headingPath;
  final int startLine;
  final int endLine;
  final int estimatedTokens;
  final String riskLevel;
  final String contentHash;
  final String text;
}

class CorpusIngestionMaterializer {
  CorpusIngestionMaterializer({required Directory repoRoot})
    : _repoRoot = repoRoot;

  final Directory _repoRoot;

  Future<MaterializationResult> materialize({
    required CorpusManifest manifest,
    required CorpusChunkPlan plan,
    String outputDirectory = 'build/advisor_corpus',
  }) async {
    final output = Directory(p.join(_repoRoot.path, outputDirectory));
    output.createSync(recursive: true);

    final documentRecords = _documentRecords(manifest);
    final chunkRecords = _chunkRecords(manifest, plan);
    final nodeRecords = _graphNodeRecords(manifest, plan);
    final edgeRecords = _graphEdgeRecords(plan);
    final summary = <String, Object?>{
      'record_type': 'materialization_summary',
      'materializer_version': 1,
      'manifest_path': defaultManifestPath,
      'document_count': documentRecords.length,
      'chunk_count': chunkRecords.length,
      'graph_node_seed_count': nodeRecords.length,
      'graph_edge_hint_count': edgeRecords.length,
      'embedding_status': 'pending',
      'output_files': <String>[
        'source_documents.jsonl',
        'source_chunks.jsonl',
        'graph_node_seeds.jsonl',
        'graph_edge_hints.jsonl',
        'manifest_summary.json',
      ],
    };

    await _writeJsonLines(output, 'source_documents.jsonl', documentRecords);
    await _writeJsonLines(output, 'source_chunks.jsonl', chunkRecords);
    await _writeJsonLines(output, 'graph_node_seeds.jsonl', nodeRecords);
    await _writeJsonLines(output, 'graph_edge_hints.jsonl', edgeRecords);
    await File(
      p.join(output.path, 'manifest_summary.json'),
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(summary));

    return MaterializationResult(
      outputDirectory: output.path,
      documentCount: documentRecords.length,
      chunkCount: chunkRecords.length,
      graphNodeSeedCount: nodeRecords.length,
      graphEdgeHintCount: edgeRecords.length,
    );
  }

  List<Map<String, Object?>> _documentRecords(CorpusManifest manifest) =>
      manifest.documents
          .where((document) => document.isIncluded)
          .map(
            (document) => <String, Object?>{
              'record_type': 'source_document',
              'doc_id': document.docId,
              'file_name': document.fileName,
              'source_path': document.sourcePath,
              'title': document.title,
              'scope': document.scope,
              'restaurant_id': document.restaurantId,
              'brand_context': document.brandContext,
              'content_role': document.contentRole,
              'authority_tier': document.authorityTier,
              'risk_level': document.riskLevel,
              'audience': document.audience,
              'chunk_profile': document.chunkProfile,
              'graph_profiles': document.graphProfiles,
              'tags': document.tags,
              'source_sha256': document.sha256Hash,
              'embedding_status': 'pending',
              'provenance': <String, Object?>{
                'manifest_path': defaultManifestPath,
                'source_path': document.sourcePath,
                'confidence': 'extracted',
              },
            },
          )
          .toList(growable: false);

  List<Map<String, Object?>> _chunkRecords(
    CorpusManifest manifest,
    CorpusChunkPlan plan,
  ) {
    final documentsById = {
      for (final document in manifest.documents) document.docId: document,
    };

    return plan.chunks
        .map((chunk) {
          final document = documentsById[chunk.docId]!;
          return <String, Object?>{
            'record_type': 'source_chunk',
            'chunk_id': chunk.chunkId,
            'doc_id': chunk.docId,
            'source_path': chunk.sourcePath,
            'scope': document.scope,
            'restaurant_id': document.restaurantId,
            'chunk_kind': chunk.chunkKind,
            'chunk_profile': chunk.chunkProfile,
            'heading_path': chunk.headingPath,
            'start_line': chunk.startLine,
            'end_line': chunk.endLine,
            'estimated_tokens': chunk.estimatedTokens,
            'risk_level': chunk.riskLevel,
            'content_sha256': chunk.contentHash,
            'embedding_status': 'pending',
            'embedding_model': null,
            'text': chunk.text,
            'provenance': <String, Object?>{
              'source_doc_id': chunk.docId,
              'source_path': chunk.sourcePath,
              'heading_path': chunk.headingPath,
              'chunk_id': chunk.chunkId,
              'confidence': 'extracted',
            },
          };
        })
        .toList(growable: false);
  }

  List<Map<String, Object?>> _graphNodeRecords(
    CorpusManifest manifest,
    CorpusChunkPlan plan,
  ) {
    final records = <Map<String, Object?>>[];
    for (final document in manifest.documents.where((doc) => doc.isIncluded)) {
      records.add(<String, Object?>{
        'record_type': 'graph_node_seed',
        'node_id': 'document:${document.docId}',
        'node_type': 'Document',
        'source_doc_id': document.docId,
        'confidence': 'extracted',
        'risk_level': document.riskLevel,
        'properties': <String, Object?>{
          'title': document.title,
          'source_path': document.sourcePath,
          'scope': document.scope,
          'content_role': document.contentRole,
          'brand_context': document.brandContext,
          'tags': document.tags,
        },
      });
    }
    for (final chunk in plan.chunks) {
      records.add(<String, Object?>{
        'record_type': 'graph_node_seed',
        'node_id': 'chunk:${chunk.chunkId}',
        'node_type': 'Chunk',
        'source_doc_id': chunk.docId,
        'source_chunk_id': chunk.chunkId,
        'confidence': 'extracted',
        'risk_level': chunk.riskLevel,
        'properties': <String, Object?>{
          'source_path': chunk.sourcePath,
          'heading_path': chunk.headingPath,
          'chunk_kind': chunk.chunkKind,
          'estimated_tokens': chunk.estimatedTokens,
          'content_sha256': chunk.contentHash,
        },
      });
    }
    return records;
  }

  List<Map<String, Object?>> _graphEdgeRecords(CorpusChunkPlan plan) => plan
      .chunks
      .map(
        (chunk) => <String, Object?>{
          'record_type': 'graph_edge_hint',
          'edge_id': 'contains:${chunk.docId}:${chunk.chunkId}',
          'edge_type': 'CONTAINS',
          'from_node_id': 'document:${chunk.docId}',
          'to_node_id': 'chunk:${chunk.chunkId}',
          'source_doc_id': chunk.docId,
          'source_chunk_id': chunk.chunkId,
          'confidence': 'extracted',
          'properties': <String, Object?>{
            'heading_path': chunk.headingPath,
            'source_path': chunk.sourcePath,
          },
        },
      )
      .toList(growable: false);

  Future<void> _writeJsonLines(
    Directory output,
    String fileName,
    List<Map<String, Object?>> records,
  ) async {
    final file = File(p.join(output.path, fileName));
    final buffer = StringBuffer();
    for (final record in records) {
      buffer.writeln(jsonEncode(record));
    }
    await file.writeAsString(buffer.toString());
  }
}

class MaterializationResult {
  MaterializationResult({
    required this.outputDirectory,
    required this.documentCount,
    required this.chunkCount,
    required this.graphNodeSeedCount,
    required this.graphEdgeHintCount,
  });

  final String outputDirectory;
  final int documentCount;
  final int chunkCount;
  final int graphNodeSeedCount;
  final int graphEdgeHintCount;
}

class CorpusDbLoadPreparer {
  CorpusDbLoadPreparer({required Directory repoRoot}) : _repoRoot = repoRoot;

  final Directory _repoRoot;

  Future<DbLoadPreparationResult> prepare({
    String materializationDirectory = 'build/advisor_corpus',
    String outputDirectory = 'build/advisor_corpus/load',
  }) async {
    final materialized = Directory(
      p.join(_repoRoot.path, materializationDirectory),
    );
    final output = Directory(p.join(_repoRoot.path, outputDirectory));
    output.createSync(recursive: true);

    final summary = await _readJsonFile(
      File(p.join(materialized.path, 'manifest_summary.json')),
    );
    final documents = await _readJsonLines(
      File(p.join(materialized.path, 'source_documents.jsonl')),
    );
    final chunks = await _readJsonLines(
      File(p.join(materialized.path, 'source_chunks.jsonl')),
    );
    final nodeSeeds = await _readJsonLines(
      File(p.join(materialized.path, 'graph_node_seeds.jsonl')),
    );
    final edgeHints = await _readJsonLines(
      File(p.join(materialized.path, 'graph_edge_hints.jsonl')),
    );

    _sortRecords(documents, 'doc_id');
    _sortRecords(chunks, 'chunk_id');
    _sortRecords(nodeSeeds, 'node_id');
    _sortRecords(edgeHints, 'edge_id');

    final runId = _deterministicUuid(jsonEncode(summary));
    final loadFiles = <String>[
      '001_ingestion_run.sql',
      '002_source_documents.sql',
      '003_source_chunks.sql',
      '004_graph_node_seeds.sql',
      '005_graph_edge_hints.sql',
    ];

    await File(
      p.join(output.path, loadFiles[0]),
    ).writeAsString(_ingestionRunSql(runId, summary));
    await File(
      p.join(output.path, loadFiles[1]),
    ).writeAsString(_sourceDocumentsSql(runId, documents));
    await File(
      p.join(output.path, loadFiles[2]),
    ).writeAsString(_sourceChunksSql(runId, chunks));
    await File(
      p.join(output.path, loadFiles[3]),
    ).writeAsString(_graphNodeSeedsSql(runId, nodeSeeds));
    await File(
      p.join(output.path, loadFiles[4]),
    ).writeAsString(_graphEdgeHintsSql(runId, edgeHints));

    final loadManifest = <String, Object?>{
      'record_type': 'advisor_corpus_load_manifest',
      'loader_version': 1,
      'run_id': runId,
      'source_materialization_directory': materializationDirectory,
      'target_schema_migration':
          'supabase/migrations/202604250001_advisor_corpus_storage_schema.sql',
      'apply_mode': 'not_applied_build_artifacts_only',
      'load_order': <Map<String, Object?>>[
        _loadStep(1, 'advisor_ingestion_runs', loadFiles[0], 1),
        _loadStep(
          2,
          'advisor_source_documents',
          loadFiles[1],
          documents.length,
        ),
        _loadStep(3, 'advisor_source_chunks', loadFiles[2], chunks.length),
        _loadStep(
          4,
          'advisor_graph_node_seeds',
          loadFiles[3],
          nodeSeeds.length,
        ),
        _loadStep(
          5,
          'advisor_graph_edge_hints',
          loadFiles[4],
          edgeHints.length,
        ),
      ],
      'counts': <String, Object?>{
        'documents': documents.length,
        'chunks': chunks.length,
        'graph_node_seeds': nodeSeeds.length,
        'graph_edge_hints': edgeHints.length,
      },
      'embedding_status': summary['embedding_status'],
      'notes':
          'Generated only. Do not apply to a live database from this slice.',
    };

    await File(
      p.join(output.path, 'load_manifest.json'),
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(loadManifest));

    return DbLoadPreparationResult(
      outputDirectory: output.path,
      runId: runId,
      documentCount: documents.length,
      chunkCount: chunks.length,
      graphNodeSeedCount: nodeSeeds.length,
      graphEdgeHintCount: edgeHints.length,
      loadFiles: loadFiles,
    );
  }

  Map<String, Object?> _loadStep(
    int order,
    String table,
    String fileName,
    int recordCount,
  ) => <String, Object?>{
    'order': order,
    'table': table,
    'file': fileName,
    'record_count': recordCount,
  };

  Future<Map<String, Object?>> _readJsonFile(File file) async {
    if (!file.existsSync()) {
      throw CorpusManifestException(
        'Materialized file not found: ${file.path}',
      );
    }
    return jsonDecode(await file.readAsString()) as Map<String, Object?>;
  }

  Future<List<Map<String, Object?>>> _readJsonLines(File file) async {
    if (!file.existsSync()) {
      throw CorpusManifestException(
        'Materialized file not found: ${file.path}',
      );
    }
    final records = <Map<String, Object?>>[];
    final lines = await file.readAsLines();
    for (final line in lines.where((line) => line.trim().isNotEmpty)) {
      records.add(jsonDecode(line) as Map<String, Object?>);
    }
    return records;
  }

  void _sortRecords(List<Map<String, Object?>> records, String key) {
    records.sort((a, b) => a[key].toString().compareTo(b[key].toString()));
  }

  String _ingestionRunSql(String runId, Map<String, Object?> summary) {
    final outputSummary = _jsonLiteral(summary);
    return '''
-- Generated by tool/advisor_corpus prepare-load.
-- Build artifact only. Do not apply without an explicit live-DB slice.

insert into public.advisor_ingestion_runs (
  run_id,
  materializer_version,
  manifest_path,
  document_count,
  chunk_count,
  graph_node_seed_count,
  graph_edge_hint_count,
  embedding_status,
  output_summary
) values (
  ${_textLiteral(runId)}::uuid,
  ${summary['materializer_version']},
  ${_textLiteral(summary['manifest_path'].toString())},
  ${summary['document_count']},
  ${summary['chunk_count']},
  ${summary['graph_node_seed_count']},
  ${summary['graph_edge_hint_count']},
  ${_textLiteral(summary['embedding_status'].toString())},
  $outputSummary::jsonb
)
on conflict (run_id) do update set
  materializer_version = excluded.materializer_version,
  manifest_path = excluded.manifest_path,
  document_count = excluded.document_count,
  chunk_count = excluded.chunk_count,
  graph_node_seed_count = excluded.graph_node_seed_count,
  graph_edge_hint_count = excluded.graph_edge_hint_count,
  embedding_status = excluded.embedding_status,
  output_summary = excluded.output_summary;
''';
  }

  String _sourceDocumentsSql(String runId, List<Map<String, Object?>> records) {
    final buffer = StringBuffer('''
-- Generated by tool/advisor_corpus prepare-load.
-- Depends on 001_ingestion_run.sql.

''');
    for (final record in records) {
      buffer.writeln('''
insert into public.advisor_source_documents (
  doc_id, ingestion_run_id, file_name, source_path, title, scope,
  restaurant_id, brand_context, content_role, authority_tier, risk_level,
  audience, chunk_profile, graph_profiles, tags, source_sha256,
  embedding_status, provenance
) values (
  ${_textLiteral(record['doc_id'])},
  ${_textLiteral(runId)}::uuid,
  ${_textLiteral(record['file_name'])},
  ${_textLiteral(record['source_path'])},
  ${_textLiteral(record['title'])},
  ${_textLiteral(record['scope'])},
  ${_uuidOrNull(record['restaurant_id'])},
  ${_textLiteral(record['brand_context'])},
  ${_textLiteral(record['content_role'])},
  ${_textLiteral(record['authority_tier'])},
  ${_textLiteral(record['risk_level'])},
  ${_textArrayLiteral(record['audience'])},
  ${_textLiteral(record['chunk_profile'])},
  ${_textArrayLiteral(record['graph_profiles'])},
  ${_textArrayLiteral(record['tags'])},
  ${_textLiteral(record['source_sha256'])},
  ${_textLiteral(record['embedding_status'])},
  ${_jsonLiteral(record['provenance'])}::jsonb
)
on conflict (doc_id) do update set
  ingestion_run_id = excluded.ingestion_run_id,
  file_name = excluded.file_name,
  source_path = excluded.source_path,
  title = excluded.title,
  scope = excluded.scope,
  restaurant_id = excluded.restaurant_id,
  brand_context = excluded.brand_context,
  content_role = excluded.content_role,
  authority_tier = excluded.authority_tier,
  risk_level = excluded.risk_level,
  audience = excluded.audience,
  chunk_profile = excluded.chunk_profile,
  graph_profiles = excluded.graph_profiles,
  tags = excluded.tags,
  source_sha256 = excluded.source_sha256,
  embedding_status = excluded.embedding_status,
  provenance = excluded.provenance;
''');
    }
    return buffer.toString();
  }

  String _sourceChunksSql(String runId, List<Map<String, Object?>> records) {
    final buffer = StringBuffer('''
-- Generated by tool/advisor_corpus prepare-load.
-- Depends on 002_source_documents.sql.

''');
    for (final record in records) {
      buffer.writeln('''
insert into public.advisor_source_chunks (
  chunk_id, doc_id, ingestion_run_id, source_path, scope, restaurant_id,
  chunk_kind, chunk_profile, heading_path, start_line, end_line,
  estimated_tokens, risk_level, content_sha256, embedding_status,
  embedding_model, text, provenance
) values (
  ${_textLiteral(record['chunk_id'])},
  ${_textLiteral(record['doc_id'])},
  ${_textLiteral(runId)}::uuid,
  ${_textLiteral(record['source_path'])},
  ${_textLiteral(record['scope'])},
  ${_uuidOrNull(record['restaurant_id'])},
  ${_textLiteral(record['chunk_kind'])},
  ${_textLiteral(record['chunk_profile'])},
  ${_textArrayLiteral(record['heading_path'])},
  ${record['start_line']},
  ${record['end_line']},
  ${record['estimated_tokens']},
  ${_textLiteral(record['risk_level'])},
  ${_textLiteral(record['content_sha256'])},
  ${_textLiteral(record['embedding_status'])},
  ${_nullableTextLiteral(record['embedding_model'])},
  ${_textLiteral(record['text'])},
  ${_jsonLiteral(record['provenance'])}::jsonb
)
on conflict (chunk_id) do update set
  doc_id = excluded.doc_id,
  ingestion_run_id = excluded.ingestion_run_id,
  source_path = excluded.source_path,
  scope = excluded.scope,
  restaurant_id = excluded.restaurant_id,
  chunk_kind = excluded.chunk_kind,
  chunk_profile = excluded.chunk_profile,
  heading_path = excluded.heading_path,
  start_line = excluded.start_line,
  end_line = excluded.end_line,
  estimated_tokens = excluded.estimated_tokens,
  risk_level = excluded.risk_level,
  content_sha256 = excluded.content_sha256,
  embedding_status = excluded.embedding_status,
  embedding_model = excluded.embedding_model,
  text = excluded.text,
  provenance = excluded.provenance;
''');
    }
    return buffer.toString();
  }

  String _graphNodeSeedsSql(String runId, List<Map<String, Object?>> records) {
    final buffer = StringBuffer('''
-- Generated by tool/advisor_corpus prepare-load.
-- Depends on 003_source_chunks.sql.

''');
    for (final record in records) {
      buffer.writeln('''
insert into public.advisor_graph_node_seeds (
  node_id, ingestion_run_id, node_type, source_doc_id, source_chunk_id,
  confidence, risk_level, properties
) values (
  ${_textLiteral(record['node_id'])},
  ${_textLiteral(runId)}::uuid,
  ${_textLiteral(record['node_type'])},
  ${_textLiteral(record['source_doc_id'])},
  ${_nullableTextLiteral(record['source_chunk_id'])},
  ${_textLiteral(record['confidence'])},
  ${_textLiteral(record['risk_level'])},
  ${_jsonLiteral(record['properties'])}::jsonb
)
on conflict (node_id) do update set
  ingestion_run_id = excluded.ingestion_run_id,
  node_type = excluded.node_type,
  source_doc_id = excluded.source_doc_id,
  source_chunk_id = excluded.source_chunk_id,
  confidence = excluded.confidence,
  risk_level = excluded.risk_level,
  properties = excluded.properties;
''');
    }
    return buffer.toString();
  }

  String _graphEdgeHintsSql(String runId, List<Map<String, Object?>> records) {
    final buffer = StringBuffer('''
-- Generated by tool/advisor_corpus prepare-load.
-- Depends on 004_graph_node_seeds.sql.

''');
    for (final record in records) {
      buffer.writeln('''
insert into public.advisor_graph_edge_hints (
  edge_id, ingestion_run_id, edge_type, from_node_id, to_node_id,
  source_doc_id, source_chunk_id, confidence, properties
) values (
  ${_textLiteral(record['edge_id'])},
  ${_textLiteral(runId)}::uuid,
  ${_textLiteral(record['edge_type'])},
  ${_textLiteral(record['from_node_id'])},
  ${_textLiteral(record['to_node_id'])},
  ${_textLiteral(record['source_doc_id'])},
  ${_nullableTextLiteral(record['source_chunk_id'])},
  ${_textLiteral(record['confidence'])},
  ${_jsonLiteral(record['properties'])}::jsonb
)
on conflict (edge_id) do update set
  ingestion_run_id = excluded.ingestion_run_id,
  edge_type = excluded.edge_type,
  from_node_id = excluded.from_node_id,
  to_node_id = excluded.to_node_id,
  source_doc_id = excluded.source_doc_id,
  source_chunk_id = excluded.source_chunk_id,
  confidence = excluded.confidence,
  properties = excluded.properties;
''');
    }
    return buffer.toString();
  }
}

class DbLoadPreparationResult {
  DbLoadPreparationResult({
    required this.outputDirectory,
    required this.runId,
    required this.documentCount,
    required this.chunkCount,
    required this.graphNodeSeedCount,
    required this.graphEdgeHintCount,
    required this.loadFiles,
  });

  final String outputDirectory;
  final String runId;
  final int documentCount;
  final int chunkCount;
  final int graphNodeSeedCount;
  final int graphEdgeHintCount;
  final List<String> loadFiles;
}

class CorpusEmbeddingJobPreparer {
  CorpusEmbeddingJobPreparer({required Directory repoRoot})
    : _repoRoot = repoRoot;

  final Directory _repoRoot;

  Future<EmbeddingJobPreparationResult> prepare({
    String materializationDirectory = 'build/advisor_corpus',
    String outputDirectory = 'build/advisor_corpus/embeddings',
    String provider = advisorEmbeddingProvider,
    String model = advisorEmbeddingModel,
    int dimensions = advisorEmbeddingDimensions,
  }) async {
    _validateEmbeddingContract(provider, model, dimensions);

    final materialized = Directory(
      p.join(_repoRoot.path, materializationDirectory),
    );
    final output = Directory(p.join(_repoRoot.path, outputDirectory));
    output.createSync(recursive: true);

    final chunks = await _readJsonLines(
      File(p.join(materialized.path, 'source_chunks.jsonl')),
    );
    chunks.sort(
      (a, b) => a['chunk_id'].toString().compareTo(b['chunk_id'].toString()),
    );

    final inputs = <Map<String, Object?>>[];
    var estimatedTokens = 0;
    for (var index = 0; index < chunks.length; index += 1) {
      final chunk = chunks[index];
      final chunkTokens = chunk['estimated_tokens']! as int;
      estimatedTokens += chunkTokens;
      inputs.add(<String, Object?>{
        'record_type': 'embedding_input',
        'sequence': index + 1,
        'provider': provider,
        'model': model,
        'dimensions': dimensions,
        'chunk_id': chunk['chunk_id'],
        'doc_id': chunk['doc_id'],
        'source_path': chunk['source_path'],
        'heading_path': chunk['heading_path'],
        'content_sha256': chunk['content_sha256'],
        'estimated_tokens': chunkTokens,
        'input': chunk['text'],
      });
    }

    final inputFileName = 'embedding_inputs.jsonl';
    final manifestFileName = 'embedding_job_manifest.json';
    final updateTemplateFileName = 'embedding_update_template.sql';
    final jobId = _deterministicUuid(
      jsonEncode(<String, Object?>{
        'provider': provider,
        'model': model,
        'dimensions': dimensions,
        'rerank_provider': advisorRerankProvider,
        'rerank_model': advisorRerankModel,
        'answer_runtime_family': advisorAnswerRuntimeFamily,
        'chunk_ids': inputs.map((input) => input['chunk_id']).toList(),
        'hashes': inputs.map((input) => input['content_sha256']).toList(),
      }),
    );

    final manifest = <String, Object?>{
      'record_type': 'advisor_corpus_embedding_job_manifest',
      'job_version': 1,
      'job_id': jobId,
      'provider': provider,
      'model': model,
      'dimensions': dimensions,
      'distance_metric': advisorEmbeddingDistanceMetric,
      'tokenizer': advisorEmbeddingTokenizer,
      'max_input_tokens': advisorEmbeddingMaxInputTokens,
      'rerank_provider': advisorRerankProvider,
      'rerank_model': advisorRerankModel,
      'answer_runtime_family': advisorAnswerRuntimeFamily,
      'planned_retrieval_pipeline': <String>[
        'pgvector_cosine_candidate_retrieval',
        'voyage_rerank_2_5',
        'claude_answer_runtime_with_provenance',
      ],
      'source_materialization_directory': materializationDirectory,
      'mode': 'dry_run_no_api_call',
      'database_mutation': false,
      'api_key_required_for_execution': 'VOYAGE_API_KEY',
      'embedding_status_before': 'pending',
      'embedding_status_after_success': 'ready',
      'input_file': inputFileName,
      'update_template_file': updateTemplateFileName,
      'chunk_count': inputs.length,
      'estimated_token_count': estimatedTokens,
      'notes':
          'Prepared only. This slice does not call Voyage embeddings or rerank and does not update a database.',
    };

    await _writeJsonLines(output, inputFileName, inputs);
    await File(
      p.join(output.path, manifestFileName),
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(manifest));
    await File(
      p.join(output.path, updateTemplateFileName),
    ).writeAsString(_embeddingUpdateTemplate(provider, model, dimensions));

    return EmbeddingJobPreparationResult(
      outputDirectory: output.path,
      jobId: jobId,
      provider: provider,
      model: model,
      dimensions: dimensions,
      chunkCount: inputs.length,
      estimatedTokenCount: estimatedTokens,
      outputFiles: <String>[
        manifestFileName,
        inputFileName,
        updateTemplateFileName,
      ],
    );
  }

  Future<List<Map<String, Object?>>> _readJsonLines(File file) async {
    if (!file.existsSync()) {
      throw CorpusManifestException(
        'Materialized file not found: ${file.path}',
      );
    }
    final records = <Map<String, Object?>>[];
    final lines = await file.readAsLines();
    for (final line in lines.where((line) => line.trim().isNotEmpty)) {
      records.add(jsonDecode(line) as Map<String, Object?>);
    }
    return records;
  }

  Future<void> _writeJsonLines(
    Directory output,
    String fileName,
    List<Map<String, Object?>> records,
  ) async {
    final file = File(p.join(output.path, fileName));
    final buffer = StringBuffer();
    for (final record in records) {
      buffer.writeln(jsonEncode(record));
    }
    await file.writeAsString(buffer.toString());
  }

  void _validateEmbeddingContract(
    String provider,
    String model,
    int dimensions,
  ) {
    if (provider != advisorEmbeddingProvider) {
      throw CorpusManifestException(
        'Unsupported embedding provider: $provider. '
        'Expected $advisorEmbeddingProvider.',
      );
    }
    if (model != advisorEmbeddingModel) {
      throw CorpusManifestException(
        'Unsupported embedding model: $model. Expected $advisorEmbeddingModel.',
      );
    }
    if (dimensions != advisorEmbeddingDimensions) {
      throw CorpusManifestException(
        'Unsupported embedding dimensions: $dimensions. '
        'Expected $advisorEmbeddingDimensions.',
      );
    }
  }

  String _embeddingUpdateTemplate(
    String provider,
    String model,
    int dimensions,
  ) =>
      '''
-- Generated by tool/advisor_corpus prepare-embeddings.
-- Template only. Do not run without a concrete vector value per chunk.
--
-- Provider: $provider
-- Model: $model
-- Dimensions: $dimensions
--
-- Expected successful row update shape:
--
-- update public.advisor_source_chunks
-- set
--   embedding_status = 'ready',
--   embedding_model = '$model',
--   embedding = '<$dimensions floats>'::vector($dimensions)
-- where chunk_id = '<chunk_id>'
--   and content_sha256 = '<content_sha256>';
''';
}

class EmbeddingJobPreparationResult {
  EmbeddingJobPreparationResult({
    required this.outputDirectory,
    required this.jobId,
    required this.provider,
    required this.model,
    required this.dimensions,
    required this.chunkCount,
    required this.estimatedTokenCount,
    required this.outputFiles,
  });

  final String outputDirectory;
  final String jobId;
  final String provider;
  final String model;
  final int dimensions;
  final int chunkCount;
  final int estimatedTokenCount;
  final List<String> outputFiles;
}

abstract class AdvisorEmbeddingGateway {
  Future<EmbeddingBatchResult> embedDocuments({
    required String apiKey,
    required String model,
    required int dimensions,
    required List<String> inputs,
  });
}

class VoyageHttpEmbeddingGateway implements AdvisorEmbeddingGateway {
  VoyageHttpEmbeddingGateway({HttpClient? httpClient, Uri? endpoint})
    : _httpClient = httpClient ?? HttpClient(),
      _endpoint = endpoint ?? Uri.parse(advisorVoyageEmbeddingsEndpoint);

  final HttpClient _httpClient;
  final Uri _endpoint;

  @override
  Future<EmbeddingBatchResult> embedDocuments({
    required String apiKey,
    required String model,
    required int dimensions,
    required List<String> inputs,
  }) async {
    final request = await _httpClient.postUrl(_endpoint);
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    request.write(
      jsonEncode(<String, Object?>{
        'input': inputs,
        'model': model,
        'input_type': advisorEmbeddingInputType,
        'output_dimension': dimensions,
        'output_dtype': advisorEmbeddingOutputDtype,
      }),
    );

    final response = await request.close();
    final body = await utf8.decodeStream(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw CorpusManifestException(
        'Voyage embedding request failed with status ${response.statusCode}: '
        '${_redactProviderError(body)}',
      );
    }

    final decoded = jsonDecode(body) as Map<String, Object?>;
    final data = decoded['data'];
    if (data is! List<Object?>) {
      throw CorpusManifestException(
        'Voyage embedding response did not include a data array.',
      );
    }

    data.sort((a, b) {
      final aIndex = (a as Map<String, Object?>)['index'] as int? ?? 0;
      final bIndex = (b as Map<String, Object?>)['index'] as int? ?? 0;
      return aIndex.compareTo(bIndex);
    });

    final vectors = <List<double>>[];
    for (final item in data.cast<Map<String, Object?>>()) {
      final embedding = item['embedding'];
      if (embedding is! List<Object?>) {
        throw CorpusManifestException(
          'Voyage embedding response item did not include an embedding array.',
        );
      }
      vectors.add(embedding.map((value) => (value as num).toDouble()).toList());
    }

    final usage = decoded['usage'];
    final totalTokens = usage is Map<String, Object?>
        ? (usage['total_tokens'] as num?)?.toInt()
        : null;

    return EmbeddingBatchResult(
      vectors: vectors,
      providerReportedTokenCount: totalTokens ?? 0,
    );
  }

  String _redactProviderError(String body) {
    if (body.length <= 500) {
      return body;
    }
    return '${body.substring(0, 500)}...';
  }
}

class EmbeddingBatchResult {
  EmbeddingBatchResult({
    required this.vectors,
    required this.providerReportedTokenCount,
  });

  final List<List<double>> vectors;
  final int providerReportedTokenCount;
}

class CorpusEmbeddingExecutor {
  CorpusEmbeddingExecutor({
    required Directory repoRoot,
    AdvisorEmbeddingGateway? gateway,
  }) : _repoRoot = repoRoot,
       _gateway = gateway ?? VoyageHttpEmbeddingGateway();

  final Directory _repoRoot;
  final AdvisorEmbeddingGateway _gateway;

  Future<EmbeddingExecutionResult> execute({
    String inputDirectory = 'build/advisor_corpus/embeddings',
    String outputDirectory = 'build/advisor_corpus/embeddings',
    String? apiKey,
    int batchItemLimit = advisorEmbeddingBatchItemLimit,
    int batchEstimatedTokenLimit = advisorEmbeddingBatchEstimatedTokenLimit,
    Duration batchDelay = Duration.zero,
    void Function(int completedBatch, int totalBatches, int chunkCount)?
    onBatchComplete,
  }) async {
    final resolvedApiKey = apiKey ?? Platform.environment['VOYAGE_API_KEY'];
    if (resolvedApiKey == null || resolvedApiKey.trim().isEmpty) {
      throw CorpusManifestException(
        'VOYAGE_API_KEY is required to execute embeddings.',
      );
    }

    final inputDir = Directory(p.join(_repoRoot.path, inputDirectory));
    final outputDir = Directory(p.join(_repoRoot.path, outputDirectory));
    outputDir.createSync(recursive: true);

    final manifest = await _readJsonFile(
      File(p.join(inputDir.path, 'embedding_job_manifest.json')),
    );
    final inputs = await _readJsonLines(
      File(p.join(inputDir.path, 'embedding_inputs.jsonl')),
    );

    final provider = manifest['provider'].toString();
    final model = manifest['model'].toString();
    final dimensions = manifest['dimensions'] as int;
    _validateEmbeddingContract(provider, model, dimensions);

    final batches = _buildBatches(
      inputs,
      batchItemLimit: batchItemLimit,
      batchEstimatedTokenLimit: batchEstimatedTokenLimit,
    );

    // 7.57.3b — route vector generation through the same Voyage
    // provider abstraction the runtime advisor uses. The gateway
    // still owns the HTTP/test seam, but the provider enforces the
    // 1:1 input/output and dimension contract. Per-batch token
    // counts (which the provider interface omits) are captured in
    // a closure variable so accounting stays unchanged.
    var lastBatchProviderReportedTokenCount = 0;
    final embeddingProvider = VoyageEmbeddingProvider(
      embedFn: (texts, {required String model}) async {
        final batchResult = await _gateway.embedDocuments(
          apiKey: resolvedApiKey,
          model: model,
          dimensions: dimensions,
          inputs: texts,
        );
        lastBatchProviderReportedTokenCount =
            batchResult.providerReportedTokenCount;
        return batchResult.vectors;
      },
    );

    final rows = <_EmbeddingUpdateRow>[];
    var providerReportedTokenCount = 0;
    for (var batchIndex = 0; batchIndex < batches.length; batchIndex += 1) {
      final batch = batches[batchIndex];
      final vectors = await embeddingProvider.embedBatch(
        batch.map((input) => input['input'].toString()).toList(),
      );
      providerReportedTokenCount += lastBatchProviderReportedTokenCount;
      for (var index = 0; index < batch.length; index += 1) {
        rows.add(
          _EmbeddingUpdateRow(
            chunkId: batch[index]['chunk_id'].toString(),
            contentSha256: batch[index]['content_sha256'].toString(),
            vector: vectors[index],
          ),
        );
      }
      onBatchComplete?.call(batchIndex + 1, batches.length, batch.length);
      if (batchDelay > Duration.zero && batchIndex < batches.length - 1) {
        await Future<void>.delayed(batchDelay);
      }
    }

    final executionId = _deterministicUuid(
      jsonEncode(<String, Object?>{
        'source_job_id': manifest['job_id'],
        'provider': provider,
        'model': model,
        'dimensions': dimensions,
        'chunk_ids': rows.map((row) => row.chunkId).toList(),
        'content_hashes': rows.map((row) => row.contentSha256).toList(),
      }),
    );
    const sqlFileName = 'embedding_updates.sql';
    const executionManifestFileName = 'embedding_execution_manifest.json';
    await File(
      p.join(outputDir.path, sqlFileName),
    ).writeAsString(_embeddingUpdatesSql(model, dimensions, rows));

    final executionManifest = <String, Object?>{
      'record_type': 'advisor_corpus_embedding_execution_manifest',
      'execution_version': 1,
      'execution_id': executionId,
      'source_job_id': manifest['job_id'],
      'provider': provider,
      'model': model,
      'dimensions': dimensions,
      'input_type': advisorEmbeddingInputType,
      'output_dtype': advisorEmbeddingOutputDtype,
      'endpoint': advisorVoyageEmbeddingsEndpoint,
      'batch_count': batches.length,
      'chunk_count': rows.length,
      'provider_reported_token_count': providerReportedTokenCount,
      'database_mutation': false,
      'sql_update_file': sqlFileName,
      'notes':
          'Voyage embeddings executed. SQL update file generated but not applied by this command.',
    };

    await File(p.join(outputDir.path, executionManifestFileName)).writeAsString(
      const JsonEncoder.withIndent('  ').convert(executionManifest),
    );

    return EmbeddingExecutionResult(
      outputDirectory: outputDir.path,
      executionId: executionId,
      provider: provider,
      model: model,
      dimensions: dimensions,
      chunkCount: rows.length,
      batchCount: batches.length,
      providerReportedTokenCount: providerReportedTokenCount,
      outputFiles: <String>[executionManifestFileName, sqlFileName],
    );
  }

  Future<Map<String, Object?>> _readJsonFile(File file) async {
    if (!file.existsSync()) {
      throw CorpusManifestException(
        'Embedding job file not found: ${file.path}',
      );
    }
    return jsonDecode(await file.readAsString()) as Map<String, Object?>;
  }

  Future<List<Map<String, Object?>>> _readJsonLines(File file) async {
    if (!file.existsSync()) {
      throw CorpusManifestException(
        'Embedding input file not found: ${file.path}',
      );
    }
    final records = <Map<String, Object?>>[];
    final lines = await file.readAsLines();
    for (final line in lines.where((line) => line.trim().isNotEmpty)) {
      records.add(jsonDecode(line) as Map<String, Object?>);
    }
    return records;
  }

  void _validateEmbeddingContract(
    String provider,
    String model,
    int dimensions,
  ) {
    if (provider != advisorEmbeddingProvider) {
      throw CorpusManifestException(
        'Unsupported embedding provider: $provider. '
        'Expected $advisorEmbeddingProvider.',
      );
    }
    if (model != advisorEmbeddingModel) {
      throw CorpusManifestException(
        'Unsupported embedding model: $model. Expected $advisorEmbeddingModel.',
      );
    }
    if (dimensions != advisorEmbeddingDimensions) {
      throw CorpusManifestException(
        'Unsupported embedding dimensions: $dimensions. '
        'Expected $advisorEmbeddingDimensions.',
      );
    }
  }

  List<List<Map<String, Object?>>> _buildBatches(
    List<Map<String, Object?>> inputs, {
    required int batchItemLimit,
    required int batchEstimatedTokenLimit,
  }) {
    final batches = <List<Map<String, Object?>>>[];
    var current = <Map<String, Object?>>[];
    var currentEstimatedTokens = 0;

    for (final input in inputs) {
      final estimatedTokens = input['estimated_tokens']! as int;
      final wouldExceedItems = current.length >= batchItemLimit;
      final wouldExceedTokens =
          current.isNotEmpty &&
          currentEstimatedTokens + estimatedTokens > batchEstimatedTokenLimit;
      if (wouldExceedItems || wouldExceedTokens) {
        batches.add(current);
        current = <Map<String, Object?>>[];
        currentEstimatedTokens = 0;
      }
      current.add(input);
      currentEstimatedTokens += estimatedTokens;
    }

    if (current.isNotEmpty) {
      batches.add(current);
    }
    return batches;
  }

  String _embeddingUpdatesSql(
    String model,
    int dimensions,
    List<_EmbeddingUpdateRow> rows,
  ) {
    final buffer = StringBuffer('''
-- Generated by tool/advisor_corpus execute-embeddings.
-- Applies Voyage embedding vectors to matching chunks by id + content hash.

begin;

''');
    for (final row in rows) {
      buffer.writeln('''
update public.advisor_source_chunks
set
  embedding_status = 'ready',
  embedding_model = ${_textLiteral(model)},
  embedding = ${_vectorLiteral(row.vector, dimensions)}
where chunk_id = ${_textLiteral(row.chunkId)}
  and content_sha256 = ${_textLiteral(row.contentSha256)};
''');
    }
    buffer.writeln('commit;');
    return buffer.toString();
  }

  String _vectorLiteral(List<double> vector, int dimensions) {
    final values = vector
        .map((value) => value.toStringAsPrecision(10))
        .join(',');
    return "${_textLiteral('[$values]')}::vector($dimensions)";
  }
}

class _EmbeddingUpdateRow {
  _EmbeddingUpdateRow({
    required this.chunkId,
    required this.contentSha256,
    required this.vector,
  });

  final String chunkId;
  final String contentSha256;
  final List<double> vector;
}

class EmbeddingExecutionResult {
  EmbeddingExecutionResult({
    required this.outputDirectory,
    required this.executionId,
    required this.provider,
    required this.model,
    required this.dimensions,
    required this.chunkCount,
    required this.batchCount,
    required this.providerReportedTokenCount,
    required this.outputFiles,
  });

  final String outputDirectory;
  final String executionId;
  final String provider;
  final String model;
  final int dimensions;
  final int chunkCount;
  final int batchCount;
  final int providerReportedTokenCount;
  final List<String> outputFiles;
}

class CorpusManifestException implements Exception {
  CorpusManifestException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _MarkdownSection {
  _MarkdownSection({
    required this.headingPath,
    required this.startLine,
    required this.endLine,
    required this.body,
  });

  final List<String> headingPath;
  final int startLine;
  final int endLine;
  final String body;
}

class _SectionSplit {
  _SectionSplit({
    required this.startLine,
    required this.endLine,
    required this.text,
  });

  final int startLine;
  final int endLine;
  final String text;
}

Future<String> sha256ForFile(File file) async {
  final bytes = await file.readAsBytes();
  return sha256.convert(bytes).toString();
}

String _sha256ForString(String value) =>
    sha256.convert(utf8.encode(value)).toString();

String _deterministicUuid(String seed) {
  final hex = _sha256ForString(seed);
  final chars = hex.substring(0, 32).split('');
  chars[12] = '5';
  chars[16] = 'a';
  final value = chars.join();
  return '${value.substring(0, 8)}-'
      '${value.substring(8, 12)}-'
      '${value.substring(12, 16)}-'
      '${value.substring(16, 20)}-'
      '${value.substring(20, 32)}';
}

String _textLiteral(Object? value) =>
    "'${value.toString().replaceAll("'", "''")}'";

String _nullableTextLiteral(Object? value) =>
    value == null ? 'null' : _textLiteral(value);

String _uuidOrNull(Object? value) =>
    value == null ? 'null' : '${_textLiteral(value)}::uuid';

String _jsonLiteral(Object? value) => _textLiteral(jsonEncode(value));

String _textArrayLiteral(Object? value) {
  final values = (value as List<Object?>?) ?? <Object?>[];
  if (values.isEmpty) {
    return "'{}'::text[]";
  }
  return 'array[${values.map(_textLiteral).join(', ')}]::text[]';
}

int _estimateTokens(String text) {
  final words = RegExp(r'\S+').allMatches(text).length;
  return (words * 4 / 3).ceil();
}

String _slug(String input) {
  final slug = input
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
  return slug.isEmpty ? 'section' : slug;
}

String _stripMarkdownInline(String input) =>
    input.replaceAll('*', '').replaceAll('`', '');

Object? _plainYaml(Object? value) {
  if (value is YamlMap) {
    return <String, Object?>{
      for (final entry in value.entries)
        entry.key.toString(): _plainYaml(entry.value),
    };
  }
  if (value is YamlList) {
    return <Object?>[for (final item in value) _plainYaml(item)];
  }
  return value;
}

Map<String, Object?> _asMap(Object? value, String context) {
  if (value is Map<String, Object?>) {
    return value;
  }
  throw CorpusManifestException('$context must be a YAML map.');
}

String _requiredString(Map<String, Object?> map, String key, String context) {
  final value = map[key];
  if (value is String && value.trim().isNotEmpty) {
    return value;
  }
  throw CorpusManifestException('$context missing required string: $key');
}

String? _optionalString(Map<String, Object?> map, String key, String context) {
  final value = map[key];
  if (value == null) {
    return null;
  }
  if (value is String) {
    return value;
  }
  throw CorpusManifestException('$context.$key must be a string or null.');
}

int _requiredInt(Map<String, Object?> map, String key, String context) {
  final value = map[key];
  if (value is int) {
    return value;
  }
  throw CorpusManifestException('$context missing required int: $key');
}

List<Map<String, Object?>> _requiredMapList(
  Map<String, Object?> map,
  String key,
  String context,
) {
  final value = map[key];
  if (value is List<Object?>) {
    return value
        .map((item) => _asMap(item, '$context.$key item'))
        .toList(growable: false);
  }
  throw CorpusManifestException('$context missing required list: $key');
}

List<Map<String, Object?>> _optionalMapList(
  Map<String, Object?> map,
  String key,
  String context,
) {
  final value = map[key];
  if (value == null) {
    return <Map<String, Object?>>[];
  }
  if (value is List<Object?>) {
    return value
        .map((item) => _asMap(item, '$context.$key item'))
        .toList(growable: false);
  }
  throw CorpusManifestException('$context.$key must be a list.');
}

List<String> _requiredStringList(
  Map<String, Object?> map,
  String key,
  String context,
) {
  final value = map[key];
  if (value is List<Object?>) {
    final strings = value.whereType<String>().toList(growable: false);
    if (strings.length == value.length && strings.isNotEmpty) {
      return strings;
    }
  }
  throw CorpusManifestException('$context missing required string list: $key');
}
