# barrio_training_card_titles.json

Authored titles for Barrio training **continuation cards**, read by
`tool/barrio_training_content_generator.py`.

A long source section is split into several cards. Card 1 keeps the
verbatim source heading; cards 2..N are titled `<heading> (cont.)`,
which tells the reader nothing about what that card actually teaches.
This manifest replaces those titles with ones that name the lesson.

The manual name still shows in the app bar and the section name in the
hero, so the card header is free to say what the card teaches.

## Entry shape

```json
{
  "training_coffee_c3_u4": {
    "was": "Words to Know (cont.)",
    "title": "Espresso Basics"
  }
}
```

* Key: the FINAL (post-split) unit id, `<doc_id>_c<chapter>_u<unit>`,
  exactly as it appears in the generated Dart (`id:` on the unit).
* `was`: the title the generator would have emitted for that card.
* `title`: the authored replacement.

The file is a pure `{unit_id: entry}` map. Do not add documentation or
comment keys: every key is validated against the run, so a stray key
would need an exemption, and that exemption is the hole a future typo
would fall through. Documentation lives here instead.

## Rules the generator enforces (hard stops, not warnings)

1. **Continuation cards only.** An entry pointing at a run's first card
   (`runIndex == 1`) is a `SystemExit`. That card carries the verbatim
   source heading, and `tool/barrio_training_verbatim_check.py` only
   passes at `lost=0w`, so replacing it would delete source words.
2. **`was` must match.** If the computed title is not exactly `was`, the
   run stops. Unit ids shift whenever a source doc or a split constant
   changes, so an id that still resolves may now name a different card.
3. **No stale ids.** A manifest id that never appears in the run stops
   the build, so a title cannot silently go missing.

## Rules the author holds (not machine-checked here)

* 26 characters or fewer, so the card header stays on one line. This is
  the measured header budget and matches the diagram engine's
  `wrap(title, 26, 3)`.
* One to four words, Title Case, naming what the card teaches.
* Unique within the chapter, and never a collision with an existing base
  title in the same manual.
* Honest: drawn from that card's body only, never invented.
* No em dash and no en dash (repo UX no-em-dash law).

`test/barrio_training_card_title_guard_test.dart` enforces the first
three of these over the generated content.

## Workflow

```
python tool/barrio_training_content_generator.py
python tool/barrio_training_verbatim_check.py   # lost=0w is mandatory
flutter test test/barrio_training_card_title_guard_test.dart
```

New title words count as `gained`, which is legal. Any `lost` words
means a source heading was replaced: revert the entry.
