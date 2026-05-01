<#
.SYNOPSIS
    Build all plugin projects and run unit tests
    
.DESCRIPTION
    Discovers and builds all .NET plugin projects in src/plugins directory,
    runs unit tests, and outputs artifacts and test results.
    
.PARAMETER artifactsPath
    Directory where plugin DLLs will be copied (default: ./artifacts/plugins)
    
.PARAMETER testResultsPath
    Directory where test results will be written (default: ./artifacts/test-results)
    
.PARAMETER configuration
    Build configuration (default: Release)
    
.PARAMETER projectPaths
    Optional comma-separated list of specific .csproj paths to build (relative to repo root).
    When provided, only these projects are built instead of discovering all.
    When omitted, all plugin projects are discovered and built.
    
.PARAMETER skipTests
    Skip running unit tests
    
.EXAMPLE
    .\Build-Plugins.ps1
    
.EXAMPLE
    .\Build-Plugins.ps1 -artifactsPath "./build/plugins" -configuration Debug
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$artifactsPath = "./artifacts/plugins",
    
    [Parameter(Mandatory=$false)]
    [string]$testResultsPath = "./artifacts/test-results",
    
    [Parameter(Mandatory=$false)]
    [string]$configuration = "Release",
    
    [Parameter(Mandatory=$false)]
    [string]$projectPaths = "",

    [Parameter(Mandatory=$false)]
    [switch]$skipTests
)

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Build Plugins" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

$ErrorActionPreference = "Stop"
$pluginsRoot = "./src/plugins"

# Ensure artifacts directories exist
if (-not (Test-Path $artifactsPath)) {
    New-Item -ItemType Directory -Path $artifactsPath -Force | Out-Null
}

if (-not (Test-Path $testResultsPath)) {
    New-Item -ItemType Directory -Path $testResultsPath -Force | Out-Null
}

# Discover or filter plugin projects
if (-not [string]::IsNullOrWhiteSpace($projectPaths)) {
    # Build only the specific projects requested
    Write-Host "Building filtered plugin projects..." -ForegroundColor Cyan
    $pluginProjects = @()
    foreach ($p in ($projectPaths -split ',')) {
        $p = $p.Trim()
        if (-not [string]::IsNullOrWhiteSpace($p)) {
            if (Test-Path $p) {
                $pluginProjects += Get-Item $p
            }
            else {
                Write-Warning "Project not found: $p"
            }
        }
    }
}
else {
    # Discover all plugin projects (exclude test projects)
    Write-Host "Discovering plugin projects..." -ForegroundColor Cyan
    $pluginProjects = @(Get-ChildItem -Path $pluginsRoot -Recurse -Filter "*.csproj" | 
        Where-Object { $_.Name -notlike "*.Tests.csproj" })
}

if ($pluginProjects.Count -eq 0) {
    Write-Warning "No plugin projects found"
    exit 0
}

Write-Host "Found $($pluginProjects.Count) plugin project(s):" -ForegroundColor Green
$pluginProjects | ForEach-Object { Write-Host "  • $($_.Name)" -ForegroundColor Gray }
Write-Host ""

# Restore NuGet packages for the solution (handles packages.config)
Write-Host "Restoring NuGet packages..." -ForegroundColor Cyan
$solutionFiles = @(Get-ChildItem -Path $pluginsRoot -Recurse -Filter "*.sln")

if ($solutionFiles.Count -gt 0) {
    # Use nuget.exe for .NET Framework projects with packages.config
    # nuget.exe should be available in PATH from workflow setup or local install
    $nugetExe = Get-Command nuget -ErrorAction SilentlyContinue
    
    if (-not $nugetExe) {
        Write-Warning "nuget.exe not found in PATH. Attempting to install..."
        # Download nuget.exe if not available
        $nugetPath = Join-Path $env:TEMP "nuget.exe"
        Invoke-WebRequest -Uri "https://dist.nuget.org/win-x86-commandline/latest/nuget.exe" -OutFile $nugetPath
        $nugetExe = $nugetPath
    }
    else {
        $nugetExe = $nugetExe.Path
    }

    foreach ($solutionFile in $solutionFiles) {
        Write-Host "  Solution: $($solutionFile.FullName)" -ForegroundColor Gray
        & $nugetExe restore "$($solutionFile.FullName)"
        
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "NuGet restore returned exit code $LASTEXITCODE for $($solutionFile.Name)"
        }
        else {
            Write-Host "  ✓ NuGet packages restored for $($solutionFile.Name)" -ForegroundColor Green
        }
    }
}
else {
    Write-Warning "No solution file found, restoring packages per-project"
}
Write-Host ""

