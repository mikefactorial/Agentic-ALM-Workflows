<#
.SYNOPSIS
    Sync or clone a solution from a Dataverse environment to the local repository
    
.DESCRIPTION
    This script exports a solution from Dataverse in unpacked (source control) format.
    It uses 'pac solution sync' for existing solutions or 'pac solution clone' for new ones.
    Also handles unpacking Canvas apps (.msapp files) for version control.
    Optionally commits changes to a Git branch.
    
.PARAMETER solutionName
    The unique name of the solution to sync/clone
    
.PARAMETER environmentUrl
    The URL of the Dataverse environment
    
.PARAMETER solutionFolder
    The folder where solutions are stored (default: ./src/solutions)
    
.PARAMETER commitMessage
    The Git commit message (required if not using -skipGitCommit)
    
.PARAMETER branchName
    The Git branch name to commit to (default: current branch)
    
.PARAMETER skipGitCommit
    Skip Git operations - only sync/clone the solution without committing
    
.PARAMETER tenantId
    Azure AD tenant ID (required if not using OIDC)
    
.PARAMETER clientId
    Azure AD application (client) ID (for federated auth in GitHub Actions)
    
.PARAMETER tenantId
    Azure AD tenant ID (for federated auth in GitHub Actions)
    
.NOTE
    Authentication modes:
    - If tenantId and clientId are provided: Uses federated authentication (OIDC)
    - If both are blank: Uses interactive authentication
    
.EXAMPLE
    # Sync solution with interactive authentication
    .\Sync-Solution.ps1 `
        -solutionName "MySolution" `
        -environmentUrl "https://org.crm.dynamics.com/" `
        -commitMessage "feat: updated solution configuration"
    
.EXAMPLE
    # Clone new solution with federated auth (GitHub Actions)
    .\Sync-Solution.ps1 `
        -solutionName "NewSolution" `
        -environmentUrl ${{ vars.DATAVERSE_URL }} `
        -commitMessage "feat: added new solution" `
        -tenantId ${{ vars.AZURE_TENANT_ID }} `
        -clientId ${{ vars.DATAVERSE_CLIENT_ID }}
    
