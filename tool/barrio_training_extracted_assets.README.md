# barrio_training_extracted_assets.json

The list of training assets `tool/barrio_training_image_extractor.py`
produced, and therefore the only ones it is allowed to delete.

## Why this exists

`assets/internal/barrio/training/<doc_id>/` used to have exactly one
writer, so the extractor could be idempotent the blunt way: clear the
folder, strip every image marker out of the knowledge-graph markdown,
re-extract. Two later passes made that false.

* The real-images pass (PR #1477, and build 32 on 2026-08-02) dropped
  licensed photographs into those same per-doc folders, numbered after
  the extracted ones. `coffee_training/07.webp` through `23.webp`, all
  57 of `latin_american_dishes/`, all 53 of
  `latin_american_ingredients/`.
* Curation captioned markers by hand. `![Photo: <credit>](...)` on the
  licensed photographs, `![Diagram: ...](...)` on seven extracted ones.
  That alt text is not decoration: the generator emits it as the
  `caption:` on each `HandbookUnitImage`, so a lost `Photo:` line is a
  lost licence attribution shipping in the app.
* Reviewers moved some markers. `drink_specs/10.webp` and `11.webp` sit
  where a person put them, not where the anchor heuristic would.

On 2026-08-06 a plain re-run on clean master deleted 127 tracked assets
and stripped markers out of 8 markdown files, with no code change
involved. The wine-manual slice had to `git checkout --` the collateral
before it could commit. This manifest is the record that makes the
difference between the two writers knowable.

## Entry shape

```json
{
  "coffee_training": ["01.webp", "02.webp", "03.webp",
                      "04.webp", "05.webp", "06.webp"]
}
```

* Key: the `doc_id` from the extractor's `SOURCES` table.
* Value: the file names the extractor emits for that doc, in reading
  order. A doc that yields no content pictures keeps an empty list; that
  is a real statement (`latin_american_dishes` extracts nothing, so every
  file in its folder is curated), not a placeholder.

The file is a pure `{doc_id: [file name]}` map, and the extractor
rewrites it on every run, so do not add documentation or comment keys.
Documentation lives here instead, the same way it does for
`tool/barrio_training_image_removals.json`.

## Rules the extractor enforces

1. **Only manifest-listed files are deleted.** Anything else in a
   `<doc_id>/` folder belongs to curation and is left alone, even when
   the extractor produces nothing at all for that doc.
2. **Only manifest-listed markers are stripped or moved.** A marker
   pointing at a curated asset is never touched.
3. **A marker that already exists is preserved exactly**, with its alt
   text and its position. Placement is derived only for an asset that has
   no marker yet, so a reviewer's hand-correction is never re-derived
   away. This is the same failure PR #1534 hit when re-pointing 44
   entries silently dropped their `"replace": true` flags.
4. **Byte-identical output is adopted.** A file whose contents already
   equal what this run produces is extractor output by definition, listed
   or not. That is how the manifest was seeded, and it means a checkout
   whose manifest is missing converges instead of hard-stopping.
5. **Writing different bytes over a file the tool does not own is a hard
   stop.** That means a source doc grew a picture and the new reading-
   order number has collided with a curated photograph. The run writes
   nothing and says so; renumbering licensed content is a human decision.
6. **A missing source doc changes nothing.** No source means no evidence
   about ownership, so the folder, the markdown, and the manifest entry
   are all left as they are.

## Verifying

```bash
python tool/barrio_training_image_extractor.py --src "<docs/training>" --check
```

`--check` plans the whole run in memory, writes nothing, and exits
non-zero if a real run would change anything. On an unchanged source drop
it must report `CHANGES none`, which is the machine-checkable form of
"a re-run leaves `git status --porcelain` empty".

```bash
python tool/barrio_training_image_extractor_test.py
```

The regression test needs no PDFs: it builds a synthetic source and a
synthetic knowledge-graph doc in a temp tree and asserts the six
behaviours above. It runs in the `pre-push` hook because, unlike
`--check`, it does not depend on the untracked `docs/training` drop.

## Seeded entries

`push_employee_sop`'s 33 files were seeded from git provenance rather
than from a run: the drop folder holds `PUSH OPERATIONS MANUAL.pdf`, but
the extractor's `SOURCES` table names that doc's source
`Push Employee SOP.pdf`, so no local run can reproduce it. The evidence
is unambiguous anyway (all 33 files landed in one extractor commit,
003e98b0 / PR #1510, and `Push Employee SOP.md` carries 33 matching
uncaptioned markers, with no photo pass having touched that doc). If the
source filename is ever reconciled, a normal run will confirm or correct
the entry.

## The future shape

The clean end state is a separate `<doc_id>_extracted/` namespace, so the
extractor and curation cannot collide by numbering at all and rule 5 can
never fire. That means renumbering and re-pointing every shipped asset,
every entry in `tool/barrio_training_diagrams_manifest.json` and
`tool/barrio_training_image_removals.json`, and every generated card.
This manifest is the smaller fix that stops the bleeding without moving
any licensed content.
