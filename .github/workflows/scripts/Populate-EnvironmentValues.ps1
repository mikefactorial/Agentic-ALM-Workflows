<#
.SYNOPSIS
    Populate environment-variables.json and connection-mappings.json from live Dataverse environments

.DESCRIPTION
    Queries each known Dataverse environment via 'pac env fetch' and writes the current
    environment variable values and connection reference IDs into the settings files.
    Existing values are preserved; only <unset> / all-zero placeholder values are overwritten.

.PARAMETER repoRoot
    Path to repository root (default: auto-detected from script location)

.PARAMETER environments
    Comma-separated list of logical env names to process.
    Defaults to all known environments.

.EXAMPLE
    .\Populate-EnvironmentValues.ps1

.EXAMPLE
    .\Populate-EnvironmentValues.ps1 -environments "myapp-test,myapp-prod"
#>
param(
    [string]$repoRoot = "",
    [string]$environments = ""
)

$ErrorActionPreference = "Stop"

# Resolve repo root (scripts/ → workflows/ → .github/ → .platform/ → repo root)
if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..") | Select-Object -ExpandProperty Path
}

# Load logical-name → Dataverse environment URL map from environment-config.json
$envConfigPath = Join-Path $repoRoot "deployments\settings\environment-config.json"
if (-not (Test-Path $envConfigPath)) {
    Write-Error "environment-config.json not found at '$envConfigPath'"
    exit 1
}
$platformConfig = Get-Content $envConfigPath -Raw | ConvertFrom-Json
$envUrlMap = [ordered]@{}
foreach ($env in $platformConfig.environments) {
    $envUrlMap[$env.slug] = $env.url
}

# Filter to requested subset
if (-not [string]::IsNullOrWhiteSpace($environments)) {
    $requested = $environments -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    $filtered  = [ordered]@{}
    foreach ($name in $requested) {
        if ($envUrlMap.Contains($name)) {
            $filtered[$name] = $envUrlMap[$name]
        } else {
            Write-Warning "Unknown environment name: '$name' — skipping"
        }
    }
    $envUrlMap = $filtered
}

# FetchXML queries — use single-quoted XML attributes to avoid PowerShell quote-stripping
$evFetchXml = "<fetch><entity name='environmentvariabledefinition'><attribute name='schemaname'/><link-entity name='environmentvariablevalue' from='environmentvariabledefinitionid' to='environmentvariabledefinitionid' alias='val' link-type='outer'><attribute name='value'/></link-entity></entity></fetch>"
$crFetchXml = "<fetch><entity name='connectionreference'><attribute name='connectorid'/><attribute name='connectionid'/></entity></fetch>"

# Parse fixed-width space-padded pac env fetch output
# Strategy: schema names / connector IDs contain no spaces, so capture with \S+ then the rest.
# Env-var rows:   schemaname<spaces>GUID<rest = value>
# Conn-ref rows:  connectorId<spaces>connectionId<spaces>displayname...
function Parse-EvRows {
    param([string[]]$raw)
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $lines = $raw | Where-Object {
        $s = $_.ToString().Trim()
        $s -ne "" -and
        $s -notmatch '^Connected (as|to)' -and
        $s -notmatch '^Microsoft PowerPlatform' -and
        $s -notmatch '^Version:' -and
        $s -notmatch '^Online documentation' -and
        $s -notmatch '^Feedback,' -and
        $s -notmatch '^Error:' -and
        $s -notmatch '^schemaname'    # skip header
    }
    foreach ($line in $lines) {
        # schema names have no spaces; GUID follows after whitespace padding
        if ($line -match '^(\S+)\s+([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(.*)$') {
            $results.Add([PSCustomObject]@{
                schemaname = $matches[1]
                'val.value' = $matches[3].Trim()
            })
        }
    }
    return $results
}

function Parse-CrRows {
    param([string[]]$raw)
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $lines = $raw | Where-Object {
        $s = $_.ToString().Trim()
        $s -ne "" -and
        $s -notmatch '^Connected (as|to)' -and
        $s -notmatch '^Microsoft PowerPlatform' -and
        $s -notmatch '^Version:' -and
        $s -notmatch '^Online documentation' -and
        $s -notmatch '^Feedback,' -and
        $s -notmatch '^Error:' -and
        $s -notmatch '^connectorid'    # skip header
    }
    foreach ($line in $lines) {
        # PAC output: col1=connectorId (no spaces), col2=connectionId+connectionReferenceId
        # connectionReferenceId (the entity PK) is ALWAYS last 36 chars; connectionId precedes it.
        # When connectionId is null, col2 is exactly 36 chars (just the reference ID).
        if ($line -match '^(\S+)\s+(\S+)') {
            $connectorId = $matches[1]
            $combined    = $matches[2]
            # Only process valid connector IDs; skip stray rows
            if (-not $connectorId.StartsWith('/providers/')) { continue }
            # If combined > 36 chars, the connectionId is the prefix before the last 36-char GUID
            if ($combined.Length -gt 36) {
                $connectionId = $combined.Substring(0, $combined.Length - 36)
                $results.Add([PSCustomObject]@{
                    connectorid  = $connectorId
                    connectionid = $connectionId
                })
            }
            # If combined == 36 chars, connectionId is empty/unset → skip
        }
    }
    return $results
}

