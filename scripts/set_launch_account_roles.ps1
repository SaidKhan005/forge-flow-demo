# Launch account role enforcement.
#
# Durable staging/prod repair for the launch smoke accounts:
#   * saidumarkhan005@gmail.com becomes the highest admin account.
#   * newoundlandlimited@gmail.com is kept as a regular staff user.
#
# This script never stores credentials in the repo and never prints
# connection strings. It expects POSTGRES_ADMIN_URL from the existing
# non-repo secret loader. When -RefreshFirebaseClaims is supplied, it
# also expects FIREBASE_PROJECT_ID and a gcloud login that can call
# Identity Toolkit accounts:update.

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
  staff_role_id uuid;
  staff_scope text;

  regular_revoked integer := 0;
  regular_staff_inserted integer := 0;
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
    into staff_role_id
    from public.roles r
   where r.operator_id is null
     and r.role_key = 'operator_staff'
     and r.deleted_at is null
   limit 1;

  if staff_role_id is null then
    raise exception 'seeded role operator_staff was not found';
  end if;

  staff_scope := case
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
       'operator_manager',
       'operator_supervisor'
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
           staff_role_id,
           regular_operator_id,
           regular_location_id,
           null,
           staff_scope,
           now(),
           null,
           admin_user_id,
           'launch account role enforcement: regular account staff role',
           now(),
           now()
     where not exists (
       select 1
         from public.user_roles existing
        where existing.user_id = regular_user_id
          and existing.operator_id = regular_operator_id
          and existing.role_id = staff_role_id
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
  select count(*) into regular_staff_inserted from inserted;

  delete from public.operator_admins
   where user_id = regular_user_id;
  get diagnostics regular_admin_deleted = row_count;

  update public.users
     set primary_role_id = staff_role_id,
         roles_version = roles_version + 1,
         updated_at = now()
   where user_id = regular_user_id
     and (
       primary_role_id is distinct from staff_role_id
       or regular_revoked > 0
       or regular_staff_inserted > 0
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

  raise notice 'launch account roles enforced: admin %, regular %, operator %, admin grant inserts %, admin assignment changes %, regular admin revokes %, regular staff inserts %, regular admin deletes %, user bumps admin/regular %/%',
    admin_email,
    regular_email,
    regular_operator_id,
    admin_grant_inserted,
    admin_operator_changed,
    regular_revoked,
    regular_staff_inserted,
    regular_admin_deleted,
    admin_user_bumped,
    regular_user_bumped;
end
$$;

__TX_END__
'@.Replace('__TX_END__', $transactionEnd)

$claimsQuery = @'
\set ON_ERROR_STOP on
select json_build_object(
  'admin', json_build_object(
    'firebase_uid', a.firebase_uid::text,
    'postgres_user_id', a.user_id::text,
    'operator_id', regular_u.operator_id::text,
    'location_id', coalesce(
      regular_u.primary_location_id::text,
      regular_operator.primary_location_id::text
    ),
    'roles_version', a.roles_version
  ),
  'regular', json_build_object(
    'firebase_uid', regular_u.firebase_uid::text,
    'postgres_user_id', regular_u.user_id::text,
    'operator_id', regular_u.operator_id::text,
    'location_id', coalesce(
      regular_u.primary_location_id::text,
      regular_operator.primary_location_id::text
    ),
    'roles_version', regular_u.roles_version
  )
)::text
from public.users a
cross join public.users regular_u
left join public.operators regular_operator
  on regular_operator.operator_id = regular_u.operator_id
where lower(a.email) = lower(:'admin_email')
  and lower(regular_u.email) = lower(:'regular_email')
  and a.deleted_at is null
  and regular_u.deleted_at is null
limit 1;
'@

try {
  $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText($tempSql, $roleSql, $utf8NoBom)
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

    function Set-FirebaseCustomClaims {
      param(
        [object] $Account,
        [bool] $IsSuperAdmin
      )

      $customClaims = [ordered] @{
        postgres_user_id = [string] $Account.postgres_user_id
        operator_id = [string] $Account.operator_id
        location_id = [string] $Account.location_id
        roles_version = [int] $Account.roles_version
      }
      if ($IsSuperAdmin) {
        $customClaims.is_super_admin = $true
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

    Set-FirebaseCustomClaims -Account $claims.admin -IsSuperAdmin $true
    Set-FirebaseCustomClaims -Account $claims.regular -IsSuperAdmin $false
    Write-Host 'Firebase custom claims refreshed for admin and regular accounts.'
  }

  Write-Host 'Done. Ask active clients to sign out and sign in so fresh ID tokens are used.'
} finally {
  if (Test-Path -LiteralPath $tempSql) {
    Remove-Item -LiteralPath $tempSql -Force
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
