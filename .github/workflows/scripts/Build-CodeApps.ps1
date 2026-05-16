<#
.SYNOPSIS
    Build all Power Apps Code App projects
    
.DESCRIPTION
    Discovers and builds all Code App projects in src/codeapps directory.
    Code App projects are identified by the presence of a power.config.json file.
    Runs npm run build for each project, pre-building any file: dependencies first.
    No solution copy is performed here — map.xml in the cdsproj handles that at dotnet build time.
    
.PARAMETER artifactsPath
    Directory where build outputs will be copied (default: ./artifacts/codeapps)
    
.PARAMETER projectPaths
    Optional comma-separated list of specific project directory paths to build (relative to repo root).
    When provided, only these projects are built instead of discovering all.
    When omitted, all code app projects are discovered and built.

.PARAMETER projectFilter
    Optional subdirectory name to filter discovered projects (e.g., 'pub_MySolution').
    Only projects whose path contains this segment are built. Ignored when projectPaths is set.

.EXAMPLE
    .\Build-CodeApps.ps1
    
.EXAMPLE
    .\Build-CodeApps.ps1 -projectFilter "pub_MySolution" -artifactsPath "./build/codeapps"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$artifactsPath = "./artifacts/codeapps",

    [Parameter(Mandatory=$false)]
    [string]$projectPaths = "",

    [Parameter(Mandatory=$false)]
    [string]$projectFilter = ""
)

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Build Power Apps Code Apps" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

$ErrorActionPreference = "Stop"

# Resolve repo root from script location
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..") | Select-Object -ExpandProperty Path

# Resolve paths
if (-not [System.IO.Path]::IsPathRooted($artifactsPath)) {
    $artifactsPath = Join-Path $repoRoot $artifactsPath
}

$codeAppsRoot = Join-Path $repoRoot "src\codeapps"

# Ensure artifacts directory exists
if (-not (Test-Path $artifactsPath)) {
    New-Item -ItemType Directory -Path $artifactsPath -Force | Out-Null
}
$artifactsPath = (Resolve-Path $artifactsPath).Path

# Discover or filter code app projects (identified by power.config.json presence)
if (-not [string]::IsNullOrWhiteSpace($projectPaths)) {
    Write-Host "Building filtered code app projects..." -ForegroundColor Cyan
    $filteredProjects = @()
    foreach ($p in ($projectPaths -split ',')) {
        $p = $p.Trim()
        if (-not [string]::IsNullOrWhiteSpace($p)) {
            if (-not [System.IO.Path]::IsPathRooted($p)) {
                $p = Join-Path $repoRoot $p
            }
            if (Test-Path $p) {
                $filteredProjects += Get-Item $p
            }
            else {
                Write-Warning "Code app project not found: $p"
            }
        }
    }
}
else {
    if (-not [string]::IsNullOrWhiteSpace($projectFilter)) {
        Write-Host "Discovering code app projects (filter: $projectFilter)..." -ForegroundColor Cyan
    } else {
        Write-Host "Discovering code app projects..." -ForegroundColor Cyan
    }

    if (-not (Test-Path $codeAppsRoot)) {
        Write-Warning "No src/codeapps directory found. Nothing to build."
        exit 0
    }

    # Identify projects by power.config.json presence
    $codeAppProjects = Get-ChildItem -Path $codeAppsRoot -Recurse -Filter "power.config.json" |
        Select-Object -ExpandProperty Directory -Unique

    if ($codeAppProjects.Count -eq 0) {
        Write-Warning "No code app projects found in $codeAppsRoot"
        exit 0
    }

    # Apply projectFilter if specified
    if (-not [string]::IsNullOrWhiteSpace($projectFilter)) {
        $codeAppProjects = $codeAppProjects | Where-Object {
            $_.FullName -like "*$([System.IO.Path]::DirectorySeparatorChar)$projectFilter$([System.IO.Path]::DirectorySeparatorChar)*" -or
            $_.FullName -like "*$([System.IO.Path]::DirectorySeparatorChar)$projectFilter"
        }
    }

    $filteredProjects = $codeAppProjects
}

