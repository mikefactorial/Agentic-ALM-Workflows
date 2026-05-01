<#
.SYNOPSIS
    Post-deployment hook to enable all Flows and Processes in deployed solutions
    
.DESCRIPTION
    After solution deployment, this script:
    - Queries all Classic Workflows (Processes) and Cloud Flows from deployed solution
    - Checks their activation status
    - Enables/activates flows and processes that are currently off
    - Uses multi-pass activation to handle parent/child flow dependencies
      (child flows activate first, enabling parent flows on subsequent passes)
    - Generates a detailed report showing status before and after
    
.PARAMETER targetEnvironmentUrl
    Dataverse environment URL for the target environment
    
.PARAMETER environmentName
    Name of the target environment
    
.PARAMETER solutionName
    Name of the solution that was deployed
    
.PARAMETER artifactsPath
    Path to artifacts directory
    
.PARAMETER deploymentStatus
    Status of the deployment (success, failure, etc.)
    
.PARAMETER tenantId
    Azure AD tenant ID (passed via context for authentication)
    
.PARAMETER clientId
    Service principal client ID (passed via context for authentication)
    
.NOTES
    This script uses the DataverseApiClient to interact with the Dataverse Web API
    Classic Workflows (statecode: 0=Draft, 1=Activated) 
    Cloud Flows (statecode: 0=Off, 1=On)
    
    This hook is automatically discovered and executed by Invoke-PipelineHooks
    when a post-deploy stage is triggered in Deploy-Solutions.ps1
#>

[CmdletBinding()]
param(
    [Parameter()] [String]$targetEnvironmentUrl = "",
    [Parameter()] [String]$targetEnvironment = "",
    [Parameter()] [String]$solutionName = "",
    [Parameter()] [String]$solutionPath = "",
    [Parameter()] [String]$artifactsPath = "",
    [Parameter()] [Boolean]$useSingleStageUpgrade = $true,
    [Parameter()] [String]$deploymentStatus = "success",
    [Parameter()] [String]$stage = "post-deploy",
    [Parameter()] [String]$tenantId = "",
    [Parameter()] [String]$clientId = ""
)

Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Post-Deploy Hook: Enable Flows and Processes" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# Only run if deployment was successful
if ($deploymentStatus -ne "success") {
    Write-Host "⚠ Deployment status is '$deploymentStatus', skipping Flows/Processes activation" -ForegroundColor Yellow
    exit 0
}

# Determine which environment URL to use (targetEnvironmentUrl takes precedence)
$envUrl = if (![string]::IsNullOrEmpty($targetEnvironmentUrl)) { 
    $targetEnvironmentUrl 
} elseif (![string]::IsNullOrEmpty($environmentUrl)) { 
    $environmentUrl 
} else { 
    "" 
}

# Validate required parameters
if ([string]::IsNullOrEmpty($envUrl)) {
    Write-Host "⚠ Environment URL not provided, skipping" -ForegroundColor Yellow
    exit 0
}

if ([string]::IsNullOrEmpty($solutionName)) {
    Write-Host "⚠ Solution name not provided, skipping" -ForegroundColor Yellow
    exit 0
}

$ErrorActionPreference = "Stop"

# Import DataverseApiClient
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptPath\..\DataverseApiClient.ps1"

