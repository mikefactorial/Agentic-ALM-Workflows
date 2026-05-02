<#
.SYNOPSIS
    Transport a solution from a source environment to a target environment
    
.DESCRIPTION
    Exports a solution as unmanaged from a source environment, imports it into a target environment,
    and copies its components to a specified target solution in the target environment.
    
    Supports both local execution (with client secret) and GitHub Actions (with OIDC).
    Can run in phases for GitHub Actions two-job workflows or all at once for local testing.
    
.PARAMETER sourceSolutionName
    The unique name of the solution to export from the source environment
    
.PARAMETER targetSolutionName
    The unique name of the solution to copy components into in the target environment
    
.PARAMETER Phase
    The phase to execute: Export, Import, or All (default: All)
    - Export: Only export the solution from source environment
    - Import: Only import the solution and copy components to target environment
    - All: Execute all phases (for local testing)
    
.PARAMETER sourceEnvironmentUrl
    The URL of the source Power Platform environment (required for Export and All phases)
    
.PARAMETER targetEnvironmentUrl
    The URL of the target Power Platform environment (required for Import and All phases)
    
.PARAMETER solutionZipPath
    The path to the solution zip file (default: ./src/solution-export/{sourceSolutionName}.zip)
    
.PARAMETER tenantId
    The Azure AD tenant ID (for federated auth). Leave blank for interactive authentication.
    
.PARAMETER clientId
    The Azure AD application (client) ID (for federated auth). Leave blank for interactive authentication.
    
.EXAMPLE
    # Local testing - Full transport with interactive auth
    .\Transport-Solution.ps1 `
        -Phase All `
        -sourceSolutionName "MyFeatureSolution" `
        -targetSolutionName "DevelopmentIntegrationSolution" `
        -sourceEnvironmentUrl "https://source.crm.dynamics.com" `
        -targetEnvironmentUrl "https://target.crm.dynamics.com"

.EXAMPLE
    # GitHub Actions Job 1 - Export only (federated auth)
    .\Transport-Solution.ps1 `
        -Phase Export `
        -sourceSolutionName "MyFeatureSolution" `
        -sourceEnvironmentUrl ${{ vars.DATAVERSE_URL }} `
        -tenantId ${{ vars.AZURE_TENANT_ID }} `
        -clientId ${{ vars.DATAVERSE_CLIENT_ID }}
        
