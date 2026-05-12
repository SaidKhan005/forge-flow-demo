[CmdletBinding()]
param(
    [switch]$Disable
)

$ErrorActionPreference = 'Stop'

$repoRoot = (& git rev-parse --show-toplevel 2>$null).Trim()
if (-not $repoRoot) {
    throw 'Not inside a git repository.'
}

Set-Location $repoRoot

if ($Disable) {
    & git config --unset core.hooksPath 2>$null
    Write-Host 'Forge & Flow git hooks disabled for this clone.'
    exit 0
}

$hookDir = Join-Path $repoRoot '.githooks'
if (-not (Test-Path $hookDir)) {
    throw "Hook directory not found: $hookDir"
}

$requiredHooks = @('pre-commit', 'pre-push')
foreach ($hook in $requiredHooks) {
    $path = Join-Path $hookDir $hook
    if (-not (Test-Path $path)) {
        throw "Required hook missing: $path"
    }
}

& git config core.hooksPath .githooks
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to set core.hooksPath.'
}

$configured = (& git config --get core.hooksPath).Trim()
if ($configured -ne '.githooks') {
    throw "Unexpected core.hooksPath value: $configured"
}

Write-Host 'Forge & Flow git hooks enabled for this clone.'
Write-Host 'Active hooks: pre-commit, pre-push.'
Write-Host 'Graphify remains manual-only; no hook refreshes the graph.'
