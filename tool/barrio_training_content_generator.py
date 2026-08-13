"""Generate Barrio verbatim training content Dart files from knowledge-graph markdown.

Usage: run from the repo root with `python tool/barrio_training_content_generator.py`.
Rewrites every file listed in DOCS under lib/internal/barrio/content/training/;
regeneration must be byte-identical unless a source markdown changed. Verify
word-for-word fidelity afterwards with `python tool/barrio_training_verbatim_check.py`.

Add `--check` to render every file in memory and compare it to what is on
disk without writing anything; it exits non-zero if a real run would change
a committed file. That is the drift guard the pre-push hook runs, and the
standing acceptance test for this generator: on a clean checkout, a run
must leave `git status --porcelain` empty.

Curation of the pictures rides two manifests next to this file, never a
hand edit of the generated Dart: barrio_training_diagrams_manifest.json
adds or replaces images, barrio_training_image_removals.json records the
extracted photos curation deliberately dropped. Both hard-stop on a stale
entry rather than silently skipping it.

Body text is carried word-for-word from the source markdown. Markdown syntax
markers (heading #, bold **, italic wrappers, code fences, list dashes kept)
are formatting, not words; headings become card/chapter titles.

Image markers (`![optional caption](assets/internal/barrio/training/...)`,
inserted by tool/barrio_training_image_extractor.py) are formatting too, not
words: each becomes a HandbookUnitImage on its unit with `afterParagraph` =
the 0-based index of the blank-line-separated paragraph of the emitted unit
body after which the image sits (-1 = before the first paragraph).
"""
import json, re, os, sys, textwrap

KG = 'docs/Knowledge_graph_docs'
OUT = 'lib/internal/barrio/content/training'

# Hand-authored pictograms/diagrams, keyed by the FINAL (post-split) unit
# id (`<doc_id>_c<chapter>_u<unit>`). These are not embedded in any source
# PDF/PPTX, so they ride a manifest instead of the image extractor. Each
# value is a list of {assetPath, caption, afterParagraph}; the generator
# appends them to that unit's images exactly like extracted photos, so the
# body text stays byte-identical (verbatim check still passes). See
# docs plan / CLAUDE.md operator sign-off 2026-07-26.
_DIAGRAM_MANIFEST_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    'barrio_training_diagrams_manifest.json')
DIAGRAM_IMAGES = {}
if os.path.exists(_DIAGRAM_MANIFEST_PATH):
    with open(_DIAGRAM_MANIFEST_PATH, encoding='utf-8') as _mf:
        DIAGRAM_IMAGES = json.load(_mf)

# Hand-authored CONTINUATION-card titles, keyed by the same FINAL
# (post-split) unit id. A split section's cards 2..N are titled
# '<heading> (cont.)' by default, which tells the reader nothing about
# what that particular card teaches. This manifest lets an authored
# title replace it. Entry shape:
#
#     "<unit_id>": {"was": "<title the generator would emit>",
#                   "title": "<the informative title>"}
#
# `was` is a drift tripwire, not decoration: unit ids shift whenever a
# source doc or a split constant changes, and a silent mismatch would
# land an authored title on the wrong card. See the guards in
# card_title_for / check_card_title_manifest below, and
# tool/barrio_training_card_titles.README.md for the authoring rules.
# The file is a pure {unit_id: entry} map with NO documentation keys:
# every key is checked against the run, so a stray '_README' key would
# have to be special-cased and that exemption is exactly the hole a
# future typo would fall through.
_CARD_TITLES_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    'barrio_training_card_titles.json')
CARD_TITLES = {}
if os.path.exists(_CARD_TITLES_PATH):
    with open(_CARD_TITLES_PATH, encoding='utf-8') as _tf:
        CARD_TITLES = json.load(_tf)

# Manifest unit ids actually reached during this run (see
# check_card_title_manifest).
_CARD_TITLES_SEEN = set()

# Extracted images the curation deliberately DROPPED, keyed by the same
# FINAL (post-split) unit id. Entry shape:
#
#     "<unit_id>": {"drop": ["assets/.../latin_american_dishes/01.webp"],
#                   "reason": "<why the card no longer shows it>"}
#
# WHY THIS EXISTS AS ITS OWN FILE. The diagram manifest already carries a
# "replace": true flag that drops a unit's extracted images. That flag
# lives ON the replacement entry, so re-pointing the replacement at a new
# asset silently takes the drop instruction with it. That is exactly what
# happened: PR #1534 rewrote 44 Latin dishes/ingredients entries to the
# new *_photos/ assets and lost "replace": true on all 44, so the next
# clean generator run resurrected 44 culled extractor photos (+206 lines)
# over curated content. Recording the DROP separately from the
# REPLACEMENT means editing one can never quietly undo the other.
#
# Same tripwire posture as the card-title manifest: every listed path must
# still be emitted by the extractor for that unit, every unit id must be
# reached, and a removal may never leave a card with no image at all. A
# stale entry is a hard stop, never a silent skip. See
# drop_extracted_images / check_image_removal_manifest below and
# tool/barrio_training_image_removals.README.md for the authoring rules.
# Pure {unit_id: entry} map with NO documentation keys, for the same
# reason as the card-title manifest.
_IMAGE_REMOVALS_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    'barrio_training_image_removals.json')
IMAGE_REMOVALS = {}
if os.path.exists(_IMAGE_REMOVALS_PATH):
    with open(_IMAGE_REMOVALS_PATH, encoding='utf-8') as _rf:
        IMAGE_REMOVALS = json.load(_rf)

# Removal manifest unit ids actually reached during this run (see
# check_image_removal_manifest).
_IMAGE_REMOVALS_SEEN = set()