try {
    # Initialize Dataverse API Client
    Write-Host "Connecting to Dataverse..." -ForegroundColor Yellow
    Write-Host "  Environment: $environmentName" -ForegroundColor Cyan
    Write-Host "  Solution: $solutionName" -ForegroundColor Cyan
    
    if ($tenantId -and $clientId) {
        Write-Host "  Using federated authentication (GitHub OIDC)" -ForegroundColor Cyan
        $apiClient = [DataverseApiClient]::new($tenantId, $clientId, $envUrl)
    }
    else {
        Write-Host "  Using interactive authentication" -ForegroundColor Cyan
        $apiClient = [DataverseApiClient]::new($envUrl)
    }
    
    Write-Host "✓ Connected to Dataverse" -ForegroundColor Green
    Write-Host ""
    
    # Remove version suffix if present (e.g., LeeIntegratedRelease_2026.02.15.2 -> LeeIntegratedRelease)
    $baseSolutionName = $solutionName -replace '_\d{4}\.\d{2}\.\d{2}\.\d+$', ''
    
    # Verify solution exists
    if (-not $apiClient.SolutionExists($baseSolutionName)) {
        Write-Host "⚠ Solution '$baseSolutionName' not found in environment. Skipping." -ForegroundColor Yellow
        Write-Host ""
        exit 0
    }
    
    $solutionId = $apiClient.GetSolutionId($baseSolutionName)
    Write-Host "Solution ID: $solutionId" -ForegroundColor Cyan
    Write-Host ""
    
    # Track results
    $allWorkflows = @()
    $allCloudFlows = @()
    $activatedCount = 0
    $alreadyActiveCount = 0
    $errorCount = 0
    $activationResults = @{}  # Track per-flow activation results for reporting
    $maxActivationPasses = 3  # Max passes for parent/child dependency resolution
    
    # Query Classic Workflows (Processes) in solution via solutioncomponent
    Write-Host "Querying classic workflows (processes)..." -ForegroundColor Cyan
    
    # Use FetchXML to join solutioncomponent to workflow
    # componenttype 29 = Workflow/Process
    $classicWorkflowFetch = @"
<fetch>
  <entity name='workflow'>
    <attribute name='workflowid' />
    <attribute name='name' />
    <attribute name='statecode' />
    <attribute name='statuscode' />
    <attribute name='type' />
    <attribute name='category' />
    <attribute name='primaryentity' />
    <link-entity name='solutioncomponent' from='objectid' to='workflowid' link-type='inner'>
      <filter>
        <condition attribute='solutionid' operator='eq' value='$solutionId' />
        <condition attribute='componenttype' operator='eq' value='29' />
      </filter>
    </link-entity>
    <filter>
      <condition attribute='category' operator='eq' value='0' />
    </filter>
  </entity>
</fetch>
"@
    
    $workflows = $apiClient.RetrieveMultipleByFetchXml("workflows", $classicWorkflowFetch)
    Write-Host "  Found $($workflows.Count) classic workflow(s)" -ForegroundColor White
    
    # Query Cloud Flows in solution via solutioncomponent
    Write-Host "Querying cloud flows..." -ForegroundColor Cyan
    
    $cloudFlowFetch = @"
<fetch>
  <entity name='workflow'>
    <attribute name='workflowid' />
    <attribute name='name' />
    <attribute name='statecode' />
    <attribute name='statuscode' />
    <attribute name='type' />
    <attribute name='category' />
    <attribute name='primaryentity' />
    <link-entity name='solutioncomponent' from='objectid' to='workflowid' link-type='inner'>
      <filter>
        <condition attribute='solutionid' operator='eq' value='$solutionId' />
        <condition attribute='componenttype' operator='eq' value='29' />
      </filter>
    </link-entity>
    <filter>
      <condition attribute='category' operator='eq' value='5' />
    </filter>
  </entity>
</fetch>
"@
    
    $cloudFlows = $apiClient.RetrieveMultipleByFetchXml("workflows", $cloudFlowFetch)
    Write-Host "  Found $($cloudFlows.Count) cloud flow(s)" -ForegroundColor White
    Write-Host ""
    
    $allWorkflows = $workflows
    $allCloudFlows = $cloudFlows
    
    # Process Classic Workflows (multi-pass for parent/child dependencies)
    if ($allWorkflows.Count -gt 0) {
        Write-Host "───────────────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "Processing Classic Workflows ($($allWorkflows.Count) total)" -ForegroundColor Yellow
        Write-Host ""
        
        # Separate already-active from those needing activation
        $workflowsToActivate = @()
        foreach ($workflow in $allWorkflows) {
            Write-Host "  Workflow: $($workflow.name)" -ForegroundColor White
            Write-Host "    Entity: $($workflow.primaryentity)" -ForegroundColor DarkGray
            
            if ($workflow.statecode -eq 1) {
                Write-Host "    Already activated" -ForegroundColor DarkGray
                $alreadyActiveCount++
                $activationResults[$workflow.workflowid] = "Already Active"
            }
            else {
                $statusText = switch ($workflow.statecode) {
                    0 { "Draft" }
                    2 { "Suspended" }
                    default { "Unknown ($($workflow.statecode))" }
                }
                Write-Host "    Status: $statusText - queued for activation" -ForegroundColor Yellow
                $workflowsToActivate += $workflow
            }
            Write-Host ""
        }
        
        # Multi-pass activation to handle parent/child dependencies
        for ($pass = 1; $pass -le $maxActivationPasses -and $workflowsToActivate.Count -gt 0; $pass++) {
            Write-Host "  ── Activation Pass $pass of $maxActivationPasses ($($workflowsToActivate.Count) workflow(s) remaining) ──" -ForegroundColor Magenta
            Write-Host ""
            
            $failedThisPass = @()
            foreach ($workflow in $workflowsToActivate) {
                try {
                    Write-Host "    Activating: $($workflow.name)..." -ForegroundColor Cyan
                    
                    $setStateBody = @{
                        statecode = 1  # Activated
                        statuscode = 2 # Activated
                    }
                    $apiClient.Update("workflows", $workflow.workflowid, $setStateBody)
                    
                    Write-Host "    ✓ Activated successfully (pass $pass)" -ForegroundColor Green
                    $activatedCount++
                    $activationResults[$workflow.workflowid] = "Activated (pass $pass)"
                }
                catch {
                    Write-Host "    ✗ Failed on pass ${pass}: $($_.Exception.Message)" -ForegroundColor $(if ($pass -lt $maxActivationPasses) { "Yellow" } else { "Red" })
                    $failedThisPass += $workflow
                    $activationResults[$workflow.workflowid] = "Failed: $($_.Exception.Message)"
                }
            }
            
            $workflowsToActivate = $failedThisPass
            
            if ($workflowsToActivate.Count -gt 0 -and $pass -lt $maxActivationPasses) {
                Write-Host ""
                Write-Host "    ⟳ $($workflowsToActivate.Count) workflow(s) failed, will retry on next pass..." -ForegroundColor Yellow
                Write-Host ""
            }
        }
        
        # Count remaining failures as errors
        $errorCount += $workflowsToActivate.Count
        Write-Host ""
    }
    
    # Process Cloud Flows (multi-pass for parent/child dependencies)
    if ($allCloudFlows.Count -gt 0) {
        Write-Host "───────────────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "Processing Cloud Flows ($($allCloudFlows.Count) total)" -ForegroundColor Yellow
        Write-Host ""
        
        # Separate already-on from those needing activation
        $flowsToActivate = @()
        foreach ($flow in $allCloudFlows) {
            Write-Host "  Cloud Flow: $($flow.name)" -ForegroundColor White
            
            if ($flow.statecode -eq 1) {
                Write-Host "    Already on" -ForegroundColor DarkGray
                $alreadyActiveCount++
                $activationResults[$flow.workflowid] = "Already On"
            }
            else {
                $statusText = switch ($flow.statecode) {
                    0 { "Off" }
                    2 { "Suspended" }
                    default { "Unknown ($($flow.statecode))" }
                }
                Write-Host "    Status: $statusText - queued for activation" -ForegroundColor Yellow
                $flowsToActivate += $flow
            }
            Write-Host ""
        }
        
        # Multi-pass activation to handle parent/child flow dependencies
        # Child flows need to be activated before parent flows that reference them
        for ($pass = 1; $pass -le $maxActivationPasses -and $flowsToActivate.Count -gt 0; $pass++) {
            Write-Host "  ── Activation Pass $pass of $maxActivationPasses ($($flowsToActivate.Count) flow(s) remaining) ──" -ForegroundColor Magenta
            Write-Host ""
            
            $failedThisPass = @()
            foreach ($flow in $flowsToActivate) {
                try {
                    Write-Host "    Turning on: $($flow.name)..." -ForegroundColor Cyan
                    
                    $setStateBody = @{
                        statecode = 1  # On
                        statuscode = 2 # On
                    }
                    $apiClient.Update("workflows", $flow.workflowid, $setStateBody)
                    
                    Write-Host "    ✓ Turned on successfully (pass $pass)" -ForegroundColor Green
                    $activatedCount++
                    $activationResults[$flow.workflowid] = "Activated (pass $pass)"
                }
                catch {
                    Write-Host "    ✗ Failed on pass ${pass}: $($_.Exception.Message)" -ForegroundColor $(if ($pass -lt $maxActivationPasses) { "Yellow" } else { "Red" })
                    $failedThisPass += $flow
                    $activationResults[$flow.workflowid] = "Failed: $($_.Exception.Message)"
                }
            }
            
            $flowsToActivate = $failedThisPass
            
            if ($flowsToActivate.Count -gt 0 -and $pass -lt $maxActivationPasses) {
                Write-Host ""
                Write-Host "    ⟳ $($flowsToActivate.Count) flow(s) failed, will retry on next pass..." -ForegroundColor Yellow
                Write-Host ""
            }
        }
        
        # Count remaining failures as errors
        $errorCount += $flowsToActivate.Count
        Write-Host ""
    }
    
    # Summary Report
    Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Summary Report" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    
    $totalItems = $allWorkflows.Count + $allCloudFlows.Count
    
    Write-Host "Total Classic Workflows: $($allWorkflows.Count)" -ForegroundColor White
    Write-Host "Total Cloud Flows: $($allCloudFlows.Count)" -ForegroundColor White
    Write-Host "Total Items: $totalItems" -ForegroundColor White
    Write-Host ""
    Write-Host "Successfully Activated/Turned On: $activatedCount" -ForegroundColor Green
    Write-Host "Already Active/On: $alreadyActiveCount" -ForegroundColor White
    
    if ($errorCount -gt 0) {
        Write-Host "Errors: $errorCount" -ForegroundColor Red
    }
    Write-Host ""
    
    # Generate detailed table report
    if ($totalItems -gt 0) {
        Write-Host "Detailed Status Report:" -ForegroundColor Yellow
        Write-Host ""
        
        $report = @()
        
        # Add workflows to report
        foreach ($workflow in $allWorkflows) {
            $result = $activationResults[$workflow.workflowid]
            $report += [PSCustomObject]@{
                Name   = $workflow.name
                Type   = "Classic Workflow"
                Entity = $workflow.primaryentity
                Result = if ($result) { $result } else { "Unknown" }
            }
        }
        
        # Add cloud flows to report
        foreach ($flow in $allCloudFlows) {
            $result = $activationResults[$flow.workflowid]
            $report += [PSCustomObject]@{
                Name   = $flow.name
                Type   = "Cloud Flow"
                Entity = $flow.primaryentity ?? "N/A"
                Result = if ($result) { $result } else { "Unknown" }
            }
        }
        
        # Display report table
        $report | Format-Table -Property Name, Type, Entity, Result -AutoSize
    }
    
    if ($errorCount -gt 0) {
        Write-Host "⚠ Hook completed with errors" -ForegroundColor Yellow
        exit 1
    }
    else {
        Write-Host "✓ Hook completed successfully" -ForegroundColor Green
        exit 0
    }
}
catch {
    Write-Host ""
    Write-Host "✗ Hook failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    exit 1
}
