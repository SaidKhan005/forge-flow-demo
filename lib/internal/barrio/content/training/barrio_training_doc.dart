// Shared model for verbatim training-document learning surfaces.
//
// Each Barrio training bubble added in the 2026-07-11 training-drop slice
// renders one [BarrioTrainingDoc]: the full source document from
// `docs/Knowledge_graph_docs/` carried word-for-word, sectioned into the
// same chapter/unit model the Company Handbook surface uses so the
// chapter rail, learning carousel, and lesson cards render identically.
//
// Unlike the curated handbook/playbook/labor-model adaptations, these
// docs are verbatim: body strings are generated from the source Markdown
// and must not be hand-edited (regenerate instead).

import '../company_handbook_content.dart';

/// A full training document rendered as a chaptered learning surface.
class BarrioTrainingDoc {
  /// Stable id — matches the [BarrioDestination] id for this bubble.
  final String id;

  /// Document title, verbatim from the source Markdown H1.
  final String title;

  /// Repo-relative path of the source Markdown in the knowledge graph.
  final String sourcePath;

  /// Document sections in reading order, reusing the handbook model so
  /// existing rendering widgets work unchanged.
  final List<HandbookChapter> chapters;

  /// Optional honest depth-framing badge word for the home shelf and doc
  /// header (e.g. 'DEEPER DIVE' for optional-depth material that is not
  /// core training). Null (the default) renders no badge. Data only:
  /// widget hookup lands separately.
  final String? depthBadge;

  const BarrioTrainingDoc({
    required this.id,
    required this.title,
    required this.sourcePath,
    required this.chapters,
    this.depthBadge,
  });
}
