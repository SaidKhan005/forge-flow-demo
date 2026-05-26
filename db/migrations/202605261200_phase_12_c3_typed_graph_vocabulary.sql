-- Phase 12 / Graph G2 C3 — typed node-kind + edge-type vocabulary.
--
-- Context: 202604280008_phase_9_0sigma_i_graph_canonical.sql created
-- `public.graph_nodes` and `public.graph_edges` with open-text `node_type`
-- / `edge_type` columns (CHECK only on char_length). That was correct for
-- Phase 9 where the vocabulary was still converging. C3 locks the approved
-- vocabulary so the admin review UI, the corpus importer, the AGE projection
-- tool, and any future Phase 12 automation all share one source of truth
-- rather than each maintaining its own enum.
--
-- Design approach — additive lookup tables, not CHECK constraints on the
-- existing columns:
--
--   * Adding a CHECK constraint to `graph_nodes.node_type` after the fact
--     would invalidate every existing row whose `node_type` does not match
--     the new list and require a data migration. The lookup-table approach
--     is forward-only: existing rows are untouched, new writes FK-validate
--     against the approved list, and the tables are easy to extend without
--     an ALTER TABLE.
--   * `graph_node_kinds` and `graph_edge_types` are global (no
--     `operator_id`) because the vocabulary is methodology-level truth
--     shared across all operators, not per-tenant data. They carry no RLS
--     because there is nothing tenant-sensitive in a vocabulary row.
--   * The existing `graph_nodes.node_type` / `graph_edges.edge_type` columns
--     are NOT altered. New writes that want FK enforcement use the helper
--     views / application-level validation against these tables. A later
--     slice can add the FK constraint once all existing rows are validated
--     against the vocabulary (that validation step belongs to C4, not here).
--
-- Vocabulary sealed at C3:
--
--   Node kinds (from admin_human_labels.dart AdminCorpusTopicKind +
--   advisor_corpus.dart kGraphifyApprovedNodeTypes + connections view):
--     Concept, SOP, Policy, Metric, Formula, Risk, Role,
--     Word_To_Know, Coaching_Move, Document, Chunk, Workflow, Procedure
--
--   Edge types (from corpus_admin_connections_view.dart corpusRelationshipVerb
--   + advisor_corpus.dart kGraphifyApprovedEdgeTypes + connections change dialog):
--     CONTAINS, CAUSES, INFORMS, RELATES_TO, DEPENDS_ON, GOVERNS, MITIGATES,
--     TEACHES, DEFINES, MEASURES, CALCULATES, REDUCES_RISK_OF, REQUIRES,
--     PART_OF, NEAR
--
-- Hard rules:
--   1. ADDITIVE ONLY. No DROP, no ALTER on graph_nodes / graph_edges.
--   2. No data backfill requiring AI — only deterministic lookups.
--   3. No operator_id / RLS on vocab tables (global methodology truth).
--   4. TIMESTAMPTZ for all datetime columns (CLAUDE.md time guardrail;
--      these tables are global, not operator-scoped, but the rule applies).
--   5. Grants match the canonical graph tables: service_role + forge_admin.
--
-- Op-gate: this migration is operator-approval-gated. It MUST NOT be
-- applied to staging or production without explicit operator sign-off.
-- The PR carrying this file is tagged "(OP-GATED — hold for approval)".

begin;

-- ─── graph_node_kinds (vocabulary lookup) ──────────────────────────────────
--
-- One row per approved node kind. The `kind` column is the canonical
-- wire value that `graph_nodes.node_type` must equal. `display_label` is
-- the human-readable short name the admin UI renders. `description` is the
-- one-line meaning.
--
-- Scope: global (shared methodology). No operator_id column, no RLS.
-- New kinds are added here; nothing is ever deleted.

create table if not exists public.graph_node_kinds (
  kind text primary key
    check (char_length(kind) between 1 and 64),
  display_label text not null
    check (char_length(display_label) between 1 and 64),
  description text not null
    check (char_length(description) between 1 and 256),
  -- Category groups related kinds for filter UX.
  -- 'methodology' = core content; 'operational' = workflow/role kinds;
  -- 'structural' = chunk/document structural kinds.
  category text not null default 'methodology'
    check (category in ('methodology', 'operational', 'structural')),
  sort_order integer not null default 99,
  created_at timestamptz not null default now()
);

comment on table public.graph_node_kinds is
  'Phase 12 / G2 C3 — approved graph node-kind vocabulary. Global (no '
  'operator_id). New kinds are added here; existing rows are never deleted. '
  'graph_nodes.node_type values SHOULD match a row here; FK enforcement '
  'deferred to C4 once existing rows are validated.';

comment on column public.graph_node_kinds.kind is
  'Canonical wire value that graph_nodes.node_type carries. '
  'Matches AdminCorpusTopicKind enum and kGraphifyApprovedNodeTypes.';

