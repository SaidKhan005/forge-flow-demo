import json, os, shutil, glob

HERE = os.path.dirname(__file__)
OUT = os.path.join(HERE, 'out')
WT = r'C:\Git Local Repos\forge_flow_demo\.claude\worktrees\diag-coverage'
ASSETS = os.path.join(WT, 'assets', 'internal', 'barrio', 'training')
MANIFEST = os.path.join(WT, 'tool', 'barrio_training_diagrams_manifest.json')

# 1) copy every rendered webp into the worktree asset folders
copied = 0
folders = []
for folder in sorted(os.listdir(OUT)):
    src_dir = os.path.join(OUT, folder)
    if not os.path.isdir(src_dir):
        continue
    dst_dir = os.path.join(ASSETS, folder)
    os.makedirs(dst_dir, exist_ok=True)
    n = 0
    for f in glob.glob(os.path.join(src_dir, '*.webp')):
        shutil.copy2(f, os.path.join(dst_dir, os.path.basename(f)))
        n += 1
    copied += n
    folders.append((folder, n))

# 2) merge manifest fragments into the existing manifest (union; keys disjoint)
existing = json.load(open(MANIFEST, encoding='utf-8'))
before = len(existing)
added = 0
collisions = []
for frag in sorted(glob.glob(os.path.join(OUT, '*.manifest.json'))):
    part = json.load(open(frag, encoding='utf-8'))
    for k, v in part.items():
        if k in existing:
            collisions.append(k)
        else:
            existing[k] = v
            added += 1

# stable key order for a clean diff
merged = {k: existing[k] for k in sorted(existing)}
json.dump(merged, open(MANIFEST, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)

print(f'copied {copied} webp into {len(folders)} folders')
for folder, n in folders:
    print(f'  {folder}: {n}')
print(f'manifest: {before} -> {len(merged)} keys (+{added} new)')
if collisions:
    print(f'!! {len(collisions)} COLLISIONS (existing keys, skipped): {collisions[:10]}')
else:
    print('no key collisions (new keys disjoint from existing 45)')