.EXAMPLE
    # Sync without Git operations (just download)
    .\Sync-Solution.ps1 `
        -solutionName "MySolution" `
        -environmentUrl "https://org.crm.dynamics.com/" `
        -skipGitCommit
        
.NOTES
    Requires: Power Platform CLI (pac)
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$solutionName,
    
    [Parameter(Mandatory=$true)]
    [string]$environmentUrl,
    
    [Parameter(Mandatory=$false)]
    [string]$solutionFolder = "./src/solutions",
    
    [Parameter(Mandatory=$false)]
    [string]$commitMessage,
    
    [Parameter(Mandatory=$false)]
    [string]$branchName,
    
    [Parameter(Mandatory=$false)]
    [switch]$skipGitCommit,
    
    [Parameter(Mandatory=$false)]
    [string]$tenantId,
    
    [Parameter(Mandatory=$false)]
    [string]$clientId,
    
    [Parameter(Mandatory=$false)]
    [bool]$publishCustomizations = $true
)

$ErrorActionPreference = "Stop"

# Get script directory
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Repository root is 4 levels up from this script:
# {repoRoot}/.platform/.github/workflows/scripts/Sync-Solution.ps1
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..\") | Select-Object -ExpandProperty Path
Write-Verbose "Repository root: $repoRoot"

# Resolve solution folder relative to repository root
if (-not [System.IO.Path]::IsPathRooted($solutionFolder)) {
    $solutionFolder = Join-Path $repoRoot $solutionFolder
    $solutionFolder = [System.IO.Path]::GetFullPath($solutionFolder)
}

# Load PowerPlatformClient
. "$scriptDir\PowerPlatformClient.ps1"

# Load pipeline hooks
. "$scriptDir\Invoke-PipelineHooks.ps1"

Write-Host ""
Write-Host "=========================================="
Write-Host "Solution Sync/Clone"
Write-Host "=========================================="
Write-Host "Solution: $solutionName"
Write-Host "Environment: $environmentUrl"
Write-Host "Target Folder: $solutionFolder"
if (-not $skipGitCommit) {
    Write-Host "Git Commit: Enabled"
    if ($branchName) {
        Write-Host "Branch: $branchName"
    }
} else {
    Write-Host "Git Commit: Skipped"
}
Write-Host "=========================================="
Write-Host ""

# Validate parameters
if (-not $skipGitCommit -and [string]::IsNullOrWhiteSpace($commitMessage)) {
    throw "commitMessage is required when not using -skipGitCommit"
}

# Determine authentication mode
$useInteractive = [string]::IsNullOrWhiteSpace($tenantId) -and [string]::IsNullOrWhiteSpace($clientId)
$useFederated = -not [string]::IsNullOrWhiteSpace($tenantId) -and -not [string]::IsNullOrWhiteSpace($clientId)

if (-not $useInteractive -and -not $useFederated) {
    throw "Either provide both tenantId and clientId (for federated auth) or neither (for interactive auth)"
}

# Check Git availability
$gitAvailable = $false
$performGitOperations = $false

if (-not $skipGitCommit) {
    try {
        $null = git --version 2>&1
        if ($LASTEXITCODE -eq 0) {
            $gitAvailable = $true
            $performGitOperations = $true
            Write-Host "✓ Git is available" -ForegroundColor Green
        }
    }
    catch {
        Write-Warning "Git is not available. Solution will be synced but not committed."
        Write-Warning "To enable Git operations, install Git: https://git-scm.com/download"
    }
} else {
    Write-Host "Git operations skipped by user request" -ForegroundColor Cyan
}

# Prepare Git branch BEFORE making any file changes
if ($performGitOperations) {
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "Preparing Git Branch" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    
    # Configure Git user if in CI environment
    if ($env:GITHUB_ACTIONS -eq "true") {
        Write-Host "Configuring Git for GitHub Actions..." -ForegroundColor Gray
        git config --global user.email "github-actions[bot]@users.noreply.github.com"
        git config --global user.name "github-actions[bot]"
    } else {
        # Check if user is configured
        $gitUser = git config user.name 2>$null
        if ([string]::IsNullOrWhiteSpace($gitUser)) {
            Write-Host "Git user not configured. Please configure Git:" -ForegroundColor Yellow
            Write-Host "  git config --global user.email 'you@example.com'"
            Write-Host "  git config --global user.name 'Your Name'"
            throw "Git user not configured"
        }
    }
    
    # Handle branch operations
    if ($branchName) {
        Write-Host "Switching to branch: $branchName" -ForegroundColor Cyan
        
        # Check if remote exists
        $hasRemote = git remote get-url origin 2>$null
        if ($hasRemote -and $LASTEXITCODE -eq 0) {
            Write-Host "Fetching latest from remote..." -ForegroundColor Gray
            git fetch origin 2>&1 | Out-Null
            
            # Check if remote branch exists
            git show-ref --verify --quiet "refs/remotes/origin/$branchName" 2>$null
            $remoteBranchExists = ($LASTEXITCODE -eq 0)
            
            # Check if local branch exists
            git show-ref --verify --quiet "refs/heads/$branchName" 2>$null
            $localBranchExists = ($LASTEXITCODE -eq 0)
            
            if ($localBranchExists) {
                Write-Host "Local branch exists, checking it out..." -ForegroundColor Gray
                git checkout $branchName 2>&1 | Out-Null
                
                if ($remoteBranchExists) {
                    Write-Host "Resetting to match origin/$branchName..." -ForegroundColor Gray
                    git reset --hard "origin/$branchName" 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) {
                        throw "Failed to reset branch to match remote"
                    }
                    Write-Host "✓ Branch synchronized with remote" -ForegroundColor Green
                }
            } elseif ($remoteBranchExists) {
                Write-Host "Remote branch exists, creating local branch from origin/$branchName..." -ForegroundColor Gray
                git checkout -b $branchName --track origin/$branchName 2>&1
            } else {
                Write-Host "Branch doesn't exist locally or remotely, creating new branch..." -ForegroundColor Gray
                git checkout -b $branchName 2>&1
            }
        } else {
            # No remote, just check/create local branch
            git show-ref --verify --quiet "refs/heads/$branchName" 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Branch exists, checking it out..." -ForegroundColor Gray
                git checkout $branchName 2>&1
            } else {
                Write-Host "Branch doesn't exist, creating it..." -ForegroundColor Gray
                git checkout -b $branchName 2>&1
            }
        }
        
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to checkout/create branch '$branchName'"
        }
    } else {
        $currentBranch = git branch --show-current 2>$null
        Write-Host "Using current branch: $currentBranch" -ForegroundColor Cyan
    }
    Write-Host "✓ Git branch ready" -ForegroundColor Green
}

# Authenticate to Power Platform
Write-Host ""
Write-Host "Authenticating to Power Platform..." -ForegroundColor Cyan

try {
    if ($useFederated) {
        Write-Host "Using federated authentication (OIDC)" -ForegroundColor Gray
        $client = [PowerPlatformClient]::new($tenantId, $clientId, $environmentUrl)
    } elseif ($useInteractive) {
        Write-Host "Using interactive authentication" -ForegroundColor Gray
        $client = [PowerPlatformClient]::new($environmentUrl)
    }
    Write-Host "✓ Authentication successful" -ForegroundColor Green
}
catch {
    throw "Failed to authenticate: $_"
}

# Publish customizations before syncing (if enabled)
if ($publishCustomizations) {
    Write-Host ""
    Write-Host "Publishing customizations in environment..." -ForegroundColor Cyan

    try {
        $publishOutput = pac solution publish --environment $environmentUrl 2>&1
        $publishExitCode = $LASTEXITCODE
        
        if ($publishExitCode -eq 0) {
            Write-Host "✓ Customizations published successfully" -ForegroundColor Green
        } else {
            Write-Warning "Failed to publish customizations, but continuing with sync..."
            Write-Warning "Output: $publishOutput"
        }
    }
    catch {
        Write-Warning "Failed to publish customizations: $_"
        Write-Warning "Continuing with sync anyway..."
    }
} else {
    Write-Host ""
    Write-Host "Skipping customizations publish (disabled by parameter)" -ForegroundColor Yellow
}

# Create solution folder if it doesn't exist
if (-not (Test-Path $solutionFolder)) {
    Write-Host ""
    Write-Host "Creating solution folder: $solutionFolder" -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $solutionFolder -Force | Out-Null
}

# Determine solution path
$solutionPath = Join-Path $solutionFolder $solutionName

# Check if solution already exists locally
$solutionExists = Test-Path $solutionPath
$cdsprojFiles = Get-ChildItem -Path $solutionPath -Filter "*.cdsproj" -Recurse -ErrorAction SilentlyContinue
$hasSolutionCdsproj = $cdsprojFiles.Count -gt 0

# Execute pre-sync hooks
$hookContext = @{
    solutionName = $solutionName
    environmentUrl = $environmentUrl
    solutionPath = $solutionPath
    solutionFolder = $solutionFolder
    operation = if ($solutionExists -and $hasSolutionCdsproj) { "sync" } else { "clone" }
}
Write-Host ""
Write-Host "Executing pre-unpack hooks..." -ForegroundColor Cyan
Invoke-PipelineHooks -Stage "pre-unpack" -Context $hookContext -ContinueOnError $true

Write-Host ""
if ($solutionExists -and $hasSolutionCdsproj) {
    # Solution exists - use sync
    Write-Host "Solution exists locally. Using 'pac solution sync'..." -ForegroundColor Cyan
    Write-Host "Solution path: $solutionPath"
    
    $originalLocation = Get-Location
    try {
        Set-Location $solutionPath
        
        Write-Host "Running: pac solution sync --environment $environmentUrl"
        $syncOutput = pac solution sync --async --max-async-wait-time 300 --environment $environmentUrl 2>&1
        $syncExitCode = $LASTEXITCODE
        
        # Always display pac output for visibility
        if ($syncOutput) {
            Write-Host ""
            Write-Host "pac CLI output:"
            Write-Host ($syncOutput | Out-String)
        }
        
        if ($syncExitCode -ne 0) {
            $errorMessage = "pac solution sync failed with exit code $syncExitCode"
            if ($syncOutput) {
                $errorMessage += "`n`npac CLI output:`n" + ($syncOutput | Out-String)
            }
            throw $errorMessage
        }
        
        Write-Host "✓ Solution synced successfully" -ForegroundColor Green
    }
    catch {
        throw $_
    }
    finally {
        Set-Location $originalLocation
    }
} else {
    # Solution doesn't exist or is incomplete - use clone
    Write-Host "Solution not found locally or incomplete. Using 'pac solution clone'..." -ForegroundColor Cyan
    
    # Remove incomplete solution if it exists
    if ($solutionExists) {
        Write-Host "Removing incomplete solution directory..." -ForegroundColor Yellow
        Remove-Item $solutionPath -Recurse -Force
    }
    
    Write-Host "Running: pac solution clone --name $solutionName --outputDirectory $solutionFolder --environment $environmentUrl"
    $cloneOutput = pac solution clone --name $solutionName --async --max-async-wait-time 300 --outputDirectory $solutionFolder --environment $environmentUrl 2>&1
    $cloneExitCode = $LASTEXITCODE
    
    # Always display pac output for visibility
    if ($cloneOutput) {
        Write-Host ""
        Write-Host "pac CLI output:"
        Write-Host ($cloneOutput | Out-String)
    }
    
    if ($cloneExitCode -ne 0) {
        $errorMessage = "pac solution clone failed with exit code $cloneExitCode"
        if ($cloneOutput) {
            $errorMessage += "`n`npac CLI output:`n" + ($cloneOutput | Out-String)
        }
        throw $errorMessage
    }
    
    Write-Host "✓ Solution cloned successfully" -ForegroundColor Green
    
    # Update .cdsproj file to enable Both (Managed and Unmanaged) package generation
    Write-Host ""
    Write-Host "Configuring solution project for Both (Managed/Unmanaged) package generation..." -ForegroundColor Cyan
    
    $cdsprojFile = Get-ChildItem -Path $solutionPath -Filter "*.cdsproj" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cdsprojFile) {
        $cdsprojPath = $cdsprojFile.FullName
        Write-Host "Found .cdsproj: $($cdsprojFile.Name)"
        
        $content = Get-Content -Path $cdsprojPath -Raw
        
        # Check if the PropertyGroup section exists (commented or uncommented)
        if ($content -match '<!--\s*<PropertyGroup>\s*<SolutionPackageType>') {
            # Uncomment and update to Both
            $content = $content -replace '<!--\s*<PropertyGroup>\s*<SolutionPackageType>[^<]*</SolutionPackageType>\s*<SolutionPackageEnableLocalization>[^<]*</SolutionPackageEnableLocalization>\s*</PropertyGroup>\s*-->', 
                "<PropertyGroup>`r`n    <SolutionPackageType>Both</SolutionPackageType>`r`n    <SolutionPackageEnableLocalization>false</SolutionPackageEnableLocalization>`r`n  </PropertyGroup>"
            Write-Host "  ✓ Uncommented and updated SolutionPackageType to 'Both'" -ForegroundColor Green
        }
        elseif ($content -match '<PropertyGroup>\s*<SolutionPackageType>') {
            # Already uncommented, just update the type
            $content = $content -replace '<SolutionPackageType>[^<]*</SolutionPackageType>', '<SolutionPackageType>Both</SolutionPackageType>'
            Write-Host "  ✓ Updated SolutionPackageType to 'Both'" -ForegroundColor Green
        }
        else {
            # Section doesn't exist, add it after the first PropertyGroup
            $insertAfterPattern = '(<PropertyGroup>[\s\S]*?</PropertyGroup>)'
            $newPropertyGroup = "`r`n`r`n  <PropertyGroup>`r`n    <SolutionPackageType>Both</SolutionPackageType>`r`n    <SolutionPackageEnableLocalization>false</SolutionPackageEnableLocalization>`r`n  </PropertyGroup>"
            $content = $content -replace $insertAfterPattern, "`$1$newPropertyGroup"
            Write-Host "  ✓ Added PropertyGroup with SolutionPackageType='Both'" -ForegroundColor Green
        }
        
        Set-Content -Path $cdsprojPath -Value $content -NoNewline
    }
    else {
        Write-Warning "Could not find .cdsproj file to configure"
    }
}

