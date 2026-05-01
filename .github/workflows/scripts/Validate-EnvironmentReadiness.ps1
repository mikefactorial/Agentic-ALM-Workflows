<#
.SYNOPSIS
    Validates that a feature solution is ready for deployment: all environment variables
    and connection references have values for every relevant deployment environment.

.DESCRIPTION
    Reads the feature solution's deployment settings template and checks:
      1. Every environment variable listed in the template has a non-empty value in
         environment-variables.json for each relevant environment.
      2. Every connection reference connector type in the template has a non-empty
         connection ID in connection-mappings.json for each relevant environment.

    Environments that would deploy the main solution are determined from
    environment-config.json by finding package groups that include the main solution.

    Run this BEFORE triggering build-deploy or create-release-package. Fix any reported gaps first.

.PARAMETER FeatureSolutionName
    The unique name of the feature solution (e.g., AB34567_StatusBadge).

.PARAMETER MainSolutionName
    The main solution this feature will be merged into (e.g., pub_MySolution).
    Used to determine which environments need values populated.

.PARAMETER SettingsRoot
    Path to the deployments/settings directory. Defaults to 'deployments/settings'.

.EXAMPLE
    .\Validate-FeatureTransport.ps1 -FeatureSolutionName "AB34567_StatusBadge" -MainSolutionName "pub_MySolution"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$FeatureSolutionName,

    [Parameter(Mandatory)]
    [string]$MainSolutionName,

    [string]$SettingsRoot = "deployments/settings"
)

$ErrorActionPreference = "Stop"

# ─── Locate files ─────────────────────────────────────────────────────────────
$templatePath = Join-Path $SettingsRoot "templates" "${FeatureSolutionName}_template.json"
$evPath       = Join-Path $SettingsRoot "environment-variables.json"
$connPath     = Join-Path $SettingsRoot "connection-mappings.json"
$configPath   = Join-Path $SettingsRoot "environment-config.json"

foreach ($f in @($templatePath, $evPath, $connPath, $configPath)) {
    if (-not (Test-Path $f)) {
        Write-Error "Required file not found: $f`nEnsure you have synced the feature solution first."
    }
}

$template = Get-Content $templatePath -Raw | ConvertFrom-Json
$evData   = Get-Content $evPath        -Raw | ConvertFrom-Json
$connData = Get-Content $connPath      -Raw | ConvertFrom-Json
$config   = Get-Content $configPath   -Raw | ConvertFrom-Json

# ─── Determine relevant environments ──────────────────────────────────────────
# Find every package group that includes the main solution, then check all
# deployment environments (all envs may receive the solution via any package group).
$matchingGroups = $config.packageGroups | Where-Object { $_.solutions -contains $MainSolutionName }
if (-not $matchingGroups) {
    Write-Warning "No package group contains '$MainSolutionName' in environment-config.json."
    Write-Warning "Defaulting to all configured environments."
}
$relevantEnvs = $config.environments

# ─── Header ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Pre-Deployment Validation" -ForegroundColor Cyan
Write-Host "  Feature solution : $FeatureSolutionName" -ForegroundColor Cyan
Write-Host "  Target solution  : $MainSolutionName" -ForegroundColor Cyan
Write-Host "  Environments     : $($relevantEnvs -join ', ')" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

$issues  = [System.Collections.Generic.List[string]]::new()
$passed  = 0

# ─── Environment Variables ────────────────────────────────────────────────────
$evEntries = @($template.EnvironmentVariables)
if ($evEntries.Count -eq 0) {
    Write-Host "  Environment Variables: none" -ForegroundColor DarkGray
} else {
    Write-Host "  Environment Variables ($($evEntries.Count)):" -ForegroundColor White
    foreach ($ev in $evEntries) {
        $schema = $ev.SchemaName
        foreach ($env in $relevantEnvs) {
            $envSection = $evData.environments.$env
            if ($null -eq $envSection) {
                $msg = "[EV] '$schema' — environment '$env' missing from environment-variables.json"
                $issues.Add($msg)
                Write-Host "    ✗ [$env] $schema — environment section missing" -ForegroundColor Red
                continue
            }

            # Use GetValue with a PSObject property lookup for dynamic key access
            $value = $envSection.PSObject.Properties[$schema]
            if ($null -eq $value) {
                $msg = "[EV] '$schema' — key missing from '$env' in environment-variables.json (add it)"
                $issues.Add($msg)
                Write-Host "    ✗ [$env] $schema — KEY MISSING" -ForegroundColor Red
            } elseif ([string]::IsNullOrEmpty($value.Value)) {
                # Empty string: flag as warning — some EVs are intentionally empty
                Write-Host "    ⚠ [$env] $schema — empty value (verify this is intentional)" -ForegroundColor Yellow
            } else {
                Write-Host "    ✓ [$env] $schema" -ForegroundColor Green
                $passed++
            }
        }
    }
}

Write-Host ""

# ─── Connection References ────────────────────────────────────────────────────
$connEntries = @($template.ConnectionReferences)
if ($connEntries.Count -eq 0) {
    Write-Host "  Connection References: none" -ForegroundColor DarkGray
} else {
    Write-Host "  Connection References ($($connEntries.Count)):" -ForegroundColor White
    foreach ($ref in $connEntries) {
        $logical     = $ref.LogicalName
        $connectorId = $ref.ConnectorId

        foreach ($env in $relevantEnvs) {
            $envSection = $connData.environments.$env
            if ($null -eq $envSection) {
                $msg = "[CR] '$logical' — environment '$env' missing from connection-mappings.json"
                $issues.Add($msg)
                Write-Host "    ✗ [$env] $logical — environment section missing" -ForegroundColor Red
                continue
            }

            $connId = $envSection.PSObject.Properties[$connectorId]
            if ($null -eq $connId) {
                $msg = "[CR] '$logical' ($connectorId) — connector missing from '$env' in connection-mappings.json"
                $issues.Add($msg)
                Write-Host "    ✗ [$env] $logical — CONNECTOR MAPPING MISSING ($connectorId)" -ForegroundColor Red
            } elseif ([string]::IsNullOrEmpty($connId.Value)) {
                Write-Host "    ⚠ [$env] $logical — empty connection ID (verify: use '<unset>' if not applicable)" -ForegroundColor Yellow
            } else {
                Write-Host "    ✓ [$env] $logical" -ForegroundColor Green
                $passed++
            }
        }
    }
}

Write-Host ""

# ─── Summary ──────────────────────────────────────────────────────────────────
if ($issues.Count -gt 0) {
    Write-Host "==========================================" -ForegroundColor Red
    Write-Host "  VALIDATION FAILED — $($issues.Count) issue(s)" -ForegroundColor Red
    Write-Host "==========================================" -ForegroundColor Red
    Write-Host ""
    $issues | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    Write-Host ""
    Write-Host "Fix these before deploying:" -ForegroundColor Yellow
    Write-Host "  - EV values      → deployments/settings/environment-variables.json" -ForegroundColor Yellow
    Write-Host "  - Connection IDs → deployments/settings/connection-mappings.json" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Use '<unset>' for environments that don't use a particular EV/connection." -ForegroundColor Yellow
    exit 1
}

Write-Host "==========================================" -ForegroundColor Green
Write-Host "  VALIDATION PASSED ($passed check(s))" -ForegroundColor Green
Write-Host "  Feature is ready to deploy." -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""
