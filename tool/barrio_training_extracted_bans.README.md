# barrio_training_extracted_bans.json

Output files `tool/barrio_training_image_extractor.py` must never
produce again. Same shape as `tool/barrio_training_extracted_assets.json`
(`{doc_id: [file name]}`), opposite question: that manifest records what
the extractor DID produce and may therefore delete; this one records
what it may NEVER produce, no matter what the source docs contain.

## Why this exists

The 2026-08-09 AI-image purge (PR #1580) deleted 13 AI-generated
pictures from `assets/internal/barrio/training/` and stripped their
markers out of the knowledge-graph markdown. The operator's rule is
absolute: zero AI-generated images may ever ship, not a single one.

The purge alone does not make that stick. The untracked `docs/training`
source drop still contains the AI art inside the source deck and PDF,
and the extractor rewrites `tool/barrio_training_extracted_assets.json`
on every run. A later run over the unchanged sources would re-extract
the pictures, write them back to disk, re-derive their markers, and
re-list them in the ownership manifest: a silent, complete resurrection
of everything the purge removed. This manifest is the permanent record
that stops it.

## Entry shape

```json
{
  "food_safety_manual": ["03.webp"]
}
```

* Key: the `doc_id` from the extractor's `SOURCES` table. A key that
  matches no `SOURCES` doc_id is a hard stop (exit 2), so a typo cannot
  silently disable a ban.
* Value: banned output file names, exactly as the extractor would have
  emitted them (reading-order `NN.webp`).

The file is a pure `{doc_id: [file name]}` map, hand-maintained, and
never rewritten by the extractor. Do not add documentation or comment
keys; documentation lives here instead, the same way it does for
`tool/barrio_training_extracted_assets.json` and
`tool/barrio_training_image_removals.json`.

## Rules the extractor enforces

1. **A banned file is never produced.** Not written to disk, no marker
   derived, not listed in the rewritten ownership manifest. When the
   source doc still yields the picture, the run reports
   `SKIPPED NN.webp (banned)` and succeeds: the source still containing
   banned art is the expected steady state, not an error.
2. **Bans apply after reading-order numbering.** Names are assigned
   over the full kept list first, then banned names are dropped, so an
   unbanned sibling keeps the number it has always shipped under
   (banning `01.webp` through `07.webp` must not slide `08.webp` down
   to `01.webp` and collide with curated content). The flip side: if a
   source doc's picture set ever changes, its numbering shifts, and a
   human must re-verify this list against the run report's SKIPPED
   lines.
3. **`--check` treats a banned file as settled.** A banned file missing
   from disk is the goal state, not a pending change, so `--check`
   exits 0 on a purged tree.
4. **Banning a still-owned file converges exactly once.** If a banned
   name is still listed in the ownership manifest, the next run deletes
   the file and drops its marker through the normal owned-cleanup path,
   and it can never come back because the name is skipped before
   anything is written. Removed once, never recreated. (The 13 seeded
   entries were delisted from the ownership manifest in the same PR
   that added them here, so this path does not fire for them.)
5. **A ban shields curated reuse of the number.** If curation later
   places a licensed file on a banned name, the extractor does not hit
   the not-extractor-owned collision hard stop for it: the banned
   output is skipped before the byte comparison, so the curated file is
   simply left alone.
6. **The extractor never deletes an unowned banned file.** If a banned
   file somehow exists on disk without an ownership-manifest entry, the
   extractor leaves it (ownership rule 1: only manifest-listed files
   may be deleted). Deleting the actual bytes is a purge PR's job; this
   manifest only guarantees they never come back.

## Seeded entries (2026-08-09, PR #1580)

All 13 seeds are AI-generated pictures removed under the operator's
no-AI-images law:

* `barrio_legado_menu_concept_slides`: `01.webp` through `07.webp` and
  `09.webp` through `13.webp` (12 files). AI-generated map and concept
  art from the Menu Concept deck. `08.webp` is a real photograph and
  stays extractable.
* `food_safety_manual`: `03.webp`. AI-generated infographic.

## Adding an entry

1. Add the doc_id + file name here, and record the reason in this
   README (every ban should say why, the way the seeds above do).
2. If the file is still listed in
   `tool/barrio_training_extracted_assets.json`, either delete the
   asset, its markers, and its manifest listing in the same commit (the
   purge-PR route), or let the next real extractor run perform that
   cleanup (rule 4 above).
3. Verify:

```
python tool/barrio_training_image_extractor_test.py
python tool/barrio_training_image_extractor.py --src "<docs/training>" --check
```

The regression test pins the ban mechanism with synthetic fixtures
(banned file not written, no marker derived, not listed, sibling
numbering stable, `--check` settled), so it needs no PDFs and runs in
the `pre-push` hook whenever this file or the extractor changes.