DOCS = [
    dict(md='Barrio Building A Strong Foundation.md', id='training_strong_foundation',
         const='kTrainingStrongFoundation', title='Building A Strong Foundation', kind='prose'),
    dict(md='Barrio Table Maintenance and Manicuring.md', id='training_table_manicuring',
         const='kTrainingTableManicuring', title='Elevate Your Table Maintenance To Table Manicuring', kind='prose'),
    dict(md='Barrio The Three Pillars of Hospitality.md', id='training_three_pillars',
         const='kTrainingThreePillars', title='The Three Pillars Of Hospitality', kind='prose'),
    dict(md='OE Leveraging Suggestive Selling Techniques.md', id='training_suggestive_selling',
         const='kTrainingSuggestiveSelling', title='Leveraging Suggestive Selling Techniques', kind='prose'),
    dict(md='Tequila Training.md', id='training_tequila',
         const='kTrainingTequila', title='Tequila Training', kind='prose'),
    dict(md='Coffee Training.md', id='training_coffee',
         const='kTrainingCoffee', title='Coffee Training', kind='prose'),
    # Manual-drop slice (2026-08-06): the operator wine manual, sitting with
    # its Food & Drink neighbours Tequila and Coffee.
    dict(md='Barrio Wine Training.md', id='training_wine',
         const='kTrainingWine', title='Wine Training', kind='prose'),
    dict(md='Latin American Dishes.md', id='training_latin_dishes',
         const='kTrainingLatinDishes', title='Latin American Words To Know: Dishes', kind='glossary'),
    dict(md='Latin American Ingredients.md', id='training_latin_ingredients',
         const='kTrainingLatinIngredients', title='Latin American Words To Know: Ingredients', kind='glossary'),
    dict(md='Labour Cost - understanding the levers.md', id='training_labour_cost',
         const='kTrainingLabourCost', title='Understanding Labour Cost & Operational Balance', kind='prose'),
    dict(md='Barrio_Legado_Menu_Concept_Slides_4.md', id='training_menu_concept',
         const='kTrainingMenuConcept', title='Barrio Legado Menu Concept Slides', kind='slides'),
    # Operator curation 2026-07-11: the routed MENU doc is the operator's
    # dinner menu plus the deck's history/info slides (1-18, 25); the
    # full deck above stays generated but is parked unrouted (slides
    # 19-24, lunch/bar/desserts, hidden per directive).
    dict(md='Barrio_Menu.md', id='training_menu_concept',
         const='kTrainingMenu', title='MENU', kind='prose',
         out='training_menu_content.dart'),
    # Verbatim rebuilds of the legacy curated bubbles (operator directive
    # 2026-07-11: everything word-for-word). Ids match the existing
    # destinations; out-file names avoid the curated content file names.
    dict(md='Barrio_company_handbook.md', id='company_handbook',
         const='kTrainingCompanyHandbook', title='Barrio Company Handbook',
         kind='prose', out='company_handbook_verbatim_content.dart'),
    dict(md='Barrio_interview_playbook.md', id='interview_playbook',
         const='kTrainingInterviewPlaybook', title='Barrio Interview Playbook',
         kind='prose', out='interview_playbook_verbatim_content.dart'),
    dict(md='jim_taylor_labor_model_deep_dive.md', id='jim_taylor_labor_model',
         const='kTrainingJimTaylor', title='How the Metrics Actually Work',
         kind='prose', out='jim_taylor_verbatim_content.dart'),
    # Corpus-complete slice (2026-07-11): the remaining 5 knowledge-graph
    # training documents, one bubble each.
    # Structure pass (2026-07-26, operator-approved): BOLD By Design is
    # optional-depth material, not core training; the doc carries an
    # honest depth-framing badge word (operator-approved) shown to the
    # reader in the doc header.
    dict(md='Bold By Design.md', id='training_bold_by_design',
         const='kTrainingBoldByDesign', title='BOLD By Design', kind='prose',
         depth='DEEPER DIVE'),
    dict(md='food safety manual.md', id='training_food_safety',
         const='kTrainingFoodSafety', title='Food Safety Manual', kind='prose'),
    dict(md='OE Cheers to Responsibility.md', id='training_cheers_responsibility',
         const='kTrainingCheersResponsibility',
         title='Responsible Alcohol Service In NL', kind='prose'),
    dict(md='OE MASTERING THE METRICS.md', id='training_mastering_metrics',
         const='kTrainingMasteringMetrics', title='Mastering The Metrics',
         kind='prose'),
    dict(md='GENERAL WORDS TO KNOW.md', id='training_general_words',
         const='kTrainingGeneralWords', title='General Words To Know',
         kind='glossary'),
    # SOP training manuals (Scribe-format point-of-sale + scheduling docs).
    dict(md='Clover SOP.md', id='training_clover_sop',
         const='kTrainingCloverSop', title='Clover POS', kind='prose'),
    dict(md='Push Employee SOP.md', id='training_push_sop',
         const='kTrainingPushSop', title='Push Schedule', kind='prose'),
    # Manual-drop slice (2026-07-28): host, bar, and combined drink-spec
    # training manuals from operator PDFs.
    dict(md='Barrio Host Manual.md', id='training_host_manual',
         const='kTrainingHostManual', title='Host Manual', kind='prose'),
    dict(md='Bar Manual.md', id='training_bar_manual',
         const='kTrainingBarManual', title='Bar Manual', kind='prose'),
    dict(md='Barrio Drink Specs.md', id='training_drink_specs',
         const='kTrainingDrinkSpecs', title='Drink Specs', kind='prose'),
    # Manual-drop slice (2026-08-13): the operator's kitchen recipes, one
    # chapter per recipe, sitting with their Food & Drink neighbours.
    dict(md='Barrio Recipes.md', id='training_recipes',
         const='kTrainingRecipes', title='Recipes', kind='prose'),
]

CHAPTER_ICON = '0xe865'  # Icons.menu_book glyph, used by the chapter rail

