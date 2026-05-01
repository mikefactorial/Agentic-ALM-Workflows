<#
.SYNOPSIS
    Add a plugin or PCF control project reference to a feature solution .cdsproj.

.DESCRIPTION
    Used during inner-loop development to selectively include a plugin (.csproj)
    or PCF control (.pcfproj) in a feature solution build. Call this when:

      - You are modifying an EXISTING plugin or PCF that already lives in the
        parent solution — add it to your feature solution so the feature build
        includes your changes.

      - You want to manually wire a net-new project into the feature solution
        (the scaffold-plugin / scaffold-pcf-control skills do this automatically
        when creating new components).

    The script resolves the feature solution .cdsproj by convention:
        src/solutions/{featureSolutionName}/{featureSolutionName}.cdsproj

.PARAMETER featureSolutionName
    Unique name of the feature solution, matching the directory under src/solutions/.
    Convention: AB{WorkItemNumber}_{BriefDescription}  e.g. AB1234_HelloWorldPCF

.PARAMETER componentPath
    Path to the .csproj (plugin) or .pcfproj (PCF control) to add.
    Accepts absolute or relative paths (relative to the current working directory).

.EXAMPLE
    # Add a modified existing plugin to a feature solution
    .\.github\workflows\scripts\Add-ToFeatureSolution.ps1 `
        -featureSolutionName "AB1234_HelloWorldPCF" `
        -componentPath "src\plugins\pub_MySolution\Publisher.Plugins.Core\Publisher.Plugins.MySolution.Core.csproj"

.EXAMPLE
    # Add a modified PCF control to a feature solution
    .\.github\workflows\scripts\Add-ToFeatureSolution.ps1 `
        -featureSolutionName "AB1234_HelloWorldPCF" `
        -componentPath "src\controls\pub_MySolution\PCF-MyControl-2025\MyControl-2025.pcfproj"

.NOTES
    For net-new projects, prefer using the scaffold-plugin or scaffold-pcf-control
    skills — they wire into both the parent solution and the feature solution in one step.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$featureSolutionName,

    [Parameter(Mandatory = $true)]
    [string]$componentPath
)

$ErrorActionPreference = "Stop"

# Repo root: four levels up from this script (.platform/.github/workflows/scripts)
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..") | Select-Object -ExpandProperty Path

# ---------------------------------------------------------------------------
# Resolve component path to absolute
# ---------------------------------------------------------------------------
if (-not [System.IO.Path]::IsPathRooted($componentPath)) {
    # Resolve relative to cwd first, then repo root as fallback
    $fromCwd = Join-Path (Get-Location) $componentPath
    if (Test-Path $fromCwd) {
        $componentPath = Resolve-Path $fromCwd | Select-Object -ExpandProperty Path
    }
    else {
        $fromRepo = Join-Path $repoRoot $componentPath
        if (Test-Path $fromRepo) {
            $componentPath = Resolve-Path $fromRepo | Select-Object -ExpandProperty Path
        }
        else {
            throw "Component path not found: '$componentPath' (tried relative to cwd and repo root)"
        }
    }
}
else {
    if (-not (Test-Path $componentPath)) {
        throw "Component path not found: '$componentPath'"
    }
}

$ext = [System.IO.Path]::GetExtension($componentPath).ToLower()
if ($ext -notin @('.csproj', '.pcfproj')) {
    throw "componentPath must point to a .csproj (plugin) or .pcfproj (PCF control). Got: '$ext'"
}

$componentType = if ($ext -eq '.pcfproj') { "PCF control" } else { "plugin" }

# ---------------------------------------------------------------------------
# Locate feature solution .cdsproj
# ---------------------------------------------------------------------------
$featSolutionDir = Join-Path $repoRoot "src\solutions\$featureSolutionName"
if (-not (Test-Path $featSolutionDir)) {
    throw "Feature solution directory not found: $featSolutionDir`nRun Initialize-FeatureSolution.ps1 first."
}

$cdsproj = Get-ChildItem -Path $featSolutionDir -Filter "*.cdsproj" -Recurse | Select-Object -First 1
if (-not $cdsproj) {
    throw "No .cdsproj found under $featSolutionDir"
}

$featDir = $cdsproj.DirectoryName

# ---------------------------------------------------------------------------
# Check if already referenced
# ---------------------------------------------------------------------------
$featRelPath = [System.IO.Path]::GetRelativePath($featDir, $componentPath)
[xml]$featXml = Get-Content $cdsproj.FullName

$alreadyAdded = $featXml.SelectNodes("//ProjectReference") | Where-Object {
    $normalised = $_.'Include' -replace '/', '\' -replace '\\\\', '\'
    $normalised -eq ($featRelPath -replace '/', '\')
}

if ($alreadyAdded) {
    Write-Host "Already referenced in feature solution: $featRelPath" -ForegroundColor Yellow
    exit 0
}

# ---------------------------------------------------------------------------
# Add reference
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "  Add Component to Feature Solution" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "Feature Solution : $featureSolutionName"
Write-Host "Component type   : $componentType"
Write-Host "Component path   : $componentPath"
Write-Host "Relative path    : $featRelPath"
Write-Host ""

Push-Location $featDir
try {
    $output = pac solution add-reference --path $featRelPath 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "pac solution add-reference failed: $output"
    }
}
finally {
    Pop-Location
}

Write-Host "✓ Added $componentType to '$featureSolutionName'" -ForegroundColor Green
Write-Host "  $featRelPath" -ForegroundColor Green
Write-Host ""
Write-Host "Remember to build and redeploy the feature solution to pick up the change:" -ForegroundColor Yellow
Write-Host "  .\.github\workflows\scripts\Build-Solutions.ps1 -solutionList '$featureSolutionName'"
