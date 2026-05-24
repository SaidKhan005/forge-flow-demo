#!/usr/bin/env python3
"""
Byte-preserving proxy tidy script (v2).

Relocates two self-contained blocks from advisor_proxy.dart into part files.

Strategy:
  1. Remove Block A (JWT + Operator scope + guard) from its current location.
  2. Remove Block B (Health infra + migration writer) from its current location.
  3. Insert both `part` directives in the DIRECTIVES section of advisor_proxy.dart
     (immediately after the existing `part 'advisor_retrieve_route_group_part.dart';`
     line) — Dart requires directives before any declarations.

The part files each get a header comment + `part of 'advisor_proxy.dart';` +
the exact bytes from the removed block.

All file I/O uses explicit encoding='utf-8' to prevent UTF-8 -> cp1252 mojibake.
"""

import os

PROXY_PATH = os.path.join(os.path.dirname(__file__), 'advisor_proxy.dart')
PART_A_PATH = os.path.join(os.path.dirname(__file__), 'jwt_verifier_part.dart')
PART_B_PATH = os.path.join(os.path.dirname(__file__), 'health_registry_part.dart')

PART_A_HEADER = (
    "// Forge & Flow advisor proxy — JWT verification + Operator scope + Request guard\n"
    "// (part of advisor_proxy.dart).\n"
    "//\n"
    "// chore(advisor-proxy): pure size refactor. This part file holds the JWT\n"
    "// verifier interface hierarchy (ProxyJwtClaims, ProxyJwtVerificationError,\n"
    "// ScaffoldRejectingJwtVerifier, ServicePrincipalJwtVerifier,\n"
    "// CompositeProxyJwtVerifier, JwtKeyMaterial, PointyCastleRs256SignatureValidator,\n"
    "// FirebaseProxyJwtVerifier), the bearer-token extraction helper, and the\n"
    "// Operator scope + request guard (OperatorContext, ProxyAuthError,\n"
    "// ProxyRequestGuard). Mechanically lifted from advisor_proxy.dart so the\n"
    "// monolith stays under the kAdvisorProxyMaxLines bleed-stop ceiling enforced\n"
    "// by tool/advisor_proxy_size_lint.dart. As a Dart `part` it shares the\n"
    "// library's imports and private scope verbatim — routing, shapes, status\n"
    "// codes, RLS, auth, and SQL are all unchanged. No symbol was renamed.\n"
    "\n"
    "part of 'advisor_proxy.dart';\n"
    "\n"
)

PART_B_HEADER = (
    "// Forge & Flow advisor proxy — Health infrastructure + Migration registry writer\n"
    "// (part of advisor_proxy.dart).\n"
    "//\n"
    "// chore(advisor-proxy): pure size refactor. This part file holds the health\n"
    "// check infrastructure (ProxyHealthCheckStore, ProxyRuntimeGauges,\n"
    "// ProxyHealthStatus, ProxyHealthMetric, ProxyHealthSurface,\n"
    "// ScaffoldFailingProxyHealthCheckStore, ProxySchemaContractException,\n"
    "// AdminProxySchemaContractVerifier, ProxyHealthRegistryContext,\n"
    "// ProxyHealthFeatureFlags, ProxyHealthRegistryResult,\n"
    "// RegistryProxyHealthCheckStore, ProxyHealthDependencyProbe) and the\n"
    "// migration apply registry writer (ProxyMigrationApplyRegistryWriter).\n"
    "// Mechanically lifted from advisor_proxy.dart so the monolith stays under the\n"
    "// kAdvisorProxyMaxLines bleed-stop ceiling enforced by\n"
    "// tool/advisor_proxy_size_lint.dart. As a Dart `part` it shares the\n"
    "// library's imports and private scope verbatim — routing, shapes, status\n"
    "// codes, RLS, auth, and SQL are all unchanged. No symbol was renamed.\n"
    "\n"
    "part of 'advisor_proxy.dart';\n"
    "\n"
)

