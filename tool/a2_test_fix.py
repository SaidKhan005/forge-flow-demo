"""
A2 test-fake fix: update the 6 remaining sink test files so their
_FakeTransaction (or _FakeXxxTransaction) classes handle the new SQL
patterns introduced by the A2 demo-flip transactionality fix:

1. Add SELECT FOR UPDATE handler in query().
2. Replace putIfAbsent in execute() insert into demo_mode_state with
   ON CONFLICT increment logic.
3. Add pending_inserts_count = 0 to execute() update demo_mode_state.
"""

import re
import sys

BASE = (
    r'C:\Git Local Repos\forge_flow_demo\.claude\worktrees'
    r'\hardcore-bartik-9e27c8\test\infrastructure\persistence\postgres'
)

# ── Snippet to INSERT before "insert into public.cover_facts" handler ──
# (i.e., inside the query() method, before cover_facts branch)
SELECT_FOR_UPDATE_HANDLER = """\
    if (sql.contains('from public.demo_mode_state') &&
        sql.contains('for update')) {
      // A2 fix: SELECT FOR UPDATE on demo_mode_state — used by the
      // watermark advance to read the pending counter before flipping.
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final category = parameters['category'] as String;
      final key = '$operatorId|$locationId|$category';
      final row = pool.demoModeState[key];
      if (row == null) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{
          'pending_inserts_count': row['pending_inserts_count'] ?? 0,
          'is_demo': row['is_demo'] ?? true,
        },
      ];
    }
"""

# Old putIfAbsent block (without pending_inserts_count)
OLD_INSERT_BLOCK = """\
    if (sql.contains('insert into public.demo_mode_state')) {
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final category = parameters['category'] as String;
      final key = '$operatorId|$locationId|$category';
      pool.demoModeState.putIfAbsent(
        key,
        () => <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'category': category,
          'is_demo': true,
          'flipped_to_live_at': null,
          'flipped_by_connection_id': null,
        },
      );
      return 1;
    }"""

# New insert block (with pending_inserts_count increment)
NEW_INSERT_BLOCK = """\
    if (sql.contains('insert into public.demo_mode_state')) {
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final category = parameters['category'] as String;
      final key = '$operatorId|$locationId|$category';
      // A2 fix: ON CONFLICT DO UPDATE increments pending_inserts_count.
      if (pool.demoModeState.containsKey(key)) {
        // ON CONFLICT DO UPDATE SET pending_inserts_count = pending_inserts_count + 1
        final existing = pool.demoModeState[key]!;
        existing['pending_inserts_count'] =
            (existing['pending_inserts_count'] as int? ?? 0) + 1;
      } else {
        pool.demoModeState[key] = <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'category': category,
          'is_demo': true,
          'pending_inserts_count': 1,
          'flipped_to_live_at': null,
          'flipped_by_connection_id': null,
        };
      }
      return 1;
    }"""

# Old update block (without pending_inserts_count = 0)
OLD_UPDATE_BLOCK = """\
      row['is_demo'] = false;
      row['flipped_to_live_at'] = parameters['now'];
      row['flipped_by_connection_id'] = parameters['connection_id'];
      return 1;"""

# New update block (with pending_inserts_count = 0)
NEW_UPDATE_BLOCK = """\
      row['is_demo'] = false;
      row['flipped_to_live_at'] = parameters['now'];
      row['flipped_by_connection_id'] = parameters['connection_id'];
      row['pending_inserts_count'] = 0;
      return 1;"""

# Pattern that appears just before the cover_facts query handler in each file
# We'll insert the SELECT FOR UPDATE handler before the cover_facts INSERT.
# The anchor is: "if (sql.contains('insert into public.cover_facts'))"
COVER_FACTS_ANCHOR = "    if (sql.contains('insert into public.cover_facts'))"


def fix_file(path):
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()

    original = content

    # 1. Add SELECT FOR UPDATE handler before cover_facts query handler.
    if SELECT_FOR_UPDATE_HANDLER.strip() not in content:
        if COVER_FACTS_ANCHOR in content:
            content = content.replace(
                COVER_FACTS_ANCHOR,
                SELECT_FOR_UPDATE_HANDLER + COVER_FACTS_ANCHOR,
            )
        else:
            print(f'WARNING: cover_facts anchor not found in {path}', file=sys.stderr)

    # 2. Replace putIfAbsent demo_mode_state insert block.
    if OLD_INSERT_BLOCK in content:
        content = content.replace(OLD_INSERT_BLOCK, NEW_INSERT_BLOCK)
    else:
        print(f'WARNING: old insert block not found in {path}', file=sys.stderr)

    # 3. Add pending_inserts_count = 0 to update block.
    if OLD_UPDATE_BLOCK in content:
        content = content.replace(OLD_UPDATE_BLOCK, NEW_UPDATE_BLOCK)
    else:
        if 'pending_inserts_count = 0' not in content:
            print(f'WARNING: old update block not found in {path}', file=sys.stderr)

    if content == original:
        print(f'SKIP {path} (no changes needed)')
    else:
        with open(path, 'w', encoding='utf-8') as f:
            f.write(content)
        print(f'OK   {path}')


FILES = [
    'square_pos_postgres_sink_test.dart',
    'clover_pos_postgres_sink_test.dart',
    'aloha_ncr_voyix_pos_postgres_sink_test.dart',
    'lightspeed_lsk_pos_postgres_sink_test.dart',
    'revel_pos_postgres_sink_test.dart',
    'oracle_micros_simphony_postgres_sink_test.dart',
]

for name in FILES:
    fix_file(BASE + '\\' + name)
