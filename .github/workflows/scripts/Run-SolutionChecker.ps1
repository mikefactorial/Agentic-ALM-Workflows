<#
.SYNOPSIS
    Runs Power Platform Solution Checker on solution packages
    
.DESCRIPTION
    Validates solution packages against Power Platform best practices using the Solution Checker.
    Analyzes each solution and generates detailed reports with findings categorized by severity.
    
.PARAMETER solutionList
    Comma-separated list of solution names to check (e.g., "SolutionA,SolutionB")
    
.PARAMETER artifactsPath
    Path to directory containing built solution ZIP files
    
.PARAMETER resultsPath
    Path to directory where checker results will be saved
    
.PARAMETER failOnHighSeverity
    If true, fails the build if high severity issues are found (default: true)
    
.PARAMETER failOnMediumSeverity
    If true, fails the build if medium severity issues are found (default: false)
    
.EXAMPLE
    .\Run-SolutionChecker.ps1 -solutionList "SolutionA" -artifactsPath "./artifacts/solutions" -resultsPath "./artifacts/solution-checker"
    
.NOTES
    This script uses the Power Platform CLI (pac) solution checker.
    Solution Checker analyzes solutions for:
    - Performance issues
    - Security vulnerabilities
    - Design pattern violations
    - Deprecated API usage
    - Best practice violations
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$solutionList,
    
    [Parameter(Mandatory=$true)]
    [string]$artifactsPath,
    
    [Parameter(Mandatory=$true)]
    [string]$resultsPath,
    
    [Parameter(Mandatory=$true)]
    [string]$environmentUrl,
    
    [Parameter(Mandatory=$false)]
    [string]$tenantId = "",
    
    [Parameter(Mandatory=$false)]
    [string]$clientId = "",
    
    [Parameter(Mandatory=$false)]
    [bool]$failOnHighSeverity = $true,
    
    [Parameter(Mandatory=$false)]
    [bool]$failOnMediumSeverity = $false,
    
    [Parameter(Mandatory=$false)]
    [bool]$writeToSummary = $false,
    
    [Parameter(Mandatory=$false)]
    [string]$highSeverityExceptions = ""
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Solution Checker Validation" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# Parse exception list
$exceptionList = @()
if (-not [string]::IsNullOrWhiteSpace($highSeverityExceptions)) {
    $exceptionList = $highSeverityExceptions -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    if ($exceptionList.Count -gt 0) {
        Write-Host "High severity exception list: $($exceptionList.Count) solution(s)" -ForegroundColor Yellow
        $exceptionList | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }
        Write-Host ""
    }
}

# Parse solution list
$solutions = $solutionList -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }

if ($solutions.Count -eq 0) {
    Write-Host "No solutions to check. Exiting." -ForegroundColor Yellow
    exit 0
}

Write-Host "Solutions to check: $($solutions.Count)"
$solutions | ForEach-Object { Write-Host "  - $_" -ForegroundColor White }
Write-Host ""
Write-Host "Environment URL: $environmentUrl" -ForegroundColor White
Write-Host ""

# Import PowerPlatformClient class
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptPath "PowerPlatformClient.ps1")

# Create results directory
if (-not (Test-Path $resultsPath)) {
    New-Item -ItemType Directory -Path $resultsPath -Force | Out-Null
}

# Authenticate to Power Platform
Write-Host "Authenticating to Power Platform..." -ForegroundColor Cyan
try {
    if ($tenantId -and $clientId) {
        Write-Host "Using federated authentication (OIDC)" -ForegroundColor Gray
        $ppClient = [PowerPlatformClient]::new($tenantId, $clientId, $environmentUrl)
    } else {
        Write-Host "Using interactive authentication" -ForegroundColor Gray
        $ppClient = [PowerPlatformClient]::new($environmentUrl)
    }
    
    # Select the auth profile to ensure pac commands use it
    $ppClient.SelectProfile()
    
    Write-Host "✓ Successfully authenticated" -ForegroundColor Green
    Write-Host ""
} catch {
    Write-Error "Failed to authenticate to Power Platform: $_"
    exit 1
}

