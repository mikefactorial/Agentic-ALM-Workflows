<#
.SYNOPSIS
    Build all PCF (PowerApps Component Framework) control projects
    
.DESCRIPTION
    Discovers and builds all PCF control projects in src/controls directory,
    runs tests if available, and outputs build artifacts.
    
.PARAMETER artifactsPath
    Directory where control outputs will be copied (default: ./artifacts/controls)
    
.PARAMETER testResultsPath
    Directory where test results will be written (default: ./artifacts/test-results)
    
.PARAMETER skipTests
    Skip running tests

.PARAMETER projectPaths
    Optional comma-separated list of specific .pcfproj paths to build (relative to repo root).
    When provided, only these control projects are built instead of discovering all.
    When omitted, all control projects are discovered and built.

.PARAMETER projectFilter
    Optional subdirectory name to filter discovered projects (e.g., 'pub_MySolution').
    Only projects whose path contains this segment are built. Ignored when projectPaths is set.

.EXAMPLE
    .\Build-Controls.ps1
    
.EXAMPLE
    .\Build-Controls.ps1 -artifactsPath "./build/controls"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$artifactsPath = "./artifacts/controls",
    
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
Write-Host "  Build PCF Controls" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

$ErrorActionPreference = "Stop"

# Resolve repo root from script location for path resolution
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..") | Select-Object -ExpandProperty Path

# Resolve all paths - convert relative defaults to absolute based on repo root
if (-not [System.IO.Path]::IsPathRooted($artifactsPath)) {
    $artifactsPath = Join-Path $repoRoot $artifactsPath
}
if (-not [System.IO.Path]::IsPathRooted($testResultsPath)) {
    $testResultsPath = Join-Path $repoRoot $testResultsPath
}

$controlsRoot = Join-Path $repoRoot "src\controls"

# Ensure artifacts directories exist and resolve to absolute paths
if (-not (Test-Path $artifactsPath)) {
    New-Item -ItemType Directory -Path $artifactsPath -Force | Out-Null
}
$artifactsPath = (Resolve-Path $artifactsPath).Path

if (-not (Test-Path $testResultsPath)) {
    New-Item -ItemType Directory -Path $testResultsPath -Force | Out-Null
}
$testResultsPath = (Resolve-Path $testResultsPath).Path

# Discover or filter PCF control projects
if (-not [string]::IsNullOrWhiteSpace($projectPaths)) {
    # Build only the specific control projects requested
    Write-Host "Building filtered PCF control projects..." -ForegroundColor Cyan
    $filteredProjects = @()
    foreach ($p in ($projectPaths -split ',')) {
        $p = $p.Trim()
        if (-not [string]::IsNullOrWhiteSpace($p)) {
            # Resolve to absolute path if relative
            if (-not [System.IO.Path]::IsPathRooted($p)) {
                $p = Join-Path $repoRoot $p
            }
            if (Test-Path $p) {
                $filteredProjects += (Get-Item $p).Directory
            }
            else {
                Write-Warning "Control project not found: $p"
            }
        }
    }
}
else {
    if (-not [string]::IsNullOrWhiteSpace($projectFilter)) {
        Write-Host "Discovering PCF control projects (filter: $projectFilter)..." -ForegroundColor Cyan
    } else {
        Write-Host "Discovering PCF control projects..." -ForegroundColor Cyan
    }

    $controlProjects = Get-ChildItem -Path $controlsRoot -Recurse -Filter "*.pcfproj" | 
        Select-Object -ExpandProperty Directory -Unique

    if ($controlProjects.Count -eq 0) {
        Write-Warning "No PCF control projects found in $controlsRoot"
        exit 0
    }

    # Apply projectFilter if specified
    if (-not [string]::IsNullOrWhiteSpace($projectFilter)) {
        $controlProjects = $controlProjects | Where-Object {
            $_.FullName -like "*$([System.IO.Path]::DirectorySeparatorChar)$projectFilter$([System.IO.Path]::DirectorySeparatorChar)*" -or
            $_.FullName -like "*$([System.IO.Path]::DirectorySeparatorChar)$projectFilter"
        }
    }

    # Filter out parent projects that contain other PCF projects
    # (e.g., my-components contains ComponentA and ComponentB)
    $filteredProjects = $controlProjects | Where-Object {
        $currentPath = $_.FullName
        $isParent = $controlProjects | Where-Object { 
            $_.FullName -ne $currentPath -and 
            $_.FullName.StartsWith($currentPath + [System.IO.Path]::DirectorySeparatorChar)
        }
        -not $isParent
    }
}

