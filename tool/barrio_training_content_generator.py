"""Generate Barrio verbatim training content Dart files from knowledge-graph markdown.

Usage: run from the repo root with `python tool/barrio_training_content_generator.py`.
Rewrites every file listed in DOCS under lib/internal/barrio/content/training/;
regeneration must be byte-identical unless a source markdown changed. Verify
word-for-word fidelity afterwards with `python tool/barrio_training_verbatim_check.py`.

Body text is carried word-for-word from the source markdown. Markdown syntax
markers (heading #, bold **, italic wrappers, code fences, list dashes kept)
are formatting, not words; headings become card/chapter titles.

Image markers (`![optional caption](assets/internal/barrio/training/...)`,
inserted by tool/barrio_training_image_extractor.py) are formatting too, not
words: each becomes a HandbookUnitImage on its unit with `afterParagraph` =
the 0-based index of the blank-line-separated paragraph of the emitted unit
body after which the image sits (-1 = before the first paragraph).
"""
import re, os, textwrap

KG = 'docs/Knowledge_graph_docs'
OUT = 'lib/internal/barrio/content/training'

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
    dict(md='Bold By Design.md', id='training_bold_by_design',
         const='kTrainingBoldByDesign', title='BOLD By Design', kind='prose'),
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
]

CHAPTER_ICON = '0xe865'  # Icons.menu_book glyph, used by the chapter rail

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


def emit(doc, chapters):
    """chapters: list of (title, units, subtitle?) where units = (title, body)."""
    lines = []
    a = lines.append
    a('// GENERATED VERBATIM TRAINING CONTENT — regenerate, do not hand-edit bodies.')
    a('//')
    a(f'// Source: docs/Knowledge_graph_docs/{doc["md"]}')
    a('// Body text is word-for-word from the source Markdown. Headings become')
    a('// chapter/card titles; markdown syntax markers are formatting, not words,')
    a('// and are omitted. Generated for the 2026-07-11 training-bubble slice.')
    a('')
    a("import '../company_handbook_content.dart';")
    a("import 'barrio_training_doc.dart';")
    a('')
    a(f'const BarrioTrainingDoc {doc["const"]} = BarrioTrainingDoc(')
    a(f"  id: '{doc['id']}',")
    a(f"  title: '{esc(doc['title'])}',")
    a(f"  sourcePath: 'docs/Knowledge_graph_docs/{esc(doc['md'])}',")
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
        a(f'      iconCodePoint: {CHAPTER_ICON},')
        a('      units: [')
        for ui, unit in enumerate(units):
            if len(unit) == 3:
                u_title, u_body, u_images = unit
            else:
                u_title, u_body = unit
                u_images = []
            if isinstance(u_body, list):
                u_body, u_images = body_and_images(u_body)
            badge = {'prose': 'READ', 'glossary': 'TERM', 'slides': 'SLIDE'}[doc['kind']]
            a('        HandbookUnit(')
            a(f"          id: '{doc['id']}_c{ci}_u{ui}',")
            a('          type: HandbookUnitType.explainer,')
            a(f"          badgeHint: '{badge}',")
            a(f"          title: '{esc(u_title)}',")
            a(f'          body: {dart_string(u_body, 14)},')
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
# aiming for ~SPLIT_WORD_TARGET words per card. Images ride along to the
# card that holds the paragraph they were anchored to. Continuation cards
# reuse the source title with a ' (cont.)' suffix.
SPLIT_WORD_MIN = 200     # units at or below this are never split
SPLIT_WORD_TARGET = 150  # target words per card once splitting
SPLIT_WORD_MAX = 210     # close a card before a paragraph that would overflow


def word_count(s):
    return len(re.findall(r'[A-Za-z0-9]+', s))


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
    """Return [(title, body, images)] — one card if short, else several."""
    paras = u_body.split('\n\n')
    if word_count(u_body) <= SPLIT_WORD_MIN or len(paras) < 2:
        return [(u_title, u_body, u_images)]
    # Group paragraphs into contiguous chunks by a word budget: close the
    # current card when it reaches the target, or before adding a paragraph
    # that would push it past the max (so two mid-size paragraphs split
    # rather than pile into one over-long card).
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
    if len(chunks) < 2:
        return [(u_title, u_body, u_images)]
    result = []
    for ci, (s, e) in enumerate(chunks):
        body = '\n\n'.join(paras[s:e + 1])
        imgs = []
        for img_path, img_caption, img_after in u_images:
            if ci == 0 and img_after < 0:
                imgs.append((img_path, img_caption, -1))
            elif s <= img_after <= e:
                imgs.append((img_path, img_caption, img_after - s))
        title = u_title if ci == 0 else f'{u_title} (cont.)'
        result.append((title, body, imgs))
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


os.makedirs(OUT, exist_ok=True)
for doc in DOCS:
    text = load_md(doc['md'])
    if doc['kind'] == 'prose':
        chapters = parse_prose(text, doc['title'])
    elif doc['kind'] == 'glossary':
        chapters = parse_glossary(text)
    else:
        chapters = parse_slides(text)
    chapters = split_chapters(chapters)
    out_path = os.path.join(OUT, doc.get('out', doc['id'] + '_content.dart'))
    with open(out_path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(emit(doc, chapters))
    n_units = sum(len(c[1]) for c in chapters)
    print(f'{doc["id"]}: {len(chapters)} chapters, {n_units} units -> {out_path}')