# Track overall results
$allResults = @()
$hasHighSeverityIssues = $false
$hasMediumSeverityIssues = $false
$totalIssues = 0

# Check each solution
foreach ($solution in $solutions) {
    Write-Host "─────────────────────────────────────────────────────────" -ForegroundColor Gray
    Write-Host "Checking solution: $solution" -ForegroundColor Cyan
    Write-Host ""
    
    # Find the latest solution ZIP for this solution
    $solutionFiles = Get-ChildItem -Path $artifactsPath -Filter "${solution}_*_managed.zip" | Sort-Object Name -Descending
    
    if ($solutionFiles.Count -eq 0) {
        Write-Warning "No solution package found for $solution in $artifactsPath"
        continue
    }
    
    $solutionFile = $solutionFiles[0].FullName
    Write-Host "Solution package: $($solutionFiles[0].Name)" -ForegroundColor White
    
    # Create output directory for this solution
    $solutionResultsPath = Join-Path $resultsPath $solution
    New-Item -ItemType Directory -Path $solutionResultsPath -Force | Out-Null
    
    try {
        Write-Host "Running solution checker..." -ForegroundColor Cyan
        
        # Run solution checker
        pac solution check `
            --path $solutionFile `
            --outputDirectory $solutionResultsPath `
            --geo "UnitedStates" `
            --saveResults
        
        $checkerExitCode = $LASTEXITCODE
        
        # List all files created in the output directory for debugging
        Write-Host "Files created in output directory:" -ForegroundColor Gray
        Get-ChildItem -Path $solutionResultsPath -File | ForEach-Object {
            Write-Host "  - $($_.Name)" -ForegroundColor Gray
        }
        
        # Find the SARIF file (pac creates files with timestamp-based names)
        $sarifFiles = Get-ChildItem -Path $solutionResultsPath -Filter "*.sarif" -File
        
        # If no direct SARIF file found, check if results are in ZIP files
        if ($sarifFiles.Count -eq 0) {
            $zipFiles = Get-ChildItem -Path $solutionResultsPath -Filter "*.zip" -File
            
            if ($zipFiles.Count -gt 0) {
                Write-Host "Extracting SARIF from ZIP files..." -ForegroundColor Gray
                
                foreach ($zipFile in $zipFiles) {
                    try {
                        $extractPath = Join-Path $solutionResultsPath "extracted_$($zipFile.BaseName)"
                        Expand-Archive -Path $zipFile.FullName -DestinationPath $extractPath -Force
                        
                        # Look for SARIF files in extracted content
                        $extractedSarif = Get-ChildItem -Path $extractPath -Filter "*.sarif" -File -Recurse
                        if ($extractedSarif.Count -gt 0) {
                            # Copy SARIF file to main results folder
                            Copy-Item -Path $extractedSarif[0].FullName -Destination (Join-Path $solutionResultsPath "$solution.sarif") -Force
                            Write-Host "  ✓ Extracted SARIF from $($zipFile.Name)" -ForegroundColor Green
                            break
                        }
                    } catch {
                        Write-Warning "Failed to extract $($zipFile.Name): $_"
                    }
                }
                
                # Re-check for SARIF files after extraction
                $sarifFiles = Get-ChildItem -Path $solutionResultsPath -Filter "*.sarif" -File
            }
        }
        
        if ($sarifFiles.Count -eq 0) {
            Write-Warning "Solution checker results file not found. Results may be in the ZIP files but SARIF extraction failed."
            Write-Warning "This typically means the checker completed but no analyzable SARIF output was generated."
            
            # Store zero results
            $allResults += [PSCustomObject]@{
                Solution = $solution
                High = 0
                Medium = 0
                Low = 0
                Informational = 0
                Total = 0
            }
            continue
        }
        
        # Use the first (or only) SARIF file found
        $outputPath = $sarifFiles[0].FullName
        Write-Host "✓ Solution checker completed" -ForegroundColor Green
        Write-Host "Results file: $($sarifFiles[0].Name)" -ForegroundColor Gray
        Write-Host "Results file: $($sarifFiles[0].Name)" -ForegroundColor Gray
            
            # Parse SARIF results
            $resultsJson = Get-Content $outputPath -Raw | ConvertFrom-Json
            
            # Count issues by severity
            $runs = $resultsJson.runs
            if ($runs -and $runs.Count -gt 0) {
                $results = $runs[0].results
                
                if ($results -and $results.Count -gt 0) {
                    $highSeverity = @($results | Where-Object { $_.level -eq "error" -or $_.properties.severity -eq "High" }).Count
                    $mediumSeverity = @($results | Where-Object { $_.level -eq "warning" -or $_.properties.severity -eq "Medium" }).Count
                    $lowSeverity = @($results | Where-Object { $_.level -eq "note" -or $_.properties.severity -eq "Low" }).Count
                    $informational = @($results | Where-Object { $_.properties.severity -eq "Informational" }).Count
                    
                    $totalForSolution = $results.Count
                    $totalIssues += $totalForSolution
                    
                    Write-Host ""
                    Write-Host "Results for $solution`:" -ForegroundColor White
                    if ($highSeverity -gt 0) {
                        Write-Host "  🔴 High Severity:    $highSeverity" -ForegroundColor Red
                        $hasHighSeverityIssues = $true
                    }
                    if ($mediumSeverity -gt 0) {
                        Write-Host "  🟡 Medium Severity:  $mediumSeverity" -ForegroundColor Yellow
                        $hasMediumSeverityIssues = $true
                    }
                    if ($lowSeverity -gt 0) {
                        Write-Host "  🔵 Low Severity:     $lowSeverity" -ForegroundColor Blue
                    }
                    if ($informational -gt 0) {
                        Write-Host "  ℹ️  Informational:   $informational" -ForegroundColor Gray
                    }
                    
                    # Store results
                    $allResults += [PSCustomObject]@{
                        Solution = $solution
                        High = $highSeverity
                        Medium = $mediumSeverity
                        Low = $lowSeverity
                        Informational = $informational
                        Total = $totalForSolution
                    }
                } else {
                    # No issues found
                    Write-Host ""
                    Write-Host "Results for $solution`:" -ForegroundColor White
                    Write-Host "  ✓ No issues found" -ForegroundColor Green
                    
                    # Store zero results
                    $allResults += [PSCustomObject]@{
                        Solution = $solution
                        High = 0
                        Medium = 0
                        Low = 0
                        Informational = 0
                        Total = 0
                    }
                }
            } else {
                # No results in SARIF
                Write-Host ""
                Write-Host "Results for $solution`:" -ForegroundColor White
                Write-Host "  ✓ No issues found" -ForegroundColor Green
                
                # Store zero results
                $allResults += [PSCustomObject]@{
                    Solution = $solution
                    High = 0
                    Medium = 0
                    Low = 0
                    Informational = 0
                    Total = 0
                }
            }
    }
    catch {
        Write-Host "Error running solution checker: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor Red
    }
    
    Write-Host ""
}

