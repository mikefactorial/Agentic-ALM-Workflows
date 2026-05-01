# Hook Implementation Examples

This document provides practical examples of how to implement hooks for various scenarios in the Power Platform ALM process.

## Example 1: Solution Version Management

**Hook: `pre-build-update-version.ps1`**

Updates solution version before building based on semantic versioning:

```powershell
param(
    [Parameter(Mandatory=$true)] [String]$solutionName,
    [Parameter(Mandatory=$true)] [String]$solutionPath,
    [Parameter()] [String]$configuration = "Release"
)

Write-Host "Updating solution version for: $solutionName"

try {
    # Path to Solution.xml
    $solutionXmlPath = Join-Path $solutionPath "src\Other\Solution.xml"
    
    if (-not (Test-Path $solutionXmlPath)) {
        Write-Warning "Solution.xml not found at: $solutionXmlPath"
        exit 0
    }
    
    # Load Solution.xml
    [xml]$solutionXml = Get-Content $solutionXmlPath
    $currentVersion = $solutionXml.ImportExportXml.SolutionManifest.Version
    
    Write-Host "Current version: $currentVersion"
    
    # Parse version (Major.Minor.Build.Revision)
    $versionParts = $currentVersion.Split('.')
    $major = [int]$versionParts[0]
    $minor = [int]$versionParts[1]
    $build = [int]$versionParts[2]
    $revision = [int]$versionParts[3]
    
    # Increment revision for each build
    $revision++
    
    # Create new version
    $newVersion = "$major.$minor.$build.$revision"
    $solutionXml.ImportExportXml.SolutionManifest.Version = $newVersion
    
    # Save updated Solution.xml
    $solutionXml.Save($solutionXmlPath)
    
    Write-Host "✓ Updated version to: $newVersion" -ForegroundColor Green
    exit 0
}
catch {
    Write-Error "Failed to update version: $($_.Exception.Message)"
    exit 1
}
```

## Example 2: Pre-Commit Validation

**Hook: `pre-commit-validate-solution.ps1`**

Validates solution components before committing to Git:

```powershell
param(
    [Parameter(Mandatory=$true)] [String]$solutionName,
    [Parameter(Mandatory=$true)] [String]$solutionPath,
    [Parameter()] [String]$commitMessage
)

Write-Host "Validating solution before commit: $solutionName"

try {
    # Check for required files
    $requiredFiles = @(
        "src\Other\Solution.xml",
        "src\Other\Customizations.xml"
    )
    
    $missingFiles = @()
    foreach ($file in $requiredFiles) {
        $filePath = Join-Path $solutionPath $file
        if (-not (Test-Path $filePath)) {
            $missingFiles += $file
        }
    }
    
    if ($missingFiles.Count -gt 0) {
        Write-Error "Missing required files:"
        $missingFiles | ForEach-Object { Write-Error "  - $_" }
        exit 1
    }
    
    # Validate Solution.xml structure
    $solutionXmlPath = Join-Path $solutionPath "src\Other\Solution.xml"
    [xml]$solutionXml = Get-Content $solutionXmlPath
    
    $solutionUniqueName = $solutionXml.ImportExportXml.SolutionManifest.UniqueName
    if ([string]::IsNullOrWhiteSpace($solutionUniqueName)) {
        Write-Error "Solution unique name is missing or empty"
        exit 1
    }
    
    Write-Host "✓ Solution validation passed" -ForegroundColor Green
    Write-Host "  - Solution: $solutionUniqueName"
    Write-Host "  - All required files present"
    
    exit 0
}
catch {
    Write-Error "Solution validation failed: $($_.Exception.Message)"
    exit 1
}
```

## Example 3: Post-Deploy Notification

**Hook: `post-deploy-notify.ps1`**

Sends Teams notification after successful deployment:

```powershell
param(
    [Parameter(Mandatory=$true)] [String]$sourceSolutionName,
    [Parameter(Mandatory=$true)] [String]$targetSolutionName,
    [Parameter(Mandatory=$true)] [String]$targetEnvironmentUrl
)

Write-Host "Sending deployment notification..."

try {
    # Read Teams webhook URL from environment variable
    $teamsWebhookUrl = $env:TEAMS_WEBHOOK_URL
    
    if ([string]::IsNullOrWhiteSpace($teamsWebhookUrl)) {
        Write-Warning "TEAMS_WEBHOOK_URL not configured, skipping notification"
        exit 0
    }
    
    # Get deployment timestamp
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    
    # Create Teams message
    $message = @{
        "@type" = "MessageCard"
        "@context" = "https://schema.org/extensions"
        "summary" = "Solution Deployed"
        "themeColor" = "0078D4"
        "title" = "Power Platform Solution Deployed"
        "sections" = @(
            @{
                "activityTitle" = "Solution: $sourceSolutionName"
                "activitySubtitle" = "Deployed to: $targetEnvironmentUrl"
                "facts" = @(
                    @{
                        "name" = "Source Solution"
                        "value" = $sourceSolutionName
                    },
                    @{
                        "name" = "Target Solution"
                        "value" = $targetSolutionName
                    },
                    @{
                        "name" = "Environment"
                        "value" = $targetEnvironmentUrl
                    },
                    @{
                        "name" = "Timestamp"
                        "value" = $timestamp
                    }
                )
            }
        )
    }
    
    # Send to Teams
    $jsonBody = $message | ConvertTo-Json -Depth 10
    Invoke-RestMethod -Uri $teamsWebhookUrl -Method Post -Body $jsonBody -ContentType "application/json"
    
    Write-Host "✓ Teams notification sent successfully" -ForegroundColor Green
    exit 0
}
catch {
    Write-Warning "Failed to send Teams notification: $($_.Exception.Message)"
    # Don't fail the pipeline for notification failures
    exit 0
}
```