# --- Structure pass (operator-approved 2026-07-26) ------------------------
# Presentation metadata only: bodies, card order, and card titles are
# untouched; the verbatim gate (lost=0w) still binds every doc. All
# section/part NAMES below are operator-approved.
#
# CHAPTER_MERGES: contiguous parsed-chapter ranges (0-based, inclusive)
# merged into one rail section each. The merged section takes the
# operator-approved name; the original per-chapter heading words survive
# verbatim as the card titles inside the section. Ranges must cover every
# parsed chapter exactly once, in order; the generator fails loudly on
# drift so a source markdown change forces a deliberate table update.
CHAPTER_MERGES = {
    # OE Cheers to Responsibility: 24 parsed chapters (18 of them 1-card)
    # fragment the rail; consolidated into 5 thematic sections. Every
    # original chapter heading survives verbatim as a card title inside
    # its section (that is why the verbatim gate still reports lost=0w).
    'training_cheers_responsibility': [
        (0, 4, 'Governing Bodies and Licenses'),
        (5, 9, 'Drinks, Intoxication, and ID'),
        (10, 14, 'Alcohol Combinations and Binge Drinking'),
        (15, 18, 'Serving Decisions and Liability'),
        (19, 23, 'Premises Rules, Hours, and Pricing'),
    ],
}

# CHAPTER_PARTS: chapters stay separate; each contiguous range (0-based,
# inclusive, over the FINAL chapter list) is annotated with an additive
# optional partTitle/partIndex/partCount the reader sees as part
# separators. Same full-coverage validation as CHAPTER_MERGES.
CHAPTER_PARTS = {
    # BOLD By Design: 34 chapters grouped into 5 named parts.
    'training_bold_by_design': [
        (0, 6, 'The Foundations'),
        (7, 13, 'Understanding Productivity'),
        (14, 21, 'Managing Productivity'),
        (22, 26, 'Building the Productivity System'),
        (27, 33, 'Leading for the Long Term'),
    ],
}


def _check_ranges(doc_id, table, n_chapters, what):
    """Ranges must tile 0..n_chapters-1 exactly, in order."""
    expect = 0
    for lo, hi, title in table:
        if lo != expect or hi < lo or hi >= n_chapters:
            raise SystemExit(
                f'{doc_id}: {what} range ({lo},{hi},{title!r}) does not fit '
                f'{n_chapters} chapters (next uncovered index {expect}); '
                f'update the grouping table for the changed source.')
        expect = hi + 1
    if expect != n_chapters:
        raise SystemExit(
            f'{doc_id}: {what} table covers {expect} of {n_chapters} '
            f'chapters; update the grouping table for the changed source.')


def apply_merges(doc_id, chapters):
    """Merge parsed chapters per CHAPTER_MERGES; unlisted docs unchanged.

    Runs BEFORE unit splitting, on parsed (title, units) chapters; the
    merged section's subtitle is recomputed downstream ('N cards').
    """
    table = CHAPTER_MERGES.get(doc_id)
    if not table:
        return chapters
    _check_ranges(doc_id, table, len(chapters), 'merge')
    out = []
    for lo, hi, title in table:
        units = []
        for ci in range(lo, hi + 1):
            units.extend(chapters[ci][1])
        out.append((title, units))
    return out


def parts_for(doc_id, chapters):
    """Per-chapter (partIndex, partCount, partTitle) list, or None."""
    table = CHAPTER_PARTS.get(doc_id)
    if not table:
        return None
    _check_ranges(doc_id, table, len(chapters), 'part')
    part_of = [None] * len(chapters)
    for pi, (lo, hi, title) in enumerate(table, start=1):
        for ci in range(lo, hi + 1):
            part_of[ci] = (pi, len(table), title)
    return part_of


# Image markers inserted by tool/barrio_training_image_extractor.py.
IMG_MARKER_RE = re.compile(
    r'^!\[([^\]]*)\]\((assets/internal/barrio/training/[^)]+)\)$')


def body_and_images(lines):
    """Split image markers out of raw unit lines.

    Returns (body_text, images) with images = [(asset_path, caption, after)].
    `after` is the afterParagraph index: the number of blank-line-separated
    paragraphs the emitted body has above the marker, minus 1. So -1 means
    the image renders before the first paragraph, 0 after the first, etc.
    """
    clean, images = [], []
    for ln in lines:
        m = IMG_MARKER_RE.match(ln.strip())
        if m:
            before = blocks_to_body(clean)
            n = len([p for p in before.split('\n\n') if p.strip()]) if before.strip() else 0
            images.append((m.group(2), m.group(1).strip() or None, n - 1))
            continue
        clean.append(ln)
    return blocks_to_body(clean), images


def load_md(name):
    text = open(os.path.join(KG, name), encoding='utf-8').read()
    text = re.sub(r'\A---\n.*?\n---\n', '', text, flags=re.S)  # front matter
    # drop the Table of Contents heading + its list lines
    text = re.sub(r'^## Table of Contents\n(?:[ \t]*- .*\n|\n)*', '', text, flags=re.M)
    return text


def clean_inline(s):
    # Strip paired emphasis markers only. Bold (**...**) markers come in
    # pairs, so removing every '**' is safe. Italic uses single '*', but a
    # lone unpaired '*' is a literal glyph the source author typed (a footnote
    # marker, or 'Cactus *' on the dinner menu) and MUST survive verbatim, so
    # we strip only *paired* single asterisks and leave any lone '*' in place.
    s = s.replace('**', '').replace('`', '')
    s = re.sub(r'\*([^*\n]+)\*', r'\1', s)
    m = re.fullmatch(r'_(.+)_', s.strip())
    if m:
        s = m.group(1)
    return s