# Execute post-unpack hooks
Write-Host ""
Write-Host "Executing post-unpack hooks..." -ForegroundColor Cyan
$hookContext.solutionPath = $solutionPath  # Update with final path
Invoke-PipelineHooks -Stage "post-unpack" -Context $hookContext -ContinueOnError $true

# Generate deployment settings template
Write-Host ""
Write-Host "Generating deployment settings template..." -ForegroundColor Cyan

$templateDir = Join-Path $repoRoot "deployments\settings\templates"
$templatePath = Join-Path $templateDir "${solutionName}_template.json"

if (-not (Test-Path $templateDir)) {
    New-Item -ItemType Directory -Path $templateDir -Force | Out-Null
}

try {
    # Parse solution XML to generate deployment settings template
    Write-Host "  Parsing solution XML for deployment settings..." -ForegroundColor Gray
    
    & "$PSScriptRoot\Parse-SolutionDeploymentSettings.ps1" `
        -solutionPath $solutionPath `
        -outputPath $templatePath 2>&1 | Out-Null
    
    if ($LASTEXITCODE -eq 0 -and (Test-Path $templatePath)) {
        Write-Host "  ✓ Template generated: $([System.IO.Path]::GetFileName($templatePath))" -ForegroundColor Green
        
        # Read template to extract environment variable schema names
        try {
            $template = Get-Content $templatePath -Raw | ConvertFrom-Json
        }
        catch {
            Write-Warning "  Failed to read or parse deployment settings template: $($_.Exception.Message)"
            $template = $null
        }
        
        if ($template) {
            # Update environment-variables.json with placeholder entries
            Write-Host "  Building path to environment-variables.json..." -ForegroundColor Gray
            Write-Host "    repoRoot: $repoRoot" -ForegroundColor Gray
            $envVarsPath = Join-Path $repoRoot "deployments\settings\environment-variables.json"
            Write-Host "    envVarsPath: $envVarsPath" -ForegroundColor Gray
            Write-Host "    Path exists: $(Test-Path $envVarsPath)" -ForegroundColor Gray
            
            Write-Host "  Reading environment-variables.json..." -ForegroundColor Gray
            try {
                $envVarsConfig = Get-Content $envVarsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                Write-Host "  ✓ environment-variables.json parsed successfully" -ForegroundColor Gray
            }
            catch {
                Write-Warning "  Failed to read/parse environment-variables.json: $($_.Exception.Message)"
                Write-Warning "    At: $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)"
                $envVarsConfig = $null
            }
            
            if ($envVarsConfig) {
                Write-Host "  Updating environment variables..." -ForegroundColor Gray
        
                # Ensure environments object exists
                if (-not $envVarsConfig.environments) {
                    Write-Host "    Creating environments property..." -ForegroundColor Gray
                    $envVarsConfig | Add-Member -NotePropertyName "environments" -NotePropertyValue ([PSCustomObject]@{}) -Force
                }
                
                # Ensure metadata object exists
                if (-not $envVarsConfig.metadata) {
                    Write-Host "    Creating metadata property..." -ForegroundColor Gray
                    $envVarsConfig | Add-Member -NotePropertyName "metadata" -NotePropertyValue ([PSCustomObject]@{}) -Force
                }
                
                # Get list of environments to populate - use repository variable if available
                $environmentsFromVar = $env:DEPLOYMENT_ENVIRONMENTS
                if (-not [string]::IsNullOrWhiteSpace($environmentsFromVar)) {
                    Write-Host "    Using environments from DEPLOYMENT_ENVIRONMENTS variable: $environmentsFromVar" -ForegroundColor Gray
                    $environments = $environmentsFromVar -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
                }
                else {
                    Write-Warning "DEPLOYMENT_ENVIRONMENTS is not set. Skipping environment variable population. Set the DEPLOYMENT_ENVIRONMENTS repository variable and re-run."
                    $environments = @()
                }
                
                $newVarsAdded = 0
                
                if ($template.EnvironmentVariables -and $template.EnvironmentVariables.Count -gt 0) {
                    # Sort environment variables alphabetically by SchemaName for easier lookup
                    $sortedEnvVars = $template.EnvironmentVariables | Sort-Object -Property SchemaName
                    
                    Write-Host "    Processing $($sortedEnvVars.Count) environment variable(s)..." -ForegroundColor Gray

                    # --- Metadata pass (unconditional — runs regardless of DEPLOYMENT_ENVIRONMENTS) ---
                    # Uses type/displayName/etc from the template's Metadata section (populated by Parse-SolutionDeploymentSettings.ps1)
                    # Always overwrites metadata so type changes in Dataverse are reflected on re-sync
                    $metadataAdded = 0
                    foreach ($envVar in $sortedEnvVars) {
                        $schemaName = $envVar.SchemaName
                        $templateMeta = if ($template.Metadata) { $template.Metadata.$schemaName } else { $null }
                        $newMeta = [PSCustomObject]@{
                            displayName  = if ($templateMeta -and $templateMeta.displayName) { $templateMeta.displayName } else { $schemaName }
                            schemaName   = $schemaName
                            type         = if ($templateMeta -and $templateMeta.type) { $templateMeta.type } else { "String" }
                            defaultValue = if ($templateMeta -and $null -ne $templateMeta.defaultValue) { $templateMeta.defaultValue } else { "" }
                            description  = if ($templateMeta -and $templateMeta.description) { $templateMeta.description } else { "" }
                        }
                        $existing = $envVarsConfig.metadata.$schemaName
                        $isNew = -not ($envVarsConfig.metadata.PSObject.Properties.Name -contains $schemaName)
                        $typeChanged = $existing -and $existing.type -ne $newMeta.type
                        if ($isNew -or $typeChanged) {
                            Write-Host "            $(if ($isNew) { 'Adding' } else { 'Updating' }) metadata for: $schemaName (type: $($newMeta.type))" -ForegroundColor Gray
                            $envVarsConfig.metadata | Add-Member -NotePropertyName $schemaName -NotePropertyValue $newMeta -Force
                            $metadataAdded++
                            Write-Host "            ✓ Metadata $(if ($isNew) { 'added' } else { 'updated' }) (type: $($newMeta.type))" -ForegroundColor Gray
                        }
                    }

                    # --- Environment placeholder pass (gated on DEPLOYMENT_ENVIRONMENTS) ---
                    foreach ($env in $environments) {
                        Write-Host "      Processing environment: $env..." -ForegroundColor Gray
                        
                        # Add environment if it doesn't exist
                        if (-not ($envVarsConfig.environments.PSObject.Properties.Name -contains $env)) {
                            Write-Host "        Adding environment..." -ForegroundColor Gray
                            $envVarsConfig.environments | Add-Member -NotePropertyName $env -NotePropertyValue ([PSCustomObject]@{}) -Force
                        }
                        
                        $envConfig = $envVarsConfig.environments.$env
                        Write-Host "        envConfig type: $($envConfig.GetType().Name)" -ForegroundColor Gray
                        
                        # Add placeholder for each environment variable
                        foreach ($envVar in $sortedEnvVars) {
                            Write-Host "          Processing EV: SchemaName=$($envVar.SchemaName)" -ForegroundColor Gray
                            $schemaName = $envVar.SchemaName
                            
                            $evPropNames = $envConfig.PSObject.Properties.Name
                            if (-not ($evPropNames -contains $schemaName)) {
                                Write-Host "            Adding member: $schemaName = '<unset>'" -ForegroundColor Gray
                                $envConfig | Add-Member -NotePropertyName $schemaName -NotePropertyValue "<unset>" -Force
                                $newVarsAdded++
                                Write-Host "            ✓ Added" -ForegroundColor Gray
                            }
                        }
                    }
                    
                    Write-Host "    Environment variables added: $newVarsAdded, Metadata entries added: $metadataAdded" -ForegroundColor Gray
                    if ($newVarsAdded -gt 0 -or $metadataAdded -gt 0) {
                        Write-Host "  Saving environment-variables.json..." -ForegroundColor Gray
                        
                        # Sort properties in each environment alphabetically
                        foreach ($env in $environments) {
                            if ($envVarsConfig.environments.PSObject.Properties.Name -contains $env) {
                                $envConfig = $envVarsConfig.environments.$env
                                $sortedProps = $envConfig.PSObject.Properties | Sort-Object Name
                                $newEnvConfig = [PSCustomObject]@{}
                                foreach ($prop in $sortedProps) {
                                    $newEnvConfig | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
                                }
                                $envVarsConfig.environments.$env = $newEnvConfig
                            }
                        }
                        
                        # Save updated environment-variables.json
                        $envVarsConfig | ConvertTo-Json -Depth 10 | Set-Content $envVarsPath -Encoding UTF8
                        Write-Host "  ✓ Updated environment-variables.json ($newVarsAdded placeholder(s) added, $metadataAdded metadata entries added)" -ForegroundColor Green
                    }
                }
                else {
                    Write-Host "  No environment variables in solution" -ForegroundColor Gray
                }
            }
            else {
                Write-Warning "  Skipping environment variable update - could not read environment-variables.json"
            }
            
            # Update connection-mappings.json with placeholder entries
            Write-Host "  Building path to connection-mappings.json..." -ForegroundColor Gray
            $connMappingsPath = Join-Path $repoRoot "deployments\settings\connection-mappings.json"
            Write-Host "    connMappingsPath: $connMappingsPath" -ForegroundColor Gray
            Write-Host "    Path exists: $(Test-Path $connMappingsPath)" -ForegroundColor Gray
            
            if ($template.ConnectionReferences -and $template.ConnectionReferences.Count -gt 0) {
                Write-Host "  Reading connection-mappings.json..." -ForegroundColor Gray
                try {
                    $connMappingsConfig = Get-Content $connMappingsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    Write-Host "  ✓ connection-mappings.json parsed successfully" -ForegroundColor Gray
                }
                catch {
                    Write-Warning "  Failed to read/parse connection-mappings.json: $($_.Exception.Message)"
                    $connMappingsConfig = $null
                }
                
                if ($connMappingsConfig) {
                    Write-Host "  Updating connection mappings..." -ForegroundColor Gray
                    
                    # Ensure environments object exists
                    if (-not $connMappingsConfig.environments) {
                        Write-Host "    Creating environments property..." -ForegroundColor Gray
                        $connMappingsConfig | Add-Member -NotePropertyName "environments" -NotePropertyValue ([PSCustomObject]@{}) -Force
                    }
                    
                    # Get list of environments
                    $environmentsFromVar = $env:DEPLOYMENT_ENVIRONMENTS
                    if (-not [string]::IsNullOrWhiteSpace($environmentsFromVar)) {
                        Write-Host "    Using environments from DEPLOYMENT_ENVIRONMENTS variable: $environmentsFromVar" -ForegroundColor Gray
                        $environments = $environmentsFromVar -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
                    }
                    else {
                        Write-Warning "DEPLOYMENT_ENVIRONMENTS is not set. Skipping connection mapping population. Set the DEPLOYMENT_ENVIRONMENTS repository variable and re-run."
                        $environments = @()
                    }
                    
                    $newConnectionsAdded = 0
                    
                    # Sort connection references alphabetically by ConnectorId for easier lookup
                    $sortedConnRefs = $template.ConnectionReferences | Sort-Object -Property ConnectorId
                    
                    Write-Host "    Processing $($sortedConnRefs.Count) connection reference(s)..." -ForegroundColor Gray
                    foreach ($env in $environments) {
                        Write-Host "      Processing environment: $env..." -ForegroundColor Gray
                        
                        # Add environment if it doesn't exist
                        if (-not ($connMappingsConfig.environments.PSObject.Properties.Name -contains $env)) {
                            Write-Host "        Adding environment..." -ForegroundColor Gray
                            $connMappingsConfig.environments | Add-Member -NotePropertyName $env -NotePropertyValue ([PSCustomObject]@{}) -Force
                        }
                        
                        $envConfig = $connMappingsConfig.environments.$env
                        
                        # Add placeholder for each connector type
                        foreach ($connRef in $sortedConnRefs) {
                            $connectorId = $connRef.ConnectorId
                            
                            # Skip if connector ID is empty
                            if ([string]::IsNullOrWhiteSpace($connectorId)) {
                                Write-Warning "          Skipping connection with empty ConnectorId"
                                continue
                            }
                            
                            Write-Host "          Processing Connection: $connectorId" -ForegroundColor Gray
                            
                            $connPropNames = $envConfig.PSObject.Properties.Name
                            if (-not ($connPropNames -contains $connectorId)) {
                                Write-Host "            Adding connector: $connectorId = '00000000000000000000000000000000'" -ForegroundColor Gray
                                $envConfig | Add-Member -NotePropertyName $connectorId -NotePropertyValue "00000000000000000000000000000000" -Force
                                $newConnectionsAdded++
                                Write-Host "            ✓ Added" -ForegroundColor Gray
                            }
                        }
                    }
                    
                    Write-Host "    Connection mappings added: $newConnectionsAdded" -ForegroundColor Gray
                    if ($newConnectionsAdded -gt 0) {
                        Write-Host "  Saving connection-mappings.json..." -ForegroundColor Gray
                        
                        # Sort properties in each environment alphabetically
                        foreach ($env in $environments) {
                            if ($connMappingsConfig.environments.PSObject.Properties.Name -contains $env) {
                                $envConfig = $connMappingsConfig.environments.$env
                                $sortedProps = $envConfig.PSObject.Properties | Sort-Object Name
                                $newEnvConfig = [PSCustomObject]@{}
                                foreach ($prop in $sortedProps) {
                                    $newEnvConfig | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
                                }
                                $connMappingsConfig.environments.$env = $newEnvConfig
                            }
                        }
                        
                        # Save updated connection-mappings.json
                        $connMappingsConfig | ConvertTo-Json -Depth 10 | Set-Content $connMappingsPath -Encoding UTF8
                        Write-Host "  ✓ Added $newConnectionsAdded connection placeholder(s) to connection-mappings.json" -ForegroundColor Green
                    }
                }
                else {
                    Write-Warning "  Skipping connection mapping update - could not read connection-mappings.json"
                }
            }
            else {
                Write-Host "  No connection references in solution" -ForegroundColor Gray
            }
        }
    }
    else {
        Write-Warning "  Failed to generate deployment settings template"
        if ($settingsOutput) {
            Write-Host "  pac CLI output:" -ForegroundColor Gray
            Write-Host ($settingsOutput | Out-String) -ForegroundColor Gray
        }
    }
}
catch {
    Write-Warning "  Failed to generate deployment settings template: $($_.Exception.Message)"
}