comment on column public.graph_node_kinds.category is
  'Groups kinds for the admin filter UX: methodology (core content), '
  'operational (workflow/role), structural (chunk/document).';

-- ─── graph_edge_types (vocabulary lookup) ──────────────────────────────────
--
-- One row per approved edge type. The `edge_type` column is the canonical
-- wire value that `graph_edges.edge_type` must equal. `verb_phrase` is the
-- plain-English reading used in the Connections view ("includes", "informs",
-- etc.) — a single source of truth so the UI and the importer share it.

create table if not exists public.graph_edge_types (
  edge_type text primary key
    check (char_length(edge_type) between 1 and 64),
  verb_phrase text not null
    check (char_length(verb_phrase) between 1 and 128),
  description text not null
    check (char_length(description) between 1 and 256),
  -- Whether this edge type is user-selectable in the Change dialog.
  -- Some types (e.g. NEAR, PART_OF) are valid in data but not offered
  -- as Change-dialog options; the UI shows the subset where selectable = true.
  selectable boolean not null default true,
  sort_order integer not null default 99,
  created_at timestamptz not null default now()
);

comment on table public.graph_edge_types is
  'Phase 12 / G2 C3 — approved graph edge-type vocabulary. Global (no '
  'operator_id). New edge types are added here; existing rows are never '
  'deleted. graph_edges.edge_type values SHOULD match a row here; FK '
  'enforcement deferred to C4 once existing rows are validated.';

comment on column public.graph_edge_types.verb_phrase is
  'Plain-English verb phrase for the connection sentence '
  '("includes", "informs", ...). Single source of truth — '
  'mirrors corpusRelationshipVerb() in corpus_admin_connections_view.dart.';

comment on column public.graph_edge_types.selectable is
  'True when this edge type appears in the Change dialog option list. '
  'NEAR and some structural types are valid in data but not offered as '
  'user-selectable re-bucketing options.';

-- ─── Seed: node kinds ──────────────────────────────────────────────────────
--
-- Sealed C3 vocabulary. Mirrors AdminCorpusTopicKind enum values and the
-- kGraphifyApprovedNodeTypes set. ON CONFLICT DO NOTHING ensures the insert
-- is idempotent on re-apply.

insert into public.graph_node_kinds
  (kind, display_label, description, category, sort_order)
values
  -- Core methodology content kinds (C3 target)
  ('Concept',       'Concept',       'An abstract idea or principle in the methodology.',           'methodology',  10),
  ('SOP',           'SOP',           'A step-by-step standard operating procedure.',                'methodology',  20),
  ('Policy',        'Policy',        'A rule, compliance requirement, or regulatory policy.',       'methodology',  30),
  ('Metric',        'Metric',        'A measurable performance indicator tracked over time.',       'methodology',  40),
  ('Formula',       'Formula',       'A calculation or equation used to derive a metric.',          'methodology',  50),
  ('Risk',          'Risk',          'A potential harm, hazard, or contamination risk.',            'methodology',  60),
  ('Word_To_Know',  'Word to Know',  'A key term or definition operators need to understand.',      'methodology',  70),
  ('Coaching_Move', 'Coaching Move', 'A coaching action or technique the advisor recommends.',      'methodology',  80),
  -- Operational kinds
  ('Role',          'Role',          'A person, position, or organizational role.',                 'operational', 110),
  ('Workflow',      'Workflow',      'A multi-step process or sequence of tasks.',                  'operational', 120),
  -- Structural kinds (corpus chunk/document structure)
  ('Document',      'Document',      'A source document or section from the corpus.',              'structural',  210),
  ('Chunk',         'Chunk',         'A discrete chunk of corpus content derived from a document.','structural',  220),
  -- Legacy alias kept for existing advisor_corpus importer compatibility
  ('Procedure',     'Procedure',     'Alias for SOP; kept for importer backward compatibility.',   'methodology',  25)
on conflict (kind) do nothing;

-- ─── Seed: edge types ──────────────────────────────────────────────────────
--
-- Sealed C3 vocabulary. Mirrors kGraphifyApprovedEdgeTypes and the full set
-- of types the Connections view renders via corpusRelationshipVerb(). Verb
-- phrases are verbatim copies from that function so the DB is the authority.

insert into public.graph_edge_types
  (edge_type, verb_phrase, description, selectable, sort_order)