# Part directives to insert in the directives section of advisor_proxy.dart.
# These go right after the existing part 'advisor_retrieve_route_group_part.dart'; line.
PART_A_DIRECTIVE_LINES = (
    "// chore(advisor-proxy) size refactor: JWT verification interface + operator\n"
    "// scope + request guard live in this part file. `part` shares this\n"
    "// library's imports + private scope verbatim, so the move is\n"
    "// behavior byte-identical (no routing/shape/status/idempotency/RLS/\n"
    "// auth/SQL change). See `tool/advisor_proxy_size_lint.dart`.\n"
    "part 'jwt_verifier_part.dart';\n"
)

PART_B_DIRECTIVE_LINES = (
    "// chore(advisor-proxy) size refactor: health check infrastructure +\n"
    "// migration apply registry writer live in this part file. `part` shares\n"
    "// this library's imports + private scope verbatim, so the move is\n"
    "// behavior byte-identical. See `tool/advisor_proxy_size_lint.dart`.\n"
    "part 'health_registry_part.dart';\n"
)

# The anchor line after which we insert the new part directives.
# This must be exactly the line content of the last existing `part` directive.
ANCHOR_PART_LINE = "part 'advisor_retrieve_route_group_part.dart';\n"

# 1-based line ranges (inclusive) — the exact blocks to relocate.
# Block A: JWT verification interface through end of ProxyRequestGuard
BLOCK_A_START = 1217
BLOCK_A_END   = 2413

# Block B: ProxyHealthCheckStore through end of ProxyMigrationApplyRegistryWriter
BLOCK_B_START = 3827
BLOCK_B_END   = 5825


def read_utf8(path):
    with open(path, encoding='utf-8') as f:
        return f.read()


def write_utf8(path, content):
    with open(path, 'w', encoding='utf-8', newline='') as f:
        f.write(content)


def safe_repr(s):
    """ASCII-safe repr for terminal output."""
    return s.rstrip().encode('ascii', errors='replace').decode('ascii')