def blocks_to_body(lines):
    """Turn raw markdown lines into verbatim body text with real newlines."""
    out = []
    para = []
    in_fence = False

    def flush():
        if para:
            out.append(' '.join(para))
            para.clear()

    for ln in lines:
        if ln.strip().startswith('```'):
            flush()
            in_fence = not in_fence
            continue
        if in_fence:
            out.append(ln.rstrip())
            continue
        if not ln.strip():
            flush()
            continue
        if re.match(r'^\s*\|', ln):
            # Table row: keep the row's words on one line, cells separated by
            # the original pipe; drop dash-only alignment rows (no words).
            flush()
            cells = [c.strip() for c in ln.strip().strip('|').split('|')]
            if all(re.fullmatch(r':?-{2,}:?', c) for c in cells if c):
                continue
            out.append(' | '.join(clean_inline(c) for c in cells if c))
            continue
        m4 = re.match(r'^#{4,6} (.*)', ln)
        if m4:
            # Deep sub-heading: its words stay in the body as their own line.
            flush()
            out.append(clean_inline(m4.group(1)).strip())
            continue
        # List item: dash bullets and numbered steps ('1. ', '2. ', ...) each
        # keep their own line so numbered procedures ('1. Call 911' ...) render
        # as discrete steps instead of collapsing into one run-on paragraph.
        if re.match(r'^\s*(?:- |\d+\. )', ln):
            flush()
            out.append(clean_inline(ln.rstrip()))
            continue
        para.append(clean_inline(ln.strip()))
    flush()
    return '\n\n'.join(out)


def parse_prose(text, doc_title):
    """Chapters at ##, units at ### (pre-### text = unit titled by the chapter)."""
    lines = text.split('\n')
    chapters = []      # (title, [(unit_title, body_lines)])
    cur_chap = None    # [title, units]
    cur_unit = None    # [title, lines]
    intro_lines = []

    def close_unit():
        nonlocal cur_unit
        if cur_unit is not None and any(l.strip() for l in cur_unit[1]):
            cur_chap[1].append((cur_unit[0], cur_unit[1]))
        cur_unit = None

    def close_chap():
        nonlocal cur_chap
        close_unit()
        if cur_chap is not None and cur_chap[1]:
            chapters.append((cur_chap[0], cur_chap[1]))
        cur_chap = None

    for ln in lines:
        m2 = re.match(r'^## (.*)', ln)
        m3 = re.match(r'^### (.*)', ln)
        m1 = re.match(r'^# (.*)', ln)
        if m1:
            continue  # doc H1 = doc title, already carried on the screen hero
        if m2:
            close_chap()
            cur_chap = [clean_inline(m2.group(1)).strip(), []]
            cur_unit = [cur_chap[0], []]
            continue
        if m3 and cur_chap is not None:
            close_unit()
            cur_unit = [clean_inline(m3.group(1)).strip(), []]
            continue
        if cur_chap is None:
            intro_lines.append(ln)
        else:
            cur_unit[1].append(ln)
    close_chap()

    result = []
    intro_body = blocks_to_body(intro_lines)
    if intro_body.strip():
        result.append((doc_title, [(doc_title, intro_lines)]))
    result.extend(chapters)
    return result


def parse_glossary(text):
    """One unit per '- **TERM:** definition' bullet; nested lines appended."""
    entries = []   # [term, body_lines, images]
    cur = None
    for ln in text.split('\n'):
        mi = IMG_MARKER_RE.match(ln.strip())
        if mi:
            if cur:
                # Glossary bodies render as one paragraph (single newlines).
                after = 0 if any(l for l in cur[1] if l) else -1
                cur[2].append((mi.group(2), mi.group(1).strip() or None, after))
            continue
        m = re.match(r'^- \*\*(.+?):?\*\*:?\s*(.*)', ln)
        if m:
            if cur:
                entries.append(cur)
            term = m.group(1).rstrip(':')
            cur = [term, [m.group(2).strip()], []]
            continue
        m_sub = re.match(r'^  - (.*)', ln)
        if m_sub and cur:
            cur[1].append('- ' + clean_inline(m_sub.group(1).strip()))
            continue
        if ln.startswith('#') or not ln.strip():
            continue
        if cur:
            cur[1].append(clean_inline(ln.strip()))
    if cur:
        entries.append(cur)

    # chapters of up to 12 terms; title 'X to Y' from first letters
    chapters = []
    for i in range(0, len(entries), 12):
        group = entries[i:i + 12]
        first, last = group[0][0], group[-1][0]
        title = f'{first[0].upper()} to {last[0].upper()}'
        units = []
        for term, body_lines, images in group:
            body = '\n'.join(l for l in body_lines if l)
            units.append((term, body, images))
        chapters.append((title, units, f'{len(units)} terms'))
    return chapters


def parse_slides(text):
    """Unit per '## Slide N' section; grouped into menu-section chapters."""
    slides = {}
    slide_images = {}
    cur_n = None
    for ln in text.split('\n'):
        m = re.match(r'^## Slide (\d+)', ln)
        if m:
            cur_n = int(m.group(1))
            slides[cur_n] = []
            continue
        if cur_n is None:
            continue
        mi = IMG_MARKER_RE.match(ln.strip())
        if mi:
            # Slide bodies render as one paragraph (single newlines).
            after = 0 if slides[cur_n] else -1
            slide_images.setdefault(cur_n, []).append(
                (mi.group(2), mi.group(1).strip() or None, after))
            continue
        m_item = re.match(r'^- (.*)', ln)
        if m_item:
            slides[cur_n].append(clean_inline(m_item.group(1)))
    groups = [
        (1, 1, 'Barrio Legado'),
        (2, 3, 'The Civilizations'),
        (4, 7, 'Ceviches'),
        (8, 10, 'Shareables'),
        (11, 18, 'Mains'),
        (19, 22, 'Lunch / Brunch'),
        (23, 23, 'Bar Menu'),
        (24, 25, 'Desserts'),
    ]
    chapters = []
    for lo, hi, title in groups:
        units = []
        for n in range(lo, hi + 1):
            if n not in slides:
                continue
            body = '\n'.join(slides[n])
            units.append((f'Slide {n}', body, slide_images.get(n, [])))
        subtitle = f'Slide {lo}' if lo == hi else f'Slides {lo} to {hi}'
        chapters.append((title, units, subtitle))
    return chapters


