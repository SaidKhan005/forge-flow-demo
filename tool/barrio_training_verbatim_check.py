"""Verify generated Dart training content carries the source markdown word-for-word.

Usage: run from the repo root with `python tool/barrio_training_verbatim_check.py`.
Compares every (generated Dart, source markdown) pair in PAIRS and prints one
summary line per doc. The verification gate is lost=0w for every doc (no source
words dropped); gained words are expected (chapter titles, card subtitles).
Regenerate content first with `python tool/barrio_training_content_generator.py`.
"""
import re, difflib

def dart_titles_and_bodies(path):
    """Reconstruct the text a reader sees: chapter/unit titles + bodies, in order."""
    src = open(path, encoding='utf-8').read()
    out = []
    # Walk unit entries: title then body (adjacent string concatenation).
    # Also chapter titles.
    pattern = re.compile(
        r"title: ((?:'(?:[^'\\]|\\.)*'\s*)+),|body: ((?:'(?:[^'\\]|\\.)*'\s*)+),", re.S)
    for m in pattern.finditer(src):
        lit = m.group(1) or m.group(2)
        parts = re.findall(r"'((?:[^'\\]|\\.)*)'", lit)
        text = ''.join(parts)
        text = text.replace("\\'", "'").replace('\\n', '\n').replace('\\$', '$').replace('\\\\', '\\')
        out.append(text)
    return '\n'.join(out)

def norm(text, is_md=False):
    if is_md:
        text = re.sub(r'\A---\n.*?\n---\n', '', text, flags=re.S)
        # Image markers (tool/barrio_training_image_extractor.py) are
        # formatting, not words: the generator turns them into
        # HandbookUnitImage entries, so strip them before comparing.
        text = re.sub(r'^!\[[^\]]*\]\(assets/internal/barrio/training/[^)]+\)[ \t]*$',
                      '', text, flags=re.M)
        text = re.sub(r'^## Table of Contents\n(?:[ \t]*- .*\n|\n)*', '', text, flags=re.M)
        text = re.sub(r'^\s{0,3}#{1,6}\s*', '', text, flags=re.M)
        text = re.sub(r'^\s*[-*+]\s+', '', text, flags=re.M)
        text = re.sub(r'^```.*$', '', text, flags=re.M)
        text = text.replace('*', '')
        text = re.sub(r'^_(.+)_$', r'\1', text, flags=re.M)
    else:
        text = re.sub(r'^\s*- ', ' ', text, flags=re.M)
    words = re.findall(r'[^\s|]+', text)
    # Strip a trailing/leading '*' from the compared token too: the md side
    # removes every '*' above, so a literal lone asterisk the generator now
    # preserves verbatim (e.g. 'importer*.') must not read as a lost word.
    return [w.strip('.,;:!?()"\'*').lower() for w in words if w.strip('.,;:!?()"\'-=*_`>')]

def contains_contiguous(haystack, needle):
    """True when needle appears as a contiguous word run inside haystack."""
    n = len(needle)
    return any(haystack[i:i + n] == needle for i in range(len(haystack) - n + 1))


def carries_every_source_word(md_words, dart_words):
    """Exact 'no source word was dropped' proof for one doc.

    The generator only ever ADDS words (chapter and card titles) around a
    verbatim body, so a faithful conversion leaves the md word sequence as
    an in-order subsequence of the dart word sequence. Greedy leftmost
    matching is provably optimal for subsequence testing, so True proves
    every source word survived in order and False proves one did not.

    This exists because the SequenceMatcher opcode walk below is only a
    heuristic: when a source doc REPEATS a long passage (Wine Training
    reproduces two paragraphs twice, once on page 59 and again on page 60,
    exactly as the operator PDF does), the matcher can pair md copy 1 with
    dart copy 2 and then report the surrounding text as deleted even though
    the dart carries every word. The windowed `contains_contiguous` carve-out
    cannot rescue that case because the generator injects a card title in the
    middle of the run, so the run is nowhere contiguous in the dart. This
    test does not widen the guard: it is the guarantee itself, stated
    exactly, and a real drop still fails it.
    """
    it = iter(dart_words)
    return all(word in it for word in md_words)