# Load settings files
$evPath   = Join-Path $repoRoot "deployments\settings\environment-variables.json"
$connPath = Join-Path $repoRoot "deployments\settings\connection-mappings.json"

$evConfig   = Get-Content $evPath   -Raw | ConvertFrom-Json
$connConfig = Get-Content $connPath -Raw | ConvertFrom-Json

# Remove any non-connector-ID keys that may have been written by a previous buggy run
foreach ($envKey in $connConfig.environments.PSObject.Properties.Name) {
    $slot    = $connConfig.environments.$envKey
    $badKeys = @($slot.PSObject.Properties | Where-Object { $_.Name -notmatch '^/providers/' } | Select-Object -ExpandProperty Name)
    foreach ($bk in $badKeys) { $slot.PSObject.Properties.Remove($bk) }
}

# Process each environment
$totalEvUpdated   = 0
$totalConnUpdated = 0

foreach ($envName in $envUrlMap.Keys) {
    $url = $envUrlMap[$envName]

    Write-Host ""
    Write-Host "━━━ $envName" -ForegroundColor Cyan
    Write-Host "    $url" -ForegroundColor Gray

    # Ensure environment slot exists in both files
    if (-not $evConfig.environments.PSObject.Properties[$envName]) {
        $evConfig.environments | Add-Member -NotePropertyName $envName -NotePropertyValue ([PSCustomObject]@{}) -Force
    }
    if (-not $connConfig.environments.PSObject.Properties[$envName]) {
        $connConfig.environments | Add-Member -NotePropertyName $envName -NotePropertyValue ([PSCustomObject]@{}) -Force
    }

    # ── Environment Variables ──────────────────────────────────────────────────
    $evRaw = pac env fetch --environment $url --xml $evFetchXml 2>&1
    if ($LASTEXITCODE -eq 0) {
        $rows    = Parse-EvRows -raw ($evRaw | ForEach-Object { $_.ToString() })
        $envSlot = $evConfig.environments.$envName
        $updated = 0

        foreach ($row in $rows) {
            $schema = $row.schemaname
            $value  = $row.'val.value'
            if ([string]::IsNullOrWhiteSpace($schema)) { continue }

            # Only write if the slot has this variable AND it's still <unset>
            $prop = $envSlot.PSObject.Properties[$schema]
            if ($prop -and $prop.Value -eq "<unset>" -and -not [string]::IsNullOrWhiteSpace($value)) {
                $envSlot.$schema = $value
                $updated++
            }
        }
        Write-Host "  ✓ Env vars: $updated updated  ($($rows.Count) fetched)" -ForegroundColor Green
        $totalEvUpdated += $updated
    } else {
        Write-Warning "  ✗ Env var fetch failed"
        $evRaw | Where-Object { $_ -match '\S' } | Select-Object -Last 5 | ForEach-Object { Write-Warning "    $_" }
    }

    # ── Connection References ──────────────────────────────────────────────────
    $crRaw = pac env fetch --environment $url --xml $crFetchXml 2>&1
    if ($LASTEXITCODE -eq 0) {
        $rows     = Parse-CrRows -raw ($crRaw | ForEach-Object { $_.ToString() })
        $connSlot = $connConfig.environments.$envName
        $updated  = 0

        foreach ($row in $rows) {
            $connectorId  = $row.connectorid
            $connectionId = $row.connectionid
            if ([string]::IsNullOrWhiteSpace($connectorId) -or [string]::IsNullOrWhiteSpace($connectionId)) { continue }

            # Only overwrite if still the all-zeros placeholder (or not yet set)
            $current = $connSlot.PSObject.Properties[$connectorId]?.Value
            if ([string]::IsNullOrWhiteSpace($current) -or $current -eq "00000000000000000000000000000000") {
                $connSlot | Add-Member -NotePropertyName $connectorId -NotePropertyValue $connectionId -Force
                $updated++
            }
        }
        Write-Host "  ✓ Connections: $updated updated ($($rows.Count) fetched)" -ForegroundColor Green
        $totalConnUpdated += $updated
    } else {
        Write-Warning "  ✗ Connection fetch failed"
    }
}

# Save both files
$evConfig   | ConvertTo-Json -Depth 10 | Set-Content $evPath   -Encoding UTF8
$connConfig | ConvertTo-Json -Depth 10 | Set-Content $connPath -Encoding UTF8

Write-Host ""
Write-Host "═══════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Done" -ForegroundColor Cyan
Write-Host "  Env vars updated : $totalEvUpdated" -ForegroundColor Green
Write-Host "  Connections updated: $totalConnUpdated" -ForegroundColor Green
Write-Host "  Files saved to settings/" -ForegroundColor Green
Write-Host "═══════════════════════════════════════" -ForegroundColor Cyan