if ($filteredProjects.Count -eq 0) {
    Write-Warning "No code app projects to build"
    exit 0
}

Write-Host "Found $($filteredProjects.Count) code app project(s):" -ForegroundColor Green
$filteredProjects | ForEach-Object { Write-Host "  • $($_.Name)" -ForegroundColor Gray }
Write-Host ""

# Recursively collect all unique file: dependency paths across a set of project directories.
# Returns paths in depth-first (leaf-first) order so deps are built before their dependents.
function Get-AllLocalFileDependencies {
    param([System.IO.DirectoryInfo[]]$Projects)

    $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $ordered = [System.Collections.Generic.List[string]]::new()

    function Visit([string]$dir) {
        $pkgPath = Join-Path $dir "package.json"
        if (-not (Test-Path $pkgPath)) { return }

        $pkg = Get-Content $pkgPath -Raw | ConvertFrom-Json

        $allDeps = [ordered]@{}
        if ($pkg.PSObject.Properties.Name -contains "dependencies") {
            $pkg.dependencies.PSObject.Properties | ForEach-Object { $allDeps[$_.Name] = $_.Value }
        }
        if ($pkg.PSObject.Properties.Name -contains "devDependencies") {
            $pkg.devDependencies.PSObject.Properties | ForEach-Object { $allDeps[$_.Name] = $_.Value }
        }

        foreach ($dep in $allDeps.GetEnumerator()) {
            if ($dep.Value -notmatch '^file:') { continue }
            $relPath = $dep.Value -replace '^file:', ''
            $depPath = [System.IO.Path]::GetFullPath((Join-Path $dir $relPath))

            if (-not (Test-Path (Join-Path $depPath "package.json"))) { continue }
            if (-not $visited.Add($depPath)) { continue }  # already queued

            Visit $depPath          # recurse: leaf deps first
            $ordered.Add($depPath)
        }
    }

    foreach ($proj in $Projects) { Visit $proj.FullName }

    return $ordered
}

# Phase 1 — Pre-build all file: library dependencies.
Write-Host "Pre-building local file: dependencies..." -ForegroundColor Cyan

$allLibDeps = Get-AllLocalFileDependencies -Projects $filteredProjects
if ($allLibDeps.Count -eq 0) {
    Write-Host "  No local file: dependencies found." -ForegroundColor Gray
}
foreach ($depPath in $allLibDeps) {
    $depPkg = Get-Content (Join-Path $depPath "package.json") -Raw | ConvertFrom-Json
    $depName = $depPkg.name
    Write-Host "  ► $depName" -ForegroundColor Gray

    Push-Location $depPath
    try {
        npm ci | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "npm ci failed for '$depName' (exit $LASTEXITCODE)" }

        $hasBuild = $depPkg.PSObject.Properties.Name -contains "scripts" -and
                    $depPkg.scripts.PSObject.Properties.Name -contains "build"
        if ($hasBuild) {
            npm run build | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "npm run build failed for '$depName' (exit $LASTEXITCODE)" }
        }
    }
    finally { Pop-Location }
}

Write-Host ""

# Phase 2 — Build each code app project.
# Note: No solution copy is performed here. The map.xml entry in the cdsproj maps
# dist/ → CanvasApps/{logicalName}_CodeAppPackages/ at dotnet build time.
$buildResults = @()

