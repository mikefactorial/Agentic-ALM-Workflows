<#
.SYNOPSIS
    Calculate the next version number using date-based versioning with Git tags
    
.DESCRIPTION
    Generates version numbers in the format YYYY.MM.DD.BuildNumber where BuildNumber
    increments for each build on the same day. Uses Git tags to track build numbers.
    
.EXAMPLE
    $version = .\Get-NextVersion.ps1
    # Returns: 2026.02.04.1 (if no builds today)
    # Returns: 2026.02.04.2 (if one build already exists today)
#>

[CmdletBinding()]
param()

try {
    # Get today's date in format YYYY.MM.DD
    $today = Get-Date -Format "yyyy.MM.dd"
    
    Write-Host "Calculating next version for date: $today" -ForegroundColor Cyan
    
    # Find all tags for today's date
    $tagPattern = "v$today.*"
    Write-Host "Searching for existing tags matching pattern: $tagPattern" -ForegroundColor Gray
    
    $existingTags = git tag --list $tagPattern 2>&1
    
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Git command failed. Ensure you're in a Git repository."
        # Default to build 1 if git fails
        $buildNumber = 1
    }
    elseif (-not $existingTags -or $existingTags.Count -eq 0) {
        Write-Host "No existing tags found for today. Starting with build 1." -ForegroundColor Gray
        $buildNumber = 1
    }
    else {
        Write-Host "Found $($existingTags.Count) existing tag(s) for today:" -ForegroundColor Gray
        $existingTags | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
        
        # Extract build numbers from tags using regex
        # Pattern: v2026.02.04.1 -> capture the final number
        $buildNumbers = $existingTags | ForEach-Object {
            if ($_ -match 'v\d{4}\.\d{2}\.\d{2}\.(\d+)') {
                [int]$matches[1]
            }
        } | Where-Object { $_ -ne $null }
        
        if ($buildNumbers.Count -gt 0) {
            $maxBuildNumber = ($buildNumbers | Measure-Object -Maximum).Maximum
            $buildNumber = $maxBuildNumber + 1
            Write-Host "Latest build number: $maxBuildNumber. Next build: $buildNumber" -ForegroundColor Gray
        }
        else {
            Write-Warning "Could not parse build numbers from tags. Starting with build 1."
            $buildNumber = 1
        }
    }
    
    # Construct the version string
    $version = "$today.$buildNumber"
    
    Write-Host ""
    Write-Host "✓ Next version: $version" -ForegroundColor Green
    Write-Host ""
    
    # Return the version string
    return $version
}
catch {
    Write-Error "Failed to calculate next version: $($_.Exception.Message)"
    exit 1
}