# Process Canvas apps
Write-Host ""
Write-Host "Processing Canvas apps..." -ForegroundColor Cyan

# Check multiple possible locations for CanvasApps
$canvasAppsPath = $null
$possiblePaths = @(
    (Join-Path $solutionPath "CanvasApps"),
    (Join-Path $solutionPath "src\CanvasApps")
)

foreach ($path in $possiblePaths) {
    if (Test-Path $path) {
        $canvasAppsPath = $path
        Write-Host "Found CanvasApps folder: $path" -ForegroundColor Gray
        break
    }
}

if ($canvasAppsPath -and (Test-Path $canvasAppsPath)) {
    $msappFiles = Get-ChildItem -Path $canvasAppsPath -Filter "*.msapp" -Recurse -ErrorAction SilentlyContinue
    
    if ($msappFiles.Count -gt 0) {
        Write-Host "Found $($msappFiles.Count) Canvas app(s)" -ForegroundColor Cyan
        
        # Execute pre-unpack-canvas hooks
        Write-Host "Executing pre-unpack-canvas hooks..." -ForegroundColor Cyan
        $unpackContext = @{
            solutionName = $solutionName
            canvasAppsPath = $canvasAppsPath
            msappFiles = $msappFiles
        }
        Invoke-PipelineHooks -Stage "pre-unpack-canvas" -Context $unpackContext -ContinueOnError $true
        
        foreach ($msappFile in $msappFiles) {
            $appName = [System.IO.Path]::GetFileNameWithoutExtension($msappFile.Name)
            $appUnpackPath = Join-Path $canvasAppsPath "$appName-src"
            
            Write-Host "  Unpacking: $appName"
            
            # Remove existing unpacked directory
            if (Test-Path $appUnpackPath) {
                Remove-Item $appUnpackPath -Recurse -Force
            }
            
            # Create destination directory
            New-Item -ItemType Directory -Path $appUnpackPath -Force | Out-Null
            
            try {
                Expand-Archive -Path $msappFile.FullName -DestinationPath $appUnpackPath -Force
                Write-Host "    ✓ Unpacked successfully" -ForegroundColor Green
            }
            catch {
                Write-Warning "    Failed to unpack: $($_.Exception.Message)"
                if (Test-Path $appUnpackPath) {
                    Remove-Item $appUnpackPath -Recurse -Force
                }
            }
        }
        
        # Execute post-unpack-canvas hooks
        Write-Host \"Executing post-unpack-canvas hooks...\" -ForegroundColor Cyan
        Invoke-PipelineHooks -Stage \"post-unpack-canvas\" -Context $unpackContext -ContinueOnError $true
    } else {
        Write-Host "No Canvas apps (.msapp files) found"
    }
} else {
    Write-Host "No CanvasApps folder found in solution"
}

