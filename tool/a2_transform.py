"""
A2 demo-flip transactional fix transformation script.

Applied to all 7 POS sinks to:
1. Remove the in-memory _pendingInsertsByTenant field + _tenantKey helper.
2. Insert the counter-increment SQL inside the withTenant upsert body.
3. Replace the post-withTenant evaluateDemoFlip call with in-transaction
   SELECT FOR UPDATE + atomic flip inside the watermark withTenant body.
4. Add pending_inserts_count = 0 to the evaluateDemoFlip UPDATE.
"""

import re
import sys

COUNTER_INCREMENT_SQL = """      if (rows.isNotEmpty) {
        // A2 fix: increment persisted pending counter inside the same
        // transaction as the cover-facts row so counter and fact are
        // always in sync (launch-blocker A2 fix).
        await exec.execute(
          'insert into public.demo_mode_state ('
          'operator_id, location_id, category, is_demo, '
          'pending_inserts_count, created_at, updated_at'
          ') values ('
          '@operator_id::uuid, @location_id::uuid, @category, true, '
          '1, @now::timestamptz, @now::timestamptz'
          ') on conflict (operator_id, location_id, category) do update set '
          'pending_inserts_count = '
          'public.demo_mode_state.pending_inserts_count + 1, '
          'updated_at = excluded.updated_at',
          parameters: <String, Object?>{
            'operator_id': operatorId,
            'location_id': locationId,
            'category': 'pos',
            'now': _clock().toUtc(),
          },
        );
      }
      return rows.isNotEmpty;
    });

    return inserted;"""


def make_flip_block(conn_id_var):
    return f"""
      // A2 fix: evaluate the demo-flip inside the same transaction as the
      // watermark commit so a crash between the two cannot leave the
      // operator stuck in demo mode. SELECT FOR UPDATE serialises
      // concurrent pods; UPDATE narrows to is_demo = true for idempotency.
      final dmsRows = await exec.query(
        'select pending_inserts_count, is_demo '
        'from public.demo_mode_state '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        'and category = @category '
        'for update',
        parameters: <String, Object?>{{
          'operator_id': operatorId,
          'location_id': locationId,
          'category': 'pos',
        }},
      );
      if (dmsRows.isNotEmpty) {{
        final dmsRow = dmsRows.single;
        final pendingCount =
            (dmsRow['pending_inserts_count'] as int? ?? 0);
        final isDemo = dmsRow['is_demo'] as bool? ?? true;
        if (pendingCount >= 1 && isDemo) {{
          await exec.execute(
            'update public.demo_mode_state set '
            'is_demo = false, '
            'flipped_to_live_at = @now::timestamptz, '
            'flipped_by_connection_id = @connection_id::uuid, '
            'pending_inserts_count = 0, '
            'updated_at = @now::timestamptz '
            'where operator_id = @operator_id::uuid '
            'and location_id = @location_id::uuid '
            'and category = @category '
            'and is_demo = true',
            parameters: <String, Object?>{{
              'operator_id': operatorId,
              'location_id': locationId,
              'category': 'pos',
              'now': _clock().toUtc(),
              'connection_id': {conn_id_var},
            }},
          );
        }}
      }}
    }});
  }}"""


FLIP_BLOCK_RESOLVED = make_flip_block('resolvedConnectionId')
FLIP_BLOCK_LSK = make_flip_block('connectionId')


