<#
.SYNOPSIS
  Dispatch a slice worker as a headless `claude -p` process in an
  isolated git worktree. New-standard transport (2026-05-15): worker
  execution draws the Agent SDK / `claude -p` $200/mo credit instead
  of the orchestrator's interactive subscription.

.DESCRIPTION
  Workflow standard: orchestrator stays interactive (subscription);
  long parallel slice workers run headless (credit). Worker contract
  is unchanged from the Agent-tool path:
    branch -> implement -> self-audit -> commit + push -> open PR -> STOP
  No --no-verify, no tracker edits, Pattern B audit table in the PR.

  This script:
    1. Creates `.claude/worktrees/<branch-leaf>` off origin/master.
    2. Installs canonical git hooks in the worktree.
    3. Launches `claude -p` headless in that worktree, in the
       background, fully autonomous (bypassPermissions — headless
       cannot answer prompts).
    4. Logs to `.claude/worker-logs/<branch-leaf>.log`.
    5. Prints the PID + log path so the orchestrator can poll
       `gh pr list` for the returning PR.

.PARAMETER Branch
  Full branch name, e.g. claude/per-daypart-slice-5-variance-read.

.PARAMETER PromptFile
  Path to the standalone worker prompt (self-contained markdown).

.PARAMETER Model
  Optional model override. Default: inherit (claude picks).

.EXAMPLE
  ./scripts/dispatch_worker.ps1 `
    -Branch claude/per-daypart-slice-5-variance-read `
    -PromptFile .claude/worker-prompts/slice_5.md

.NOTES
  v1 — TESTING PHASE. Flag set (permission mode, allowed tools,
  output format) is a first guess; tune on first real runs and
  update memory/feedback_agent_sdk_credit_dispatch.md with findings.
  If headless proves flakier than the in-session Agent tool, fall
  back to the Agent tool and accept the subscription draw — the
  Pattern B audit + operator merge gates are non-negotiable either way.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string] $Branch,
  [Parameter(Mandatory = $true)] [string] $PromptFile,
  [string] $Model = ""
)

$ErrorActionPreference = "Stop"

# Native git writes progress to stderr; under ErrorActionPreference=Stop
# PowerShell 5.1 wraps each stderr line as a terminating NativeCommandError
# even on exit code 0. Run git through this helper: stderr is captured (not
# fatal), only a non-zero exit code throws.
function Invoke-Git {
  param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $GitArgs)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $out = & git @GitArgs 2>&1
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  if ($code -ne 0) {
    throw "git $($GitArgs -join ' ') failed (exit $code): $out"
  }
  return $out
}

# --- Resolve the MAIN working tree root ------------------------------------
# This script may be invoked from inside a linked worktree (its scripts/ dir
# is a per-worktree copy), so `git rev-parse --show-toplevel` would return
# the wrong tree. `git worktree list --porcelain` always lists the main
# worktree first.
Push-Location $PSScriptRoot
$wtList   = Invoke-Git worktree list --porcelain
Pop-Location
$mainLine = ($wtList | Select-String '^worktree ' | Select-Object -First 1).ToString()
$repoRoot = ($mainLine -replace '^worktree ', '').Trim()
if (-not (Test-Path $repoRoot)) {
  throw "Could not resolve main worktree root (got: '$repoRoot')"
}

if (-not (Test-Path $PromptFile)) {
  throw "Prompt file not found: $PromptFile"
}
# Resolve to an ABSOLUTE path. The launch below runs cmd.exe with
# -WorkingDirectory set to the fresh worktree (a clean master checkout
# that does NOT contain uncommitted prompt files), so a relative
# `< "$PromptFile"` redirect would resolve against the worktree and
# fail with "The system cannot find the path specified." Absolute path
# makes the stdin redirect work regardless of cmd's working directory.
$PromptFile = (Resolve-Path -LiteralPath $PromptFile).Path
$promptText = Get-Content -Raw -Encoding utf8 $PromptFile

$leaf       = ($Branch -split "/")[-1]
$worktree   = Join-Path $repoRoot ".claude/worktrees/$leaf"
$logDir     = Join-Path $repoRoot ".claude/worker-logs"
$logFile    = Join-Path $logDir "$leaf.log"

New-Item -ItemType Directory -Force -Path $logDir | Out-Null

# --- Create the worktree off latest origin/master --------------------------
Push-Location $repoRoot
Invoke-Git fetch origin --quiet | Out-Null
if (Test-Path $worktree) {
  Write-Host "[dispatch] worktree exists, reusing: $worktree"
} else {
  Invoke-Git worktree add -b $Branch $worktree origin/master | Out-Null
}
Pop-Location

# --- Install canonical hooks in the worktree (per house rule) --------------
# pwsh may not be on PATH (Windows PowerShell-only host); fall back.
$hookScript = Join-Path $repoRoot "scripts/install_git_hooks.ps1"
Push-Location $worktree
try {
  if (Get-Command pwsh -ErrorAction SilentlyContinue) {
    pwsh -NoProfile -File $hookScript | Out-Null
  } else {
    powershell -NoProfile -ExecutionPolicy Bypass -File $hookScript | Out-Null
  }
} catch {
  Write-Warning "[dispatch] hook install warning: $_"
}
Pop-Location

# --- Launch headless claude -p in background -------------------------------
# Windows specifics:
#   * `claude` on Windows is `claude.cmd` (an npm shim batch file). Start-Process
#     cannot exec a .cmd as -FilePath ("%1 is not a valid Win32 application"),
#     so we go through the command processor ($env:ComSpec / cmd.exe).
#   * The prompt is far larger than cmd.exe's ~8191-char command-line limit, so
#     it MUST NOT be passed as an argument. `claude -p` reads the prompt from
#     stdin when no positional prompt is given; we redirect the prompt file in
#     via cmd's `<` so there is no length ceiling.
#   * bypassPermissions: headless has no TTY to approve tool use; the worker
#     runs fully autonomously. Scope is contained by the worktree + the
#     prompt's explicit forbidden list (no --no-verify, no tracker edits).
$modelArg = ""
if ($Model -ne "") { $modelArg = " --model $Model" }
$innerCmd =
  "claude -p --permission-mode bypassPermissions" +
  " --add-dir `"$worktree`"$modelArg" +
  " < `"$PromptFile`""

$proc = Start-Process -FilePath $env:ComSpec `
  -ArgumentList @("/c", $innerCmd) `
  -WorkingDirectory $worktree `
  -RedirectStandardOutput $logFile `
  -RedirectStandardError "$logFile.err" `
  -WindowStyle Hidden `
  -PassThru

[pscustomobject]@{
  Branch   = $Branch
  Worktree = $worktree
  Pid      = $proc.Id
  Log      = $logFile
  ErrLog   = "$logFile.err"
} | Format-List

Write-Host "[dispatch] headless worker launched. Poll: gh pr list --head $Branch"