def esc(s):
    return s.replace('\\', '\\\\').replace("'", "\\'").replace('$', '\\$')


def dart_string(body, indent):
    """Emit body (with real newlines) as adjacent single-quoted Dart strings."""
    pad = ' ' * indent
    body_lines = body.split('\n')
    segs = []
    for li, line in enumerate(body_lines):
        pieces = textwrap.wrap(line, width=62, break_long_words=False,
                               break_on_hyphens=False) or ['']
        for pi, piece in enumerate(pieces):
            tail_space = pi < len(pieces) - 1
            tail_nl = (not tail_space) and li < len(body_lines) - 1
            segs.append(esc(piece) + (' ' if tail_space else '') +
                        ('\\n' if tail_nl else ''))
    return ('\n' + pad).join(f"'{s}'" for s in segs)


def card_title_for(unit_id, computed_title, run_idx):
    """Title to emit for one card: the manifest override, or the computed one.

    Same posture as _check_ranges: a manifest that no longer lines up with
    the parsed source is a hard stop, never a silent skip.

      * run-start guard - only continuation cards (runIndex > 1) may be
        retitled. The first card of a run carries the verbatim source
        heading, and tool/barrio_training_verbatim_check.py only passes at
        lost=0w, so replacing that heading would delete source words.
      * drift tripwire - the computed title must equal the entry's `was`.
        Unit ids shift when a source doc or a split constant changes, so
        an id that still resolves but now names a different card would
        otherwise land an authored title on the wrong content.
    """
    entry = CARD_TITLES.get(unit_id)
    if entry is None:
        return computed_title
    _CARD_TITLES_SEEN.add(unit_id)
    if run_idx <= 1:
        raise SystemExit(
            f'{unit_id}: card-title manifest entry targets the FIRST card '
            f'of a run (runIndex {run_idx}); only continuation cards may be '
            f'retitled, because the first card carries the verbatim source '
            f'heading. Move the entry to the right unit id or drop it.')
    if computed_title != entry['was']:
        raise SystemExit(
            f'{unit_id}: card-title manifest drift. Expected `was` '
            f'{entry["was"]!r} but the generator computed '
            f'{computed_title!r}; unit ids shift when a source doc or a '
            f'split constant changes. Re-point the entry at the card it '
            f'was authored for before regenerating.')
    return entry['title']


def check_card_title_manifest():
    """Every manifest unit id must have been reached by this run."""
    missing = sorted(set(CARD_TITLES) - _CARD_TITLES_SEEN)
    if missing:
        raise SystemExit(
            f'card-title manifest: {len(missing)} unit id(s) never appeared '
            f'in this run: {", ".join(missing)}. Unit ids shift when a '
            f'source doc or a split constant changes; re-point or drop each '
            f'stale entry (a title silently going missing is the failure '
            f'this guard exists to prevent).')


def drop_extracted_images(unit_id, u_images):
    """Extracted images for one card, minus the ones curation dropped.

    Same posture as card_title_for: a manifest that no longer lines up
    with the parsed source is a hard stop, never a silent skip.

      * drift tripwire - every path listed under `drop` must actually be
        emitted by the extractor for this unit right now. A path that no
        longer appears means the source markdown, the extraction, or the
        unit ids moved, and the entry is describing a card that no longer
        exists. Silently accepting it would let a real photo the operator
        wants disappear the day its unit id shifts onto this entry.
    """
    entry = IMAGE_REMOVALS.get(unit_id)
    if entry is None:
        return u_images
    _IMAGE_REMOVALS_SEEN.add(unit_id)
    present = [p for p, _c, _a in u_images]
    stale = [p for p in entry['drop'] if p not in present]
    if stale:
        raise SystemExit(
            f'{unit_id}: image-removal manifest drift. These path(s) are '
            f'listed for removal but the extractor no longer emits them on '
            f'this card: {", ".join(stale)}. Emitted here now: '
            f'{", ".join(present) or "(none)"}. Unit ids shift when a source '
            f'doc or a split constant changes; re-point or delete the entry '
            f'before regenerating.')
    dropped = set(entry['drop'])
    return [img for img in u_images if img[0] not in dropped]


def check_image_removals_kept_a_picture(unit_id, u_images):
    """A removal may never leave a card with no image at all.

    Every entry in the removal manifest exists because a curated image
    took the dropped photo's place. If that replacement is later deleted
    from the diagram manifest, the removal would silently strip the card
    bare instead of swapping its picture. Stop instead.
    """
    if unit_id in IMAGE_REMOVALS and not u_images:
        raise SystemExit(
            f'{unit_id}: the image-removal manifest dropped this card\'s '
            f'only picture(s) and nothing replaced them, so the card would '
            f'render with no image. Restore the curated replacement in '
            f'tool/barrio_training_diagrams_manifest.json, or delete the '
            f'removal entry if the card is meant to lose its picture.')


def check_image_removal_manifest():
    """Every removal manifest unit id must have been reached by this run."""
    missing = sorted(set(IMAGE_REMOVALS) - _IMAGE_REMOVALS_SEEN)
    if missing:
        raise SystemExit(
            f'image-removal manifest: {len(missing)} unit id(s) never '
            f'appeared in this run: {", ".join(missing)}. Unit ids shift '
            f'when a source doc or a split constant changes; re-point or '
            f'delete each stale entry (a culled photo silently coming back '
            f'is the failure this guard exists to prevent).')


