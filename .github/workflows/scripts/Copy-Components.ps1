param (
    [Parameter(Mandatory)] [String]$environmentUrl,
    [Parameter(Mandatory)] [String]$sourceSolutionName,
    [Parameter(Mandatory)] [String]$targetSolutionName,
    [Parameter(Mandatory = $false)] [String]$tenantId = "",
    [Parameter(Mandatory = $false)] [String]$clientId = ""
)

# Import the Dataverse API Client
. "$PSScriptRoot\DataverseApiClient.ps1"

# Determine authentication mode
$useFederated   = -not [string]::IsNullOrWhiteSpace($tenantId) -and -not [string]::IsNullOrWhiteSpace($clientId)
$useTenantScoped = -not [string]::IsNullOrWhiteSpace($tenantId) -and [string]::IsNullOrWhiteSpace($clientId)
$useInteractive = [string]::IsNullOrWhiteSpace($tenantId) -and [string]::IsNullOrWhiteSpace($clientId)

if (-not $useFederated -and -not $useTenantScoped -and -not $useInteractive) {
    Write-Host "Error: Invalid authentication configuration." -ForegroundColor Red
    Write-Host "Either provide both tenantId and clientId (federated), tenantId only (interactive guest-safe), or neither (interactive)." -ForegroundColor Yellow
    exit 1
}

# Check if target solution name is empty or same as source
if ([string]::IsNullOrWhiteSpace($targetSolutionName) -or $targetSolutionName -eq $sourceSolutionName) {
    Write-Host "Target solution is empty or same as source solution. Skipping component copy."
    exit 0
}

# Check if manual component copy is required
if ($targetSolutionName -eq "None (Pause Commit for Manual Component Copy)") {
    Write-Host "Manual component copy required. Skipping automated component copy."
    Write-Host "Please manually copy components as needed before proceeding with the next pipeline step."
    exit 0
}

Write-Host "Copying components from solution '$sourceSolutionName' to '$targetSolutionName'..."
Write-Host "Environment Url: $environmentUrl"
Write-Host "Authentication: $(if ($useFederated) { 'Federated (OIDC)' } elseif ($useTenantScoped) { "Interactive (tenant-scoped: $tenantId)" } else { 'Interactive' })"

# Initialize Dataverse API Client with service principal authentication
try {
    Write-Host "Initializing Dataverse API client..."
    
    if ($useFederated) {
        $apiClient = [DataverseApiClient]::new($tenantId, $clientId, $environmentUrl)
    }
    elseif ($useTenantScoped) {
        Write-Host "Tip: ensure you ran 'Connect-AzAccount -TenantId $tenantId' first." -ForegroundColor Yellow
        $apiClient = [DataverseApiClient]::new($environmentUrl, $tenantId)
    }
    else {
        $apiClient = [DataverseApiClient]::new($environmentUrl)
    }
    
    Write-Host "Dataverse API client initialized successfully"
}
catch {
    Write-Host "Failed to initialize Dataverse API client: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

try {
    # Verify source solution exists
    Write-Host "Verifying source solution '$sourceSolutionName' exists..."
    if (-not $apiClient.SolutionExists($sourceSolutionName)) {
        Write-Host "Source solution '$sourceSolutionName' not found in environment" -ForegroundColor Red
        exit 1
    }
    
    # Check if target solution exists, create if it doesn't
    Write-Host "Checking target solution '$targetSolutionName'..."
    if (-not $apiClient.SolutionExists($targetSolutionName)) {
        Write-Host "Target solution '$targetSolutionName' does not exist. Creating it..."
        $success = $apiClient.CreateSolution($targetSolutionName, $targetSolutionName, "new")
        if ($success) {
            Write-Host "Target solution '$targetSolutionName' created successfully"
            } else {
                Write-Host "Failed to create target solution" -ForegroundColor Red
                exit 1
            }
        } else {
            Write-Host "Target solution '$targetSolutionName' already exists"
        }

        # Get solution IDs
        Write-Host "Getting source solution ID..."
        $sourceSolutionId = $apiClient.GetSolutionId($sourceSolutionName)
        Write-Host "Source solution ID: $sourceSolutionId"
        
        Write-Host "Getting target solution ID..."
        $targetSolutionId = $apiClient.GetSolutionId($targetSolutionName)
        Write-Host "Target solution ID: $targetSolutionId"
        
        # Get components from source solution
        Write-Host "Getting components from source solution..."
        $sourceComponents = $apiClient.GetSolutionComponents($sourceSolutionId)
        Write-Host "Found $($sourceComponents.Count) components in source solution"
        
        # Get components from target solution to avoid duplicates
        Write-Host "Getting existing components from target solution..."
        $targetComponents = $apiClient.GetSolutionComponents($targetSolutionId)
        Write-Host "Found $($targetComponents.Count) existing components in target solution"
        
        # Create a hashtable for quick lookup of existing components
        $existingComponents = @{}
        foreach ($component in $targetComponents) {
            $key = "$($component.objectid)-$($component.componenttype)"
            $existingComponents[$key] = $true
        }
        
        $copiedCount = 0
        $skippedCount = 0
        
        # Copy components from source to target
        foreach ($component in $sourceComponents) {
            $key = "$($component.objectid)-$($component.componenttype)"
            
            # Skip if component already exists in target solution
            if ($existingComponents.ContainsKey($key)) {
                $skippedCount++
                Write-Verbose "Skipping component $($component.objectid) (type: $($component.componenttype)) - already exists in target"
                continue
            }
            
            # Determine if we should not include subcomponents
            $doNotIncludeSubcomponents = $false
            if ($component.ismetadata -and ($sourceComponents | Where-Object { $_.rootsolutioncomponentid -eq $component.solutioncomponentid })) {
                $doNotIncludeSubcomponents = $true
                Write-Verbose "Setting DoNotIncludeSubcomponents to true for metadata component"
            }
            
            # Add component to target solution
            Write-Host "Copying component $($component.objectid) (type: $($component.componenttype))..."
            $success = $apiClient.AddComponentToSolution($component.objectid, $component.componenttype, $targetSolutionName, $doNotIncludeSubcomponents)
            
            if ($success) {
                $copiedCount++
                Write-Verbose "Successfully copied component $($component.objectid)"
            }
        }
        
        Write-Host "Component copy operation completed!"
        Write-Host "Components copied: $copiedCount"
        Write-Host "Components skipped (already exist): $skippedCount"
    }
    catch {
        Write-Host "Error during component copy operation: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Stack trace: $($_.ScriptStackTrace)" -ForegroundColor Yellow
        exit 1
    }