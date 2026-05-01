<#
.SYNOPSIS
    Build the deployment packages for this platform.

.DESCRIPTION
    Reads package groups from deployments/settings/environment-config.json (packageGroups array)
    and the package project path from the packageProjectPath field.

    Runs dotnet publish once on the configured .csproj (which builds all referenced solution
    projects), then assembles one named deployment package per group from the publish output.

    Each package is produced in both unmanaged (dev/test) and managed (production) editions,
    yielding 2 ZIPs per package group plus a package-manifest.json.

    Data inclusion: for each package, if the ConfigData.xml in
    deployments/data/<dataSolution>/ConfigData.xml contains any <entity> children, the
    config-data/ folder is zipped and included in the package's PkgAssets as ConfigData.zip,
    and ImportConfig.xml is updated with crmmigdataimportfile="ConfigData.zip".

    Produces (per package group):
      <Name>_<version>.zip           Unmanaged package (dev / test environments)
      <Name>_Managed_<version>.zip   Managed package   (production environments)
    Plus:
      package-manifest.json          Build metadata

.PARAMETER PackageVersion
    Date-based version string to embed (e.g. "2026.04.04.1").
    Omit to auto-calculate from the latest git tag.

.PARAMETER ArtifactsPath
    Output directory for package ZIPs and manifest. Defaults to ./artifacts/package.

.PARAMETER SolutionArtifactsPath
    Directory containing individual solution ZIPs from Build-Solutions.ps1, used to
    source managed ZIPs. Defaults to ./artifacts/solutions.

.PARAMETER Configuration
    MSBuild configuration. Defaults to Release.

.EXAMPLE
    # Local — auto-version
    .\Build-Package.ps1

.EXAMPLE
    # CI — explicit version
    .\Build-Package.ps1 -PackageVersion "2026.04.04.1"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$PackageVersion = "",

    [Parameter(Mandatory = $false)]
    [string]$ArtifactsPath = "./artifacts/package",

    [Parameter(Mandatory = $false)]
    [string]$SolutionArtifactsPath = "./artifacts/solutions",

    [Parameter(Mandatory = $false)]
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"

# ── Paths ─────────────────────────────────────────────────────────────────────

$repoRoot         = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..\") | Select-Object -ExpandProperty Path
$srcSolutions     = Join-Path $repoRoot "src\solutions"
$dataRoot         = Join-Path $repoRoot "deployments\data"

if (-not [System.IO.Path]::IsPathRooted($ArtifactsPath)) {
    $ArtifactsPath = Join-Path $repoRoot $ArtifactsPath
}
if (-not [System.IO.Path]::IsPathRooted($SolutionArtifactsPath)) {
    $SolutionArtifactsPath = Join-Path $repoRoot $SolutionArtifactsPath
}

# ── Load config from environment-config.json ─────────────────────────────────

$envConfigPath = Join-Path $repoRoot "deployments\settings\environment-config.json"
if (-not (Test-Path $envConfigPath)) { throw "environment-config.json not found at: $envConfigPath" }
$envConfig = Get-Content $envConfigPath -Raw | ConvertFrom-Json