if ($filteredProjects.Count -eq 0) {
    Write-Warning "No PCF control projects to build"
    exit 0
}

Write-Host "Found $($filteredProjects.Count) control project(s):" -ForegroundColor Green
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

# Phase 1 ─ Pre-install and pre-build every file: library dependency across ALL
# control projects before any control build starts.  Shared libraries (e.g.
# PCF-InputControls used by both vet controls) are built only once, in
# dependency order (leaf packages first).
Write-Host "Pre-building local file: dependencies..." -ForegroundColor Cyan

$allLibDeps = Get-AllLocalFileDependencies -Projects $filteredProjects
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

# Phase 2 ─ Build each control project.
# Use --ignore-scripts so npm ci does NOT re-run prepare on the file: deps;
# their dist/ folders already exist from Phase 1 above.
# After install, remove node_modules from any file: deps that live *inside*
# this project directory (e.g. ./MiscExtras) to prevent TypeScript from finding
# duplicate type packages (e.g. two csstype instances → TS2322).
# Sibling/parent deps keep their node_modules so webpack can resolve their
# peer dependencies (e.g. react-dom) during bundling.

$buildResults = @()
$testResults = @()

foreach ($projectDir in $filteredProjects) {
    $projectName = $projectDir.Name
    
    Write-Host "Building $projectName..." -ForegroundColor Cyan
    Write-Host "  Directory: $($projectDir.FullName)" -ForegroundColor Gray
    
    $originalLocation = Get-Location
    try {
        Set-Location $projectDir.FullName
        
        # Check if package.json exists
        if (-not (Test-Path "package.json")) {
            Write-Warning "  No package.json found, skipping..."
            $buildResults += @{
                Project = $projectName
                Status = "Skipped"
            }
            continue
        }
        
        # Install local file: dependencies first so their prepare scripts can run.
        # Capture the resolved dep paths so we can clean up their node_modules afterwards.
        $localFileDeps = @(Get-AllLocalFileDependencies -Projects @($projectDir))

        # All file: deps are already pre-built in Phase 1, so skip lifecycle scripts.
        # Use 'npm install' (not 'npm ci') when file: deps are present — lock files for
        # local file: deps become stale whenever those packages' versions are bumped,
        # causing 'npm ci' to fail with "lock file out of sync".
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

        # Remove node_modules only from file: deps that live INSIDE this project's directory
        # (e.g. ./MiscExtras). Those nested node_modules cause TypeScript to find duplicate
        # type packages (e.g. two csstype instances) and produce TS2322 errors.
        # Deps in sibling/parent directories must keep their node_modules so that webpack
        # can resolve peer dependencies (e.g. react-dom) relative to those packages.
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
        
        # Run npm build
        Write-Host "  Running npm run build..." -ForegroundColor Cyan
        npm run build
        
        if ($LASTEXITCODE -ne 0) {
            throw "npm run build failed with exit code $LASTEXITCODE"
        }
        
        Write-Host "  ✓ Build succeeded" -ForegroundColor Green
        
        # Copy build outputs to artifacts
        # PCF controls typically output to out/ or dist/ directories
        $outputDirs = @("out", "dist", "bin")
        $outputCopied = $false
        
        foreach ($outDir in $outputDirs) {
            if (Test-Path $outDir) {
                $controlArtifactPath = Join-Path $artifactsPath $projectName
                if (-not (Test-Path $controlArtifactPath)) {
                    New-Item -ItemType Directory -Path $controlArtifactPath -Force | Out-Null
                }
                
                Copy-Item -Path "$outDir\*" -Destination $controlArtifactPath -Recurse -Force
                Write-Host "  ✓ Copied outputs from $outDir to artifacts" -ForegroundColor Green
                $outputCopied = $true
                break
            }
        }
        
        if (-not $outputCopied) {
            Write-Warning "  Could not find output directory (out/dist/bin)"
        }
        
        # Run tests if they exist
        if (-not $skipTests) {
            $packageJson = Get-Content "package.json" | ConvertFrom-Json
            
            if ($packageJson.scripts.PSObject.Properties.Name -contains "test") {
                Write-Host "  Running npm test..." -ForegroundColor Cyan
                
                try {
                    # Ensure jest-junit is available for CI test reporting
                    if (-not (Test-Path "node_modules/jest-junit")) {
                        Write-Host "  Installing jest-junit reporter..." -ForegroundColor Gray
                        npm install --no-save jest-junit 2>&1 | Out-Null
                    }
                    
                    # Tell jest-junit where to write output
                    $env:JEST_JUNIT_OUTPUT_DIR = $testResultsPath
                    $env:JEST_JUNIT_OUTPUT_NAME = "$projectName.junit.xml"
                    
                    npm test -- --reporters=default --reporters=jest-junit 2>&1 | Out-Null
                    
                    $testExitCode = $LASTEXITCODE
                    
                    # Look for JUnit XML test results generated by jest-junit
                    $junitFiles = Get-ChildItem -Path $testResultsPath -Filter "$projectName*.junit.xml" -ErrorAction SilentlyContinue
                    
                    if ($junitFiles) {
                        foreach ($junitFile in $junitFiles) {
                            [xml]$testResults_xml = Get-Content $junitFile.FullName
                            $testCount = $testResults_xml.testsuites.testsuite | Measure-Object | Select-Object -ExpandProperty Count
                            $failureCount = $testResults_xml.testsuites.testsuite.failure | Measure-Object | Select-Object -ExpandProperty Count
                            
                            if ($testExitCode -eq 0) {
                                Write-Host "  ✓ Tests passed ($testCount tests)" -ForegroundColor Green
                                $testResults += @{
                                    Project = $projectName
                                    Status = "Passed"
                                    TestFile = $junitFile.FullName
                                    TestCount = $testCount
                                }
                            }
                            else {
                                Write-Host "  ❌ Tests failed ($failureCount failures of $testCount tests)" -ForegroundColor Red
                                $testResults += @{
                                    Project = $projectName
                                    Status = "Failed"
                                    TestFile = $junitFile.FullName
                                    TestCount = $testCount
                                    FailureCount = $failureCount
                                }
                            }
                        }
                    }
                    else {
                        # No JUnit XML file generated, report based on exit code
                        if ($testExitCode -eq 0) {
                            Write-Host "  ✓ Tests passed" -ForegroundColor Green
                            $testResults += @{
                                Project = $projectName
                                Status = "Passed"
                            }
                        }
                        else {
                            Write-Host "  ❌ Tests failed" -ForegroundColor Red
                            $testResults += @{
                                Project = $projectName
                                Status = "Failed"
                            }
                        }
                    }
                }
                catch {
                    Write-Host "  ❌ Test execution failed: $($_.Exception.Message)" -ForegroundColor Red
                    $testResults += @{
                        Project = $projectName
                        Status = "Error"
                        Error = $_.Exception.Message
                    }
                }
            }
            else {
                Write-Host "  No test script found in package.json" -ForegroundColor Gray
            }
        }
        
        $buildResults += @{
            Project = $projectName
            Status = "Success"
        }
    }
    catch {
        Write-Host "  ❌ Build failed: $($_.Exception.Message)" -ForegroundColor Red
        $buildResults += @{
            Project = $projectName
            Status = "Failed"
            Error = $_.Exception.Message
        }
    }
    finally {
        Set-Location $originalLocation
    }
    
    Write-Host ""
}

