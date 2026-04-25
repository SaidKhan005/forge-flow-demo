# Phase 11a.0 - Corpus Manifest + Ingestion Contract

Updated: 2026-04-25
Owner: Codex planning / advisor infrastructure lane
Status: Complete - contract and manifest landed; backend ingestion not started

## Plain English

This run makes the advisor corpus explicit before any graph or embedding work
starts. It tells the future ingestion pipeline which Markdown files are
allowed in, how to split them, what each document is for, and how to keep
shared methodology separate from private live restaurant data.

## Scope

This slice owns the corpus contract only:

- active corpus manifest for `docs/Knowledge_graph_docs`
- included / excluded source truth
- global/shared methodology metadata
- first-pass chunking profiles
- first-pass graph node and edge taxonomy
- retrieval provenance requirements
- internal smoke-test expectations for future ingestion

It does not own:

- Supabase migrations
- Apache AGE graph creation
- pgvector columns or embedding dimensions
- embedding provider selection
- MCP server implementation
- agent runtime or UX
- cleanup or rewriting of source Markdown text
- live POS / labor / reservation transport

## Corpus Root

The active Markdown corpus root is:

```text
docs/Knowledge_graph_docs
```

The manifest is:

```text
docs/Knowledge_graph_docs/corpus_manifest.yaml
```

The manifest is the ingestion authority. Future ingestion must not treat a
directory scan as permission to ingest a file. Markdown files not listed in the
manifest are flagged for review and skipped until explicitly added.

## Included Corpus

| Document | Role | Scope | Risk | Chunk profile |
| --- | --- | --- | --- | --- |
| `Barrio_company_handbook.md` | Operating handbook | Global shared methodology | Medium-high | `heading_aware_policy_handbook` |
| `Barrio_interview_playbook.md` | Hiring / interview playbook | Global shared methodology | Medium | `heading_aware_short_playbook` |
| `Bold By Design.md` | Labor methodology book | Global shared methodology | Medium | `heading_aware_methodology_formula` |
| `food safety manual.md` | Food safety policy manual | Global shared methodology | High | `heading_aware_risk_policy` |
| `GENERAL WORDS TO KNOW.md` | Glossary | Global shared methodology | Low | `glossary_entry_per_term` |
| `jim_taylor_labor_model_deep_dive.md` | Labor metric study notes | Global shared methodology | Medium | `heading_aware_methodology_formula` |
| `OE Cheers to Responsibility.md` | Responsible alcohol service training | Global shared methodology | High | `heading_aware_risk_policy` |
| `OE MASTERING THE METRICS.md` | Metric training | Global shared methodology | Medium | `heading_aware_metric_training` |

All included rows use `restaurant_id: null` and
`scope: global_shared_methodology`. This means they can support Barrio internal
coaching and Forge & Flow advisor answers, but they do not carry private
operator metrics or tenant-specific live facts.

## Excluded Corpus

`The Empty Apron - 2026.md` is excluded. The owner removed it from the active
folder before this slice. If the file is reintroduced later, ingestion must
still skip it unless the manifest is deliberately updated.

## Source Text Rules

- Preserve source Markdown as the founder-authored source of truth.
- Do not rewrite OCR artifacts or normalize prose during ingestion.
- Store chunk hashes so later source edits can be detected.
- Preserve original heading paths, page/source metadata, tables, formulas, and
  examples wherever present.
- Preserve risk metadata for food safety, alcohol service, employment, and
  other policy-like content.
- Non-Markdown source material is not ingested silently; it must be converted
  to Markdown and added to the manifest first.

## Chunking Contract

### Heading-aware documents

Use heading paths as the primary structure:

```text
Document -> H1 -> H2 -> H3 -> chunk
```

Preferred chunk size is content-aware, not a blind fixed window:

- target 400-900 tokens
- hard cap around 1200 tokens unless splitting would break a table or formula
- carry the parent heading path into every chunk
- add a short contextual prefix at indexing time, not by rewriting the source
- keep tables, formulas, and worked examples atomic when possible

### Glossary document

`GENERAL WORDS TO KNOW.md` should not be chunked as one large prose section.
Each glossary term becomes a term/alias unit:

```text
Term -> Definition
```

Terms may emit `Alias` nodes when abbreviations or parenthetical expansions
exist, such as `BOH` -> `Back of House`.

### Risk policy documents

Food safety and alcohol-responsibility material should emit risk-aware chunks:

- source section required
- answer policy should prefer citation and caution
- do not generate legal/compliance certainty beyond the source text
- missing jurisdiction or stale policy date should reduce answer confidence

## Graph Schema Contract

The first production graph should support these node types:

- `Document`
- `Section`
- `Chunk`
- `Concept`
- `Term`
- `Alias`
- `Metric`
- `Formula`
- `Policy`
- `Procedure`
- `Role`
- `Risk`
- `CoachingMove`
- `ProductSurface`

The first edge set should support:

- `CONTAINS` - document to section / section to chunk
- `DEFINES` - term or metric definition
- `ALIAS_OF` - abbreviation or synonym relationship
- `EXPLAINS` - methodology explanation relationship
- `APPLIES_TO` - concept applies to role, metric, procedure, or surface
- `REQUIRES` - prerequisite procedure or safety requirement
- `CONTRASTS_WITH` - similar terms that must not be conflated
- `CITES` - generated answer or derived node points back to source chunk
- `SUPPORTS_COACHING_MOVE` - concept supports a coaching recommendation
- `SIMILAR_TO` - vector-derived relationship, stored only after embedding
  similarity has been computed

Every node and edge should carry provenance:

- `source_doc_id`
- `source_path`
- `heading_path`
- `chunk_id` when applicable
- `confidence`: `extracted`, `inferred`, or `ambiguous`
- `risk_level`
- `created_at` / `updated_at`

## Retrieval Contract

The advisor has two knowledge lanes and one live-data lane:

1. Graph retrieval for methodology, definitions, formulas, roles, procedures,
   and coaching relationships.
2. Passage retrieval for exact founder-authored text and examples.
3. MCP/live tools for private operator data such as covers, labor, sales,
   variance, targets, reservations, freshness, and historical shifts.

The graph must never become a shadow source for live metrics. If a future
answer mentions actual restaurant numbers, those numbers must come from the
tool layer and cite tool provenance. The corpus may explain what CPLH means,
but it must not store a restaurant's current CPLH.

## Internal Smoke-Test Contract

Future ingestion should create its own synthetic smoke-test set from the
manifested corpus. No owner-provided question list is required for 11a.0.

The smoke set should cover:

- concept definition questions
- formula explanation questions
- glossary abbreviation questions
- procedure lookup questions
- high-risk policy questions
- methodology-to-metric path questions
- mixed questions that require graph context plus mocked live values

Each smoke answer should be evaluated for:

- source citation presence
- correct document / chunk retrieval
- no private data leakage
- no unsupported compliance certainty
- no invented metric values
- correct routing between methodology and live tool requirements

## Research Basis

The contract follows the practical shape implied by the 11a plan and the
current RAG research pattern:

- graph retrieval for relationships and path tracing
- vector retrieval for semantically similar passages
- contextualized chunks that carry parent document/section meaning
- row-level scoping for future operator-specific material
- provenance in every answer

Primary references used during the 11a.0 planning pass:

- Microsoft GraphRAG documentation and GraphRAG paper
- Anthropic Contextual Retrieval
- Anthropic Claude embeddings guide / Voyage embedding and reranker docs
- Supabase pgvector and row-level security docs
- Apache AGE docs
- pgvector docs

These references inform the contract, but the repo-local phase plan and
manifest remain the authority for implementation prompts.
