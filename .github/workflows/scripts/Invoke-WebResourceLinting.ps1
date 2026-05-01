<#
.SYNOPSIS
    Lint JavaScript web resources in Power Platform solutions
    
.DESCRIPTION
    Runs ESLint on all JavaScript files in solution WebResources folders.
    Reports findings as warnings but does not fail the build unless critical errors are found.
    
.PARAMETER solutionPath
    Path to the solution folder containing src/WebResources
    
.PARAMETER failOnError
    If true, exit with non-zero code on ESLint errors (default: false, warnings only)
    
.PARAMETER configFile
    Path to ESLint configuration file (default: .eslintrc.solution-webresources.json in repo root)
    
.EXAMPLE
    .\Invoke-WebResourceLinting.ps1 -solutionPath ".\src\solutions\MySolutionName"
    
.EXAMPLE
    .\Invoke-WebResourceLinting.ps1 -solutionPath ".\src\solutions\MySolutionName" -failOnError $true
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$solutionPath,
    
    [Parameter(Mandatory=$false)]
    [bool]$failOnError = $false,
    
    [Parameter(Mandatory=$false)]
    [string]$configFile = "",
    
    [Parameter(Mandatory=$false)]
    [string]$outputFile = ""
)

$ErrorActionPreference = "Continue"

# Resolve repo root
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..") | Select-Object -ExpandProperty Path

# Set default config file if not specified
if ([string]::IsNullOrWhiteSpace($configFile)) {
    $configFile = Join-Path $repoRoot "eslint.config.solution-webresources.mjs"
}

# Check if ESLint config exists
if (-not (Test-Path $configFile)) {
    Write-Warning "ESLint config not found: $configFile"
    Write-Warning "Skipping web resource linting"
    return
}

# Check if solution has WebResources
$webResourcesPath = Join-Path $solutionPath "src\WebResources"

if (-not (Test-Path $webResourcesPath)) {
    Write-Host "  No WebResources folder found, skipping linting" -ForegroundColor Gray
    return
}

# Find JavaScript files (exclude minified and generated files)
$jsFiles = Get-ChildItem -Path $webResourcesPath -Filter "*.js" -Recurse -File | 
    Where-Object { 
        $_.Name -notmatch '\.min\.js$' -and 
        $_.Name -notmatch '\.bundle\.js$' -and
        $_.Directory.Name -ne 'node_modules'
    }

if ($jsFiles.Count -eq 0) {
    Write-Host "  No JavaScript files found to lint" -ForegroundColor Gray
    return
}

Write-Host "  Linting $($jsFiles.Count) JavaScript files..." -ForegroundColor Cyan

# Check if npx is available
$npx = Get-Command npx -ErrorAction SilentlyContinue

if (-not $npx) {
    Write-Warning "npx not found. Please install Node.js to enable linting."
    Write-Warning "Download from: https://nodejs.org/"
    return
}

# Run ESLint
$eslintPattern = "$webResourcesPath/**/*.js" -replace '\\', '/'

Write-Host "  Running: npx eslint --config $configFile $eslintPattern" -ForegroundColor Gray
Write-Host ""

# Use Start-Process to avoid PowerShell argument parsing issues
$eslintCmd = "npx eslint --config `"$configFile`" `"$eslintPattern`" --format stylish --ignore-pattern `"**/*.min.js`" --ignore-pattern `"**/*.bundle.js`" --ignore-pattern `"**/node_modules/**`""

$eslintOutput = Invoke-Expression $eslintCmd 2>&1

$exitCode = $LASTEXITCODE

# Parse output to count errors and warnings
$errorCount = 0
$warningCount = 0
$hasProblems = $false

# Display output and count issues
if ($eslintOutput) {
    $eslintOutput | ForEach-Object {
        $line = $_
        
        # Check for the summary line like "✖ 8 problems (0 errors, 8 warnings)"
        # Handle character encoding issues by looking for "problems"
        if ($line -match '(\d+)\s+problem.*\((\d+)\s+error.*,?\s*(\d+)\s+warning') {
            $hasProblems = $true
            $errorCount = [int]$matches[2]
            $warningCount = [int]$matches[3]
        }
        
        # Color-code output
        if ($line -match "error") {
            Write-Host "    $line" -ForegroundColor Red
        }
        elseif ($line -match "warning") {
            Write-Host "    $line" -ForegroundColor Yellow
        }
        else {
            Write-Host "    $line" -ForegroundColor Gray
        }
    }
}

Write-Host ""

# Summary based on what was found
if (-not $hasProblems) {
    Write-Host "  ✓ No linting issues found" -ForegroundColor Green
}
else {
    # Build summary message
    $summaryParts = @()
    if ($errorCount -gt 0) { $summaryParts += "$errorCount error$(if($errorCount -ne 1){'s'})" }
    if ($warningCount -gt 0) { $summaryParts += "$warningCount warning$(if($warningCount -ne 1){'s'})" }
    $summary = $summaryParts -join ", "
    
    if ($errorCount -gt 0) {
        Write-Host "  ⚠ Linting found $summary" -ForegroundColor Red
        if ($failOnError) {
            Write-Error "Build configured to fail on linting errors."
            exit 1
        }
        else {
            Write-Host "  (Set failOnError=`$true to fail build on linting errors)" -ForegroundColor Gray
        }
    }
    else {
        Write-Host "  ⚠ Linting found $summary" -ForegroundColor Yellow
        Write-Host "  (Warnings do not fail the build)" -ForegroundColor Gray
    }
}

Write-Host ""

# Output results to JSON file if requested
if (-not [string]::IsNullOrWhiteSpace($outputFile)) {
    $solutionName = Split-Path -Path $solutionPath -Leaf
    
    $lintingResults = @{
        Solution = $solutionName
        FileCount = $jsFiles.Count
        ErrorCount = $errorCount
        WarningCount = $warningCount
        HasProblems = $hasProblems
        Status = if (-not $hasProblems) { "Success" } elseif ($errorCount -gt 0) { "Error" } else { "Warning" }
    }
    
    # Ensure output directory exists
    $outputDir = Split-Path -Path $outputFile -Parent
    if (-not [string]::IsNullOrWhiteSpace($outputDir) -and -not (Test-Path $outputDir)) {
        New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
    }
    
    # Save to file
    $lintingResults | ConvertTo-Json -Compress | Set-Content -Path $outputFile -Encoding UTF8
}
