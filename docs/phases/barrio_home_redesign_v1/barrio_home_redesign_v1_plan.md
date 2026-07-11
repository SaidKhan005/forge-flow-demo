# Barrio Home Redesign V1 + Full Corpus Coverage

Status: ACTIVE 2026-07-11 (operator-directed Barrio carve-out, same
authority as BSP.* and the training-bubble slices).

Operator directive: add the 5 remaining knowledge-graph manuals to the
app word-for-word, AND reorganize the Barrio home screen: with 19
training destinations the orbit-bubble hub no longer works as the sole
organization. Research current mobile learning-hub layout patterns and
implement a better home screen. **Scope limit: home screen UX only.**
Inner training surfaces (`TrainingDocScreen`, curated legacy screens)
do not change.

## Non-goals

- No changes to `TrainingDocScreen` or any destination screen body.
- No auth/permission changes (B18 resolver wiring stays as-is).
- No El Podio / role-preview unhide (BSP.2 flags stay false).
- No deletion of the bubble hub widget; the home screen stops
  composing it (file stays for reversal, same doctrine as the curated
  content screens).

## Category model (binding for both waves)

`BarrioCategory` enum on `BarrioDestination` (new required field):

| category | destinations |
|---|---|
| `product` | forge_and_flow |
| `serviceHospitality` | training_strong_foundation, training_table_manicuring, training_three_pillars, training_suggestive_selling |
| `foodAndDrink` | training_tequila, training_coffee, training_latin_dishes, training_latin_ingredients, training_menu_concept |
| `numbersAndLabor` | jim_taylor_labor_model, training_labour_cost, training_bold_by_design, training_mastering_metrics, preston_lee_model |
| `companyAndCompliance` | company_handbook, interview_playbook, training_food_safety, training_cheers_responsibility, training_general_words, supervisor_content |

Operator-facing section titles (no em dash law):
Service & Hospitality / Food & Drink / Running the Numbers /
Company & Compliance. Forge & Flow renders as the primary product
entry, not inside a training section.

## New verbatim destinations (Wave 1 content lane)

| source manual | id | label | kind |
|---|---|---|---|
| Bold By Design.md | training_bold_by_design | Bold By Design | prose |
| food safety manual.md | training_food_safety | Food Safety | prose |
| OE Cheers to Responsibility.md | training_cheers_responsibility | Responsible Service | prose |
| OE MASTERING THE METRICS.md | training_mastering_metrics | Mastering Metrics | prose |
| GENERAL WORDS TO KNOW.md | training_general_words | Words To Know | glossary |

Same generator + verbatim gates as PR #1451/#1452: programmatic
word-sequence diff must show 0 source words lost per doc; additions
limited to navigation scaffold; no U+2014 in any operator-facing
string; generator committed to `tool/` for reproducibility.

## Waves

- **Wave 1 (parallel):**
  - Lane R (research, read-only): 2025/2026 mobile learning-hub home
    screen patterns; deliver a ranked recommendation fitting Barrio's
    constraints (dark premium photo background, Playfair/IBM Plex, 20
    destinations in 5 categories, honest metrics, static motion).
  - Lane C (content, worktree -> PR -> STOP): 5 verbatim conversions +
    category field + registry/destinations/routes/icons/accents +
    tests.
- **Wave 2 (after Wave 1 merges):**
  - Lane H (home screen, worktree -> PR -> STOP): implement the new
    home screen composition per Lane R findings + this category model.
    Only `barrio_home_screen.dart` + new home widgets (+ tests).

## Acceptance

1. All 18 corpus manuals have an in-app surface; word-for-word
   verification passes 0-lost on all of them.
2. Home screen organizes all destinations by the category model with
   the Forge & Flow product entry prominent; every destination
   reachable in at most 2 interactions; renders clean on a 390x844
   phone viewport; no RenderFlex overflows.
3. Barrio test battery green; `dart analyze` clean; pre-push lints
   (incl. complexity ratchet) clean.
4. BSP flags, B18 wiring, demo-mode doctrine untouched.