# Resolve package project path from config
if (-not $envConfig.packageProjectPath) { throw "packageProjectPath not defined in environment-config.json" }
$packageProj = Join-Path $repoRoot ($envConfig.packageProjectPath -replace '/', '\')
$projectDir  = Split-Path $packageProj -Parent

# ── Package configurations ────────────────────────────────────────────────────
# Driven by packageGroups in environment-config.json.
# Each group requires: name, solutions[], dataSolution.

if (-not $envConfig.packageGroups) { throw "packageGroups not defined in environment-config.json" }
$packageConfigs = @($envConfig.packageGroups | ForEach-Object {
    if (-not $_.dataSolution) { throw "packageGroup '$($_.name)' is missing required field: dataSolution" }
    [PSCustomObject]@{
        Name         = $_.name
        Solutions    = @($_.solutions)
        DataSolution = $_.dataSolution
    }
})

# Pre-compute the full list of known solution names for ZIP filtering.
$allSolutionNames = @($packageConfigs | ForEach-Object { $_.Solutions } | Sort-Object -Unique)

# ── Helper ────────────────────────────────────────────────────────────────────

function Test-HasConfigData {
    <#
    .SYNOPSIS
        Returns $true if the ConfigData.xml for a solution has any <entity> children.
    #>
    param([string]$DataRoot, [string]$SolutionName)
    $configDataPath = Join-Path $DataRoot "$SolutionName\ConfigData.xml"
    if (-not (Test-Path $configDataPath)) { return $false }
    [xml]$xml = Get-Content $configDataPath -Encoding UTF8
    $entityNodes = $xml.SelectNodes("/entities/entity")
    return ($entityNodes.Count -gt 0)
}

# ── Version ───────────────────────────────────────────────────────────────────

if ([string]::IsNullOrWhiteSpace($PackageVersion)) {
    Write-Host "Calculating version from git tags..." -ForegroundColor Cyan
    $PackageVersion = & "$PSScriptRoot\Get-NextVersion.ps1"
    if (-not $PackageVersion) { throw "Get-NextVersion.ps1 returned no version." }
    Write-Host "  Calculated version: $PackageVersion" -ForegroundColor Green
}

$tagSuffix  = if ($envConfig.packageTag) { $envConfig.packageTag } else { "Package" }
$packageTag = "v$PackageVersion-$tagSuffix"

# ── Banner ────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Build $tagSuffix Deployment Packages  v$PackageVersion" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Package project    : $packageProj" -ForegroundColor Gray
Write-Host "  Configuration      : $Configuration" -ForegroundColor Gray
Write-Host "  Artifacts path     : $ArtifactsPath" -ForegroundColor Gray
Write-Host "  Solution artifacts : $SolutionArtifactsPath" -ForegroundColor Gray
Write-Host ""
Write-Host "  Packages to build:" -ForegroundColor Gray
foreach ($cfg in $packageConfigs) {
    $dataLabel = if (Test-HasConfigData -DataRoot $dataRoot -SolutionName $cfg.DataSolution) { " [+data]" } else { "" }
    Write-Host "    $($cfg.Name)$dataLabel — $($cfg.Solutions -join ', ')" -ForegroundColor Gray
}
Write-Host ""

# ── Pre-flight ────────────────────────────────────────────────────────────────

if (-not (Test-Path $packageProj)) { throw "Package project not found: $packageProj" }
try { & dotnet --version 2>&1 | Out-Null } catch { throw ".NET SDK not found." }
New-Item -ItemType Directory -Path $ArtifactsPath -Force | Out-Null

# ── Update Solution versions ──────────────────────────────────────────────────
# Build-Package.ps1 calls dotnet publish directly (bypassing Build-Solutions.ps1),
# so Solution.xml version numbers would otherwise stay at whatever was last committed.
# We call Get-NextVersion.ps1 here to get today's date-based version and patch each
# Solution.xml before dotnet publish picks them up.

Write-Host "Updating solution versions to $PackageVersion..." -ForegroundColor Cyan

$solutionXmlFiles = Get-ChildItem -Path $srcSolutions -Recurse -Filter "Solution.xml" -ErrorAction SilentlyContinue
foreach ($xmlFile in $solutionXmlFiles) {
    [xml]$solutionXml = Get-Content $xmlFile.FullName -Encoding UTF8
    $versionNode = $solutionXml.SelectSingleNode("//Version")
    if ($versionNode) {
        $versionNode.InnerText = $PackageVersion
        $solutionXml.Save($xmlFile.FullName)
        Write-Host "  ✓ $($xmlFile.FullName.Replace($repoRoot, '').TrimStart('\/'))" -ForegroundColor Green
    } else {
        Write-Warning "  No <Version> element found in $($xmlFile.FullName)"
    }
}
Write-Host ""

# ── Build / Publish ───────────────────────────────────────────────────────────

Write-Host "Running dotnet publish..." -ForegroundColor Cyan

$publishArgs = @(
    "publish", $packageProj
    "--configuration", $Configuration
    "/p:Version=$PackageVersion"
    "-maxcpucount:1"
    "--verbosity", "minimal"
)
Write-Host "  dotnet $($publishArgs -join ' ')" -ForegroundColor Gray

$publishOutput = & dotnet @publishArgs 2>&1
$publishOutput | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }

if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed with exit code $LASTEXITCODE"
}

$publishDir = Join-Path $projectDir "bin" $Configuration "net472" "pdpublish"
if (-not (Test-Path $publishDir)) { throw "Publish directory not found: $publishDir" }