PAIRS = [
    ('company_handbook_verbatim', 'Barrio_company_handbook.md'),
    ('interview_playbook_verbatim', 'Barrio_interview_playbook.md'),
    ('jim_taylor_verbatim', 'jim_taylor_labor_model_deep_dive.md'),
    ('training_strong_foundation', 'Barrio Building A Strong Foundation.md'),
    ('training_table_manicuring', 'Barrio Table Maintenance and Manicuring.md'),
    ('training_three_pillars', 'Barrio The Three Pillars of Hospitality.md'),
    ('training_suggestive_selling', 'OE Leveraging Suggestive Selling Techniques.md'),
    ('training_tequila', 'Tequila Training.md'),
    ('training_coffee', 'Coffee Training.md'),
    ('training_wine', 'Barrio Wine Training.md'),
    ('training_latin_dishes', 'Latin American Dishes.md'),
    ('training_latin_ingredients', 'Latin American Ingredients.md'),
    ('training_labour_cost', 'Labour Cost - understanding the levers.md'),
    ('training_menu_concept', 'Barrio_Legado_Menu_Concept_Slides_4.md'),
    ('training_menu', 'Barrio_Menu.md'),
    ('training_bold_by_design', 'Bold By Design.md'),
    ('training_food_safety', 'food safety manual.md'),
    ('training_cheers_responsibility', 'OE Cheers to Responsibility.md'),
    ('training_mastering_metrics', 'OE MASTERING THE METRICS.md'),
    ('training_general_words', 'GENERAL WORDS TO KNOW.md'),
    ('training_clover_sop', 'Clover SOP.md'),
    ('training_push_sop', 'Push Employee SOP.md'),
    ('training_host_manual', 'Barrio Host Manual.md'),
    ('training_bar_manual', 'Bar Manual.md'),
    ('training_drink_specs', 'Barrio Drink Specs.md'),
]

for doc_id, md_name in PAIRS:
    dart = norm(dart_titles_and_bodies(f'lib/internal/barrio/content/training/{doc_id}_content.dart'))
    md = norm(open(f'docs/Knowledge_graph_docs/{md_name}', encoding='utf-8').read(), is_md=True)
    sm = difflib.SequenceMatcher(None, md, dart, autojunk=False)
    # Exact proof, computed once per doc: when the md word sequence is an
    # in-order subsequence of the dart word sequence, nothing was dropped and
    # every delete/replace opcode below is an alignment artifact. See
    # carries_every_source_word.
    intact = carries_every_source_word(md, dart)
    lost, gained = [], []
    moved = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag in ('delete', 'replace') and i2 > i1:
            # SequenceMatcher alignment artifact, not a loss: the md words
            # appear contiguously in the dart within a tight window around
            # the deletion point (e.g. the doc H1 rendered on the hero above
            # a preface line the source puts first). A real drop leaves the
            # window without them; distant duplicates are rescued only by the
            # exact `intact` proof, never by the window.
            window = dart[max(0, j1 - 60):j2 + 60]
            if intact or contains_contiguous(window, md[i1:i2]):
                moved.append(' '.join(md[i1:i2]))
                if tag == 'replace' and j2 > j1:
                    gained.append(' '.join(dart[j1:j2]))
                continue
            lost.append(' '.join(md[i1:i2]))
        if tag in ('insert', 'replace') and j2 > j1:
            gained.append(' '.join(dart[j1:j2]))
    n_lost = sum(len(c.split()) for c in lost)
    n_gained = sum(len(c.split()) for c in gained)
    n_moved = sum(len(c.split()) for c in moved)
    moved_note = f' moved={n_moved}w' if n_moved else ''
    print(f'== {doc_id}: md={len(md)}w dart={len(dart)}w ratio={sm.ratio():.4f} lost={n_lost}w gained={n_gained}w{moved_note}')
    for c in lost[:8]:
        print(f'   LOST : {c[:140]}')
    for c in moved[:8]:
        print(f'   MOVED: {c[:140]}')
    for c in gained[:8]:
        print(f'   GAIN : {c[:140]}')
