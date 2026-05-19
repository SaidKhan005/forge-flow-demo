# Per-Daypart Targets V1 — audit trail

Audit artifacts for the **active** Per-Daypart Targets V1 feature.

## Layout convention

- **`landed/`** — point-in-time verdicts on merged PRs and completed
  fixes. Rule of thumb: any `pr_*` or `fix_*` doc is a frozen
  historical verdict (feature slices already landed) and lives here.
- **flat (this dir)** — active working docs: `slice_*` specs,
  `demo_*` datasets/fixtures, `ux_*` reviews, `benchmark_*`,
  `INVESTIGATION_*`, `architecture_*`, `DEMO_DATASET_*`, this README.
  These stay flat while the feature is in flight.

## Rule of thumb

`pr_*` / `fix_*` = landed point-in-time verdicts -> `landed/`.
Specs / demos / investigations / ux = active, stay flat.

## Archive

When Per-Daypart Targets V1 closes, the whole folder
(`docs/_audits/per_daypart_v1/`) archives in one move to
`docs/archive/_audits/`. The `landed/` split makes that sweep clean.
