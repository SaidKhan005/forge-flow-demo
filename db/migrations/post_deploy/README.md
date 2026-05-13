# Post-Deploy Migration Convention

`db/migrations/post_deploy/` holds schema-contract work that must not run in the
same deploy gate as the expand-phase migration.

Use top-level `db/migrations/*.sql` for expand-only changes:

- create new tables, indexes, functions, triggers, and policies;
- add nullable columns;
- add constraints as `NOT VALID` when existing rows need verification;
- add forward-compatible defaults that older app builds can tolerate.

Use `db/migrations/post_deploy/*.sql` for work that depends on the new writer or
reader being deployed and observed first:

- large or sensitive `UPDATE` backfills;
- `ALTER COLUMN ... SET NOT NULL` after a verified backfill;
- `DROP COLUMN`, `DROP TABLE`, or other contract-phase removals;
- constraint tightening after production evidence says the data is ready.

Name post-deploy files with the timestamp of the originating expand migration:

```text
db/migrations/202606010900_example_expand.sql
db/migrations/post_deploy/202606010900_example_backfill.sql
db/migrations/post_deploy/202606010900_example_contract.sql
```

Post-deploy SQL is operator-gated. Do not apply these files as part of routine
staging setup, CI, or a feature deploy unless the matching runbook explicitly
calls for the post-deploy phase.
