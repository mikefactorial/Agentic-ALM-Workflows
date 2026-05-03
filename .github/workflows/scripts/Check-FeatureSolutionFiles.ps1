<#
.SYNOPSIS
    Checks a pull request diff for feature solution files that must not enter develop or main.
.DESCRIPTION
    Reads allowed main solution names from environment-config.json, then inspects changed files
    to detect any src/solutions/<name>/ paths where <name> is not a mainSolution. Fails with
    remediation instructions if violations are found.
.PARAMETER BaseBranch
    The base (target) branch of the pull request.
.PARAMETER HeadSha
    The commit SHA of the pull request head.
.PARAMETER ConfigPath
    Path to environment-config.json. Defaults to deployments/settings/environment-config.json.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$BaseBranch,

    [Parameter(Mandatory = $true)]
    [string]$HeadSha,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "deployments/settings/environment-config.json"
)

$ErrorActionPreference = "Stop"

# --- Read allowed main solutions ---
if (-not (Test-Path $ConfigPath)) {
    Write-Error "environment-config.json not found at '$ConfigPath'"
    exit 1
}

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$mainSolutions = $config.solutionAreas | ForEach-Object { $_.mainSolution } | Where-Object { $_ }

Write-Host "Allowed main solutions: $($mainSolutions -join ', ')"

# --- Get changed files in this PR ---
$changedFiles = git diff --name-only "origin/$BaseBranch...$HeadSha" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "git diff failed: $changedFiles"
    exit 1
}

Write-Host ""
Write-Host "Changed files:"
$changedFiles | ForEach-Object { Write-Host "  $_" }

# --- Find src/solutions/<name>/ paths ---
$solutionPattern = '^src/solutions/([^/]+)/'
$changedSolutions = $changedFiles |
    Where-Object { $_ -match $solutionPattern } |
    ForEach-Object { [regex]::Match($_, $solutionPattern).Groups[1].Value } |
    Sort-Object -Unique

if (-not $changedSolutions) {
    Write-Host ""
    Write-Host "✅ No files under src/solutions/ in this PR."
    exit 0
}

Write-Host ""
Write-Host "Solution folders touched: $($changedSolutions -join ', ')"

# --- Check each solution against the allowed list ---
$violations = $changedSolutions | Where-Object { $_ -notin $mainSolutions }

if (-not $violations) {
    Write-Host ""
    Write-Host "✅ All solution files belong to main solutions. PR is clean."
    exit 0
}

Write-Host ""
Write-Error @"
❌ Feature solution files detected in this PR.

The following solution folders are not main solutions and must not be merged into develop or main:

  $($violations -join "`n  ")

Feature solution folders (src/solutions/<featureSolution>/) are build artifacts for dev-test
and must never enter develop or main.

How to fix:
  Use Create-FeatureCodePR.ps1 from the repo root instead of opening a PR directly from
  your feature branch. That script strips src/solutions/<featureSolution>/ and its settings
  templates before opening the PR, so only code-first changes (plugins, PCF controls, etc.)
  are included.

  .platform/.github/workflows/scripts/Create-FeatureCodePR.ps1 ``
      -featureSolutionName "<featureSolution>" ``
      -baseBranch "develop"
"@
exit 1
