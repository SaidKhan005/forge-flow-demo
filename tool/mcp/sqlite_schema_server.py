"""Read-only MCP server for inspecting a SQLite schema."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sqlite3
import sys
from typing import Any


PROTOCOL_VERSION = "2024-11-05"


class McpError(Exception):
    def __init__(self, code: int, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def quote_identifier(identifier: str) -> str:
    return '"' + identifier.replace('"', '""') + '"'


def connect_ro(db_path: Path) -> sqlite3.Connection:
    if not db_path.exists():
        raise McpError(-32602, f"SQLite database not found: {db_path}")
    uri = f"file:{db_path.as_posix()}?mode=ro"
    conn = sqlite3.connect(uri, uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def fetch_objects(db_path: Path, object_type: str | None = None) -> list[sqlite3.Row]:
    query = "SELECT type, name, tbl_name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'"
    params: list[str] = []
    if object_type:
        query += " AND type = ?"
        params.append(object_type)
    query += " ORDER BY type, name"
    with connect_ro(db_path) as conn:
        return conn.execute(query, params).fetchall()


def table_names(db_path: Path) -> list[str]:
    return [row["name"] for row in fetch_objects(db_path, "table")]


def table_detail(db_path: Path, table: str) -> str:
    if table not in table_names(db_path):
        raise McpError(-32602, f"Unknown table: {table}")
    quoted = quote_identifier(table)
    with connect_ro(db_path) as conn:
        columns = conn.execute(f"PRAGMA table_info({quoted})").fetchall()
        indexes = conn.execute(f"PRAGMA index_list({quoted})").fetchall()
        foreign_keys = conn.execute(f"PRAGMA foreign_key_list({quoted})").fetchall()
        create_sql = conn.execute(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
            [table],
        ).fetchone()

    lines = [f"# {table}", ""]
    if create_sql and create_sql["sql"]:
        lines.extend(["## Create SQL", "```sql", create_sql["sql"], "```", ""])
    lines.append("## Columns")
    for col in columns:
        parts = [col["name"], col["type"] or "ANY"]
        if col["pk"]:
            parts.append("PRIMARY KEY")
        if col["notnull"]:
            parts.append("NOT NULL")
        if col["dflt_value"] is not None:
            parts.append(f"DEFAULT {col['dflt_value']}")
        lines.append("- " + " | ".join(parts))
    lines.append("")
    lines.append("## Indexes")
    if indexes:
        for idx in indexes:
            lines.append(f"- {idx['name']} unique={bool(idx['unique'])} origin={idx['origin']}")
    else:
        lines.append("- none")
    lines.append("")
    lines.append("## Foreign Keys")
    if foreign_keys:
        for fk in foreign_keys:
            lines.append(f"- {fk['from']} -> {fk['table']}.{fk['to']} on_update={fk['on_update']} on_delete={fk['on_delete']}")
    else:
        lines.append("- none")
    return "\n".join(lines)


def schema_summary(db_path: Path) -> str:
    objects = fetch_objects(db_path)
    counts: dict[str, int] = {}
    for row in objects:
        counts[row["type"]] = counts.get(row["type"], 0) + 1
    lines = [
        f"# SQLite Schema Summary",
        "",
        f"Database: `{db_path}`",
        "",
        "## Object Counts",
    ]
    for key in sorted(counts):
        lines.append(f"- {key}: {counts[key]}")
    lines.extend(["", "## Tables"])
    for table in table_names(db_path):
        lines.append(f"- {table}")
    return "\n".join(lines)


def objects_listing(db_path: Path, object_type: str | None = None) -> str:
    rows = fetch_objects(db_path, object_type)
    lines = [f"# SQLite {object_type or 'objects'}", ""]
    for row in rows:
        lines.append(f"## {row['type']} {row['name']}")
        if row["tbl_name"] and row["tbl_name"] != row["name"]:
            lines.append(f"Table: {row['tbl_name']}")
        if row["sql"]:
            lines.extend(["```sql", row["sql"], "```"])
        lines.append("")
    return "\n".join(lines).rstrip()


def resources(db_path: Path) -> list[dict[str, str]]:
    items = [
        ("sqlite://schema/summary", "summary", "SQLite schema summary"),
        ("sqlite://schema/tables", "tables", "SQLite table definitions"),
        ("sqlite://schema/indexes", "indexes", "SQLite index definitions"),
        ("sqlite://schema/views", "views", "SQLite view definitions"),
        ("sqlite://schema/triggers", "triggers", "SQLite trigger definitions"),
    ]
    for table in table_names(db_path):
        items.append((f"sqlite://schema/table/{table}", f"table/{table}", f"SQLite table detail for {table}"))
    return [
        {"uri": uri, "name": name, "description": desc, "mimeType": "text/markdown"}
        for uri, name, desc in items
    ]


def read_resource(db_path: Path, uri: str) -> str:
    if uri == "sqlite://schema/summary":
        return schema_summary(db_path)
    if uri == "sqlite://schema/tables":
        return objects_listing(db_path, "table")
    if uri == "sqlite://schema/indexes":
        return objects_listing(db_path, "index")
    if uri == "sqlite://schema/views":
        return objects_listing(db_path, "view")
    if uri == "sqlite://schema/triggers":
        return objects_listing(db_path, "trigger")
    prefix = "sqlite://schema/table/"
    if uri.startswith(prefix):
        return table_detail(db_path, uri[len(prefix) :])
    raise McpError(-32602, f"Unsupported URI: {uri}")


def search_schema(db_path: Path, args: dict[str, Any]) -> str:
    query = str(args.get("query", "")).strip().lower()
    if not query:
        raise McpError(-32602, "query is required")
    matches: list[str] = []
    for row in fetch_objects(db_path):
        haystack = " ".join(str(row[key] or "") for key in row.keys()).lower()
        if query in haystack:
            matches.append(f"{row['type']} {row['name']} on {row['tbl_name']}")
    return "\n".join(matches) if matches else "No matches."


def handle_request(db_path: Path, request: dict[str, Any]) -> dict[str, Any] | None:
    method = request.get("method")
    request_id = request.get("id")
    try:
        if method == "initialize":
            result = {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"resources": {}, "tools": {}},
                "serverInfo": {"name": "sqlite-schema", "version": "0.1.0"},
            }
        elif method == "resources/list":
            result = {"resources": resources(db_path)}
        elif method == "resources/read":
            uri = request.get("params", {}).get("uri", "")
            result = {"contents": [{"uri": uri, "mimeType": "text/markdown", "text": read_resource(db_path, uri)}]}
        elif method == "tools/list":
            result = {
                "tools": [
                    {
                        "name": "search_schema",
                        "description": "Search SQLite object names and CREATE SQL by literal text.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {"query": {"type": "string"}},
                            "required": ["query"],
                        },
                    }
                ]
            }
        elif method == "tools/call":
            params = request.get("params", {})
            if params.get("name") != "search_schema":
                raise McpError(-32601, f"Unknown tool: {params.get('name')}")
            result = {"content": [{"type": "text", "text": search_schema(db_path, params.get("arguments") or {})}]}
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
    except Exception as exc:
        if request_id is None:
            return None
        return {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32603, "message": str(exc)}}


def serve(db_path: Path) -> None:
    db_path = db_path.resolve()
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            response = handle_request(db_path, json.loads(line))
        except Exception as exc:
            response = {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": str(exc)}}
        if response is not None:
            sys.stdout.write(json.dumps(response, separators=(",", ":")) + "\n")
            sys.stdout.flush()


def main() -> None:
    parser = argparse.ArgumentParser(description="Read-only SQLite schema MCP server")
    parser.add_argument("database", help="Path to SQLite database")
    args = parser.parse_args()
    serve(Path(args.database))


if __name__ == "__main__":
    main()