.EXAMPLE
    # GitHub Actions Job 2 - Import and copy (federated auth)
    .\Transport-Solution.ps1 `
        -Phase Import `
        -sourceSolutionName "MySourceSolution" `
        -targetSolutionName "MyTargetSolution" `
        -targetEnvironmentUrl ${{ vars.DATAVERSE_URL }} `
        -solutionZipPath "./src/solution-export/MySourceSolution.zip" `
        -tenantId ${{ vars.AZURE_TENANT_ID }} `
        -clientId ${{ vars.DATAVERSE_CLIENT_ID }}

.NOTES
    Authentication modes:
    - Federated: When both tenantId and clientId are provided (GitHub Actions OIDC)
    - Interactive: When both tenantId and clientId are blank (local development)
    Requires: Power Platform CLI (pac) to be installed
#>

param (
    [Parameter(Mandatory = $true)]
    [String]$sourceSolutionName,
    
    [Parameter(Mandatory = $false)]
    [String]$targetSolutionName,
    
    [Parameter(Mandatory = $false)]
    [ValidateSet("Export", "Import", "All")]
    [String]$Phase = "All",
    
    [Parameter(Mandatory = $false)]
    [String]$sourceEnvironmentUrl,
    
    [Parameter(Mandatory = $false)]
    [String]$targetEnvironmentUrl,
    
    [Parameter(Mandatory = $false)]
    [String]$solutionZipPath,
    
    [Parameter(Mandatory = $false)]
    [String]$tenantId = "",
    
    [Parameter(Mandatory = $false)]
    [String]$clientId = "",
    
    [Parameter(Mandatory = $false)]
    [Switch]$publishCustomizations = $true
)

# Set error action preference
$ErrorActionPreference = "Stop"

# Import required modules
. "$PSScriptRoot\PowerPlatformClient.ps1"
. "$PSScriptRoot\DataverseApiClient.ps1"

# Import hook manager
. "$PSScriptRoot\Invoke-PipelineHooks.ps1"

# Validate parameters based on phase
if ($Phase -eq "Export" -or $Phase -eq "All") {
    if ([string]::IsNullOrWhiteSpace($sourceEnvironmentUrl)) {
        throw "sourceEnvironmentUrl is required for $Phase phase"
    }
}

if ($Phase -eq "Import" -or $Phase -eq "All") {
    if ([string]::IsNullOrWhiteSpace($targetEnvironmentUrl)) {
        throw "targetEnvironmentUrl is required for $Phase phase"
    }
    if ([string]::IsNullOrWhiteSpace($targetSolutionName)) {
        throw "targetSolutionName is required for $Phase phase"
    }
}

# Determine authentication mode
$useFederated = -not [string]::IsNullOrWhiteSpace($tenantId) -and -not [string]::IsNullOrWhiteSpace($clientId)
$useInteractive = [string]::IsNullOrWhiteSpace($tenantId) -and [string]::IsNullOrWhiteSpace($clientId)

if (-not $useFederated -and -not $useInteractive) {
    throw "Invalid authentication configuration. Either provide both tenantId and clientId (federated), or provide neither (interactive)."
}

# Set default solution zip path if not provided
if ([string]::IsNullOrWhiteSpace($solutionZipPath)) {
    $solutionZipPath = Join-Path $PSScriptRoot "solution-export\$sourceSolutionName.zip"
}

# Ensure export directory exists for Export phase
if ($Phase -eq "Export" -or $Phase -eq "All") {
    $exportDir = Split-Path $solutionZipPath -Parent
    if (-not (Test-Path $exportDir)) {
        New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
    }
}

Write-Host "=========================================="
Write-Host "Power Platform Solution Transport - $Phase Phase"
Write-Host "=========================================="
Write-Host "Source Solution: $sourceSolutionName"
if ($Phase -ne "Export") {
    Write-Host "Target Solution: $targetSolutionName"
}
if ($Phase -eq "Export" -or $Phase -eq "All") {
    Write-Host "Source Environment: $sourceEnvironmentUrl"
}
if ($Phase -eq "Import" -or $Phase -eq "All") {
    Write-Host "Target Environment: $targetEnvironmentUrl"
}
Write-Host "Solution Zip Path: $solutionZipPath"
Write-Host "Authentication: $(if ($useFederated) { 'Federated (OIDC)' } else { 'Interactive' })"
Write-Host "=========================================="
Write-Host ""

try {
    # ====== EXPORT PHASE ======
    if ($Phase -eq "Export" -or $Phase -eq "All") {
        Write-Host "[EXPORT] Exporting solution from source environment..."
        Write-Host "-----------------------------------------------"
        
        # Execute pre-export hooks
        Write-Host "Executing pre-export hooks..." -ForegroundColor Cyan
        $exportContext = @{
            sourceSolutionName = $sourceSolutionName
            sourceEnvironmentUrl = $sourceEnvironmentUrl
            solutionZipPath = $solutionZipPath
            phase = $Phase
        }
        Invoke-PipelineHooks -Stage "pre-export" -Context $exportContext -ContinueOnError $true
        Write-Host ""
        
        if ($useFederated) {
            $sourceClient = [PowerPlatformClient]::new($tenantId, $clientId, $sourceEnvironmentUrl)
        }
        else {
            $sourceClient = [PowerPlatformClient]::new($sourceEnvironmentUrl)
        }
        
        # Publish customizations before export (if enabled)
        if ($publishCustomizations) {
            Write-Host "Publishing customizations in source environment..." -ForegroundColor Cyan
            try {
                $publishOutput = pac solution publish --environment $sourceEnvironmentUrl 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "✓ Customizations published successfully" -ForegroundColor Green
                } else {
                    Write-Warning "Failed to publish customizations, but continuing with export..."
                    Write-Warning "Output: $publishOutput"
                }
            }
            catch {
                Write-Warning "Failed to publish customizations: $_"
                Write-Warning "Continuing with export anyway..."
            }
            Write-Host ""
        } else {
            Write-Host "Skipping customizations publish (disabled by parameter)" -ForegroundColor Yellow
            Write-Host ""
        }
        
        Write-Host "Exporting solution '$sourceSolutionName' to '$solutionZipPath'..."
        $sourceClient.ExportSolution($sourceSolutionName, $solutionZipPath)
        Write-Host "✓ Solution exported successfully" -ForegroundColor Green
        Write-Host ""
        
        # Verify export file exists
        if (-not (Test-Path $solutionZipPath)) {
            throw "Solution export file not found: $solutionZipPath"
        }
        
        $fileSize = (Get-Item $solutionZipPath).Length / 1MB
        Write-Host "Solution file size: $([Math]::Round($fileSize, 2)) MB" -ForegroundColor Cyan
        Write-Host ""
        
        # Execute post-export hooks
        Write-Host "Executing post-export hooks..." -ForegroundColor Cyan
        Invoke-PipelineHooks -Stage "post-export" -Context $exportContext -ContinueOnError $true
        Write-Host ""
        
        # Cleanup auth for export client
        $sourceClient.ClearAuth()
    }
    
    # ====== IMPORT PHASE ======
    if ($Phase -eq "Import" -or $Phase -eq "All") {
        # Verify solution zip exists for import
        if (-not (Test-Path $solutionZipPath)) {
            throw "Solution zip file not found at: $solutionZipPath. Run Export phase first or provide correct path."
        }
        
        Write-Host "[IMPORT] Importing solution to target environment..."
        Write-Host "-----------------------------------------------"
        
        # Execute pre-import hooks
        Write-Host "Executing pre-import hooks..." -ForegroundColor Cyan
        $importContext = @{
            sourceSolutionName = $sourceSolutionName
            targetSolutionName = $targetSolutionName
            targetEnvironmentUrl = $targetEnvironmentUrl
            solutionZipPath = $solutionZipPath
            phase = $Phase
        }
        Invoke-PipelineHooks -Stage "pre-import" -Context $importContext -ContinueOnError $true
        Write-Host ""
        
        if ($useFederated) {
            $targetClient = [PowerPlatformClient]::new($tenantId, $clientId, $targetEnvironmentUrl)
        }
        else {
            $targetClient = [PowerPlatformClient]::new($targetEnvironmentUrl)
        }
        
        Write-Host "Importing solution from '$solutionZipPath'..."
        $targetClient.ImportSolution($solutionZipPath, "", $false)
        Write-Host "✓ Solution imported successfully" -ForegroundColor Green
        Write-Host ""
        
        # Execute post-import hooks
        Write-Host "Executing post-import hooks..." -ForegroundColor Cyan
        Invoke-PipelineHooks -Stage "post-import" -Context $importContext -ContinueOnError $true
        Write-Host ""
        
        # Step 3: Copy components to target solution
        Write-Host "[COPY] Copying components to target solution..."
        Write-Host "-----------------------------------------------"
        
        # Use the Copy-Components.ps1 script
        $copyComponentsScript = Join-Path $PSScriptRoot "Copy-Components.ps1"
        
        if (-not (Test-Path $copyComponentsScript)) {
            throw "Copy-Components.ps1 script not found at: $copyComponentsScript"
        }
        
        $copyParams = @{
            environmentUrl = $targetEnvironmentUrl
            sourceSolutionName = $sourceSolutionName
            targetSolutionName = $targetSolutionName
            tenantId = $tenantId
            clientId = $clientId
        }
        
        Write-Host "Executing Copy-Components.ps1..."
        & $copyComponentsScript @copyParams
        
        if ($LASTEXITCODE -ne 0) {
            throw "Component copy operation failed with exit code: $LASTEXITCODE"
        }
        
        Write-Host "✓ Components copied successfully" -ForegroundColor Green
        Write-Host ""
        
        # Cleanup auth for target client
        $targetClient.ClearAuth()
    }
    
    # ====== SUCCESS SUMMARY ======
    Write-Host "=========================================="
    Write-Host "✓ $Phase Phase Completed Successfully" -ForegroundColor Green
    Write-Host "=========================================="
    Write-Host ""
    Write-Host "Summary:"
    if ($Phase -eq "Export" -or $Phase -eq "All") {
        Write-Host "  • Exported: $sourceSolutionName from source environment" -ForegroundColor Green
        Write-Host "    Location: $solutionZipPath"
    }
    if ($Phase -eq "Import" -or $Phase -eq "All") {
        Write-Host "  • Imported: $sourceSolutionName to target environment" -ForegroundColor Green
        Write-Host "  • Copied components to: $targetSolutionName" -ForegroundColor Green
    }
    Write-Host ""
    
    exit 0
}
catch {
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Red
    Write-Host "✗ Solution Transport Failed" -ForegroundColor Red
    Write-Host "==========================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "Stack Trace:" -ForegroundColor Yellow
    Write-Host "$($_.ScriptStackTrace)" -ForegroundColor Yellow
    
    # Cleanup auth profiles on error
    if ($null -ne $sourceClient) {
        try { $sourceClient.ClearAuth() } catch { }
    }
    if ($null -ne $targetClient) {
        try { $targetClient.ClearAuth() } catch { }
    }
    
    exit 1
}
