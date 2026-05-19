# Launch account role enforcement.
#
# Durable staging/prod repair for the launch smoke accounts:
#   * saidumarkhan005@gmail.com becomes the highest admin account.
#   * newoundlandlimited@gmail.com is kept as a regular supervisor user.
#
# This script never stores credentials in the repo and never prints
# connection strings. It expects POSTGRES_ADMIN_URL from the existing
# non-repo secret loader. When -RefreshFirebaseClaims is supplied, it
# also expects FIREBASE_PROJECT_ID and a gcloud login that can call
# Identity Toolkit accounts:lookup/accounts:update. Claim refresh first
# reconciles public.users.firebase_uid to the live Firebase account found
# by email so claims cannot be written to a stale placeholder UID.

[CmdletBinding()]
param(
  [string] $AdminEmail = 'saidumarkhan005@gmail.com',
  [string] $RegularEmail = 'newoundlandlimited@gmail.com',
  [string] $ConnectionString = $env:POSTGRES_ADMIN_URL,
  [string] $FirebaseProjectId = $env:FIREBASE_PROJECT_ID,
  [switch] $DryRun,
  [switch] $RefreshFirebaseClaims
)

$ErrorActionPreference = 'Stop'

function Assert-NonBlank {
  param(
    [string] $Name,
    [string] $Value
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    Write-Host "BLOCKED: $Name is required"
    exit 1
  }
}

Assert-NonBlank -Name 'AdminEmail' -Value $AdminEmail
Assert-NonBlank -Name 'RegularEmail' -Value $RegularEmail

if ($AdminEmail.Trim().ToLowerInvariant() -eq $RegularEmail.Trim().ToLowerInvariant()) {
  Write-Host 'BLOCKED: AdminEmail and RegularEmail must be different accounts'
  exit 1
}

if ([string]::IsNullOrWhiteSpace($ConnectionString)) {
  Write-Host 'BLOCKED: POSTGRES_ADMIN_URL is missing'
  Write-Host 'Run: . scripts/use_forge_flow_secrets.ps1'
  exit 1
}

if ($DryRun -and $RefreshFirebaseClaims) {
  Write-Host 'BLOCKED: -RefreshFirebaseClaims cannot be combined with -DryRun'
  exit 1
}

$psqlCommand = Get-Command psql -ErrorAction SilentlyContinue
if ($null -eq $psqlCommand) {
  Write-Host 'BLOCKED: psql was not found on PATH'
  exit 1
}
$psqlPath = if ($psqlCommand.Source) { $psqlCommand.Source } else { $psqlCommand.Path }

function Add-ConnectionStringParameter {
  param(
    [string] $Value,
    [string] $Name,
    [string] $ParameterValue
  )

  $normalized = $ParameterValue -replace '\\', '/'
  $escaped = [Uri]::EscapeDataString($normalized)
  if ($Value -match '^\s*postgres(ql)?://') {
    $separator = if ($Value.Contains('?')) { '&' } else { '?' }
    return "$Value$separator$Name=$escaped"
  }
  return "$Value $Name=$escaped"
}

