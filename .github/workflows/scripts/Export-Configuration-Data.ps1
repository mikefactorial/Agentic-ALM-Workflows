<#
.SYNOPSIS
    Export Configuration Data from Dataverse using PAC CLI

.DESCRIPTION
    Uses 'pac data export' to pull the latest configuration data from Dataverse
    into the repo's deployments\data\{solutionName} folder.

    Features:
    - Automatically checks for existing PAC authentication profiles
    - Creates a new profile if needed (device code flow)
    - Switches to the correct profile if multiple exist
    - Expects a ConfigData.xml schema file in deployments\data\{solutionName}\
    - Exports data and extracts it into that same solution folder

    Prerequisites:
    - Microsoft Power Platform CLI installed (pac)
    - ConfigData.xml schema file in deployments\data\{solutionName}\
    - Optional: set PAC_PATH environment variable to a custom pac path

.PARAMETER SolutionName
    The solution whose data to export (e.g. pub_MySolution, pub_AnotherSolution).
    Must match a subfolder under deployments\data\.

.PARAMETER EnvironmentUrl
    The Dataverse environment URL to export data from.

.PARAMETER PacPath
    Path to the pac executable. Defaults to PAC_PATH env var or 'pac'.

.EXAMPLE
    .\Export-Configuration-Data.ps1 -SolutionName pub_MySolution -EnvironmentUrl "https://myapp-prod-contoso.crm.dynamics.com"

.EXAMPLE
    .\Export-Configuration-Data.ps1 -SolutionName pub_AnotherSolution -EnvironmentUrl "https://otherapp-prod-contoso.crm.dynamics.com"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SolutionName,

    [Parameter(Mandatory = $true)]
    [string]$EnvironmentUrl,

    [Parameter(Mandatory = $false)]
    [string]$PacPath = ""
)

$ErrorActionPreference = "Stop"

# Resolve repo root and paths
$repoRoot        = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..") | Select-Object -ExpandProperty Path
$solutionDataDir = Join-Path $repoRoot "deployments\data\$SolutionName"
$configDataPath  = Join-Path $solutionDataDir "ConfigData.xml"
$dataZipPath     = Join-Path $solutionDataDir "data.zip"

$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/')

# ── Resolve pac path ─────────────────────────────────────────────────────────

if ([string]::IsNullOrWhiteSpace($PacPath)) {
    $PacPath = if ($env:PAC_PATH) { $env:PAC_PATH } else { "pac" }
}

# ── Helper functions ─────────────────────────────────────────────────────────

