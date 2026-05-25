import json, sys, collections

tests = {}       # id -> {name, url, suite}
suites = {}      # id -> path
fails = []       # list of dicts
counts = collections.Counter()
done_ids = set()

with open('test_results.json', 'r', encoding='utf-8', errors='replace') as f:
    for line in f:
        line = line.strip()
        if not line or not line.startswith('{'):
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        t = ev.get('type')
        if t == 'suite':
            s = ev['suite']
            suites[s['id']] = s.get('path')
        elif t == 'testStart':
            te = ev['test']
            tests[te['id']] = {
                'name': te.get('name', ''),
                'suiteID': te.get('suiteID'),
                'line': te.get('line'),
                'url': te.get('url'),
            }
        elif t == 'error':
            tid = ev.get('testID')
            if tid in tests:
                tests[tid].setdefault('errors', []).append({
                    'error': ev.get('error', ''),
                    'stackTrace': ev.get('stackTrace', ''),
                })
        elif t == 'testDone':
            tid = ev.get('testID')
            if tid in done_ids:
                continue
            done_ids.add(tid)
            result = ev.get('result')
            hidden = ev.get('hidden', False)
            skipped = ev.get('skipped', False)
            te = tests.get(tid, {})
            name = te.get('name', '')
            # loading/group scaffolding tests are hidden
            if hidden and result == 'success':
                continue
            if skipped:
                counts['skipped'] += 1
                continue
            if result == 'success':
                counts['passed'] += 1
            elif result == 'failure':
                counts['failed'] += 1
                fails.append((tid, te, 'failure'))
            elif result == 'error':
                counts['error'] += 1
                fails.append((tid, te, 'error'))
            else:
                counts['other'] += 1

total = counts['passed'] + counts['failed'] + counts['error'] + counts['skipped'] + counts['other']
out = []
out.append("=== COUNTS ===")
out.append(f"total(non-hidden tests done): {total}")
for k in ('passed', 'failed', 'error', 'skipped', 'other'):
    out.append(f"{k}: {counts[k]}")

out.append("\n=== FAILURES ===")
for tid, te, kind in sorted(fails, key=lambda x: (suites.get(x[1].get('suiteID'), '') or '', x[1].get('name', '') or '')):
    path = suites.get(te.get('suiteID'), '?')
    name = te.get('name', '?')
    ln = te.get('line')
    out.append(f"\n[{kind.upper()}] {path}")
    out.append(f"  test: {name}  (line {ln})")
    errs = te.get('errors', [])
    if errs:
        emsg = "\n    ".join(errs[0]['error'].splitlines()[:4])
        out.append(f"  error: {emsg}")
    else:
        out.append("  error: (no error event captured)")

out.append(f"\n=== FAIL FILE SUMMARY ===")
byfile = collections.Counter()
for tid, te, kind in fails:
    byfile[suites.get(te.get('suiteID'), '?')] += 1
for fp, c in byfile.most_common():
    out.append(f"{c:3d}  {fp}")

text = "\n".join(out)
with open('parsed_failures.txt', 'w', encoding='utf-8') as fo:
    fo.write(text)
print(text.encode('ascii', 'replace').decode('ascii'))