## Example 4: Pre-Export Environment Backup

**Hook: `pre-export-backup.ps1`**

Creates an environment backup before exporting solution:

```powershell
param(
    [Parameter(Mandatory=$true)] [String]$solutionName,
    [Parameter(Mandatory=$true)] [String]$environmentUrl
)

Write-Host "Creating environment backup before export..."

try {
    # Check if backup is needed (skip for dev environments)
    if ($environmentUrl -like "*-dev*") {
        Write-Host "Skipping backup for dev environment" -ForegroundColor Yellow
        exit 0
    }
    
    # Generate backup label
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupLabel = "pre-export-$solutionName-$timestamp"
    
    Write-Host "Creating backup: $backupLabel"
    
    # Create backup using pac CLI
    pac admin backup create `
        --environment $environmentUrl `
        --label $backupLabel `
        --notes "Automated backup before exporting solution: $solutionName"
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ Backup created successfully" -ForegroundColor Green
    } else {
        Write-Warning "Backup creation failed, but continuing with export"
    }
    
    exit 0
}
catch {
    Write-Warning "Failed to create backup: $($_.Exception.Message)"
    # Don't fail the export if backup fails
    exit 0
}
```

## Example 5: Post-Unpack Canvas App Processing

**Hook: `post-unpack-process-canvas-apps.ps1`**

Processes unpacked Canvas apps for better source control:

```powershell
param(
    [Parameter(Mandatory=$true)] [String]$solutionName,
    [Parameter(Mandatory=$true)] [String]$canvasAppsPath
)

Write-Host "Processing unpacked Canvas apps for solution: $solutionName"

try {
    # Find all unpacked Canvas app directories
    $unpackedApps = Get-ChildItem -Path $canvasAppsPath -Directory -Filter "*-src"
    
    if ($unpackedApps.Count -eq 0) {
        Write-Host "No unpacked Canvas apps found"
        exit 0
    }
    
    foreach ($appDir in $unpackedApps) {
        $appName = $appDir.Name -replace '-src$', ''
        Write-Host "Processing Canvas app: $appName"
        
        # Find all JSON files and format them
        $jsonFiles = Get-ChildItem -Path $appDir.FullName -Filter "*.json" -Recurse
        
        foreach ($jsonFile in $jsonFiles) {
            try {
                # Read, parse, and reformat JSON for better diff
                $json = Get-Content $jsonFile.FullName -Raw | ConvertFrom-Json
                $formatted = $json | ConvertTo-Json -Depth 100
                Set-Content -Path $jsonFile.FullName -Value $formatted -NoNewline
                
                Write-Host "  ✓ Formatted: $($jsonFile.Name)" -ForegroundColor Gray
            }
            catch {
                Write-Warning "  Failed to format: $($jsonFile.Name)"
            }
        }
    }
    
    Write-Host "✓ Canvas app processing completed" -ForegroundColor Green
    exit 0
}
catch {
    Write-Error "Canvas app processing failed: $($_.Exception.Message)"
    exit 1
}
```

## Hook Development Best Practices

### 1. Error Handling
- Always use try/catch blocks
- Return exit code 0 for success, non-zero for failure
- Use `Write-Warning` for non-critical issues
- Use `Write-Error` for critical failures

### 2. Parameter Validation
- Use `[Parameter(Mandatory=$true)]` for required parameters
- Provide default values for optional parameters
- Validate parameter values before processing

### 3. Logging
- Use descriptive messages with `Write-Host`
- Use color coding: Green for success, Yellow for warnings, Red for errors
- Include context information (solution name, environment, etc.)

### 4. Performance
- Keep hooks fast and efficient
- Avoid long-running operations that block the pipeline
- Consider async operations for notifications

### 5. Idempotency
- Hooks should be safe to run multiple times
- Check current state before making changes
- Clean up resources properly

### 6. Testing
- Test hooks locally before committing
- Test both success and failure scenarios
- Verify hook behavior with different parameter combinations

## Debugging Hooks

To debug hooks, you can:

1. **Run hooks manually:**
```powershell
.\hooks\pre-build-update-version.ps1 `
    -solutionName "MySolution" `
    -solutionPath ".\src\solutions\MySolution" `
    -configuration "Debug"
```

2. **Add verbose logging:**
```powershell
$VerbosePreference = "Continue"
Write-Verbose "Detailed debugging information here"
```

3. **Check hook execution in pipeline logs:**
Look for sections like:
```
Executing pre-build hooks for solution: MySolution
Executing hook: pre-build-update-version.ps1
✓ Hook 'pre-build-update-version.ps1' completed successfully
```

## Disabling Hooks

To temporarily disable a hook without deleting it:

1. Rename the file (remove `.ps1` extension):
   ```
   pre-build-update-version.ps1 → pre-build-update-version.ps1.disabled
   ```

2. Or add a `.disabled` suffix:
   ```
   pre-build-update-version.ps1 → pre-build-update-version.disabled.ps1
   ```

The hook manager only executes files ending in `.ps1`, so renamed hooks will be skipped.
