"""Read-only MCP server for Forge & Flow authority docs.

The server intentionally exposes local Markdown/text files as MCP resources and
adds a small search tool. It does not mutate files or call external services.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys
from typing import Any


PROTOCOL_VERSION = "2024-11-05"
TEXT_EXTENSIONS = {".md", ".txt", ".yaml", ".yml", ".json", ".sql", ".ps1", ".dart"}


ROOT_FILES = [
    "PROJECT_TRACKER.md",
    "CLAUDE.md",
    "README.md",
    "AI_RECONCILE.md",
    "docs/README.md",
    "docs/POST_HARDENING_FOLLOWUPS.md",
    "docs/CODEX_PROMPT_GENERATION_STANDARD.md",
    "docs/BETWEEN_SPRINT_AUDIT_PROMPT.md",
]

DOC_DIRS = [
    "docs/contracts",
    "docs/phases",
    "docs/runbooks",
    "runbooks",
    "docs/_walkthroughs",
    "docs/_execution",
]

SKIP_DIRS = {
    ".git",
    ".dart_tool",
    ".firebase",
    ".codex_appdata",
    ".claude",
    "build",
    "graphify-out",
}


class McpError(Exception):
    def __init__(self, code: int, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def as_posix(path: Path) -> str:
    return path.as_posix()


def safe_relative(root: Path, candidate: str) -> Path:
    raw = candidate.replace("\\", "/").lstrip("/")
    path = (root / raw).resolve()
    if root not in path.parents and path != root:
        raise McpError(-32602, f"Path escapes repo root: {candidate}")
    return path


def is_text_file(path: Path) -> bool:
    return path.is_file() and path.suffix.lower() in TEXT_EXTENSIONS


def iter_doc_files(root: Path) -> list[Path]:
    files: list[Path] = []
    for name in ROOT_FILES:
        path = safe_relative(root, name)
        if is_text_file(path):
            files.append(path)

    for dirname in DOC_DIRS:
        directory = safe_relative(root, dirname)
        if not directory.exists():
            continue
        for path in directory.rglob("*"):
            if any(part in SKIP_DIRS for part in path.parts):
                continue
            if is_text_file(path):
                files.append(path)

    return sorted(set(files), key=lambda p: as_posix(p.relative_to(root)).lower())


def uri_for(root: Path, path: Path) -> str:
    return "forgeflow://docs/" + as_posix(path.relative_to(root))


def path_for_uri(root: Path, uri: str) -> Path:
    prefix = "forgeflow://docs/"
    if not uri.startswith(prefix):
        raise McpError(-32602, f"Unsupported URI: {uri}")
    return safe_relative(root, uri[len(prefix) :])


def read_text(path: Path) -> str:
    if not is_text_file(path):
        raise McpError(-32602, f"Not a readable text resource: {path}")
    return path.read_text(encoding="utf-8", errors="replace")


def make_resource(root: Path, path: Path) -> dict[str, Any]:
    rel = as_posix(path.relative_to(root))
    return {
        "uri": uri_for(root, path),
        "name": rel,
        "description": "Forge & Flow authority/resource doc",
        "mimeType": "text/markdown" if path.suffix.lower() == ".md" else "text/plain",
    }


def search_docs(root: Path, args: dict[str, Any]) -> str:
    query = str(args.get("query", "")).strip()
    if not query:
        raise McpError(-32602, "query is required")
    limit = int(args.get("limit", 30))
    limit = max(1, min(limit, 100))
    areas = args.get("areas") or []
    areas = [str(area).replace("\\", "/").strip("/") for area in areas if str(area).strip()]

    query_lower = query.lower()
    matches: list[str] = []
    for path in iter_doc_files(root):
        rel = as_posix(path.relative_to(root))
        if areas and not any(rel.startswith(area + "/") or rel == area for area in areas):
            continue
        try:
            lines = read_text(path).splitlines()
        except McpError:
            continue
        for line_number, line in enumerate(lines, start=1):
            if query_lower in line.lower():
                excerpt = " ".join(line.strip().split())
                matches.append(f"{rel}:{line_number}: {excerpt}")
                if len(matches) >= limit:
                    return "\n".join(matches)
    return "No matches."


def authority_summary(root: Path) -> str:
    tracker = safe_relative(root, "PROJECT_TRACKER.md")
    claude = safe_relative(root, "CLAUDE.md")
    lines = [
        "Forge & Flow authority resources exposed by this MCP server:",
        "",
        f"- {as_posix(tracker.relative_to(root))}: routing, active lanes, hard gates.",
        f"- {as_posix(claude.relative_to(root))}: durable repo rules and hard promises.",
        "- docs/contracts/**: durable architecture and acceptance contracts.",
        "- docs/phases/**: live phase plans.",
        "- docs/CODEX_PROMPT_GENERATION_STANDARD.md: prompt/review/closeout workflow.",
        "",
        "Use the search_docs tool for scoped lookup before opening broad docs.",
    ]
    return "\n".join(lines)


def handle_request(root: Path, request: dict[str, Any]) -> dict[str, Any] | None:
    method = request.get("method")
    request_id = request.get("id")

    try:
        if method == "initialize":
            result = {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"resources": {}, "tools": {}},
                "serverInfo": {"name": "forgeflow-docs", "version": "0.1.0"},
            }
        elif method == "resources/list":
            resources = [
                {
                    "uri": "forgeflow://docs/.authority-summary",
                    "name": "authority-summary",
                    "description": "Forge & Flow authority order and exposed resource guide",
                    "mimeType": "text/markdown",
                }
            ]
            resources.extend(make_resource(root, path) for path in iter_doc_files(root))
            result = {"resources": resources}
        elif method == "resources/read":
            uri = request.get("params", {}).get("uri", "")
            if uri == "forgeflow://docs/.authority-summary":
                text = authority_summary(root)
            else:
                text = read_text(path_for_uri(root, uri))
            result = {"contents": [{"uri": uri, "mimeType": "text/markdown", "text": text}]}
        elif method == "tools/list":
            result = {
                "tools": [
                    {
                        "name": "search_docs",
                        "description": "Search Forge & Flow authority docs by literal text. Optional areas are repo-relative prefixes such as docs/contracts or docs/phases/phase_10_5.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "query": {"type": "string"},
                                "areas": {
                                    "type": "array",
                                    "items": {"type": "string"},
                                    "description": "Repo-relative path prefixes to search.",
                                },
                                "limit": {"type": "integer", "minimum": 1, "maximum": 100},
                            },
                            "required": ["query"],
                        },
                    }
                ]
            }
        elif method == "tools/call":
            params = request.get("params", {})
            name = params.get("name")
            args = params.get("arguments") or {}
            if name != "search_docs":
                raise McpError(-32601, f"Unknown tool: {name}")
            result = {"content": [{"type": "text", "text": search_docs(root, args)}]}
        elif method in {"notifications/initialized", "notifications/cancelled"}:
            return None
        else:
            raise McpError(-32601, f"Method not found: {method}")

        if request_id is None:
            return None
        return {"jsonrpc": "2.0", "id": request_id, "result": result}
    except McpError as exc:
        if request_id is None:
            return None
        return {"jsonrpc": "2.0", "id": request_id, "error": {"code": exc.code, "message": exc.message}}
    except Exception as exc:  # Defensive: keep MCP client informed.
        if request_id is None:
            return None
        return {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32603, "message": str(exc)}}


def serve(root: Path) -> None:
    root = root.resolve()
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
            response = handle_request(root, request)
        except Exception as exc:
            response = {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": str(exc)}}
        if response is not None:
            sys.stdout.write(json.dumps(response, separators=(",", ":")) + "\n")
            sys.stdout.flush()


def main() -> None:
    parser = argparse.ArgumentParser(description="Forge & Flow docs MCP server")
    parser.add_argument("--root", default=os.getcwd(), help="Forge & Flow repo root")
    args = parser.parse_args()
    serve(Path(args.root))


if __name__ == "__main__":
    main()