Write-Host "✓ dotnet publish complete" -ForegroundColor Green
Write-Host ""

# ── Build per-config packages ─────────────────────────────────────────────────

$builtPackages = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($config in $packageConfigs) {
    $cfgName = $config.Name
    Write-Host "──────────────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "Building package: $cfgName" -ForegroundColor Cyan
    Write-Host "  Solutions : $($config.Solutions -join ', ')" -ForegroundColor Gray

    # ── Copy publish output to temp dir ──────────────────────────────────────

    $tempDir = Join-Path $ArtifactsPath "tmp_$cfgName"
    if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    Copy-Item "$publishDir\*" $tempDir -Recurse -Force

    $pkgAssetsDir = Join-Path $tempDir "PkgAssets"

    # ── Remove solution ZIPs not in this config ───────────────────────────────

    foreach ($zipFile in @(Get-ChildItem $pkgAssetsDir -Filter "*.zip" -ErrorAction SilentlyContinue)) {
        $solName = [System.IO.Path]::GetFileNameWithoutExtension($zipFile.Name)
        if ($allSolutionNames -contains $solName -and $config.Solutions -notcontains $solName) {
            Remove-Item $zipFile.FullName -Force
            Write-Host "  - Removed $($zipFile.Name) (not in $cfgName)" -ForegroundColor DarkGray
        }
    }

    # ── Filter ImportConfig.xml & include config data ─────────────────────────

    $importConfigPath = Join-Path $pkgAssetsDir "ImportConfig.xml"
    $hasData = $false

    if (Test-Path $importConfigPath) {
        [xml]$importXml = Get-Content $importConfigPath -Encoding UTF8

        # Remove <configsolutionfile> entries for excluded solutions
        $solutionsNode = $importXml.SelectSingleNode("//solutions")
        if ($solutionsNode) {
            $toRemove = @()
            foreach ($child in @($solutionsNode.ChildNodes)) {
                if ($child.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
                $filename = $child.GetAttribute("solutionpackagefilename")
                $solName = [System.IO.Path]::GetFileNameWithoutExtension($filename)
                if ($config.Solutions -notcontains $solName) {
                    $toRemove += $child
                }
            }
            foreach ($node in $toRemove) { $solutionsNode.RemoveChild($node) | Out-Null }
        }

        # Include configuration migration data if entities are present
        $hasData = Test-HasConfigData -DataRoot $dataRoot -SolutionName $config.DataSolution
        if ($hasData) {
            Write-Host "  + Including config data for $($config.DataSolution)" -ForegroundColor Cyan
            $importXml.DocumentElement.SetAttribute("crmmigdataimportfile", "ConfigData.zip")
            $configDataSrcDir = Join-Path $dataRoot "$($config.DataSolution)\config-data"
            $configDataZipPath = Join-Path $pkgAssetsDir "ConfigData.zip"
            Compress-Archive -Path "$configDataSrcDir\*" -DestinationPath $configDataZipPath -Force
        } else {
            Write-Host "  - No config data for $($config.DataSolution) (ConfigData.xml has no entities)" -ForegroundColor DarkGray
        }

        $importXml.Save($importConfigPath)
    }

    # ── Create unmanaged ZIP ──────────────────────────────────────────────────

    $unmanagedZip = Join-Path $ArtifactsPath "${cfgName}_$PackageVersion.zip"
    if (Test-Path $unmanagedZip) { Remove-Item $unmanagedZip -Force }
    Compress-Archive -Path "$tempDir\*" -DestinationPath $unmanagedZip -CompressionLevel Optimal -Force
    Write-Host "  ✓ ${cfgName}_$PackageVersion.zip ($([math]::Round((Get-Item $unmanagedZip).Length/1MB,2)) MB)" -ForegroundColor Green

    # ── Create managed package ZIP ────────────────────────────────────────────
    # Same structure as unmanaged but solution ZIPs swapped to managed editions.

    $tempMgrDir = Join-Path $ArtifactsPath "tmp_${cfgName}_managed"
    if (Test-Path $tempMgrDir) { Remove-Item $tempMgrDir -Recurse -Force }
    New-Item -ItemType Directory -Path $tempMgrDir -Force | Out-Null
    Copy-Item "$tempDir\*" $tempMgrDir -Recurse -Force
    $pkgAssetsMgr = Join-Path $tempMgrDir "PkgAssets"

    foreach ($sol in $config.Solutions) {
        $mgdZip = Get-ChildItem $SolutionArtifactsPath -Filter "${sol}_*managed*.zip" -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending | Select-Object -First 1

        if (-not $mgdZip) {
            $fallback = Join-Path $srcSolutions $sol "bin" $Configuration "${sol}_managed.zip"
            if (Test-Path $fallback) { $mgdZip = Get-Item $fallback }
        }

        if ($mgdZip) {
            Copy-Item $mgdZip.FullName (Join-Path $pkgAssetsMgr "$sol.zip") -Force
            Write-Host "  ✓ $sol (managed)" -ForegroundColor Green
        } else {
            Write-Warning "  $sol — managed ZIP not found, keeping unmanaged in managed package"
        }
    }

    $managedZip = Join-Path $ArtifactsPath "${cfgName}_Managed_$PackageVersion.zip"
    if (Test-Path $managedZip) { Remove-Item $managedZip -Force }
    Compress-Archive -Path "$tempMgrDir\*" -DestinationPath $managedZip -CompressionLevel Optimal -Force
    Write-Host "  ✓ ${cfgName}_Managed_$PackageVersion.zip ($([math]::Round((Get-Item $managedZip).Length/1MB,2)) MB)" -ForegroundColor Green

    # Clean up temp dirs
    Remove-Item $tempMgrDir -Recurse -Force
    Remove-Item $tempDir -Recurse -Force

    $builtPackages.Add([PSCustomObject]@{
        Name      = $cfgName
        Solutions = $config.Solutions
        HasData   = $hasData
        Unmanaged = "${cfgName}_$PackageVersion.zip"
        Managed   = "${cfgName}_Managed_$PackageVersion.zip"
    })
    Write-Host ""
}

Write-Host "──────────────────────────────────────────────────────" -ForegroundColor DarkGray

# ── Manifest ──────────────────────────────────────────────────────────────────

$manifest = [ordered]@{
    packageVersion = $PackageVersion
    packageTag     = $packageTag
    packages       = @($builtPackages | ForEach-Object {
        [ordered]@{
            name         = $_.Name
            solutions    = $_.Solutions
            unmanaged    = $_.Unmanaged
            managed      = $_.Managed
            includesData = $_.HasData
        }
    })
    configuration  = $Configuration
    builtAt        = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
}

$manifestPath = Join-Path $ArtifactsPath "package-manifest.json"
$manifest | ConvertTo-Json -Depth 5 | Set-Content $manifestPath -Encoding UTF8
Write-Host "✓ Manifest: $manifestPath" -ForegroundColor Green

# ── GitHub Actions outputs ────────────────────────────────────────────────────

if ($env:GITHUB_OUTPUT) {
    "package_version=$PackageVersion" | Add-Content $env:GITHUB_OUTPUT
    "package_tag=$packageTag"          | Add-Content $env:GITHUB_OUTPUT
    "artifacts_path=$ArtifactsPath"    | Add-Content $env:GITHUB_OUTPUT
}

if ($env:GITHUB_STEP_SUMMARY) {
    $tableRows = $builtPackages | ForEach-Object {
        "| ``$($_.Unmanaged)`` | ``$($_.Managed)`` | $($_.Solutions -join ', ') |"
    }
    @"
## 📦 Package Build: $PackageVersion

| Unmanaged | Managed | Solutions |
|---|---|---|
$($tableRows -join "`n")

"@ | Add-Content $env:GITHUB_STEP_SUMMARY
}

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  ✓ Package build complete  v$PackageVersion" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host "  Tag      : $packageTag" -ForegroundColor Gray
Write-Host ""
Write-Host "  Packages:" -ForegroundColor Gray
foreach ($pkg in $builtPackages) {
    Write-Host "    $($pkg.Name):" -ForegroundColor Gray
    Write-Host "      Unmanaged : $($pkg.Unmanaged)" -ForegroundColor Gray
    Write-Host "      Managed   : $($pkg.Managed)" -ForegroundColor Gray
    if ($pkg.HasData) {
        Write-Host "      Data      : ConfigData.zip included" -ForegroundColor Gray
    }
}
Write-Host ""
Write-Host "  Artifacts : $ArtifactsPath" -ForegroundColor Gray
Write-Host ""