def emit(doc, chapters, part_of=None):
    """chapters: list of (title, units, subtitle?) where units = (title, body).

    part_of: optional per-chapter (partIndex, partCount, partTitle) list
    (see CHAPTER_PARTS); None emits no part fields.
    """
    lines = []
    a = lines.append
    a('// GENERATED VERBATIM TRAINING CONTENT — regenerate, do not hand-edit bodies.')
    a('//')
    a(f'// Source: docs/Knowledge_graph_docs/{doc["md"]}')
    a('// Body text is word-for-word from the source Markdown. Headings become')
    a('// chapter/card titles; markdown syntax markers are formatting, not words,')
    a('// and are omitted. Generated for the 2026-07-11 training-bubble slice.')
    a('//')
    a('// Continuation cards (runIndex > 1) default to the source heading plus')
    a('// " (cont.)". Where tool/barrio_training_card_titles.json carries an')
    a("// entry for the card, its authored title is emitted instead, naming what")
    a('// that card teaches. Body text is untouched either way.')
    a('')
    a("import '../company_handbook_content.dart';")
    a("import 'barrio_training_doc.dart';")
    a('')
    a(f'const BarrioTrainingDoc {doc["const"]} = BarrioTrainingDoc(')
    a(f"  id: '{doc['id']}',")
    a(f"  title: '{esc(doc['title'])}',")
    a(f"  sourcePath: 'docs/Knowledge_graph_docs/{esc(doc['md'])}',")
    if doc.get('depth'):
        a(f"  depthBadge: '{esc(doc['depth'])}',")
    a('  chapters: [')
    for ci, chap in enumerate(chapters):
        if len(chap) == 3:
            ch_title, units, subtitle = chap
        else:
            ch_title, units = chap
            n = len(units)
            subtitle = f'{n} card{"" if n == 1 else "s"}'
        a('    HandbookChapter(')
        a(f"      id: '{doc['id']}_c{ci}',")
        a(f"      title: '{esc(ch_title)}',")
        a(f"      subtitle: '{esc(subtitle)}',")
        if part_of is not None and part_of[ci] is not None:
            p_idx, p_count, p_title = part_of[ci]
            a(f"      partTitle: '{esc(p_title)}',")
            a(f'      partIndex: {p_idx},')
            a(f'      partCount: {p_count},')
        a(f'      iconCodePoint: {CHAPTER_ICON},')
        a('      units: [')
        for ui, unit in enumerate(units):
            run_idx, run_len = 1, 1
            if len(unit) == 5:
                u_title, u_body, u_images, run_idx, run_len = unit
            elif len(unit) == 3:
                u_title, u_body, u_images = unit
            else:
                u_title, u_body = unit
                u_images = []
            if isinstance(u_body, list):
                u_body, u_images = body_and_images(u_body)
            # Inject hand-authored diagrams for this exact card. Default is to
            # APPEND the manifest image(s) after the unit's extracted images.
            # If ANY manifest entry for this unit sets "replace": true, the
            # manifest image(s) REPLACE the extracted image(s) entirely (the
            # extractor's photos for this unit are dropped) — used to swap out
            # an inaccurate/off-brand extracted photo with an accurate one.
            unit_id = f"{doc['id']}_c{ci}_u{ui}"
            # Extracted photos curation deliberately dropped come out
            # BEFORE the manifest injection below, so the drop is recorded
            # independently of whatever replacement is wired today.
            u_images = drop_extracted_images(unit_id, u_images)
            if unit_id in DIAGRAM_IMAGES:
                manifest_images = [
                    (e['assetPath'], e.get('caption'), e['afterParagraph'])
                    for e in DIAGRAM_IMAGES[unit_id]
                ]
                if any(e.get('replace') for e in DIAGRAM_IMAGES[unit_id]):
                    u_images = manifest_images
                else:
                    u_images = list(u_images) + manifest_images
            check_image_removals_kept_a_picture(unit_id, u_images)
            # Authored continuation-card titles ride the same unit id as the
            # diagram manifest above; guards live in card_title_for.
            u_title = card_title_for(unit_id, u_title, run_idx)
            badge = {'prose': 'READ', 'glossary': 'TERM', 'slides': 'SLIDE'}[doc['kind']]
            a('        HandbookUnit(')
            a(f"          id: '{doc['id']}_c{ci}_u{ui}',")
            a('          type: HandbookUnitType.explainer,')
            a(f"          badgeHint: '{badge}',")
            a(f"          title: '{esc(u_title)}',")
            a(f'          body: {dart_string(u_body, 14)},')
            if run_len > 1:
                a(f'          runIndex: {run_idx},')
                a(f'          runLength: {run_len},')
            if u_images:
                a('          images: [')
                for img_path, img_caption, img_after in u_images:
                    a('            HandbookUnitImage(')
                    a(f"              assetPath: '{esc(img_path)}',")
                    if img_caption:
                        a(f"              caption: '{esc(img_caption)}',")
                    a(f'              afterParagraph: {img_after},')
                    a('            ),')
                a('          ],')
            a('        ),')
        a('      ],')
        a('    ),')
    a('  ],')
    a(');')
    a('')
    return '\n'.join(lines)


# --- Digestible-card splitting -------------------------------------------
# A single card carrying 400+ words is a wall of text to swipe through. Any
# over-long unit is split into multiple cards at blank-line paragraph
# boundaries (never mid-paragraph, so words stay verbatim and in order),
# aiming for ~SPLIT_WORD_TARGET words per card. On top of that budget, a
# hard cap holds: no emitted card may exceed SPLIT_CARD_HARD_MAX
# whitespace-separated words. A card still over the cap splits further at
# paragraph boundaries; a single over-cap paragraph splits at sentence
# boundaries into balanced pieces (operator-authorized 2026-07-21) — every
# word kept, original order, only break points chosen. Images ride along to
# the card that holds the paragraph they were anchored to. Continuation
# cards reuse the source title with a ' (cont.)' suffix (never doubled).
SPLIT_WORD_MIN = 200     # units at or below this are never split
SPLIT_WORD_TARGET = 150  # target words per card once splitting
SPLIT_WORD_MAX = 210     # close a card before a paragraph that would overflow
SPLIT_CARD_HARD_MAX = 200  # absolute per-card cap in whitespace-separated words


def word_count(s):
    return len(re.findall(r'[A-Za-z0-9]+', s))


def audit_word_count(s):
    """Whitespace-token count — the measure card-length audits use."""
    return len(s.split())


