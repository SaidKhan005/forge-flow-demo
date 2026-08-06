# barrio_training_image_removals.json

Extracted photos the curation deliberately **dropped** from Barrio
training cards, read by `tool/barrio_training_content_generator.py`.

`tool/barrio_training_image_extractor.py` pulls every picture out of the
source PDFs and PPTXs and leaves an `![](...)` marker in the knowledge
graph markdown. The generator turns each marker into a
`HandbookUnitImage`. When curation decides one of those extracted photos
is wrong, generic, or has been replaced by a licensed photograph, the
marker is still in the markdown, so the generator would keep emitting it
forever. This manifest is where that decision is recorded.

Not to be confused with `tool/barrio_training_extracted_assets.json`,
which answers a different question: which files in a `<doc_id>/` folder
the extractor produced, and may therefore delete. That one governs the
EXTRACTOR's writes; this one governs what the GENERATOR emits from the
markers that survive.

## Why this is separate from the diagram manifest

`tool/barrio_training_diagrams_manifest.json` already understands
`"replace": true`, which drops a unit's extracted images. That flag sits
**on the replacement entry**, so re-pointing the replacement at a new
asset carries the drop instruction away with it.

That is not hypothetical. PR #1515 wired 48 upgraded food photos with
`"replace": true`. PR #1534 (build 32) re-pointed 44 of those entries at
new `*_photos/` assets with new captions and lost the flag on all 44. The
committed content stayed correct, so nobody noticed, but the next clean
generator run put 44 culled extractor photos back (+206 lines across
`training_latin_dishes_content.dart` and
`training_latin_ingredients_content.dart`). Regenerating became unsafe.

Recording the DROP separately from the REPLACEMENT means editing one can
never quietly undo the other.

## Entry shape

```json
{
  "training_latin_dishes_c0_u0": {
    "drop": [
      "assets/internal/barrio/training/latin_american_dishes/01.webp"
    ],
    "reason": "Extractor photo superseded by the curated food photograph for this card (PR #1515)."
  }
}
```

* Key: the FINAL (post-split) unit id, `<doc_id>_c<chapter>_u<unit>`,
  exactly as it appears in the generated Dart (`id:` on the unit).
* `drop`: extractor asset paths to suppress on that card, written exactly
  as the generator would have emitted them.
* `reason`: why the card no longer shows it, for the next reader.

The file is a pure `{unit_id: entry}` map. Do not add documentation or
comment keys: every key is validated against the run, so a stray key
would need an exemption, and that exemption is the hole a future typo
would fall through. Documentation lives here instead.

## Rules the generator enforces (hard stops, not warnings)

1. **Every dropped path must still exist.** If a listed path is not among
   the images the extractor emits for that unit right now, the run stops.
   Unit ids shift when a source doc or a split constant changes, so an id
   that still resolves may now name a different card, and a silent skip
   would let a photo the operator wants disappear.
2. **No stale ids.** A manifest id that never appears in the run stops
   the build, so a culled photo cannot silently come back.
3. **A removal may never blank a card.** If the drop leaves a unit with
   no images at all, the run stops. Every entry here exists because a
   curated picture took the dropped one's place; if that replacement is
   later deleted from the diagram manifest, the card must not quietly go
   pictureless.

## Adding an entry

1. Wire the curated replacement in
   `tool/barrio_training_diagrams_manifest.json` first (rule 3 above
   stops the run otherwise).
2. Add the entry here with the exact extractor path and an honest reason.
3. Regenerate and verify:

```
python tool/barrio_training_content_generator.py
python tool/barrio_training_verbatim_check.py       # lost=0w is mandatory
python tool/barrio_training_content_generator.py --check
git status --porcelain                              # must be empty
```

Images are formatting, not words, so dropping one never changes the
verbatim word count. Any `lost` words means something other than an image
moved: revert and look again.

## The drift check

`python tool/barrio_training_content_generator.py --check` renders every
generated file in memory and compares it to what is on disk, writing
nothing. It exits non-zero if a real run would change anything, which
covers all three ways this rots: a source markdown edited without a
regenerate, a manifest edited without a regenerate, and a generated
`.dart` hand-edited directly. The `pre-push` hook runs it whenever the
generator, a manifest, a knowledge-graph doc, or a generated content file
is part of the push.
