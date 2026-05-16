<#
.SYNOPSIS
    Build all TypeScript Web Resource projects
    
.DESCRIPTION
    Discovers and builds all TypeScript web resource projects in src/webresources directory,
    runs tests if available, and outputs build artifacts. Web resource projects are identified
    by the presence of a vite.config.ts file. Uses the same file: dependency pre-build pattern
    as Build-Controls.ps1.
    
.PARAMETER artifactsPath
    Directory where web resource outputs will be copied (default: ./artifacts/webresources)
    
.PARAMETER testResultsPath
    Directory where test results will be written (default: ./artifacts/test-results)
    
.PARAMETER skipTests
    Skip running tests

.PARAMETER projectPaths
    Optional comma-separated list of specific project directory paths to build (relative to repo root).
    When provided, only these projects are built instead of discovering all.
    When omitted, all web resource projects are discovered and built.

.PARAMETER projectFilter
    Optional subdirectory name to filter discovered projects (e.g., 'pub_MySolution').
    Only projects whose path contains this segment are built. Ignored when projectPaths is set.

.EXAMPLE
    .\Build-WebResources.ps1
    
.EXAMPLE
    .\Build-WebResources.ps1 -projectFilter "pub_MySolution" -artifactsPath "./build/webresources"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$artifactsPath = "./artifacts/webresources",
    
    [Parameter(Mandatory=$false)]
    [string]$testResultsPath = "./artifacts/test-results",
    
    [Parameter(Mandatory=$false)]
    [switch]$skipTests,

    [Parameter(Mandatory=$false)]
    [string]$projectPaths = "",

    [Parameter(Mandatory=$false)]
    [string]$projectFilter = ""
)

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Build TypeScript Web Resources" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

$ErrorActionPreference = "Stop"

# Resolve repo root from script location
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..") | Select-Object -ExpandProperty Path

# Resolve all paths
if (-not [System.IO.Path]::IsPathRooted($artifactsPath)) {
    $artifactsPath = Join-Path $repoRoot $artifactsPath
}
if (-not [System.IO.Path]::IsPathRooted($testResultsPath)) {
    $testResultsPath = Join-Path $repoRoot $testResultsPath
}

$webResourcesRoot = Join-Path $repoRoot "src\webresources"

# Ensure artifacts directories exist
if (-not (Test-Path $artifactsPath)) {
    New-Item -ItemType Directory -Path $artifactsPath -Force | Out-Null
}
$artifactsPath = (Resolve-Path $artifactsPath).Path

if (-not (Test-Path $testResultsPath)) {
    New-Item -ItemType Directory -Path $testResultsPath -Force | Out-Null
}
$testResultsPath = (Resolve-Path $testResultsPath).Path

# Discover or filter web resource projects (identified by vite.config.ts presence)
if (-not [string]::IsNullOrWhiteSpace($projectPaths)) {
    Write-Host "Building filtered web resource projects..." -ForegroundColor Cyan
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
                Write-Warning "Web resource project not found: $p"
            }
        }
    }
}
else {
    if (-not [string]::IsNullOrWhiteSpace($projectFilter)) {
        Write-Host "Discovering web resource projects (filter: $projectFilter)..." -ForegroundColor Cyan
    } else {
        Write-Host "Discovering web resource projects..." -ForegroundColor Cyan
    }

    if (-not (Test-Path $webResourcesRoot)) {
        Write-Warning "No src/webresources directory found. Nothing to build."
        exit 0
    }

    # Identify projects by vite.config.ts presence
    $webResourceProjects = Get-ChildItem -Path $webResourcesRoot -Recurse -Filter "vite.config.ts" |
        Select-Object -ExpandProperty Directory -Unique

    if ($webResourceProjects.Count -eq 0) {
        Write-Warning "No web resource projects found in $webResourcesRoot"
        exit 0
    }

    # Apply projectFilter if specified
    if (-not [string]::IsNullOrWhiteSpace($projectFilter)) {
        $webResourceProjects = $webResourceProjects | Where-Object {
            $_.FullName -like "*$([System.IO.Path]::DirectorySeparatorChar)$projectFilter$([System.IO.Path]::DirectorySeparatorChar)*" -or
            $_.FullName -like "*$([System.IO.Path]::DirectorySeparatorChar)$projectFilter"
        }
    }

    $filteredProjects = $webResourceProjects
}

if ($filteredProjects.Count -eq 0) {
    Write-Warning "No web resource projects to build"
    exit 0
}

Write-Host "Found $($filteredProjects.Count) web resource project(s):" -ForegroundColor Green
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

# Phase 1 — Pre-build all file: library dependencies before any web resource build starts.
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

# Phase 2 — Build each web resource project.
$buildResults = @()
$testResults  = @()

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

        # Remove node_modules only from file: deps nested inside this project
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
        
        # Copy dist/ output to artifacts
        if (Test-Path "dist") {
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

        # Run tests if present
        if (-not $skipTests) {
            $packageJson = Get-Content "package.json" | ConvertFrom-Json
            
            if ($packageJson.scripts.PSObject.Properties.Name -contains "test") {
                Write-Host "  Running npm test..." -ForegroundColor Cyan
                
                try {
                    if (-not (Test-Path "node_modules/jest-junit")) {
                        Write-Host "  Installing jest-junit reporter..." -ForegroundColor Gray
                        npm install --no-save jest-junit 2>&1 | Out-Null
                    }
                    
                    $env:JEST_JUNIT_OUTPUT_DIR  = $testResultsPath
                    $env:JEST_JUNIT_OUTPUT_NAME = "$projectName.junit.xml"
                    
                    npm test -- --reporters=default --reporters=jest-junit 2>&1 | Out-Null
                    $testExitCode = $LASTEXITCODE
                    
                    $junitFiles = Get-ChildItem -Path $testResultsPath -Filter "$projectName*.junit.xml" -ErrorAction SilentlyContinue
                    
                    if ($junitFiles) {
                        foreach ($junitFile in $junitFiles) {
                            [xml]$testXml = Get-Content $junitFile.FullName
                            $testCount    = $testXml.testsuites.testsuite | Measure-Object | Select-Object -ExpandProperty Count
                            $failureCount = $testXml.testsuites.testsuite.failure | Measure-Object | Select-Object -ExpandProperty Count
                            
                            if ($testExitCode -eq 0) {
                                Write-Host "  ✓ Tests passed ($testCount tests)" -ForegroundColor Green
                                $testResults += @{ Project = $projectName; Status = "Passed"; TestCount = $testCount }
                            }
                            else {
                                Write-Host "  ❌ Tests failed ($failureCount failures of $testCount tests)" -ForegroundColor Red
                                $testResults += @{ Project = $projectName; Status = "Failed"; TestCount = $testCount; FailureCount = $failureCount }
                            }
                        }
                    }
                    elseif ($testExitCode -eq 0) {
                        Write-Host "  ✓ Tests passed" -ForegroundColor Green
                        $testResults += @{ Project = $projectName; Status = "Passed" }
                    }
                    else {
                        Write-Host "  ❌ Tests failed" -ForegroundColor Red
                        $testResults += @{ Project = $projectName; Status = "Failed" }
                    }
                }
                catch {
                    Write-Host "  ❌ Test execution failed: $($_.Exception.Message)" -ForegroundColor Red
                    $testResults += @{ Project = $projectName; Status = "Error"; Error = $_.Exception.Message }
                }
            }
            else {
                Write-Host "  No test script defined, skipping tests" -ForegroundColor Gray
            }
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
    Write-Error "One or more web resource builds failed."
    exit 1
}

Write-Host "All web resource builds completed successfully." -ForegroundColor Green
