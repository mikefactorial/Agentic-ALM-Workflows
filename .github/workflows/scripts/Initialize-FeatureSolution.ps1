<#
.SYNOPSIS
    Initialize a feature solution locally and push it to a development environment.

.DESCRIPTION
    Checks whether a feature solution already exists in the target development environment.
    - If it does NOT exist: initialises the solution locally with 'pac solution init',
      then pushes it to the environment with 'pac solution push'.
    - If it already exists: clones it from the environment with 'pac solution clone'.

    After the .cdsproj is in place, all plugin and PCF project references from the
    parent solution's .cdsproj are copied over so the feature solution can be built
    and deployed with Build-Solutions.ps1 / Deploy-Solutions.ps1.

.PARAMETER featureSolutionName
    Unique name (no spaces) for the feature solution.
    Convention: AB{WorkItemNumber}_{BriefDescription}  e.g. AB1234_HelloWorldPCF

.PARAMETER solutionArea
    The parent solution area that this feature belongs to.
    Must match a name defined in environment-config.json solutionAreas[*].name.

.PARAMETER environmentUrl
    Full URL of the development environment to target.
    e.g. https://myapp-dev-contoso.crm.dynamics.com

.EXAMPLE
    # Initialize a feature solution in the dev environment
    .\Initialize-FeatureSolution.ps1 `
        -featureSolutionName "AB1234_HelloWorldPCF" `
        -solutionArea "MySolution" `
        -environmentUrl "https://myapp-dev-contoso.crm.dynamics.com"

.EXAMPLE
    # Another feature in a different solution area
    .\Initialize-FeatureSolution.ps1 `
        -featureSolutionName "AB5678_AnotherFeature" `
        -solutionArea "AnotherSolution" `
        -environmentUrl "https://otherapp-dev-contoso.crm.dynamics.com"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$featureSolutionName,

    [Parameter(Mandatory = $true)]
    [string]$solutionArea,

    [Parameter(Mandatory = $true)]
    [string]$environmentUrl
)

$ErrorActionPreference = "Stop"

# Repo root — four levels up from this script's directory (.platform/.github/workflows/scripts)
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..") | Select-Object -ExpandProperty Path

# ---------------------------------------------------------------------------
# Load solution area config from environment-config.json
# ---------------------------------------------------------------------------
$envConfigPath  = Join-Path $repoRoot "deployments\settings\environment-config.json"
$platformConfig = Get-Content $envConfigPath -Raw | ConvertFrom-Json
$areaConfig     = $platformConfig.solutionAreas | Where-Object { $_.name -eq $solutionArea }
if (-not $areaConfig) {
    $validAreas = ($platformConfig.solutionAreas.name) -join ', '
    Write-Error "Unknown solution area '$solutionArea'. Valid areas defined in environment-config.json: $validAreas"
    exit 1
}

$publisherPrefix = $areaConfig.prefix
$publisherName   = $platformConfig.publisher

