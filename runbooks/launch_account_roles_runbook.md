# Launch Account Roles Runbook

This runbook makes the launch smoke accounts durable in staging or production
without hand-editing rows.

## Accounts

| Account | Intended role |
| --- | --- |
| `saidumarkhan005@gmail.com` | Highest admin, `super_admin` |
| `newoundlandlimited@gmail.com` | Regular restaurant user, `operator_staff` |

The target restaurant/operator is resolved from the regular user account. Said
is granted `super_admin` for that operator and is written to `operator_admins`,
so MFA recovery requests for Newfoundland's operator can find the assigned
admin. Newfoundland has active seeded admin roles revoked, receives
`operator_staff`, and is removed from `operator_admins`.

## Commands

Load local non-repo secrets first:

```powershell
. scripts/use_forge_flow_secrets.ps1
```

Dry-run the database write:

```powershell
scripts/set_launch_account_roles.ps1 -DryRun
```

Apply the database write and refresh Firebase custom claims:

```powershell
scripts/set_launch_account_roles.ps1 -RefreshFirebaseClaims
```

`-RefreshFirebaseClaims` requires
`db/migrations/202605020300_phase_9_firebase_uid_text.sql` to be applied first.
That migration makes `public.users.firebase_uid` a `text` link to the real
Firebase Identity Platform UID. The script blocks if the column is still the
old UUID type.

After the script completes, sign both accounts out and back in so the app uses
fresh Firebase ID tokens.

## What The Script Does

- Uses `POSTGRES_ADMIN_URL` without printing its value.
- Fails if either account is missing from `public.users`.
- Grants Said the global seeded `super_admin` role scoped to Newfoundland's
  operator.
- Upserts Said into `operator_admins` for that operator with
  `scope_type = 'super_admin'`.
- Revokes Newfoundland's active seeded elevated roles:
  `super_admin`, `ff_support`, `operator_owner`, `operator_manager`, and
  `operator_supervisor`.
- Ensures Newfoundland has an active `operator_staff` grant.
- Bumps `users.roles_version` only when the effective DB state changes.
- With `-RefreshFirebaseClaims`, looks up both Firebase accounts by email,
  reconciles `public.users.firebase_uid` to those live Firebase UIDs, then
  projects Firebase custom claims from the database role/admin rows.
- Blocks if Said's projection lacks an admin claim or if Newfoundland still
  projects an admin claim.
