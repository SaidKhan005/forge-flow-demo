#!/usr/bin/env python3
"""Check for mojibake in the proxy files."""
import os

FILES = [
    'tool/advisor_proxy/advisor_proxy.dart',
    'tool/advisor_proxy/jwt_verifier_part.dart',
    'tool/advisor_proxy/health_registry_part.dart',
]

BASE = os.path.join(os.path.dirname(__file__), '..', '..')

# Mojibake signature: when UTF-8 multi-byte sequences are decoded
# as cp1252, you get sequences like â€" (for em-dash U+2014).
# The tell-tale character is U+00E2 (â) followed by U+0080 (€) or similar.
# More specifically, look for bytes that represent cp1252 mojibake:
# The mojibake of any UTF-8 byte sequence starting with 0xE2 (U+00E2 â)
# or 0xC2 (U+00C2 Â) when misread as cp1252.
#
# The actual check: any file that was properly written in UTF-8 will NOT
# contain the sequence "â€" or "Â" followed by a non-ASCII char as text.
# We scan for the mojibake indicator: if a file decoded as UTF-8 contains
# these cp1252-decoded remnants as visible text characters.

# The true mojibake indicator: the sequence that results from reading
# UTF-8 bytes as cp1252. For em-dash (E2 80 94):
# cp1252 sees E2=â, 80=€, 94=? (undefined) → shows as â€ with missing char
# Actually in cp1252: E2=â, 80=€, 94=? (undefined, shows as ?)
# For >= (E2 89 A5): E2=â, 89=‰, A5=¥ → â‰¥
#
# The key: legitimate UTF-8 source has proper single Unicode chars.
# Mojibake source has SEQUENCES of replacement chars that are 2-3 chars
# each representing what should be one character.
#
# Simple reliable check: scan raw bytes for mojibake patterns.
# Mojibake occurs when UTF-8 bytes were written as if they were latin-1.
# The result in a UTF-8 file would be: the mojibake chars are 2-3 bytes each.
# e.g., â€" = U+00E2 U+20AC U+201C = 3 chars that look wrong together.

# Simplest check: after reading as UTF-8, look for the specific multi-char
# sequences that are classic mojibake of our source characters.

MOJIBAKE_PATTERNS = [
    # em-dash U+2014 → â€" in mojibake
    'â€“',  # that's â€"
    # >= sign U+2265 → â‰¥
    'â‰¥',
    # § sign U+00a7 → Â§
    'Â§',
    # → arrow U+2192 → â†'
    'â†’',
    # box-drawing ─ U+2500 → â"€
    'â‘€',
    # Generic: any  U+00E2 followed by U+20AC (the classic â€ start)
    'â€',
    # Generic: Â followed by non-breaking things
    'Â«',
    'Â»',
]

# Even simpler: just check for any instance of U+00E2 (â) in the files.
# In proper UTF-8 Dart source, the only non-ASCII chars should be:
# em-dash (—), box-drawing (─), ≥, §, →, etc.
# These are represented directly as their Unicode codepoints.
# If we see U+00E2 (â) in the source, it's almost certainly mojibake
# because â is not used in Dart source or English comments.

found_any = False
for rel_path in FILES:
    full_path = os.path.normpath(os.path.join(BASE, rel_path))
    with open(full_path, encoding='utf-8') as f:
        content = f.read()

    # Check for mojibake indicator: U+00E2 followed by U+0080..U+009F
    # (these are control chars in Unicode but were cp1252 graphic chars)
    mojibake_count = 0
    for i, ch in enumerate(content):
        if ch == 'â':
            # This is â — check if followed by something that looks like mojibake
            if i + 1 < len(content):
                next_ch = content[i+1]
                # If next char is in the C1 control range (0x80-0x9F),
                # that's a cp1252 graphic misread as Unicode control char.
                # Or if next char is € (U+20AC) which is cp1252 0x80.
                if '' <= next_ch <= '' or next_ch == '€':
                    mojibake_count += 1
                    context = content[max(0,i-10):i+20]
                    print(f"MOJIBAKE at {rel_path}:{i}: ...{context!r}...")
                    found_any = True
                    if mojibake_count >= 5:
                        print(f"  (stopping after 5 matches in {rel_path})")
                        break
        elif ch == 'Â':
            # This is Â — check if followed by something that looks like mojibake
            if i + 1 < len(content):
                next_ch = content[i+1]
                if ' ' <= next_ch <= '¿':
                    # Latin-1 supplement range — could be mojibake of 2-byte UTF-8
                    # e.g., Â§ = mojibake of § (C2 A7)
                    # But we need to distinguish from legitimate use.
                    # In Dart proxy source, Â followed by Latin-1 supplement is always mojibake.
                    mojibake_count += 1
                    context = content[max(0,i-10):i+20]
                    print(f"MOJIBAKE-C2 at {rel_path}:{i}: ...{context!r}...")
                    found_any = True
                    if mojibake_count >= 5:
                        print(f"  (stopping after 5 matches in {rel_path})")
                        break

    if mojibake_count == 0:
        # Count legitimate non-ASCII chars
        nonascii = [(i, ch) for i, ch in enumerate(content) if ord(ch) > 127]
        legit_count = len(nonascii)
        # Sample a few
        sample = [(i, ch, hex(ord(ch))) for i, ch in nonascii[:5]]
        sample_safe = [(i, hex(ord(ch))) for i, ch in nonascii[:5]]
        print(f"OK: {rel_path} - {legit_count} non-ASCII chars, no mojibake. Sample codepoints: {sample_safe}")

if not found_any:
    print("\nRESULT: NO MOJIBAKE — all 3 files clean.")
else:
    print("\nRESULT: MOJIBAKE DETECTED — STOP, do not proceed.")
    exit(1)
