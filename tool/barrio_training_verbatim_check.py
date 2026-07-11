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
        text = re.sub(r'^## Table of Contents\n(?:[ \t]*- .*\n|\n)*', '', text, flags=re.M)
        text = re.sub(r'^\s{0,3}#{1,6}\s*', '', text, flags=re.M)
        text = re.sub(r'^\s*[-*+]\s+', '', text, flags=re.M)
        text = re.sub(r'^```.*$', '', text, flags=re.M)
        text = text.replace('*', '')
        text = re.sub(r'^_(.+)_$', r'\1', text, flags=re.M)
    else:
        text = re.sub(r'^\s*- ', ' ', text, flags=re.M)
    words = re.findall(r'[^\s|]+', text)
    return [w.strip('.,;:!?()"\'').lower() for w in words if w.strip('.,;:!?()"\'-=*_`>')]

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
    ('training_latin_dishes', 'Latin American Dishes.md'),
    ('training_latin_ingredients', 'Latin American Ingredients.md'),
    ('training_labour_cost', 'Labour Cost - understanding the levers.md'),
    ('training_menu_concept', 'Barrio_Legado_Menu_Concept_Slides_4.md'),
    ('training_bold_by_design', 'Bold By Design.md'),
    ('training_food_safety', 'food safety manual.md'),
    ('training_cheers_responsibility', 'OE Cheers to Responsibility.md'),
    ('training_mastering_metrics', 'OE MASTERING THE METRICS.md'),
    ('training_general_words', 'GENERAL WORDS TO KNOW.md'),
]

for doc_id, md_name in PAIRS:
    dart = norm(dart_titles_and_bodies(f'lib/internal/barrio/content/training/{doc_id}_content.dart'))
    md = norm(open(f'docs/Knowledge_graph_docs/{md_name}', encoding='utf-8').read(), is_md=True)
    sm = difflib.SequenceMatcher(None, md, dart, autojunk=False)
    lost, gained = [], []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag in ('delete', 'replace') and i2 > i1:
            lost.append(' '.join(md[i1:i2]))
        if tag in ('insert', 'replace') and j2 > j1:
            gained.append(' '.join(dart[j1:j2]))
    n_lost = sum(len(c.split()) for c in lost)
    n_gained = sum(len(c.split()) for c in gained)
    print(f'== {doc_id}: md={len(md)}w dart={len(dart)}w ratio={sm.ratio():.4f} lost={n_lost}w gained={n_gained}w')
    for c in lost[:8]:
        print(f'   LOST : {c[:140]}')
    for c in gained[:8]:
        print(f'   GAIN : {c[:140]}')