# Test summary
if ($testResults.Count -gt 0 -and -not $skipTests) {
    Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Test Summary" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    
    foreach ($result in $testResults) {
        $status = if ($result.Status -eq "Passed") { "✓" } else { "❌" }
        $color = if ($result.Status -eq "Passed") { "Green" } else { "Red" }
        Write-Host "$status $($result.Project): $($result.Status)" -ForegroundColor $color
    }
    Write-Host ""
    
    # Fail if any tests failed
    $failedTests = $testResults | Where-Object { $_.Status -ne "Passed" }
    if ($failedTests.Count -gt 0) {
        Write-Error "One or more control test suites failed"
        exit 1
    }
}

# Build summary
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Build Summary" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

foreach ($result in $buildResults) {
    if ($result.Status -eq "Skipped") {
        Write-Host "⊘ $($result.Project): Skipped" -ForegroundColor Yellow
    }
    else {
        $status = if ($result.Status -eq "Success") { "✓" } else { "❌" }
        $color = if ($result.Status -eq "Success") { "Green" } else { "Red" }
        Write-Host "$status $($result.Project): $($result.Status)" -ForegroundColor $color
    }
}

Write-Host ""
Write-Host "Artifacts directory: $artifactsPath" -ForegroundColor Cyan
if (-not $skipTests -and $testResults.Count -gt 0) {
    Write-Host "Test results directory: $testResultsPath" -ForegroundColor Cyan
}
Write-Host ""

# Fail if any builds failed
$failedBuilds = $buildResults | Where-Object { $_.Status -eq "Failed" }
if ($failedBuilds.Count -gt 0) {
    Write-Error "One or more control builds failed"
    exit 1
}

Write-Host "✓ All control builds completed successfully" -ForegroundColor Green
Write-Host ""
exit 0
