import re, json, os

BASE = r'C:\Git Local Repos\forge_flow_demo\lib\internal\barrio\content\training'
DOC_FILE = {
 'company_handbook':'company_handbook_verbatim_content.dart',
 'interview_playbook':'interview_playbook_verbatim_content.dart',
 'jim_taylor_labor_model':'jim_taylor_verbatim_content.dart',
 'training_strong_foundation':'training_strong_foundation_content.dart',
 'training_table_manicuring':'training_table_manicuring_content.dart',
 'training_three_pillars':'training_three_pillars_content.dart',
 'training_suggestive_selling':'training_suggestive_selling_content.dart',
 'training_tequila':'training_tequila_content.dart',
 'training_coffee':'training_coffee_content.dart',
 'training_latin_dishes':'training_latin_dishes_content.dart',
 'training_latin_ingredients':'training_latin_ingredients_content.dart',
 'training_labour_cost':'training_labour_cost_content.dart',
 'training_menu_concept':'training_menu_content.dart',
 'training_bold_by_design':'training_bold_by_design_content.dart',
 'training_food_safety':'training_food_safety_content.dart',
 'training_cheers_responsibility':'training_cheers_responsibility_content.dart',
 'training_mastering_metrics':'training_mastering_metrics_content.dart',
 'training_general_words':'training_general_words_content.dart',
 'training_clover_sop':'training_clover_sop_content.dart',
 'training_push_sop':'training_push_sop_content.dart',
 'training_host_manual':'training_host_manual_content.dart',
 'training_bar_manual':'training_bar_manual_content.dart',
 'training_drink_specs':'training_drink_specs_content.dart',
}
ACCENT = {
 'company_handbook':'#D4584C','interview_playbook':'#2ECC71','jim_taylor_labor_model':'#3A6ED0',
 'training_strong_foundation':'#CC8A3A','training_table_manicuring':'#5FB8A6','training_three_pillars':'#B06AC9',
 'training_suggestive_selling':'#2ECC71','training_tequila':'#DFAA40','training_coffee':'#9A6B4F',
 'training_latin_dishes':'#D4584C','training_latin_ingredients':'#7FA84C','training_labour_cost':'#3A6ED0',
 'training_menu_concept':'#40CFCF','training_bold_by_design':'#5A7BD8','training_food_safety':'#52B788',
 'training_cheers_responsibility':'#DFAA40','training_mastering_metrics':'#3A6ED0','training_general_words':'#40CFCF',
 'training_clover_sop':'#5A7BD8','training_push_sop':'#5FB8A6','training_host_manual':'#B06AC9',
 'training_bar_manual':'#DFAA40','training_drink_specs':'#7FA84C',
}
LIT = re.compile(r"'((?:[^'\\]|\\.)*)'")

def unescape(s):
    out = []
    i = 0
    while i < len(s):
        c = s[i]
        if c == '\\' and i + 1 < len(s):
            nxt = s[i+1]
            out.append(' ' if nxt == 'n' else nxt)
            i += 2
        else:
            out.append(c)
            i += 1
    return ''.join(out)

def parse(path):
    txt = open(path, encoding='utf-8').read()
    parts = re.split(r'\bHandbookUnit\(', txt)[1:]
    units = []
    for ch in parts:
        mid = re.search(r"id:\s*'([^']*)'", ch)
        if not mid:
            continue
        uid = mid.group(1)
        mtype = re.search(r"type:\s*HandbookUnitType\.(\w+)", ch)
        utype = mtype.group(1) if mtype else '?'
        mtitle = re.search(r"title:\s*'((?:[^'\\]|\\.)*)'", ch)
        title = unescape(mtitle.group(1)) if mtitle else ''
        has_img = bool(re.search(r'\bimages:\s*\[', ch))
        body = ''
        mb = re.search(r'\bbody:\s*', ch)
        if mb:
            rest = ch[mb.end():]
            stop = re.search(r'\n\s*(images|options|runIndex|runLength|badgeHint):', rest)
            seg = rest[:stop.start()] if stop else rest
            body = ' '.join(unescape(m.group(1)) for m in LIT.finditer(seg))
        units.append(dict(id=uid, type=utype, title=title.strip(), body=body.strip(), has_image=has_img))
    return units

out = {}
summary = []
for doc, fn in DOC_FILE.items():
    p = os.path.join(BASE, fn)
    if not os.path.exists(p):
        summary.append((doc, 'MISSING', 0, 0, 0)); continue
    us = parse(p)
    expl = [u for u in us if u['type'] == 'explainer']
    bare = [u for u in expl if not u['has_image']]
    other_bare = [u for u in us if u['type'] != 'explainer' and not u['has_image']]
    for u in bare:
        u['doc'] = doc; u['accent'] = ACCENT[doc]
    out[doc] = bare
    summary.append((doc, 'ok', len(us), len(bare), len(other_bare)))

json.dump(out, open(os.path.join(os.path.dirname(__file__), 'bare_cards.json'), 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
tot_units = sum(s[2] for s in summary if s[1] == 'ok')
tot_bare = sum(s[3] for s in summary if s[1] == 'ok')
print(f"{'DOC':34} {'units':>6} {'bareExpl':>9} {'bareOther':>9}")
for d, st, n, b, o in summary:
    print(f"{d:34} {n:>6} {b:>9} {o:>9}" if st == 'ok' else f"{d:34}  {st}")
print(f"\nTOTAL routed units={tot_units}  BARE explainer cards to illustrate={tot_bare}")
