# Configure the Firebase Auth email action handler for one Firebase project.
#
# This patches Identity Platform's `notification.sendEmail.callbackUri`, which
# is the actual host Firebase puts in password reset / verification emails.
# `ActionCodeSettings.url` is only the continue URL and does not replace this.
# For production, pass the production Firebase project and a production URL only
# after that host serves the handler successfully.

param(
  [string] $Project = 'forge-flow-staging',
  [string] $ActionUrl = "https://$Project.firebaseapp.com/auth/action",
  [string] $SecretsFile = (Join-Path $HOME '.forge_flow\forge_flow.secrets.ps1')
)

$ErrorActionPreference = 'Stop'

if (Test-Path -LiteralPath $SecretsFile) {
  . $SecretsFile
}

if (-not [string]::IsNullOrWhiteSpace($env:GOOGLE_APPLICATION_CREDENTIALS) -and
    (Test-Path -LiteralPath $env:GOOGLE_APPLICATION_CREDENTIALS)) {
  & gcloud auth activate-service-account `
    --key-file $env:GOOGLE_APPLICATION_CREDENTIALS `
    --project $Project `
    --quiet | Out-Null
}

$token = (& gcloud auth print-access-token).Trim()
if ([string]::IsNullOrWhiteSpace($token)) {
  Write-Host 'BLOCKED: gcloud did not return an access token.'
  exit 1
}

$patchUri = "https://identitytoolkit.googleapis.com/admin/v2/projects/$Project/config?updateMask=notification.sendEmail.callbackUri"
$body = @{
  name = "projects/$Project/config"
  notification = @{
    sendEmail = @{
      callbackUri = $ActionUrl
    }
  }
} | ConvertTo-Json -Depth 10

$headers = @{
  Authorization = "Bearer $token"
  'Content-Type' = 'application/json'
}

$response = Invoke-RestMethod -Method Patch -Uri $patchUri -Headers $headers -Body $body

$secretsText = if (Test-Path -LiteralPath $SecretsFile) {
  [System.IO.File]::ReadAllText($SecretsFile)
} else {
  ''
}

$assignmentPattern = '(?m)^\s*\$env:FORGE_FLOW_AUTH_ACTION_URL\s*=.*$'
$assignment = "`$env:FORGE_FLOW_AUTH_ACTION_URL = '$($ActionUrl.Replace("'", "''"))'"
if ([regex]::IsMatch($secretsText, $assignmentPattern)) {
  $secretsText = [regex]::Replace($secretsText, $assignmentPattern, $assignment)
} else {
  if (-not [string]::IsNullOrEmpty($secretsText) -and -not $secretsText.EndsWith("`n")) {
    $secretsText += "`r`n"
  }
  $secretsText += "`r`n# Reachable Firebase action handler for password reset and auth email links.`r`n$assignment`r`n"
}

if (-not [string]::IsNullOrWhiteSpace($SecretsFile)) {
  $parent = Split-Path -Parent $SecretsFile
  if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent | Out-Null
  }
  [System.IO.File]::WriteAllText($SecretsFile, $secretsText)
}

Write-Host 'Firebase Auth email action callback configured:'
Write-Host " - project: $Project"
Write-Host " - callback host: $(([Uri]$response.notification.sendEmail.callbackUri).Host)"
Write-Host ' - FORGE_FLOW_AUTH_ACTION_URL: PRESENT (value not printed)'
