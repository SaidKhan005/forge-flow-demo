[CmdletBinding()]
param(
    [switch]$StagedOnly
)

$ErrorActionPreference = 'Stop'

function Invoke-GitList {
    param([string[]]$GitArgs)

    $output = & git @GitArgs
    if ($LASTEXITCODE -ne 0) {
        throw "git $($GitArgs -join ' ') failed"
    }

    return @($output | Where-Object { $_ -and $_.Trim() })
}

function Test-PathMatch {
    param(
        [string[]]$Paths,
        [string[]]$Patterns
    )

    foreach ($path in $Paths) {
        foreach ($pattern in $Patterns) {
            if ($path -match $pattern) {
                return $true
            }
        }
    }
    return $false
}

$repoRoot = (& git rev-parse --show-toplevel 2>$null).Trim()
if (-not $repoRoot) {
    throw 'Not inside a git repository.'
}

Set-Location $repoRoot

$staged = Invoke-GitList @('diff', '--cached', '--name-only')
$unstaged = if ($StagedOnly) { @() } else { Invoke-GitList @('diff', '--name-only') }
$untracked = if ($StagedOnly) { @() } else { Invoke-GitList @('ls-files', '--others', '--exclude-standard') }
$allChanged = @($staged + $unstaged + $untracked) | Sort-Object -Unique

$repoRootPosix = $repoRoot -replace '\\', '/'
$inAgentWorktree = $repoRootPosix -match '/\.claude/worktrees/|/\.codex_worktrees/'

$hasMigrations = Test-PathMatch $allChanged @('^db/migrations/.*\.sql$')
$hasTracker = Test-PathMatch $allChanged @('^PROJECT_TRACKER\.md$')
$hasWalkthrough = Test-PathMatch $allChanged @('^docs/_walkthroughs/')
$hasPhaseDoc = Test-PathMatch $allChanged @('^docs/phases/')
$hasContracts = Test-PathMatch $allChanged @('^docs/contracts/')
$hasUi = Test-PathMatch $allChanged @('^(lib/screens|lib/widgets|web|tool/advisor_proxy/.*admin|tool/advisor_proxy/.*operator)')
$hasProxy = Test-PathMatch $allChanged @('^tool/advisor_proxy/')
$hasScripts = Test-PathMatch $allChanged @('^(scripts|tool)/')
$hasCode = Test-PathMatch $allChanged @('^(lib|tool|test|integration_test|web|android|ios|windows|db|scripts|infrastructure)/|^(pubspec\.yaml|pubspec\.lock|analysis_options\.yaml|Dockerfile|Dockerfile\..*)$')

Write-Host 'Forge & Flow closeout check'
Write-Host "Repo: $repoRoot"
if ($StagedOnly) {
    Write-Host 'Scope: staged files only'
} else {
    Write-Host 'Scope: staged, unstaged, and untracked files'
}
Write-Host ''

if ($inAgentWorktree) {
    Write-Warning 'You are in an agent worktree. Commit/push should happen from the main repo after review/merge.'
    Write-Host ''
}

Write-Host 'Change Summary'
Write-Host "  Staged:    $($staged.Count)"
Write-Host "  Unstaged:  $($unstaged.Count)"
Write-Host "  Untracked: $($untracked.Count)"

if ($allChanged.Count -eq 0) {
    Write-Host ''
    Write-Host 'No local changes detected.'
    exit 0
}

Write-Host ''
Write-Host 'Touched Surfaces'
Write-Host "  Migrations:  $(if ($hasMigrations) { 'yes' } else { 'no' })"
Write-Host "  Tracker:     $(if ($hasTracker) { 'yes' } else { 'no' })"
Write-Host "  Walkthrough: $(if ($hasWalkthrough) { 'yes' } else { 'no' })"
Write-Host "  Phase docs:  $(if ($hasPhaseDoc) { 'yes' } else { 'no' })"
Write-Host "  Contracts:   $(if ($hasContracts) { 'yes' } else { 'no' })"
Write-Host "  UI/web:      $(if ($hasUi) { 'yes' } else { 'no' })"
Write-Host "  Proxy:       $(if ($hasProxy) { 'yes' } else { 'no' })"
Write-Host "  Scripts:     $(if ($hasScripts) { 'yes' } else { 'no' })"

Write-Host ''
Write-Host 'Expected Checks'
if ($hasMigrations) {
    Write-Host '  - dart run tool/migration_drift_scanner.dart --fix --strict-docs'
    Write-Host '  - dart run tool/migration_cutoff_lint.dart'
    Write-Host '  - Consider dart run tool/index_leading_column_lint.dart and dart run tool/rls_policy_lint.dart when indexes/RLS policies changed.'
}
if ($hasProxy) {
    Write-Host '  - Run focused proxy/runtime tests for touched advisor_proxy routes or services.'
}
if ($hasUi) {
    Write-Host '  - Run focused Flutter/widget tests where available.'
    Write-Host '  - Capture Browser Use or equivalent visual evidence for user-visible admin/web/mobile behavior.'
}
if ($hasCode -and -not $hasMigrations -and -not $hasProxy -and -not $hasUi) {
    Write-Host '  - Run the smallest meaningful focused test or lint for the touched code.'
}
if ($hasTracker) {
    Write-Host '  - Confirm tracker status is supported by implementation, tests, and evidence.'
}
if ($hasWalkthrough) {
    Write-Host '  - Ensure walkthrough evidence lists exact commands and honest results.'
}
if (-not ($hasMigrations -or $hasProxy -or $hasUi -or $hasCode -or $hasTracker -or $hasWalkthrough)) {
    Write-Host '  - Documentation-only change: verify links, authority order, and scope.'
}

Write-Host ''
Write-Host 'Cheap Push Lints'
Write-Host '  - pre-push runs repo lints after hooks are installed with scripts/install_git_hooks.ps1.'
Write-Host '  - It does not run graphify, Flutter full tests, providers, or cloud actions.'