# Commit and push changes
if ($performGitOperations) {
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "Committing and Pushing Changes" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    
    # Execute pre-commit hooks
    Write-Host ""
    Write-Host "Executing pre-commit hooks..." -ForegroundColor Cyan
    $commitContext = @{
        solutionName = $solutionName
        solutionPath = $solutionPath
        solutionFolder = $solutionFolder
        branchName = $branchName
        commitMessage = $commitMessage
    }
    Invoke-PipelineHooks -Stage "pre-commit" -Context $commitContext -ContinueOnError $true
    
    # Stage solution files
    Write-Host ""
    Write-Host "Staging solution files..." -ForegroundColor Cyan
    git add "$solutionFolder/" 2>&1
    
    # Stage deployment settings files
    Write-Host "Staging deployment settings files..." -ForegroundColor Cyan
    git add "deployments/settings/" 2>&1
    
    # Check for changes
    $gitStatus = git status --porcelain 2>$null
    
    if ([string]::IsNullOrWhiteSpace($gitStatus)) {
        Write-Host "No changes detected in solution files" -ForegroundColor Yellow
        Write-Host "Solution is already up to date in Git"
    } else {
        Write-Host "Changes detected, committing..." -ForegroundColor Cyan
        
        # Commit changes
        git commit -m "$commitMessage" 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✓ Changes committed successfully" -ForegroundColor Green
            
            # Execute post-commit hooks
            Write-Host ""
            Write-Host "Executing post-commit hooks..." -ForegroundColor Cyan
            Invoke-PipelineHooks -Stage "post-commit" -Context $commitContext -ContinueOnError $true
            
                # Push if in CI or if remote exists
                $hasRemote = git remote get-url origin 2>$null
                if ($hasRemote -and $LASTEXITCODE -eq 0) {
                    $pushBranch = if ($branchName) { $branchName } else { git branch --show-current }
                    
                    Write-Host ""
                    Write-Host "Pushing to remote..." -ForegroundColor Cyan
                    git push origin $pushBranch 2>&1
                    
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "✓ Pushed to origin/$pushBranch" -ForegroundColor Green
                    } else {
                        Write-Warning "Push failed. This may indicate a concurrent change was pushed."
                        Write-Warning "Since we started from the latest remote state, this is unexpected."
                        throw "Failed to push changes. Exit code: $LASTEXITCODE"
                    }
                } else {
                    Write-Host "No remote configured or unable to detect remote. Skipping push." -ForegroundColor Yellow
                }
        } else {
            throw "Failed to commit changes"
        }
    }
}

# Cleanup auth
$client.ClearAuth()

Write-Host ""
Write-Host "=========================================="
Write-Host "✓ Solution Sync Complete" -ForegroundColor Green
Write-Host "=========================================="
Write-Host "Solution: $solutionName"
Write-Host "Location: $solutionPath"
if ($performGitOperations -and -not [string]::IsNullOrWhiteSpace($gitStatus)) {
    Write-Host "Git: Committed and pushed" -ForegroundColor Green
} elseif ($performGitOperations) {
    Write-Host "Git: No changes to commit" -ForegroundColor Yellow
} else {
    Write-Host "Git: Skipped"
}
Write-Host ""

exit 0