values
  -- Core graph vocabulary (from contracts + importer)
  ('CONTAINS',       'includes',                    'One node structurally includes or is composed of the other.',            true,   10),
  ('CAUSES',         'can cause',                   'One node is a direct or contributing cause of the other.',               true,   20),
  ('INFORMS',        'informs',                     'One node provides knowledge or context that informs the other.',         true,   30),
  ('RELATES_TO',     'is related to',               'A general semantic relationship; used as the fallback type.',            true,   40),
  ('DEPENDS_ON',     'depends on',                  'One node requires the other to be true or in place first.',              true,   50),
  ('GOVERNS',        'governs',                     'One node (a role or policy) has authority over the other.',              true,   60),
  ('MITIGATES',      'reduces the risk of',         'One node reduces the probability or severity of the other (a risk).',    true,   70),
  -- C3 additions: types rendered by the UI but absent from kGraphifyApprovedEdgeTypes
  ('TEACHES',        'teaches',                     'One node imparts knowledge or skill about the other.',                   true,   80),
  ('DEFINES',        'defines',                     'One node provides the authoritative definition of the other.',           true,   90),
  ('MEASURES',       'measures',                    'One node quantifies or measures the other.',                             true,  100),
  ('CALCULATES',     'is used to calculate',        'One node (a formula) is used to compute the value of the other.',       true,  110),
  ('REDUCES_RISK_OF','reduces the risk of',         'Explicit alias for MITIGATES from the connections view vocabulary.',     true,  120),
  ('REQUIRES',       'requires',                    'One node requires the other as a prerequisite or dependency.',           true,  130),
  ('PART_OF',        'is part of',                  'One node is a component or sub-part of the other.',                     false, 140),
  ('NEAR',           'is related to',               'Proximity-based semantic similarity; not a directional relationship.',   false, 150)
on conflict (edge_type) do nothing;

-- ─── Indexes ───────────────────────────────────────────────────────────────
--
-- Both tables are small (< 20 rows each) and queried only at admin
-- screen load or import time, so simple primary-key lookups dominate.
-- The category + sort_order index on graph_node_kinds lets the UI build
-- a sorted, grouped dropdown without a full scan.

create index if not exists graph_node_kinds_category_sort_idx
  on public.graph_node_kinds (category, sort_order);

create index if not exists graph_edge_types_selectable_sort_idx
  on public.graph_edge_types (selectable, sort_order);

-- ─── Grants ────────────────────────────────────────────────────────────────
--
-- Read + write for service_role (the importer adds kinds here) and
-- forge_admin (cross-tenant admin paths). SELECT-only for authenticated
-- users so the admin UI can load the vocabulary without service-role.

grant select, insert, update on public.graph_node_kinds to service_role;
grant select, insert, update on public.graph_node_kinds to forge_admin;
grant select on public.graph_node_kinds to authenticated;

grant select, insert, update on public.graph_edge_types to service_role;
grant select, insert, update on public.graph_edge_types to forge_admin;
grant select on public.graph_edge_types to authenticated;

-- ─── View: active vocabulary join (convenience for C4 FK validation) ───────
--
-- Helper view that joins graph_nodes against graph_node_kinds to surface
-- rows whose node_type has no matching vocabulary entry. Returns nothing
-- when the canonical graph is fully vocabulary-aligned. C4 will use this
-- view to identify rows needing re-tagging before adding the hard FK.

create or replace view public.graph_nodes_unknown_kinds as
  select
    gn.id,
    gn.operator_id,
    gn.graph_scope,
    gn.graph_version,
    gn.node_key,
    gn.node_type,
    gn.created_at
  from public.graph_nodes gn
  where not exists (
    select 1
    from public.graph_node_kinds gnk
    where gnk.kind = gn.node_type
  )
  and gn.deleted_at is null
  and gn.archived_at is null;

comment on view public.graph_nodes_unknown_kinds is
  'Phase 12 / G2 C3 — surfaces graph_nodes rows whose node_type does not '
  'match any graph_node_kinds row. Returns empty when canonical graph is '
  'fully vocabulary-aligned. Used by C4 to validate rows before adding FK.';

create or replace view public.graph_edges_unknown_types as
  select
    ge.id,
    ge.operator_id,
    ge.graph_scope,
    ge.graph_version,
    ge.edge_key,
    ge.edge_type,
    ge.created_at
  from public.graph_edges ge
  where not exists (
    select 1
    from public.graph_edge_types get2
    where get2.edge_type = ge.edge_type
  )
  and ge.deleted_at is null
  and ge.archived_at is null;

comment on view public.graph_edges_unknown_types is
  'Phase 12 / G2 C3 — surfaces graph_edges rows whose edge_type does not '
  'match any graph_edge_types row. Returns empty when canonical graph is '
  'fully vocabulary-aligned. Used by C4 to validate rows before adding FK.';

grant select on public.graph_nodes_unknown_kinds to service_role;
grant select on public.graph_nodes_unknown_kinds to forge_admin;

grant select on public.graph_edges_unknown_types to service_role;
grant select on public.graph_edges_unknown_types to forge_admin;

commit;