def transform_sink(path, use_resolved_conn_id=True):
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()

    original = content
    flip_block = FLIP_BLOCK_RESOLVED if use_resolved_conn_id else FLIP_BLOCK_LSK

    # 1. Remove the in-memory map field declaration (comment + field + helper).
    # Handles slight comment variation across sinks.
    content = re.sub(
        r'  /// In-memory per-\(operator, location\) counter[^\n]*\n'
        r'(?:  ///[^\n]*\n){1,3}'
        r'  final Map<String, int> _pendingInsertsByTenant = <String, int>\{\};\n'
        r'\n'
        r"  String _tenantKey\(String operatorId, String locationId\) =>\n"
        r"      '\\\$operatorId\|\\\$locationId';\n"
        r'\n',
        '',
        content,
    )

    # 2. Replace the post-withTenant counter increment block.
    # Two variants: multi-line and single-line assignment.
    content = re.sub(
        r"      return rows\.isNotEmpty;\n"
        r"    \}\);\n"
        r"\n"
        r"    if \(inserted\) \{\n"
        r"      final key = _tenantKey\(operatorId, locationId\);\n"
        r"      _pendingInsertsByTenant\[key\] =\n"
        r"          \(_pendingInsertsByTenant\[key\] \?\? 0\) \+ 1;\n"
        r"    \}\n"
        r"    return inserted;",
        COUNTER_INCREMENT_SQL,
        content,
    )
    content = re.sub(
        r"      return rows\.isNotEmpty;\n"
        r"    \}\);\n"
        r"\n"
        r"    if \(inserted\) \{\n"
        r"      final key = _tenantKey\(operatorId, locationId\);\n"
        r"      _pendingInsertsByTenant\[key\] = \(_pendingInsertsByTenant\[key\] \?\? 0\) \+ 1;\n"
        r"    \}\n"
        r"    return inserted;",
        COUNTER_INCREMENT_SQL,
        content,
    )

    # 3. Replace the post-withTenant flip evaluation block.
    content = re.sub(
        r"\n    \}\);\n"
        r"\n"
        r"    final tenantKey = _tenantKey\(operatorId, locationId\);\n"
        r"    final pending = _pendingInsertsByTenant\.remove\(tenantKey\) \?\? 0;\n"
        r"    if \(pending >= 1\) \{\n"
        r"      await evaluateDemoFlip\(\n"
        r"        operatorId: operatorId,\n"
        r"        locationId: locationId,\n"
        r"        category: IntegrationCategory\.pos,\n"
        r"        connectionStatus: ConnectionStatus\.connected,\n"
        r"        firstBackfillCommitted: true,\n"
        r"        backfillRecordsWritten: pending,\n"
        r"        connectionId: resolvedConnectionId,\n"
        r"      \);\n"
        r"    \}\n"
        r"  \}",
        flip_block,
        content,
    )

    # Lightspeed-specific variant: connectionId (not resolvedConnectionId)
    content = re.sub(
        r"\n    \}\);\n"
        r"\n"
        r"    final tenantKey = _tenantKey\(operatorId, locationId\);\n"
        r"    final pending = _pendingInsertsByTenant\.remove\(tenantKey\) \?\? 0;\n"
        r"    if \(pending >= 1\) \{\n"
        r"      await evaluateDemoFlip\(\n"
        r"        operatorId: operatorId,\n"
        r"        locationId: locationId,\n"
        r"        category: IntegrationCategory\.pos,\n"
        r"        connectionStatus: ConnectionStatus\.connected,\n"
        r"        firstBackfillCommitted: true,\n"
        r"        backfillRecordsWritten: pending,\n"
        r"        connectionId: connectionId,\n"
        r"      \);\n"
        r"    \}\n"
        r"  \}",
        FLIP_BLOCK_LSK,
        content,
    )

    # 4. Add pending_inserts_count = 0 to every evaluateDemoFlip UPDATE statement
    # (both the in-watermark flip and the standalone evaluateDemoFlip method).
    content = content.replace(
        "        'is_demo = false, '\n"
        "        'flipped_to_live_at = @now::timestamptz, '\n"
        "        'flipped_by_connection_id = @connection_id::uuid, '\n"
        "        'updated_at = @now::timestamptz '",
        "        'is_demo = false, '\n"
        "        'flipped_to_live_at = @now::timestamptz, '\n"
        "        'flipped_by_connection_id = @connection_id::uuid, '\n"
        "        'pending_inserts_count = 0, '\n"
        "        'updated_at = @now::timestamptz '",
    )

    if content == original:
        print(f'WARNING: no changes made to {path}', file=sys.stderr)
    else:
        remaining = content.count('_pendingInsertsByTenant')
        pc = content.count('pending_inserts_count')
        with open(path, 'w', encoding='utf-8') as f:
            f.write(content)
        print(f'OK  {path}  (remaining _pendingInsertsByTenant={remaining}, pending_inserts_count={pc})')


BASE = r'C:\Git Local Repos\forge_flow_demo\.claude\worktrees\hardcore-bartik-9e27c8\lib\infrastructure\persistence\postgres'

standard_sinks = [
    'toast_pos_postgres_sink.dart',
    'clover_pos_postgres_sink.dart',
    'square_pos_postgres_sink.dart',
    'aloha_ncr_voyix_pos_postgres_sink.dart',
    'revel_pos_postgres_sink.dart',
    'oracle_micros_simphony_postgres_sink.dart',
]

for name in standard_sinks:
    transform_sink(BASE + '\\' + name, use_resolved_conn_id=True)

transform_sink(BASE + '\\lightspeed_lsk_pos_postgres_sink.dart', use_resolved_conn_id=False)
