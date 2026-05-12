#!/usr/bin/env python3
"""Generate docs/contracts/migrations_summary.md from db/migrations/*.sql.

Runs as part of the manual graph-refresh helper. Captures
filename, applied date, title, and the leading comment block from each
migration so the architectural shape lands in the knowledge graph even
though graphify doesn't ingest .sql files.
"""
import re
from pathlib import Path

MIGRATIONS_DIR = Path("db/migrations")
OUTPUT = Path("docs/contracts/migrations_summary.md")


def parse_filename(name: str):
    """Expected format: YYYYMMDDHHMM_title.sql -> ('2026-04-25 00:00', 'advisor roles')."""
    m = re.match(r"(\d{12})_(.+)\.sql$", name)
    if not m:
        return None, name.removesuffix(".sql")
    ts = m.group(1)
    date = f"{ts[0:4]}-{ts[4:6]}-{ts[6:8]} {ts[8:10]}:{ts[10:12]}"
    return date, m.group(2).replace("_", " ")


def extract_leading_comment(text: str) -> str:
    """Lines starting with -- at the top of the file, before any non-comment line."""
    out = []
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("--"):
            out.append(s.lstrip("-").strip())
        elif s == "":
            if out:
                out.append("")
        else:
            break
    while out and not out[-1]:
        out.pop()
    return "\n".join(out)


def indent_markdown_block(text: str) -> str:
    return "\n".join(f"  {line}" if line else "" for line in text.splitlines())


def main() -> None:
    if not MIGRATIONS_DIR.exists():
        raise SystemExit(f"ERROR: {MIGRATIONS_DIR} does not exist")
    sqls = sorted(MIGRATIONS_DIR.glob("*.sql"))
    parts = [
        "# Database migrations summary",
        "",
        "Auto-generated from `db/migrations/*.sql` by",
        "`scripts/generate_migrations_summary.py` (manual graph-refresh helper).",
        "",
        "Architectural index of `db/migrations/` for the knowledge graph.",
        "The `.sql` files are not extension-supported by graphify; this",
        "summary stands in for them so the graph captures migration shape.",
        "",
        f"Migration count: **{len(sqls)}**",
        "",
    ]
    for f in sqls:
        date, title = parse_filename(f.name)
        comment = extract_leading_comment(
            f.read_text(encoding="utf-8", errors="replace")
        )
        parts += [
            f"## `{f.name}`",
            "",
            f"- **Applied:** {date or 'unknown'}",
            f"- **Title:** {title}",
        ]
        if comment:
            parts += [
                "- **Description:**",
                "",
                indent_markdown_block(comment),
            ]
        else:
            parts += ["- **Description:** (no leading comment block)"]
        parts.append("")
    while parts and parts[-1] == "":
        parts.pop()
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text("\n".join(parts) + "\n", encoding="utf-8")
    print(f"Wrote {OUTPUT} ({len(sqls)} migrations)")


if __name__ == "__main__":
    main()