def main():
    print(f"Reading: {PROXY_PATH}")
    source = read_utf8(PROXY_PATH)
    lines = source.splitlines(keepends=True)
    total = len(lines)
    print(f"Total lines in advisor_proxy.dart: {total}")

    # Validate ranges
    assert 1 <= BLOCK_A_START <= BLOCK_A_END <= total, \
        f"Block A out of range: {BLOCK_A_START}-{BLOCK_A_END} (total: {total})"
    assert 1 <= BLOCK_B_START <= BLOCK_B_END <= total, \
        f"Block B out of range: {BLOCK_B_START}-{BLOCK_B_END} (total: {total})"
    assert BLOCK_A_END < BLOCK_B_START, "Blocks overlap"

    # 0-based
    a0 = BLOCK_A_START - 1
    a1 = BLOCK_A_END        # exclusive end
    b0 = BLOCK_B_START - 1
    b1 = BLOCK_B_END        # exclusive end

    # Show what we're extracting
    print(f"\nBlock A [{BLOCK_A_START}..{BLOCK_A_END}]:")
    print(f"  start: {safe_repr(lines[a0])!r}")
    print(f"  end:   {safe_repr(lines[a1-1])!r}")
    print(f"  size:  {a1-a0} lines")

    print(f"\nBlock B [{BLOCK_B_START}..{BLOCK_B_END}]:")
    print(f"  start: {safe_repr(lines[b0])!r}")
    print(f"  end:   {safe_repr(lines[b1-1])!r}")
    print(f"  size:  {b1-b0} lines")

    # Verify blank lines surround both blocks (sanity)
    assert lines[a0-1].strip() == '', f"Expected blank line before Block A, got: {lines[a0-1]!r}"
    assert lines[a1].strip() == '', f"Expected blank line after Block A, got: {lines[a1]!r}"
    assert lines[b0-1].strip() == '', f"Expected blank line before Block B, got: {lines[b0-1]!r}"
    assert lines[b1].strip() == '', f"Expected blank line after Block B, got: {lines[b1]!r}"
    print("\nSurrounding blank lines verified.")

    # Find the anchor line for inserting the part directives
    anchor_idx = None
    for i, line in enumerate(lines):
        if line == ANCHOR_PART_LINE:
            anchor_idx = i
            break
    assert anchor_idx is not None, f"Could not find anchor line: {ANCHOR_PART_LINE!r}"
    print(f"\nAnchor found at line {anchor_idx + 1}: {safe_repr(lines[anchor_idx])!r}")
    assert anchor_idx < a0, "Anchor must be before Block A"

    # Extract the block lines (byte-for-byte from the source)
    block_a_lines = lines[a0:a1]
    block_b_lines = lines[b0:b1]

    # Build part file contents
    part_a_content = PART_A_HEADER + ''.join(block_a_lines)
    part_b_content = PART_B_HEADER + ''.join(block_b_lines)

    # Build the new advisor_proxy.dart:
    # 1. Lines before anchor (inclusive of anchor)
    # 2. Blank line + part A directive lines
    # 3. Blank line + part B directive lines
    # 4. Lines from anchor+1 up to (but not including) Block A (drop the blank line before Block A)
    # 5. (Block A removed — replaced by nothing; keep the blank line after Block A)
    # 6. Lines from after Block A up to (but not including) Block B (drop the blank line before Block B)
    # 7. (Block B removed — replaced by nothing; keep the blank line after Block B)
    # 8. Lines after Block B

    new_lines = []

    # Part 1: lines[0..anchor_idx] inclusive
    new_lines.extend(lines[:anchor_idx + 1])

    # Part 2: blank line + part A directive
    new_lines.append('\n')
    new_lines.append(PART_A_DIRECTIVE_LINES)

    # Part 3: blank line + part B directive
    new_lines.append('\n')
    new_lines.append(PART_B_DIRECTIVE_LINES)

    # Part 4: lines from anchor+1 up to the blank line BEFORE Block A (exclusive)
    # i.e., lines[anchor_idx+1 .. a0-1] (drop the blank line at a0-1 since we removed the block)
    # Actually we want to keep the surrounding structure clean.
    # lines[anchor_idx+1] through lines[a0-2] (keeping the blank line BEFORE the block-A marker)
    # The blank line at a0-1 is redundant now (the block is gone), so drop it.
    new_lines.extend(lines[anchor_idx + 1:a0 - 1])  # drop blank line before block A

    # Part 5: Block A is removed. Keep the blank line AFTER Block A (at a1).
    new_lines.append(lines[a1])  # the blank line after block A becomes a separator

    # Part 6: lines from a1+1 up to the blank line BEFORE Block B (exclusive)
    # Drop the blank line at b0-1 since the block is gone.
    new_lines.extend(lines[a1 + 1:b0 - 1])  # drop blank line before block B

    # Part 7: Block B is removed. Keep the blank line AFTER Block B (at b1).
    new_lines.append(lines[b1])  # the blank line after block B becomes a separator

    # Part 8: lines from b1+1 to end
    new_lines.extend(lines[b1 + 1:])

    new_total = len(new_lines)
    removed = total - new_total
    print(f"\nOriginal line count: {total}")
    print(f"New line count:      {new_total}")
    print(f"Net lines removed:   {removed}")
    print(f"Headroom vs 19900:   {19900 - new_total} lines")

    assert new_total < 19900, f"Still at or over ceiling: {new_total}"
    assert removed > 1500, f"Expected >1500 lines removed, got {removed}"

    # Write part files
    print(f"\nWriting {PART_A_PATH}")
    write_utf8(PART_A_PATH, part_a_content)
    print(f"  ({len(block_a_lines)} block lines + header = {len(part_a_content.splitlines())} total)")

    print(f"Writing {PART_B_PATH}")
    write_utf8(PART_B_PATH, part_b_content)
    print(f"  ({len(block_b_lines)} block lines + header = {len(part_b_content.splitlines())} total)")

    # Write updated monolith
    new_source = ''.join(new_lines)
    print(f"\nWriting updated {PROXY_PATH}")
    write_utf8(PROXY_PATH, new_source)

    print("\nDone. Run verification:")
    print("  python3 tool/advisor_proxy/check_mojibake.py")
    print("  git diff -w --numstat origin/master -- tool/advisor_proxy/advisor_proxy.dart")
    print("  dart analyze tool/advisor_proxy/")
    print("  dart run tool/advisor_proxy_size_lint.dart")


if __name__ == '__main__':
    main()
