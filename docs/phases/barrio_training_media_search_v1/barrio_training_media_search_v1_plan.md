# Barrio Training Media + Search V1 Plan

Status: ACTIVE (2026-07-11). Operator-approved scope, decided in chat
2026-07-11 after a read-only census of `docs/training/**` sources.

Follows the Barrio Home Redesign V1 plan
(`docs/phases/barrio_home_redesign_v1/barrio_home_redesign_v1_plan.md`),
whose corpus + one-scroll home landed via PRs #1450-#1458. This plan
adds two features to the Barrio Legado internal shell:

1. **Wave A: source pictures placed into the verbatim training docs.**
2. **Wave B: full-text search over all 18 manuals from the home screen.**

Waves are SERIAL (both touch `training_doc_screen.dart` and the home
surface; Cost & Convergence #3).

## Operator decisions (binding for this plan)

- Build BOTH features; pictures first, search second.
- **Content pictures only.** Repeated logos, page backgrounds, and pure
  decoration are excluded. Filter = repetition across pages + tiny-size
  heuristics + a reviewer pass over the placement report (report goes in
  the Wave A PR body; no separate operator gate).
- **Skip the four manuals whose source files are absent** from
  `docs/training/`: `bold_by_design`, `jim_taylor_labor_model_deep_dive`,
  `oe_cheers_to_responsibility`, `oe_mastering_the_metrics`. They stay
  text-only until their sources are re-dropped. `general_words_to_know`
  has zero images (DOCX census) and needs nothing.

## Census (read-only, 2026-07-11, PyMuPDF 1.27 + zip media listing)

101 unique embedded images, ~49.6 MB raw, across 13 PDFs + 1 PPTX:
Company Handbook 25 (9.9 MB), Coffee 14 (3.0 MB), Menu Concept PPTX 13
(16.6 MB), Food Safety 12 (3.6 MB), Interview Playbook 11 (15.0 MB),
Strong Foundation 9 (0.5 MB), Three Pillars 8 (0.4 MB), remaining seven
sources 9 images combined (<0.5 MB). Post-filter, post-compression
budget: **target <= 10 MB added app assets** (WebP, max long edge
1200 px). Actual number reported in the Wave A PR body.

## Hard rules carried forward

- **Verbatim guarantee is untouched.** Pictures are additions. Image
  markers in the knowledge-graph markdown are formatting, not words;
  `tool/barrio_training_verbatim_check.py` learns to strip them and must
  still report 0 words lost for all 18 docs.
- Knowledge-graph markdown stays the source of truth: image references
  are written into `docs/Knowledge_graph_docs/*.md` at the source
  position; `corpus_manifest.yaml` sha256/notes refresh accordingly.
- Readers never branch on `kDemoMode`; no `demo_*` anything.
- UX no-em-dash law covers all new strings (`widgets/home` is already a
  lint root; new training-surface strings stay clean regardless).
- Metric honesty: search shows real matches or an honest empty state;
  no suggestions, no fake counts.
- B18: search results respect the same visibility resolution as the
  home bubbles (resolver first, preview-role tier fallback).
- Complexity ratchet: baselines only tighten; decompose, never raise.
- Agent contract: worktree -> implement -> self-audit -> commit + push ->
  PR -> STOP; Pattern B table in every PR body.

## Wave A: pictures (2-3 slices, one agent lane)

**A1. Extraction tool + assets.** New `tool/barrio_training_image_extractor.py`:
reads `docs/training/**` (absolute path; the drop folder is untracked
and lives only in the main checkout), extracts unique images per doc,
filters decoration (repeat-across-pages digest check, <100 px or <10 KB
skip-list, full-page-background review flag), converts to WebP (quality
~80, max long edge 1200 px), writes
`assets/internal/barrio/training/<doc_id>/NN.webp`, and emits a
placement report (image -> doc -> page/slide -> nearest preceding source
text -> target markdown anchor). PPTX media map via slide relationship
XML (no python-pptx dependency); slide N images attach to the
`## Slide N` unit.

**A2. Markdown + manifest.** Insert `![<caption-or-empty>](<asset path>)`
markers into the knowledge-graph markdowns at the mapped positions
(captions only when the source has a real caption; never invented).
Refresh `corpus_manifest.yaml` (sha256 over LF bytes, conversion_notes
mention image markers).

**A3. App wiring.**
- Model: `HandbookUnit` gains an optional `images` list (default const
  empty; additive, curated content untouched). Each entry: asset path,
  optional caption, `afterParagraph` index (renderer splits the verbatim
  body on blank lines for display only; the stored string is unchanged).
- Generator (`tool/barrio_training_content_generator.py`): parse markers,
  emit image entries; regenerate all affected content files.
- Verbatim checker: strip markers; all 18 docs still 0 lost.
- Renderer: training lesson cards render images at their positions
  (rounded 12-14 px, full card width, `errorBuilder` icon fallback so
  widget tests never throw); tap opens a full-screen viewer
  (InteractiveViewer pinch-zoom, dark scrim, close button).
- `pubspec.yaml`: register `assets/internal/barrio/training/`.
- Tests: generator/checker round-trip on a fixture, image + viewer
  widget test, existing suites stay green.

Acceptance: verbatim check 0-lost x18, analyzer 0, Barrio suites green,
placement report in PR body, added-asset megabytes stated in PR body.

## Wave B: search (1 slice, one agent lane, after Wave A merges)

- Pure-Dart `BarrioTrainingSearch` (no I/O): case- and
  diacritic-insensitive matching over every `HandbookUnit` body/title in
  `kBarrioTrainingDocs` (fold to ASCII lowercase once, cache per doc);
  returns doc + chapter + unit + snippet spans, ranked by hit count then
  corpus order. Debounced as-you-type (~200 ms).
- Home surface: glass search field under the brand header (above the
  Forge & Flow bubble); results replace the shelf while active (accent
  icon chip, doc title, section title, snippet with highlighted match,
  honest "No matches for '<query>'" empty state; clear/cancel restores
  the shelf).
- `TrainingDocScreen` gains optional `initialChapterIndex` so a result
  opens the exact section.
- Results filter through the same B18 resolver / preview-role visibility
  as bubbles; `supervisor_content` has no doc and can never appear.
- Tests: search-service unit tests (matching, diacritics, ranking,
  empty), widget tests (type -> results -> tap -> correct doc + section;
  clear restores shelf; no overflow at 390x844).

Acceptance: analyzer 0, all Barrio suites + new tests green, home
entrance/ambient effects unaffected when search is idle.

## Out of scope (explicitly)

- Images for the four skipped manuals (until sources are re-dropped).
- OCR of text inside images; PDF vector re-rendering.
- Search inside a single open doc (v2 candidate), fuzzy/semantic search,
  or any AI/proxy involvement.
- Any change to routing rules, destinations, categories, or the parked
  hub/cards (reversal doctrine untouched).