# A sentence ends at '.', '!' or '?' (plus any closing quote/paren), then
# whitespace, then an uppercase letter, digit, or opening quote. Common
# abbreviations (Mr., Dr., e.g., a.m., single initials like 'J.') do not
# end a sentence; skipping a real boundary is safe (fewer break points),
# inventing one inside an abbreviation is not.
_SENT_BOUNDARY_RE = re.compile(r'''[.!?]['")\]”]*\s+''')
_SENT_NEXT_RE = re.compile(r'''[A-Z0-9"'(“‘]''')
_SENT_ABBREV_RE = re.compile(
    r'\b(?:Mr|Mrs|Ms|Dr|St|No|vs|etc|approx|Inc|Ltd|Co|'
    r'e\.g|i\.e|a\.m|p\.m|U\.S|[A-Z])\.$')


def sentence_starts(text):
    """Offsets where a new sentence starts inside a paragraph."""
    starts = []
    for m in _SENT_BOUNDARY_RE.finditer(text):
        if not _SENT_NEXT_RE.match(text[m.end():m.end() + 1]):
            continue
        if _SENT_ABBREV_RE.search(text[:m.start() + 1]):
            continue
        starts.append(m.end())
    return starts


def balanced_groups(weights, cap):
    """Split a weight list into contiguous runs: the fewest roughly-even
    groups whose sums stay at or under cap (when item sizes allow)."""
    total = sum(weights)
    n_items = len(weights)
    prefix, cum = [], 0
    for w in weights:
        cum += w
        prefix.append(cum)
    n_groups = max(2, -(-total // cap))
    while True:
        cuts = sorted({min(range(n_items - 1),
                           key=lambda i: abs(prefix[i] - total * k / n_groups))
                       for k in range(1, n_groups)})
        runs, prev = [], 0
        for c in cuts:
            runs.append((prev, c))
            prev = c + 1
        runs.append((prev, n_items - 1))
        worst = max(sum(weights[gs:ge + 1]) for gs, ge in runs)
        if worst <= cap or n_groups >= n_items:
            if worst > cap:
                print(f'  !! balanced_groups: a single item exceeds the '
                      f'{cap}-word cap (worst run {worst}w)')
            return runs
        n_groups += 1


def split_long_paragraph(para):
    """Sentence-split one over-cap paragraph into balanced <= cap pieces,
    every word kept in order. Returns [para] (and reports) when no sentence
    boundary can be found."""
    starts = sentence_starts(para)
    if not starts:
        print(f'  !! no sentence boundary in {audit_word_count(para)}-word '
              f'paragraph; left whole: {para[:70]!r}')
        return [para]
    bounds = [0] + starts + [len(para)]
    sents = [para[bounds[i]:bounds[i + 1]] for i in range(len(bounds) - 1)]
    groups = balanced_groups([audit_word_count(x) for x in sents],
                             SPLIT_CARD_HARD_MAX)
    # Slicing at sentence-start offsets keeps every internal character
    # (including single-newline line breaks); only the whitespace at the
    # chosen cut is trimmed from each piece's tail.
    return [''.join(sents[gs:ge + 1]).rstrip() for gs, ge in groups]


def normalize_unit(unit):
    """Coerce any unit shape into (title, body_str, images)."""
    if len(unit) == 3:
        u_title, u_body, u_images = unit
    else:
        u_title, u_body = unit
        u_images = []
    if isinstance(u_body, list):
        u_body, u_images = body_and_images(u_body)
    return u_title, u_body, u_images


def split_unit(u_title, u_body, u_images):
    """Return [(title, body, images, runIndex, runLength)] — one card if
    short, else several. Run metadata is honest arithmetic over the split:
    card k of a section split into N cards carries (k, N); an unsplit card
    carries (1, 1)."""
    paras = u_body.split('\n\n')
    # Group paragraphs into contiguous chunks by a word budget: close the
    # current card when it reaches the target, or before adding a paragraph
    # that would push it past the max (so two mid-size paragraphs split
    # rather than pile into one over-long card).
    if word_count(u_body) <= SPLIT_WORD_MIN or len(paras) < 2:
        chunks = [(0, len(paras) - 1)]
    else:
        chunks = []  # (start_idx, end_idx_inclusive)
        start, acc = 0, 0
        for i, p in enumerate(paras):
            w = word_count(p)
            if i > start and acc + w > SPLIT_WORD_MAX:
                chunks.append((start, i - 1))
                start, acc = i, 0
            acc += w
            if acc >= SPLIT_WORD_TARGET and i < len(paras) - 1:
                chunks.append((start, i))
                start, acc = i + 1, 0
        chunks.append((start, len(paras) - 1))

    # Hard-cap pass: any chunk over SPLIT_CARD_HARD_MAX audit words splits
    # further — at paragraph boundaries when it has several paragraphs, at
    # sentence boundaries when a single paragraph itself exceeds the cap.
    # Sentence pieces are atomic: each is emitted as its own card, so the
    # grouping below can never re-merge them into an over-cap card. Chunks
    # already at or under the cap pass through byte-identical.
    cards = []  # each card: [(orig_para_idx, text), ...]
    for s, e in chunks:
        if audit_word_count('\n\n'.join(paras[s:e + 1])) <= SPLIT_CARD_HARD_MAX:
            cards.append([(pi, paras[pi]) for pi in range(s, e + 1)])
            continue
        run = []  # consecutive under-cap (orig_para_idx, text) items

        def flush_run():
            if not run:
                return
            weights = [audit_word_count(t) for _pi, t in run]
            if sum(weights) <= SPLIT_CARD_HARD_MAX or len(run) < 2:
                cards.append(list(run))
            else:
                for gs, ge in balanced_groups(weights, SPLIT_CARD_HARD_MAX):
                    cards.append(run[gs:ge + 1])
            run.clear()

        for pi in range(s, e + 1):
            p = paras[pi]
            if audit_word_count(p) > SPLIT_CARD_HARD_MAX:
                pieces = split_long_paragraph(p)
                if len(pieces) == 1:
                    run.append((pi, p))  # unsplittable: kept whole, reported
                    continue
                flush_run()
                for piece in pieces:
                    cards.append([(pi, piece)])
                continue
            run.append((pi, p))
        flush_run()

    if len(cards) < 2:
        return [(u_title, u_body, u_images, 1, 1)]

    # Images anchored after paragraph k render after that paragraph's final
    # piece, on whichever card holds it (afterParagraph re-based per card).
    last_card_of_para, last_pos_in_card = {}, {}
    for ci, card in enumerate(cards):
        for pos, (pi, _t) in enumerate(card):
            last_card_of_para[pi] = ci
            last_pos_in_card[pi] = pos
    result = []
    for ci, card in enumerate(cards):
        body = '\n\n'.join(t for _pi, t in card)
        imgs = []
        for img_path, img_caption, img_after in u_images:
            if img_after < 0:
                if ci == 0:
                    imgs.append((img_path, img_caption, -1))
            elif last_card_of_para.get(img_after) == ci:
                imgs.append((img_path, img_caption, last_pos_in_card[img_after]))
        if ci == 0 or u_title.endswith(' (cont.)'):
            title = u_title  # first card, or already suffixed: never doubled
        else:
            title = f'{u_title} (cont.)'
        result.append((title, body, imgs, ci + 1, len(cards)))
    return result


def split_chapters(chapters):
    """Normalize + split every unit; refresh any 'N cards' subtitle."""
    out = []
    for chap in chapters:
        if len(chap) == 3:
            ch_title, units, subtitle = chap
        else:
            ch_title, units, subtitle = chap[0], chap[1], None
        new_units = []
        for unit in units:
            new_units.extend(split_unit(*normalize_unit(unit)))
        if subtitle is None or re.fullmatch(r'\d+ cards?', subtitle or ''):
            n = len(new_units)
            subtitle = f'{n} card{"" if n == 1 else "s"}'
        out.append((ch_title, new_units, subtitle))
    return out


def rendered_bytes(out_path, text):
    """`text` encoded with the line endings the checkout already uses.

    The generated files are stored in git with LF, but a Windows clone
    with core.autocrlf=true materializes them as CRLF. Writing LF
    unconditionally therefore left all 24 generated files reported
    modified by `git status` on every run, even the ones whose content
    had not changed by a single character, which buried real drift in
    noise. Match whatever the checkout produced instead: CRLF if the file
    on disk already uses it, LF for a brand new file (and on any platform
    that checks out LF).
    """
    data = text.encode('utf-8')
    if os.path.exists(out_path):
        with open(out_path, 'rb') as f:
            existing = f.read()
        if b'\r\n' in existing:
            data = data.replace(b'\n', b'\r\n')
    return data


def write_generated(out_path, text):
    """Write one generated file. Returns True when the bytes changed.

    An unchanged file is not rewritten at all, so its mtime stays put and
    nothing downstream (git, build caches) sees a phantom edit.
    """
    data = rendered_bytes(out_path, text)
    if os.path.exists(out_path):
        with open(out_path, 'rb') as f:
            if f.read() == data:
                return False
    with open(out_path, 'wb') as f:
        f.write(data)
    return True


def check_generated(out_path, text):
    """Would a real run change this file? Reports without touching it."""
    if not os.path.exists(out_path):
        return True
    with open(out_path, 'rb') as f:
        return f.read() != rendered_bytes(out_path, text)


_ARGS = sys.argv[1:]
CHECK_ONLY = '--check' in _ARGS
_UNKNOWN = [a for a in _ARGS if a != '--check']
if _UNKNOWN:
    raise SystemExit(f'unknown argument(s): {", ".join(_UNKNOWN)}. '
                     f'Usage: barrio_training_content_generator.py [--check]')

if not CHECK_ONLY:
    os.makedirs(OUT, exist_ok=True)
drifted = []
for doc in DOCS:
    text = load_md(doc['md'])
    if doc['kind'] == 'prose':
        chapters = parse_prose(text, doc['title'])
    elif doc['kind'] == 'glossary':
        chapters = parse_glossary(text)
    else:
        chapters = parse_slides(text)
    chapters = apply_merges(doc['id'], chapters)
    chapters = split_chapters(chapters)
    part_of = parts_for(doc['id'], chapters)
    out_path = os.path.join(OUT, doc.get('out', doc['id'] + '_content.dart'))
    emitted = emit(doc, chapters, part_of)
    if CHECK_ONLY:
        changed = check_generated(out_path, emitted)
        if changed:
            drifted.append(out_path)
    else:
        changed = write_generated(out_path, emitted)
    n_units = sum(len(c[1]) for c in chapters)
    if not CHECK_ONLY:
        print(f'{doc["id"]}: {len(chapters)} chapters, {n_units} units '
              f'-> {out_path}{"" if changed else " (unchanged)"}')

check_card_title_manifest()
check_image_removal_manifest()
if CHECK_ONLY:
    if drifted:
        raise SystemExit(
            'barrio content drift: a generator run would change '
            f'{len(drifted)} committed file(s):\n  '
            + '\n  '.join(drifted)
            + '\n\nThe content files under lib/internal/barrio/content/training/'
              ' are generated output. Either the source markdown or a manifest '
              'changed and the files were not regenerated, or a generated file '
              'was hand-edited (curation belongs in '
              'tool/barrio_training_diagrams_manifest.json or '
              'tool/barrio_training_image_removals.json, never in the .dart). '
              'Run: python tool/barrio_training_content_generator.py')
    print(f'barrio content check: all {len(DOCS)} generated file(s) match a '
          f'fresh generator run.')
elif CARD_TITLES:
    print(f'card titles: {len(CARD_TITLES)} continuation card(s) retitled '
          f'from the manifest')