function New-SystemRootCertBundle {
  $roots = @()
  try {
    $roots = @(
      Get-ChildItem -Path Cert:\CurrentUser\Root,Cert:\LocalMachine\Root `
        -ErrorAction Stop
    )
  } catch {
    return $null
  }
  if ($roots.Count -eq 0) { return $null }

  $path = Join-Path ([System.IO.Path]::GetTempPath()) (
    "forge-flow-postgres-roots-{0}.pem" -f ([Guid]::NewGuid().ToString('N'))
  )
  $builder = [System.Text.StringBuilder]::new()
  foreach ($root in $roots) {
    try {
      $raw = $root.Export(
        [System.Security.Cryptography.X509Certificates.X509ContentType]::Cert
      )
      $body = [Convert]::ToBase64String(
        $raw,
        [Base64FormattingOptions]::InsertLineBreaks
      )
      [void] $builder.AppendLine('-----BEGIN CERTIFICATE-----')
      [void] $builder.AppendLine($body)
      [void] $builder.AppendLine('-----END CERTIFICATE-----')
    } catch {
      # Skip unreadable local roots; the bundle only needs one matching issuer.
    }
  }
  if ($builder.Length -eq 0) { return $null }

  $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText($path, $builder.ToString(), $utf8NoBom)
  return $path
}

$tempSql = Join-Path ([System.IO.Path]::GetTempPath()) (
  "forge-flow-launch-account-roles-{0}.sql" -f ([Guid]::NewGuid().ToString('N'))
)
$uidRepairSql = Join-Path ([System.IO.Path]::GetTempPath()) (
  "forge-flow-launch-account-firebase-uids-{0}.sql" -f ([Guid]::NewGuid().ToString('N'))
)
$claimsSql = Join-Path ([System.IO.Path]::GetTempPath()) (
  "forge-flow-launch-account-claims-{0}.sql" -f ([Guid]::NewGuid().ToString('N'))
)
$tempRootBundle = $null
$effectiveConnectionString = $ConnectionString
if (
  $ConnectionString -match '(^|[?&\s])sslmode=verify-(full|ca)' -and
  $ConnectionString -notmatch '(^|[?&\s])sslrootcert='
) {
  $tempRootBundle = New-SystemRootCertBundle
  if (-not [string]::IsNullOrWhiteSpace($tempRootBundle)) {
    $effectiveConnectionString = Add-ConnectionStringParameter `
      -Value $ConnectionString `
      -Name 'sslrootcert' `
      -ParameterValue $tempRootBundle
  }
}

$transactionEnd = if ($DryRun) { 'rollback;' } else { 'commit;' }

$roleSql = @'
\set ON_ERROR_STOP on
begin;

select set_config('forge_flow.launch_admin_email', :'admin_email', true);
select set_config('forge_flow.launch_regular_email', :'regular_email', true);

do $$
declare
  admin_email constant text := lower(current_setting('forge_flow.launch_admin_email'));
  regular_email constant text := lower(current_setting('forge_flow.launch_regular_email'));

  admin_user_id uuid;
  regular_user_id uuid;
  regular_operator_id uuid;
  regular_location_id uuid;

  admin_role_id uuid;
  supervisor_role_id uuid;
  supervisor_scope text;

  regular_revoked integer := 0;
  regular_supervisor_inserted integer := 0;
  regular_admin_deleted integer := 0;
  regular_user_bumped integer := 0;
  admin_grant_inserted integer := 0;
  admin_operator_changed integer := 0;
  admin_user_bumped integer := 0;
begin
  select u.user_id
    into admin_user_id
    from public.users u
   where lower(u.email) = admin_email
     and u.deleted_at is null
   limit 1;

  if admin_user_id is null then
    raise exception 'admin account % was not found in public.users', admin_email;
  end if;

  select u.user_id,
         u.operator_id,
         coalesce(u.primary_location_id, o.primary_location_id)
    into regular_user_id,
         regular_operator_id,
         regular_location_id
    from public.users u
    left join public.operators o on o.operator_id = u.operator_id
   where lower(u.email) = regular_email
     and u.deleted_at is null
   limit 1;

  if regular_user_id is null then
    raise exception 'regular account % was not found in public.users', regular_email;
  end if;

  if regular_operator_id is null then
    raise exception 'regular account % has no operator_id', regular_email;
  end if;

  select r.role_id
    into admin_role_id
    from public.roles r
   where r.operator_id is null
     and r.role_key = 'super_admin'
     and r.deleted_at is null
   limit 1;

  if admin_role_id is null then
    raise exception 'seeded role super_admin was not found';
  end if;

  select r.role_id
    into supervisor_role_id
    from public.roles r
   where r.operator_id is null
     and r.role_key = 'supervisor'
     and r.deleted_at is null
   limit 1;

  if supervisor_role_id is null then
    raise exception 'seeded role supervisor was not found';
  end if;

  supervisor_scope := case
    when regular_location_id is null then 'operator_wide'
    else 'location'
  end;

  update public.user_roles ur
     set revoked_at = now(),
         revoked_by = admin_user_id,
         reason = 'launch account role enforcement: regular account is not admin',
         updated_at = now()
    from public.roles r
   where ur.role_id = r.role_id
     and ur.user_id = regular_user_id
     and ur.revoked_at is null
     and r.role_key in (
       'super_admin',
       'ff_support',
       'operator_owner',
       'operator_general_manager',
       'operator_manager',
       'operator_supervisor',
       'operator_staff'
     );
  get diagnostics regular_revoked = row_count;

  with inserted as (
    insert into public.user_roles (
      user_role_id,
      user_id,
      role_id,
      operator_id,
      location_id,
      org_unit_id,
      scope_type,
      valid_from,
      valid_until,
      granted_by,
      reason,
      created_at,
      updated_at
    )
    select gen_random_uuid(),
           regular_user_id,
           supervisor_role_id,
           regular_operator_id,
           regular_location_id,
           null,
           supervisor_scope,
           now(),
           null,
           admin_user_id,
           'launch account role enforcement: regular account supervisor role',
           now(),
           now()
     where not exists (
       select 1
         from public.user_roles existing
        where existing.user_id = regular_user_id
          and existing.operator_id = regular_operator_id
          and existing.role_id = supervisor_role_id
          and existing.revoked_at is null
          and coalesce(
            existing.location_id,
            '00000000-0000-0000-0000-000000000000'::uuid
          ) = coalesce(
            regular_location_id,
            '00000000-0000-0000-0000-000000000000'::uuid
          )
     )
    returning 1
  )
  select count(*) into regular_supervisor_inserted from inserted;

  delete from public.operator_admins
   where user_id = regular_user_id;
  get diagnostics regular_admin_deleted = row_count;

  update public.users
     set primary_role_id = supervisor_role_id,
         roles_version = roles_version + 1,
         updated_at = now()
   where user_id = regular_user_id
     and (
       primary_role_id is distinct from supervisor_role_id
       or regular_revoked > 0
       or regular_supervisor_inserted > 0
       or regular_admin_deleted > 0
     );
  get diagnostics regular_user_bumped = row_count;

  with inserted as (
    insert into public.user_roles (
      user_role_id,
      user_id,
      role_id,
      operator_id,
      location_id,
      org_unit_id,
      scope_type,
      valid_from,
      valid_until,
      granted_by,
      reason,
      created_at,
      updated_at
    )
    select gen_random_uuid(),
           admin_user_id,
           admin_role_id,
           regular_operator_id,
           null,
           null,
           'operator_wide',
           now(),
           null,
           admin_user_id,
           'launch account role enforcement: highest admin account',
           now(),
           now()
     where not exists (
       select 1
         from public.user_roles existing
        where existing.user_id = admin_user_id
          and existing.operator_id = regular_operator_id
          and existing.role_id = admin_role_id
          and existing.location_id is null
          and existing.revoked_at is null
     )
    returning 1
  )
  select count(*) into admin_grant_inserted from inserted;

  with changed as (
    insert into public.operator_admins (
      user_id,
      operator_id,
      is_super_admin,
      scope_type,
      scope_location_id,
      valid_from,
      valid_until,
      created_at,
      updated_at
    )
    values (
      admin_user_id,
      regular_operator_id,
      true,
      'super_admin',
      null,
      now(),
      null,
      now(),
      now()
    )
    on conflict (user_id, operator_id) do update
       set is_super_admin = true,
           scope_type = 'super_admin',
           scope_location_id = null,
           valid_until = null,
           updated_at = now()
     where public.operator_admins.is_super_admin is distinct from true
        or public.operator_admins.scope_type is distinct from 'super_admin'
        or public.operator_admins.scope_location_id is not null
        or public.operator_admins.valid_until is not null
    returning 1
  )
  select count(*) into admin_operator_changed from changed;

  update public.users
     set primary_role_id = admin_role_id,
         roles_version = roles_version + 1,
         updated_at = now()
   where user_id = admin_user_id
     and (
       primary_role_id is distinct from admin_role_id
       or admin_grant_inserted > 0
       or admin_operator_changed > 0
     );
  get diagnostics admin_user_bumped = row_count;

  raise notice 'launch account roles enforced: admin %, regular %, operator %, admin grant inserts %, admin assignment changes %, regular admin revokes %, regular supervisor inserts %, regular admin deletes %, user bumps admin/regular %/%',
    admin_email,
    regular_email,
    regular_operator_id,
    admin_grant_inserted,
    admin_operator_changed,
    regular_revoked,
    regular_supervisor_inserted,
    regular_admin_deleted,
    admin_user_bumped,
    regular_user_bumped;
end
$$;

__TX_END__
'@.Replace('__TX_END__', $transactionEnd)

$firebaseUidRepairQuery = @'
\set ON_ERROR_STOP on
begin;

create temporary table launch_firebase_uid_repair (
  kind text primary key,
  email text not null,
  firebase_uid text not null
) on commit drop;

insert into launch_firebase_uid_repair (kind, email, firebase_uid)
values
  ('admin', lower(:'admin_email'), :'admin_firebase_uid'),
  ('regular', lower(:'regular_email'), :'regular_firebase_uid');

do $$
declare
  conflict_message text;
  updated_count integer := 0;
begin
  select format(
           '%s Firebase UID is already linked to another active Postgres user: %s',
           r.kind,
           u.email
         )
    into conflict_message
    from launch_firebase_uid_repair r
    join public.users u
      on u.firebase_uid = r.firebase_uid
   where lower(u.email) <> r.email
     and u.deleted_at is null
   limit 1;

  if conflict_message is not null then
    raise exception '%', conflict_message;
  end if;

  update public.users u
     set firebase_uid = r.firebase_uid,
         roles_version = roles_version + 1,
         updated_at = now()
    from launch_firebase_uid_repair r
   where lower(u.email) = r.email
     and u.deleted_at is null
     and u.firebase_uid is distinct from r.firebase_uid;
  get diagnostics updated_count = row_count;

  raise notice 'launch Firebase UID links reconciled, rows updated %',
    updated_count;
end
$$;

commit;
'@

$claimsQuery = @'
\set ON_ERROR_STOP on
with launch_accounts as (
  select
    'admin'::text as kind,
    a.user_id,
    a.firebase_uid::text,
    regular_u.operator_id,
    coalesce(
      regular_u.primary_location_id,
      regular_operator.primary_location_id
    ) as location_id,
    a.roles_version
  from public.users a
  cross join public.users regular_u
  left join public.operators regular_operator
    on regular_operator.operator_id = regular_u.operator_id
  where lower(a.email) = lower(:'admin_email')
    and lower(regular_u.email) = lower(:'regular_email')
    and a.deleted_at is null
    and regular_u.deleted_at is null

  union all

  select
    'regular'::text as kind,
    regular_u.user_id,
    regular_u.firebase_uid::text,
    regular_u.operator_id,
    coalesce(
      regular_u.primary_location_id,
      regular_operator.primary_location_id
    ) as location_id,
    regular_u.roles_version
  from public.users a
  cross join public.users regular_u
  left join public.operators regular_operator
    on regular_operator.operator_id = regular_u.operator_id
  where lower(a.email) = lower(:'admin_email')
    and lower(regular_u.email) = lower(:'regular_email')
    and a.deleted_at is null
    and regular_u.deleted_at is null
)
select json_object_agg(kind, account_json)::text
from (
  select
    kind,
    json_build_object(
      'firebase_uid', firebase_uid,
      'postgres_user_id', user_id::text,
      'operator_id', operator_id::text,
      'location_id', location_id::text,
      'roles_version', roles_version,
      'is_super_admin', (
        exists (
          select 1
          from public.user_roles ur
          join public.roles r on r.role_id = ur.role_id
          where ur.user_id = launch_accounts.user_id
            and ur.operator_id = launch_accounts.operator_id
            and ur.revoked_at is null
            and (ur.valid_until is null or ur.valid_until > now())
            and ur.valid_from <= now()
            and r.operator_id is null
            and r.role_key = 'super_admin'
            and r.deleted_at is null
        )
        or exists (
          select 1
          from public.operator_admins oa
          where oa.user_id = launch_accounts.user_id
            and oa.operator_id = launch_accounts.operator_id
            and oa.valid_from <= now()
            and (oa.valid_until is null or oa.valid_until > now())
            and (
              oa.is_super_admin is true
              or oa.scope_type = 'super_admin'
            )
        )
      ),
      'is_ff_support', (
        exists (
          select 1
          from public.user_roles ur
          join public.roles r on r.role_id = ur.role_id
          where ur.user_id = launch_accounts.user_id
            and ur.operator_id = launch_accounts.operator_id
            and ur.revoked_at is null
            and (ur.valid_until is null or ur.valid_until > now())
            and ur.valid_from <= now()
            and r.operator_id is null
            and r.role_key = 'ff_support'
            and r.deleted_at is null
        )
        or exists (
          select 1
          from public.operator_admins oa
          where oa.user_id = launch_accounts.user_id
            and oa.operator_id = launch_accounts.operator_id
            and oa.valid_from <= now()
            and (oa.valid_until is null or oa.valid_until > now())
            and oa.scope_type = 'ff_support'
        )
      )
    ) as account_json
  from launch_accounts
) projected;
'@

try {
  $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText($tempSql, $roleSql, $utf8NoBom)
  [System.IO.File]::WriteAllText(
    $uidRepairSql,
    $firebaseUidRepairQuery,
    $utf8NoBom
  )
  [System.IO.File]::WriteAllText($claimsSql, $claimsQuery, $utf8NoBom)

  Write-Host 'Applying launch account role enforcement.'
  if ($DryRun) {
    Write-Host 'Mode: dry run, transaction will roll back.'
  } else {
    Write-Host 'Mode: apply, transaction will commit.'
  }

  & $psqlPath `
    -v ON_ERROR_STOP=1 `
    -v "admin_email=$AdminEmail" `
    -v "regular_email=$RegularEmail" `
    -f $tempSql `
    $effectiveConnectionString
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

  if ($RefreshFirebaseClaims) {
    Assert-NonBlank -Name 'FIREBASE_PROJECT_ID' -Value $FirebaseProjectId
    $gcloudCommand = Get-Command gcloud -ErrorAction SilentlyContinue
    if ($null -eq $gcloudCommand) {
      Write-Host 'BLOCKED: gcloud was not found on PATH'
      exit 1
    }
    $gcloudPath = if ($gcloudCommand.Source) { $gcloudCommand.Source } else { $gcloudCommand.Path }

    $firebaseUidType = (
      "select data_type from information_schema.columns where " +
      "table_schema = 'public' and table_name = 'users' and " +
      "column_name = 'firebase_uid'"
    ) | & $psqlPath `
      -v ON_ERROR_STOP=1 `
      -t `
      -A `
      $effectiveConnectionString
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    $firebaseUidType = ($firebaseUidType |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      Select-Object -Last 1).Trim()
    if ($firebaseUidType -ne 'text') {
      Write-Host 'BLOCKED: public.users.firebase_uid must be text before Firebase claim refresh.'
      Write-Host 'Apply db/migrations/202605020300_phase_9_firebase_uid_text.sql first.'
      exit 1
    }

    $accessToken = $null
    if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('GOOGLE_APPLICATION_CREDENTIALS'))) {
      $accessToken = & $gcloudPath auth application-default print-access-token
    }
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($accessToken)) {
      $accessToken = & $gcloudPath auth print-access-token
    }
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($accessToken)) {
      Write-Host 'BLOCKED: could not obtain a gcloud access token'
      exit 1
    }

    function Get-FirebaseAccountByEmail {
      param([string] $Email)

      $body = @{
        email = @($Email)
      } | ConvertTo-Json -Compress
      $uri = "https://identitytoolkit.googleapis.com/v1/projects/$([Uri]::EscapeDataString($FirebaseProjectId))/accounts:lookup"
      $response = Invoke-RestMethod `
        -Method Post `
        -Uri $uri `
        -Headers @{ Authorization = "Bearer $accessToken" } `
        -ContentType 'application/json' `
        -Body $body
      $user = @($response.users) | Select-Object -First 1
      if ($null -eq $user -or [string]::IsNullOrWhiteSpace([string] $user.localId)) {
        Write-Host "BLOCKED: Firebase account was not found for $Email"
        exit 1
      }
      return $user
    }

    $adminFirebaseAccount = Get-FirebaseAccountByEmail -Email $AdminEmail
    $regularFirebaseAccount = Get-FirebaseAccountByEmail -Email $RegularEmail
    if (
      [string] $adminFirebaseAccount.localId -eq
      [string] $regularFirebaseAccount.localId
    ) {
      Write-Host 'BLOCKED: admin and regular emails resolved to the same Firebase UID'
      exit 1
    }

    & $psqlPath `
      -v ON_ERROR_STOP=1 `
      -v "admin_email=$AdminEmail" `
      -v "regular_email=$RegularEmail" `
      -v "admin_firebase_uid=$($adminFirebaseAccount.localId)" `
      -v "regular_firebase_uid=$($regularFirebaseAccount.localId)" `
      -f $uidRepairSql `
      $effectiveConnectionString
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $claimsRaw = & $psqlPath `
      -v ON_ERROR_STOP=1 `
      -v "admin_email=$AdminEmail" `
      -v "regular_email=$RegularEmail" `
      -t `
      -A `
      -f $claimsSql `
      $effectiveConnectionString
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $claimsJson = $claimsRaw |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      Select-Object -Last 1
    if ([string]::IsNullOrWhiteSpace($claimsJson)) {
      Write-Host 'BLOCKED: account claim lookup returned no rows'
      exit 1
    }
    $claims = $claimsJson | ConvertFrom-Json

    if (
      $claims.admin.is_super_admin -ne $true -and
      $claims.admin.is_ff_support -ne $true
    ) {
      Write-Host 'BLOCKED: admin account projection does not contain an admin claim'
      exit 1
    }
    if (
      $claims.regular.is_super_admin -eq $true -or
      $claims.regular.is_ff_support -eq $true
    ) {
      Write-Host 'BLOCKED: regular account projection still contains an admin claim'
      exit 1
    }

    function Set-FirebaseCustomClaims {
      param([object] $Account)

      $customClaims = [ordered] @{
        postgres_user_id = [string] $Account.postgres_user_id
        operator_id = [string] $Account.operator_id
        location_id = [string] $Account.location_id
        roles_version = [int] $Account.roles_version
      }
      if ($Account.is_super_admin -eq $true) {
        $customClaims.is_super_admin = $true
      }
      if ($Account.is_ff_support -eq $true) {
        $customClaims.is_ff_support = $true
      }

      $body = @{
        localId = [string] $Account.firebase_uid
        customAttributes = ($customClaims | ConvertTo-Json -Compress)
      } | ConvertTo-Json -Compress -Depth 6

      $uri = "https://identitytoolkit.googleapis.com/v1/projects/$([Uri]::EscapeDataString($FirebaseProjectId))/accounts:update"
      Invoke-RestMethod `
        -Method Post `
        -Uri $uri `
        -Headers @{ Authorization = "Bearer $accessToken" } `
        -ContentType 'application/json' `
        -Body $body | Out-Null
    }

    Set-FirebaseCustomClaims -Account $claims.admin
    Set-FirebaseCustomClaims -Account $claims.regular
    Write-Host 'Firebase custom claims refreshed for admin and regular accounts.'
  }

  Write-Host 'Done. Ask active clients to sign out and sign in so fresh ID tokens are used.'
} finally {
  if (Test-Path -LiteralPath $tempSql) {
    Remove-Item -LiteralPath $tempSql -Force
  }
  if (Test-Path -LiteralPath $uidRepairSql) {
    Remove-Item -LiteralPath $uidRepairSql -Force
  }
  if (Test-Path -LiteralPath $claimsSql) {
    Remove-Item -LiteralPath $claimsSql -Force
  }
  if (
    -not [string]::IsNullOrWhiteSpace($tempRootBundle) -and
    (Test-Path -LiteralPath $tempRootBundle)
  ) {
    Remove-Item -LiteralPath $tempRootBundle -Force
  }
}
