# Graphify Candidate Artifacts

This directory carries the sanitized `prepare-graphify-candidates` output that
the advisor proxy image copies to `/app/graphify-out/candidates`.

Regenerate from the repo root with:

```powershell
dart run tool\advisor_corpus\main.dart prepare-graphify-candidates
Copy-Item graphify-out\candidates\graphify_* tool\advisor_proxy\graphify_candidates\candidates\
```

Do not commit the raw `graphify-out/graph.json`, cache, or converted source
files. The proxy only needs the reviewed candidate JSONL files and manifest.
The manifest must keep repo-relative paths only; it must not include a local
developer checkout path.
