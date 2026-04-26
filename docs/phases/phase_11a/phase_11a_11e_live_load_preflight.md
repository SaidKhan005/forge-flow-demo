# Phase 11a.11e Live Load Preflight

Date: 2026-04-26
Status: SUPERSEDED BY LIVE RESULT

## Summary

This was the preflight before the staging live-load gate. The gate was later
approved and executed. Current live status is recorded in
`phase_11a_11e_staging_live_load_result.md`.

## Local Artifact Rebuild

Commands run locally with no provider calls and no DB mutation:

- `dart run tool/advisor_corpus/main.dart validate`
- `dart run tool/advisor_corpus/main.dart materialize`
- `dart run tool/advisor_corpus/main.dart prepare-load`
- `dart run tool/advisor_corpus/main.dart prepare-embeddings`
- `dart run tool/advisor_corpus/main.dart prepare-age-projection`

Observed local outputs:

- Manifest validation: 8 documents, 8 active Markdown files.
- Materialization: 8 documents, 233 chunks, 241 graph node seeds, 233 graph
  edge hints.
- Load prep output: `build/advisor_corpus/load`.
- Embedding dry-run prep: 233 chunks, 108462 estimated tokens,
  `voyage/voyage-4-large`, 1024 dimensions.
- AGE projection prep: graph `advisor_corpus`, files
  `006_age_projection.sql`, `007_age_smoke_traversal.sql`,
  `008_age_index_strategy.sql`, `009_age_benchmark_harness.sql`,
  `010_vector_index_decision_harness.sql`, and
  `age_projection_manifest.json`.

## Read-Only Env Preflight

Values were not printed or inspected.

| Env name | Result |
| --- | --- |
| `POSTGRES_URL` | PRESENT |
| `POSTGRES_ADMIN_URL` | PRESENT |
| `VOYAGE_API_KEY` | PRESENT |
| `ANTHROPIC_API_KEY` | MISSING |

Postgres staging env names load through
`scripts/use_postgres_staging_env.ps1`, and
`scripts/postgres_staging_preflight.ps1` reports the required Postgres env
names present.

## Human Gate Needed

Before this slice can complete, the user must explicitly decide:

1. Approve staging Azure DB mutation: apply generated load SQL and AGE
   projection SQL to the staging database.
2. Approve billable Voyage calls: run `execute-embeddings` against
   `VOYAGE_API_KEY` and then apply generated embedding updates to staging.
3. Provide/export `ANTHROPIC_API_KEY` or explicitly defer Anthropic
   Contextual Retrieval context generation and Claude answer-runtime smoke.
4. Confirm this remains staging-only. Production load is out of scope.

## Not Run

- No `psql` apply of `build/advisor_corpus/load/*.sql`.
- No `execute-embeddings` live Voyage API call.
- No apply of `build/advisor_corpus/embeddings/embedding_updates.sql`.
- No AGE projection SQL apply to Azure.
- No vector search, Voyage rerank, or Claude answer-runtime smoke against live
  staging data.

## Verification

- `flutter test test/advisor_corpus_manifest_test.dart` passed: 35/35.