foreach ($projectDir in $filteredProjects) {
    $projectName = $projectDir.Name
    
    Write-Host "Building $projectName..." -ForegroundColor Cyan
    Write-Host "  Directory: $($projectDir.FullName)" -ForegroundColor Gray
    
    $originalLocation = Get-Location
    try {
        Set-Location $projectDir.FullName
        
        if (-not (Test-Path "package.json")) {
            Write-Warning "  No package.json found, skipping..."
            $buildResults += @{ Project = $projectName; Status = "Skipped" }
            continue
        }

        $localFileDeps = @(Get-AllLocalFileDependencies -Projects @($projectDir))

        if ($localFileDeps.Count -gt 0) {
            Write-Host "  Running npm install --ignore-scripts (file: deps detected)..." -ForegroundColor Cyan
            npm install --ignore-scripts
        } else {
            Write-Host "  Running npm ci --ignore-scripts..." -ForegroundColor Cyan
            npm ci --ignore-scripts
        }
        
        if ($LASTEXITCODE -ne 0) {
            throw "npm install/ci failed with exit code $LASTEXITCODE"
        }

        # Remove node_modules from file: deps nested inside this project
        foreach ($depPath in $localFileDeps) {
            $isInsideProject = $depPath.StartsWith($projectDir.FullName + [System.IO.Path]::DirectorySeparatorChar)
            if (-not $isInsideProject) { continue }
            $depNodeModules = Join-Path $depPath "node_modules"
            if (Test-Path $depNodeModules) {
                Write-Host "  Removing node_modules from $(Split-Path $depPath -Leaf) to prevent duplicate type resolution..." -ForegroundColor Gray
                Remove-Item -Path $depNodeModules -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        
        Write-Host "  ✓ Dependencies installed" -ForegroundColor Green
        
        Write-Host "  Running npm run build..." -ForegroundColor Cyan
        npm run build
        
        if ($LASTEXITCODE -ne 0) {
            throw "npm run build failed with exit code $LASTEXITCODE"
        }
        
        Write-Host "  ✓ Build succeeded" -ForegroundColor Green

        # Verify content hashing is disabled (dist/ should not contain hash-suffixed filenames)
        if (Test-Path "dist") {
            $hashedFiles = Get-ChildItem -Path "dist" -Recurse -File |
                Where-Object { $_.Name -match '-[A-Za-z0-9]{8}\.' }
            if ($hashedFiles) {
                Write-Warning "  Content-hashed filenames detected in dist/ — map.xml paths may be unstable."
                Write-Warning "  Ensure vite.config.ts sets entryFileNames/chunkFileNames/assetFileNames without hashes."
                $hashedFiles | ForEach-Object { Write-Warning "    $($_.Name)" }
            }

            # Copy dist/ to artifacts
            $projectArtifactPath = Join-Path $artifactsPath $projectName
            if (-not (Test-Path $projectArtifactPath)) {
                New-Item -ItemType Directory -Path $projectArtifactPath -Force | Out-Null
            }
            Copy-Item -Path "dist\*" -Destination $projectArtifactPath -Recurse -Force
            Write-Host "  ✓ Copied dist/ to artifacts" -ForegroundColor Green
        }
        else {
            Write-Warning "  No dist/ directory found after build"
        }
        
        $buildResults += @{ Project = $projectName; Status = "Success" }
    }
    catch {
        Write-Host "  ❌ Build failed: $($_.Exception.Message)" -ForegroundColor Red
        $buildResults += @{ Project = $projectName; Status = "Failed"; Error = $_.Exception.Message }
    }
    finally {
        Set-Location $originalLocation
        Write-Host ""
    }
}

# Summary
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Build Summary" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan

$hasFailures = $false
foreach ($result in $buildResults) {
    if ($result.Status -eq "Success") {
        Write-Host "  ✓ $($result.Project)" -ForegroundColor Green
    }
    elseif ($result.Status -eq "Skipped") {
        Write-Host "  ⚪ $($result.Project) (skipped)" -ForegroundColor Gray
    }
    else {
        Write-Host "  ❌ $($result.Project): $($result.Error)" -ForegroundColor Red
        $hasFailures = $true
    }
}

Write-Host ""

if ($hasFailures) {
    Write-Error "One or more code app builds failed."
    exit 1
}

Write-Host "All code app builds completed successfully." -ForegroundColor Green