# Build each plugin project
$buildResults = @()
foreach ($project in $pluginProjects) {
    $projectName = [System.IO.Path]::GetFileNameWithoutExtension($project.Name)
    
    Write-Host "Building $projectName..." -ForegroundColor Cyan
    Write-Host "  Project: $($project.FullName)" -ForegroundColor Gray
    
    try {
        dotnet build "$($project.FullName)" --configuration $configuration
        
        if ($LASTEXITCODE -ne 0) {
            throw "Build failed with exit code $LASTEXITCODE"
        }
        
        Write-Host "  ✓ Build succeeded" -ForegroundColor Green
        
        # Look for merged DLL in bin/{configuration}/merged/ folder
        $projectDir = $project.Directory.FullName
        $mergedPath = Join-Path $projectDir "bin\$configuration\merged"
        
        if (Test-Path $mergedPath) {
            $mergedDlls = Get-ChildItem -Path $mergedPath -Filter "*.dll"
            
            if ($mergedDlls.Count -gt 0) {
                foreach ($dll in $mergedDlls) {
                    $destinationPath = Join-Path $artifactsPath $dll.Name
                    Copy-Item -Path $dll.FullName -Destination $destinationPath -Force
                    Write-Host "  ✓ Copied merged DLL: $($dll.Name)" -ForegroundColor Green
                }
            }
            else {
                Write-Warning "  No merged DLLs found in $mergedPath"
            }
        }
        else {
            # Fall back to regular bin output
            $binPath = Join-Path $projectDir "bin\$configuration"
            $dll = Get-ChildItem -Path $binPath -Filter "$projectName.dll" -ErrorAction SilentlyContinue | Select-Object -First 1
            
            if ($dll) {
                $destinationPath = Join-Path $artifactsPath $dll.Name
                Copy-Item -Path $dll.FullName -Destination $destinationPath -Force
                Write-Host "  ✓ Copied DLL: $($dll.Name)" -ForegroundColor Green
            }
            else {
                Write-Warning "  Could not find output DLL"
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
    
    Write-Host ""
}

# Discover and run test projects
if (-not $skipTests) {
    Write-Host "Discovering test projects..." -ForegroundColor Cyan

    if (-not [string]::IsNullOrWhiteSpace($projectPaths)) {
        # When filtering, only find test projects that match the built plugins
        $testProjects = @()
        foreach ($pluginProject in $pluginProjects) {
            $pluginName = [System.IO.Path]::GetFileNameWithoutExtension($pluginProject.Name)
            $testCsproj = Get-ChildItem -Path $pluginsRoot -Recurse -Filter "$pluginName.Tests.csproj" -ErrorAction SilentlyContinue
            if ($testCsproj) { $testProjects += $testCsproj }
        }
    }
    else {
        $testProjects = @(Get-ChildItem -Path $pluginsRoot -Recurse -Filter "*.Tests.csproj")
    }
    
    if ($testProjects.Count -eq 0) {
        Write-Host "No test projects found" -ForegroundColor Gray
    }
    else {
        Write-Host "Found $($testProjects.Count) test project(s):" -ForegroundColor Green
        $testProjects | ForEach-Object { Write-Host "  • $($_.Name)" -ForegroundColor Gray }
        Write-Host ""
        
        $absoluteTestResultsPath = (Resolve-Path $testResultsPath).Path
        $testResults = @()
        foreach ($testProject in $testProjects) {
            $testProjectName = [System.IO.Path]::GetFileNameWithoutExtension($testProject.Name)
            
            Write-Host "Running tests for $testProjectName..." -ForegroundColor Cyan
            
            try {
                dotnet test "$($testProject.FullName)" `
                    --configuration $configuration `
                    --logger "trx;LogFileName=$testProjectName.trx" `
                    --results-directory "$absoluteTestResultsPath"
                
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  ✓ Tests passed" -ForegroundColor Green
                    $testResults += @{
                        Project = $testProjectName
                        Status = "Passed"
                    }
                }
                else {
                    Write-Host "  ❌ Tests failed" -ForegroundColor Red
                    $testResults += @{
                        Project = $testProjectName
                        Status = "Failed"
                    }
                }
            }
            catch {
                Write-Host "  ❌ Test execution failed: $($_.Exception.Message)" -ForegroundColor Red
                $testResults += @{
                    Project = $testProjectName
                    Status = "Error"
                    Error = $_.Exception.Message
                }
            }
            
            Write-Host ""
        }
        
        # Test summary
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
            Write-Error "One or more test projects failed"
            exit 1
        }
    }
}
else {
    Write-Host "Skipping tests (skipTests flag set)" -ForegroundColor Yellow
    Write-Host ""
}

# Build summary
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Build Summary" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

foreach ($result in $buildResults) {
    $status = if ($result.Status -eq "Success") { "✓" } else { "❌" }
    $color = if ($result.Status -eq "Success") { "Green" } else { "Red" }
    Write-Host "$status $($result.Project): $($result.Status)" -ForegroundColor $color
}

Write-Host ""
Write-Host "Artifacts directory: $artifactsPath" -ForegroundColor Cyan
if (-not $skipTests) {
    Write-Host "Test results directory: $testResultsPath" -ForegroundColor Cyan
}
Write-Host ""

# Fail if any builds failed
$failedBuilds = $buildResults | Where-Object { $_.Status -ne "Success" }
if ($failedBuilds.Count -gt 0) {
    Write-Error "One or more plugin builds failed"
    exit 1
}

Write-Host "✓ All plugin builds completed successfully" -ForegroundColor Green
Write-Host ""
exit 0