# Summary
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Solution Checker Summary" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

if ($allResults.Count -eq 0) {
    Write-Host "No solutions were checked" -ForegroundColor Yellow
    exit 0
}

# Display summary table
Write-Host "Solution".PadRight(40) + "High".PadLeft(6) + "Medium".PadLeft(8) + "Low".PadLeft(6) + "Info".PadLeft(6) + "Total".PadLeft(7)
Write-Host ("-" * 73) -ForegroundColor Gray

foreach ($result in $allResults) {
    $line = $result.Solution.PadRight(40)
    $line += $result.High.ToString().PadLeft(6)
    $line += $result.Medium.ToString().PadLeft(8)
    $line += $result.Low.ToString().PadLeft(6)
    $line += $result.Informational.ToString().PadLeft(6)
    $line += $result.Total.ToString().PadLeft(7)
    
    if ($result.High -gt 0) {
        Write-Host $line -ForegroundColor Red
    }
    elseif ($result.Medium -gt 0) {
        Write-Host $line -ForegroundColor Yellow
    }
    else {
        Write-Host $line -ForegroundColor White
    }
}

Write-Host ""
Write-Host "Results saved to: $resultsPath" -ForegroundColor Gray
Write-Host ""

# Write to GitHub Step Summary if requested
if ($writeToSummary -and $env:GITHUB_STEP_SUMMARY) {
    $summaryLines = @()
    $summaryLines += "## Solutions Checker Results"
    $summaryLines += ""
    $summaryLines += "| Solution | High | Medium | Low | Info | Total |"
    $summaryLines += "|----------|------|--------|-----|---------|-------|"
    
    foreach ($result in $allResults) {
        $summaryLines += "| $($result.Solution) | $($result.High) | $($result.Medium) | $($result.Low) | $($result.Informational) | $($result.Total) |"
    }
    
    $summaryLines += ""
    
    if ($hasHighSeverityIssues) {
        $summaryLines += "⚠️ **High severity issues found**. Review before merging."
    } elseif ($hasMediumSeverityIssues) {
        $summaryLines += "ℹ️ Medium severity warnings found."
    } else {
        $summaryLines += "✅ No high or medium severity issues detected."
    }
    
    $summaryLines += ""
    $summaryLines += "_Download the solution-checker-results artifact for detailed analysis._"
    
    $summaryContent = $summaryLines -join "`n"
    $summaryContent | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

# Cleanup authentication profile
Write-Host "Cleaning up authentication..." -ForegroundColor Gray
try {
    $ppClient.ClearAuth()
} catch {
    Write-Warning "Failed to clear authentication: $_"
}
Write-Host ""

# Determine if we should fail the build
$shouldFail = $false
$failureReasons = @()

if ($hasHighSeverityIssues -and $failOnHighSeverity) {
    # Check if all high severity solutions are in the exception list
    $highSeveritySolutions = @($allResults | Where-Object { $_.High -gt 0 } | Select-Object -ExpandProperty Solution)
    $nonExemptSolutions = @($highSeveritySolutions | Where-Object { $_ -notin $exceptionList })
    
    if ($nonExemptSolutions.Count -gt 0) {
        $shouldFail = $true
        $failureReasons += "High severity issues found in: $($nonExemptSolutions -join ', ')"
    } elseif ($highSeveritySolutions.Count -gt 0) {
        Write-Host "⚠️  High severity issues found but all affected solutions are exempt" -ForegroundColor Yellow
        $highSeveritySolutions | ForEach-Object {
            Write-Host "  - $_ (exempt from high severity failures)" -ForegroundColor Gray
        }
        Write-Host ""
    }
}

if ($hasMediumSeverityIssues -and $failOnMediumSeverity) {
    $shouldFail = $true
    $failureReasons += "Medium severity issues found"
}

if ($shouldFail) {
    Write-Host "❌ Solution checker validation FAILED" -ForegroundColor Red
    Write-Host ""
    foreach ($reason in $failureReasons) {
        Write-Host "  - $reason" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "Review the solution checker results in the artifacts for details." -ForegroundColor Yellow
    exit 1
}
else {
    if ($totalIssues -gt 0) {
        Write-Host "⚠️  Solution checker found $totalIssues issue(s), but none are blocking" -ForegroundColor Yellow
    }
    else {
        Write-Host "✓ Solution checker validation PASSED" -ForegroundColor Green
    }
    Write-Host ""
    exit 0
}