$featSolutionDir = Join-Path $repoRoot "src\solutions\$featureSolutionName"
$parentCdsproj   = Join-Path $repoRoot ($areaConfig.cdsproj -replace "/", "\")

Write-Host ""
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "  Initialize Feature Solution" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "Feature Solution : $featureSolutionName"
Write-Host "Solution Area    : $solutionArea  (publisher: $publisherName / $publisherPrefix)"
Write-Host "Environment      : $environmentUrl"
Write-Host "Output Path      : $featSolutionDir"
Write-Host ""

# ---------------------------------------------------------------------------
# Ensure pac CLI is available
# ---------------------------------------------------------------------------
if (-not (Get-Command pac -ErrorAction SilentlyContinue)) {
    throw "pac CLI not found. Install with: dotnet tool install --global Microsoft.PowerApps.CLI.Tool"
}

# ---------------------------------------------------------------------------
# Check whether the solution already exists in the environment
# ---------------------------------------------------------------------------
Write-Host "Checking whether '$featureSolutionName' exists in $environmentUrl ..." -ForegroundColor Cyan
$solutionListOutput = pac solution list --environment $environmentUrl 2>&1 | Out-String
$solutionExists = $solutionListOutput -match [regex]::Escape($featureSolutionName)

# ---------------------------------------------------------------------------
# Create or clone the solution
# ---------------------------------------------------------------------------
if (-not $solutionExists) {
    Write-Host "'$featureSolutionName' not found — initialising locally and pushing to environment..." -ForegroundColor Yellow

    if (Test-Path $featSolutionDir) {
        Write-Warning "Directory $featSolutionDir already exists locally. Skipping pac solution init."
    }
    else {
        New-Item -ItemType Directory -Path $featSolutionDir -Force | Out-Null
        Push-Location $featSolutionDir
        try {
            pac solution init `
                --publisher-name $publisherName `
                --publisher-prefix $publisherPrefix
        }
        finally {
            Pop-Location
        }
    }

    # Push to environment so it exists in Dataverse — build the empty solution and import it
    Write-Host "Pushing feature solution to $environmentUrl ..." -ForegroundColor Cyan
    $tempZip = Join-Path ([System.IO.Path]::GetTempPath()) "$featureSolutionName.zip"
    pac solution pack --zipfile $tempZip --folder (Join-Path $featSolutionDir "src") --packagetype Unmanaged --errorlevel Warning 2>&1 | Out-Null
    if (-not (Test-Path $tempZip)) {
        # If pack from src subfolder failed, try the root (clone layout)
        pac solution pack --zipfile $tempZip --folder $featSolutionDir --packagetype Unmanaged --errorlevel Warning 2>&1 | Out-Null
    }
    if (Test-Path $tempZip) {
        pac solution import --path $tempZip --environment $environmentUrl --activate-plugins --publish-changes 2>&1 | Out-Null
        Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
        Write-Host "✓ Feature solution '$featureSolutionName' created and imported to environment" -ForegroundColor Green
    }
    else {
        Write-Warning "Could not pack solution for initial import — solution will be created on first 'pac solution import' from the build output."
    }
}
else {
    Write-Host "'$featureSolutionName' already exists — cloning from $environmentUrl ..." -ForegroundColor Yellow

    # pac solution clone creates a subdirectory named after the solution inside the outputDirectory
    # We point it at src/solutions so the result is src/solutions/{featureSolutionName}/
    $solutionsRoot = Join-Path $repoRoot "src\solutions"

    pac solution clone `
        --name $featureSolutionName `
        --environment $environmentUrl `
        --outputDirectory $solutionsRoot `
        --packagetype Unmanaged

    Write-Host "✓ Feature solution '$featureSolutionName' cloned from environment" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Locate the .cdsproj that was just created
# ---------------------------------------------------------------------------
$cdsproj = Get-ChildItem -Path $featSolutionDir -Filter "*.cdsproj" -Recurse | Select-Object -First 1
if (-not $cdsproj) {
    throw "Could not find a .cdsproj file under $featSolutionDir after init/clone."
}
Write-Host "Using .cdsproj : $($cdsproj.FullName)"

# ---------------------------------------------------------------------------
# Rewrite the .cdsproj to use the AlbanianXrm.CDSProj.Sdk format.
#
# pac solution init generates an old ToolsVersion="15.0" project format.
# The AlbanianXrm SDK is required for plugin packages (nupkg) to be included
# in the solution ZIP — without it, ProjectReferences to plugin package
# projects are silently ignored, so the assembly never lands in Dataverse.
#
# The rewrite:
#   - Switches to Sdk="AlbanianXrm.CDSProj.Sdk/1.0.9"
#   - Sets SolutionPackageType=Both (managed + unmanaged ZIPs)
#   - Drops the ToolsVersion boilerplate / manual Import statements /
#     Microsoft.PowerApps.MSBuild.Solution PackageReference (all handled by SDK)
#   - Preserves the ProjectGuid so the project identity is stable
# ---------------------------------------------------------------------------
$cdsprojContent = Get-Content $cdsproj.FullName -Raw

# Extract ProjectGuid if present (pac solution init always adds one)
$guidMatch = [regex]::Match($cdsprojContent, '<ProjectGuid>({[^}]+}|[0-9a-fA-F\-]+)</ProjectGuid>')
$projectGuid = if ($guidMatch.Success) { $guidMatch.Groups[1].Value } else { [System.Guid]::NewGuid().ToString() }

$sdkCdsproj = @"
<?xml version="1.0" encoding="utf-8"?>
<Project Sdk="AlbanianXrm.CDSProj.Sdk/1.0.9">
  <PropertyGroup>
    <ProjectGuid>$projectGuid</ProjectGuid>
    <TargetFrameworkVersion>v4.6.2</TargetFrameworkVersion>
    <!--Remove TargetFramework when this is available in 16.1-->
    <TargetFramework>net462</TargetFramework>
    <RestoreProjectStyle>PackageReference</RestoreProjectStyle>
    <SolutionRootPath>src</SolutionRootPath>
  </PropertyGroup>
  <PropertyGroup>
    <SolutionPackageType>Both</SolutionPackageType>
  </PropertyGroup>

</Project>
"@

Set-Content -Path $cdsproj.FullName -Value $sdkCdsproj -NoNewline
Write-Host "✓ Rewrote cdsproj to AlbanianXrm.CDSProj.Sdk format in $($cdsproj.Name)" -ForegroundColor Green
Write-Host "✓ Set SolutionPackageType = Both in $($cdsproj.Name)" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Feature solution starts with NO plugin/PCF project references.
#
# Only the components that change or are net-new in this feature should be
# referenced. Add them selectively as you work:
#
#   Net-new plugin/PCF (scaffold-plugin / scaffold-pcf-control skills):
#     - Add to the parent solution .cdsproj (permanent home)
#     - Add to THIS feature solution .cdsproj (so it builds in the feature)
#
#   Modified existing plugin/PCF:
#     - Add ONLY to this feature solution .cdsproj:
#         .\.github\workflows\scripts\Add-ToFeatureSolution.ps1 `
#             -featureSolutionName "$featureSolutionName" `
#             -componentPath "path\to\The.csproj_or_.pcfproj"
# ---------------------------------------------------------------------------
Write-Host "Feature solution initialised with no code-first references." -ForegroundColor Cyan
Write-Host "Use Add-ToFeatureSolution.ps1 to selectively add changed/new plugins or PCF controls." -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=================================================" -ForegroundColor Green
Write-Host "  ✓ Feature Solution Ready" -ForegroundColor Green
Write-Host "=================================================" -ForegroundColor Green
Write-Host "Solution dir : $featSolutionDir"
Write-Host "cdsproj      : $($cdsproj.FullName)"
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Open make.powerapps.com → $environmentUrl → Solutions"
Write-Host "     Set '$featureSolutionName' as your Preferred Solution"
Write-Host "  2. Develop your feature (tables, forms, flows, plugins, PCF controls)"
Write-Host "     - Net-new plugin/PCF: scaffold with scaffold-plugin / scaffold-pcf-control skills"
Write-Host "       (adds to parent solution AND this feature solution automatically)"
Write-Host "     - Modified existing plugin/PCF: add to this feature solution with:"
Write-Host "       .\.github\workflows\scripts\Add-ToFeatureSolution.ps1 -featureSolutionName '$featureSolutionName' -componentPath <path-to-.csproj-or-.pcfproj>"
Write-Host "  3. Sync to repo when ready:"
Write-Host "     Trigger sync-solution workflow with environment: $environmentUrl"
Write-Host ""
