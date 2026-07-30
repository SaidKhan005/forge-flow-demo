# Barrio training-diagram engine

Generates the house-style **diagram pictogram** that sits on every otherwise
text-only Barrio training reading card (full-coverage pass, 2026-07-30). Output
is one `<unit_id>.webp` per card, wired into the reading cards through
`tool/barrio_training_diagrams_manifest.json` (the same mechanism the earlier
Company Handbook + Food Safety diagrams use).

Each pictogram is a clean line-icon in the manual's own accent colour on the
warm cream ground, with the card title beneath: cream `#F7F3EA`, deep-navy
text `#16243B`, per-manual accent from `kBarrioTrainingAccents`.

## Provenance & licensing

The line-icons are **Lucide** (https://lucide.dev), used under the **ISC
License**:

> Copyright (c) for portions of Lucide are held by Cole Bemis 2013-2022 as part
> of Feather (MIT). All other copyright (c) for Lucide are held by Lucide
> Contributors 2022.
>
> Permission to use, copy, modify, and/or distribute this software for any
> purpose with or without fee is hereby granted, provided that the above
> copyright notice and this permission notice appear in all copies.

The engine recolours each icon to the manual accent and rasterises it to webp
with [`sharp`](https://sharp.pixelplumbing.com/); only the rendered webp ships
in the app. No fabricated data appears on any card (Metric Honesty), and no
caption uses an em dash (UX no-em-dash law). Diagram images all carry a
`Diagram: <title>` caption, which is the signal the app uses to keep them OFF
photo-only surfaces (browse thumbnails, A-Z index, photo grid, flashcard
fronts) via the `HandbookUnitPhotos` extension in
`lib/internal/barrio/content/company_handbook_content.dart`.

## Regenerate

```
cd tool/barrio_diagram_engine
npm install                 # sharp + lucide-static (see package.json)
python extract_bare.py      # scan routed content -> bare_cards.json
node engine.mjs ALL         # render every bare card -> out/<folder>/*.webp
python wire.py              # copy webp into assets/, merge the diagrams manifest
cd ../.. && python tool/barrio_training_content_generator.py   # bake into content
python tool/barrio_training_verbatim_check.py                  # must be lost=0w
```

`extract_bare.py` / `wire.py` carry absolute paths from the original run and are
kept as a reference of the exact pass; adjust the `BASE` / `WT` paths before a
re-run. `engine.mjs` holds the keyword -> icon map; extend it there when adding
manuals. Icon choices are keyword-matched on each card title first, then body;
split "(cont.)" cards share their base card's icon.