function Test-PacExists {
    try {
        & pac help 2>&1 | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function Get-AuthProfiles {
    try {
        $output = & pac auth list 2>&1 | Out-String
        $profiles = @()

        foreach ($line in ($output -split "`n")) {
            if ($line -match '^\[(\d+)\]\s+(\*?)\s+\w+\s+.*?(https://[^\s]+)') {
                $profiles += [PSCustomObject]@{
                    Index    = [int]$Matches[1]
                    IsActive = $Matches[2] -eq '*'
                    Url      = $Matches[3].TrimEnd('/')
                }
            }
        }

        return $profiles
    }
    catch {
        Write-Warning "Could not list auth profiles: $($_.Exception.Message)"
        return @()
    }
}

function Select-AuthProfile {
    param([int]$Index)
    try {
        $output = & pac auth select --index $Index 2>&1
        if ($output) { Write-Host ($output | Out-String).Trim() }
        Write-Host "✓ Switched to profile [$Index]" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Error "Failed to select auth profile: $($_.Exception.Message)"
        return $false
    }
}

function New-AuthProfile {
    param([string]$Url)
    try {
        Write-Host ""
        Write-Host "Creating new authentication profile..." -ForegroundColor Cyan
        Write-Host "Please follow the device code authentication prompts." -ForegroundColor Yellow
        Write-Host ""

        $output = & pac auth create --url "$Url" 2>&1
        if ($output) { Write-Host ($output | Out-String).Trim() }

        Write-Host ""
        Write-Host "✓ Authentication profile created successfully!" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Error "Failed to create auth profile: $($_.Exception.Message)"
        Write-Host ""
        Write-Host "Please try authenticating manually:" -ForegroundColor Yellow
        Write-Host "  pac auth create --url `"$Url`""
        return $false
    }
}

function Confirm-Authenticated {
    param([string]$Url)

    Write-Host ""
    Write-Host "Checking authentication for: $Url" -ForegroundColor Cyan

    $profiles = Get-AuthProfiles

    if ($profiles.Count -eq 0) {
        Write-Host "No authentication profiles found." -ForegroundColor Yellow
        Write-Host "You can also run: pac auth create --url `"$Url`" manually"
        Write-Host ""
        Write-Host "Creating new profile automatically..." -ForegroundColor Cyan
        return New-AuthProfile -Url $Url
    }

    Write-Host ""
    Write-Host "Found $($profiles.Count) authentication profile(s):" -ForegroundColor Cyan
    foreach ($p in $profiles) {
        $status = if ($p.IsActive) { "[ACTIVE]" } else { "" }
        Write-Host "   [$($p.Index)] $($p.Url) $status"
    }

    $match = $profiles | Where-Object { $_.Url -eq $Url } | Select-Object -First 1

    if ($match) {
        if ($match.IsActive) {
            Write-Host ""
            Write-Host "✓ Already authenticated to the correct environment." -ForegroundColor Green
            return $true
        }
        else {
            Write-Host ""
            Write-Host "Switching to existing profile [$($match.Index)] for $Url..." -ForegroundColor Cyan
            return Select-AuthProfile -Index $match.Index
        }
    }
    else {
        Write-Host ""
        Write-Host "No matching profile found for $Url" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Creating new profile automatically..." -ForegroundColor Cyan
        return New-AuthProfile -Url $Url
    }
}

function Assert-ConfigDataFile {
    if (-not (Test-Path $configDataPath)) {
        throw "ConfigData.xml not found: $configDataPath`n`nPlease create the ConfigData.xml schema file using the Configuration Migration Tool or manually."
    }
    Write-Host "✓ Found ConfigData.xml: $configDataPath" -ForegroundColor Green
}

function Export-Data {
    Write-Host ""
    Write-Host "Exporting data..." -ForegroundColor Cyan

    # Ensure output directory exists
    if (-not (Test-Path $solutionDataDir)) {
        New-Item -ItemType Directory -Path $solutionDataDir -Force | Out-Null
    }

    # Clean up any existing data.zip
    if (Test-Path $dataZipPath) {
        Remove-Item $dataZipPath -Force
        Write-Host "Cleaned up existing data.zip" -ForegroundColor Gray
    }

    $command = @(
        "data", "export",
        "--environment", $EnvironmentUrl,
        "--schemaFile",  $configDataPath,
        "--dataFile",    $dataZipPath,
        "--overwrite"
    )

    Write-Host "Running: $PacPath $($command -join ' ')"

    $output = & $PacPath @command 2>&1
    if ($output) { Write-Host ($output | Out-String).Trim() }

    if ($LASTEXITCODE -ne 0) {
        throw "PAC data export failed with exit code $LASTEXITCODE"
    }

    Write-Host "✓ Data export completed" -ForegroundColor Green

    if (Test-Path $dataZipPath) {
        Expand-DataZip
    }
    else {
        Write-Warning "Data ZIP file not found after export"
    }
}

function Expand-DataZip {
    Write-Host "Extracting data.zip..." -ForegroundColor Cyan

    try {
        Expand-Archive -Path $dataZipPath -DestinationPath $solutionDataDir -Force
        Remove-Item $dataZipPath -Force

        Write-Host "✓ Data extracted to: $solutionDataDir" -ForegroundColor Green
        Write-Host "  data.zip cleaned up" -ForegroundColor Gray

        Write-Host ""
        Write-Host "Extracted files:" -ForegroundColor Cyan
        Get-ChildItem $solutionDataDir | ForEach-Object { Write-Host "  - $($_.Name)" }
    }
    catch {
        throw "Failed to extract data.zip: $($_.Exception.Message)"
    }
}

# ── Main ─────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Dataverse Data Export  [$SolutionName]" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan

# Verify PAC CLI is available
if (-not (Test-PacExists)) {
    Write-Error "Power Platform CLI (pac) is not available on PATH. Install it and try again."
    exit 1
}

# Ensure authenticated
$authenticated = Confirm-Authenticated -Url $EnvironmentUrl
if (-not $authenticated) {
    throw "Authentication failed. Cannot proceed with data export."
}

# Validate ConfigData.xml exists
Assert-ConfigDataFile

# Export data
Export-Data

Write-Host ""
Write-Host "✓ Data export completed successfully!" -ForegroundColor Green
Write-Host "  Data files available in: deployments\data\$SolutionName\" -ForegroundColor Gray
