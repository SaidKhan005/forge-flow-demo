# Daily graph-refresh routine. Runs at 7am via Windows Task Scheduler.
# Complements the post-commit hook and manual /graphify --update workflow.
#
# Steps:
#   1. git pull --rebase
#   2. regenerate docs/contracts/migrations_summary.md
#   3. claude -p "/graphify --update ." headlessly
#   4. commit + push if migrations_summary.md changed
#      (graphify-out/ is gitignored, so it stays local; only the
#       migrations summary triggers commits.)

$ErrorActionPreference = 'Stop'
$logDir = Join-Path $env:USERPROFILE 'AppData\Local\ForgeFlow\logs'
$null = New-Item -ItemType Directory -Force -Path $logDir
$logFile = Join-Path $logDir ("refresh_graph_" + (Get-Date -Format "yyyy-MM-dd") + ".log")

function Resolve-Python {
    if ($env:FORGE_FLOW_PYTHON) {
        return $env:FORGE_FLOW_PYTHON
    }

    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        return $python.Source
    }

    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) {
        return $py.Source
    }

    throw 'Python not found. Set FORGE_FLOW_PYTHON to the interpreter path.'
}

Start-Transcript -Path $logFile -Append | Out-Null

try {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    Set-Location $repoRoot

    Write-Host "[$(Get-Date -f HH:mm:ss)] git pull..."
    git pull --rebase origin master

    Write-Host "[$(Get-Date -f HH:mm:ss)] regenerate migrations summary..."
    $python = Resolve-Python
    if ((Split-Path -Leaf $python) -ieq 'py.exe') {
        & $python -3 scripts/generate_migrations_summary.py
    } else {
        & $python scripts/generate_migrations_summary.py
    }

    Write-Host "[$(Get-Date -f HH:mm:ss)] /graphify --update . (this can take 10-30 min on heavy days)..."
    claude -p '/graphify --update .'

    Write-Host "[$(Get-Date -f HH:mm:ss)] staging migrations summary..."
    git add docs/contracts/migrations_summary.md
    $staged = git diff --cached --name-only

    if (-not $staged) {
        Write-Host "[$(Get-Date -f HH:mm:ss)] no migration changes; graph refreshed locally, nothing to commit."
    } else {
        $today = Get-Date -Format "yyyy-MM-dd"
        git commit -m "graph update $today"
        git push origin master
        Write-Host "[$(Get-Date -f HH:mm:ss)] pushed."
    }
}
catch {
    Write-Host "[$(Get-Date -f HH:mm:ss)] FAILED: $_"
    exit 1
}
finally {
    Stop-Transcript | Out-Null
}
