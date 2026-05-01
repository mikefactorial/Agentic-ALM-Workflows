# Workflow Hooks System

This directory contains pipeline hooks that execute at specific points during the ALM process. Hooks provide extensibility without modifying core pipeline functionality.

## Implementation Status

✅ **Fully Integrated** - Hooks are now implemented in all major workflow scripts:

- **Sync-Solution.ps1** - Includes pre-unpack, post-unpack, pre-unpack-canvas, post-unpack-canvas, pre-commit, and post-commit hooks
- **Build-Solutions.ps1** - Includes pre-build and post-build hooks

All hooks are called with `ContinueOnError = $true` by default, meaning failures won't stop the pipeline unless the hook explicitly throws an error.

## Hook Stages

### Available Stages
- **pre-unpack** - Before solution sync/clone operations (pac solution sync/clone)
- **post-unpack** - After solution sync/clone operations
- **pre-unpack-canvas** - Before unpacking Canvas apps (.msapp files) 
- **post-unpack-canvas** - After unpacking Canvas apps
- **pre-commit** - Before Git operations
- **post-commit** - After Git operations
- **pre-build** - Before solution building
- **post-build** - After solution building

### Hook Naming Convention
Hooks must follow the naming pattern: `{Stage}-{Description}.ps1`

Examples:
- `pre-sync-validate.ps1`
- `post-build-notify.ps1`
- `pre-deploy-backup.ps1`

## Using Hooks

### In Your Pipeline Scripts
```powershell
# Import the hook manager
. "$PSScriptRoot\Invoke-PipelineHooks.ps1"

# Execute hooks at a specific stage
$context = @{
    environmentUrl = $environmentUrl
    solutionName = $solutionName
    commitMessage = $commitMessage
    # ... other relevant parameters
}

$success = Invoke-PipelineHooks -Stage "pre-build" -Context $context
if (-not $success) {
    Write-Error "Pre-build hooks failed"
    exit 1
}
```

### Hook Parameters
Hooks receive parameters via splatting based on their stage context:

### Global Hook Variables (JSON)
You can provide shared hook parameters for any hook via JSON strings in the following environment variables:

- `HOOK_VARIABLES` - Non-secret parameters as JSON
- `HOOK_SECRETS` - Secret parameters as JSON (kept in GitHub Secrets)

Hooks read these JSON values directly from environment variables, so they can pull only the keys they need at runtime.

Example:
```json
{
    "LEON_WEBHOOK_URL": "https://...",
    "LEON_WEBHOOK_NAME": "LEON"
}
```

```json
{
    "LEON_WEBHOOK_SUBSCRIPTION_KEY": "..."
}
```

Use the helper in hooks:
```powershell
. "$PSScriptRoot\..\HookVariables.ps1"

$webhookName = Get-HookVariable -Name "LEON_WEBHOOK_NAME" -Default "LEON Webhook"
$webhookUrl = Get-HookVariable -Name "LEON_WEBHOOK_URL"
$webhookSubKey = Get-HookSecret -Name "LEON_WEBHOOK_SUBSCRIPTION_KEY"
```

**Export hooks (pre-export, post-export)** receive:
- `solutionName` - Name of solution being exported/synced
- `environmentUrl` - Source environment URL
- `solutionPath` - Path where solution will be/was exported
- `solutionFolder` - Parent folder containing solutions
- `operation` - Either "sync" or "clone" depending on whether solution exists locally

**Unpack hooks (pre-unpack, post-unpack)** receive:
- `solutionName` - Name of solution containing Canvas apps
- `canvasAppsPath` - Path to CanvasApps folder
- `msappFiles` - Collection of .msapp files to be unpacked

**Commit hooks (pre-commit, post-commit)** receive:
- `solutionName` - Name of solution being committed
- `solutionPath` - Path to solution directory
- `solutionFolder` - Parent folder containing solutions
- `branchName` - Git branch name (may be null for current branch)
- `commitMessage` - Git commit message

**Build hooks (pre-build, post-build)** receive:
- `solutionName` - Name of solution being built
- `solutionPath` - Path to solution source directory
- `cdsprojPath` - Full path to the .cdsproj file
- `artifactsPath` - Directory where build artifacts are stored
- `targetEnvironmentUrl` - Target environment URL
- `configuration` - Build configuration (Debug/Release)
- `buildOutputPath` - Path where build outputs are generated (post-build only)
- `builtZipFiles` - Array of built ZIP file paths (post-build only)
- `targetEnvironmentName` - Name of target environment (post-build only)

**Import hooks (pre-import, post-import)** receive:
- `sourceSolutionName` - Name of solution being imported
- `targetSolutionName` - Name of target solution (where components will be copied)
- `targetEnvironmentUrl` - Target environment URL
- `solutionZipPath` - Path to solution zip file
- `phase` - Current phase: "Import", "Export", or "All"

**Deploy hooks (pre-deploy, post-deploy)** receive:
- `environmentUrl` - Source environment URL
- `environmentName` - Name of the environment
- `solutionName` - Name of solution being deployed
- `targetEnvironmentUrl` - Target environment URL
- `solutionPath` - Path to solution directory
- `artifactsPath` - Path to artifacts directory
- `useSingleStageUpgrade` - Whether single-stage upgrade is being used
- `deploymentStatus` - Status of deployment (success, failure, etc.)
- `stage` - Hook stage identifier
- `integrationBranch` - Integration branch name
- `remoteName` - Git remote name
- `versionInfoFile` - Path to version info file (if applicable)
- Additional context parameters like `tenantId`, `clientId` for authentication

Additional parameters vary by stage and context.

## Example Hooks

### Pre-Export Validation (`Pre-Export-Validate.ps1`)
- Validates solution health before export
- Checks solution dependencies
- Performs solution checker validation
- Verifies component integrity

### Post-Export Cleanup (`Post-Export-Cleanup.ps1`)
- Verifies exported solution structure
- Archives exported solution files
- Sends export completion notifications
- Updates solution tracking systems

### Pre-Import Preparation (`Pre-Import-Prepare.ps1`)
- Validates target environment health
- Checks solution file integrity
- Verifies environment capacity
- Performs dependency validation
- Creates environment backups

### Post-Import Verification (`Post-Import-Verify.ps1`)
- Verifies successful solution installation
- Activates imported components
- Runs integration tests
- Updates documentation
- Sends deployment notifications

### Post-Deploy Actions (`Post-Deploy-EnableFlowsAndProcesses.ps1`)
- Activates Flows and Processes in deployed solutions
- Automatically turns on Cloud Flows
- Activates Classic Workflows
- Generates activation status reports
- Runs after solution deployment completes

### Pre-Build Cleanup (`Pre-Build-Cleanup.ps1`)
- Removes bin/obj directories
- Cleans up .user files
- Prepares solution for clean build

### Pre-Commit Modifications (`Pre-Commit-Modify.ps1`)
- Updates solution version numbers
- Adds commit metadata files
- Processes Canvas app source files

### Post-Commit Notifications (`Post-Commit-Notify.ps1`)
- Sends Teams notifications
- Logs to external services
- Creates audit trails

### Pre-Deploy Validation (`Pre-Deploy-Validate.ps1`)
- Validates solution file integrity
- Checks target environment connectivity
- Enforces file size limits

### Post-Deploy Logging (`Post-Deploy-Log.ps1`)
- Creates deployment logs
- Updates tracking systems
- Generates reports

### Enable Flows and Processes (`Post-Deploy-EnableFlowsAndProcesses.ps1`)
- Post-deployment hook that automatically activates Flows and Processes
- Queries all Classic Workflows (Processes) and Cloud Flows from the deployed solution
- Checks activation status (Draft/Activated for workflows, Off/On for flows)
- Automatically enables/activates flows and processes that are currently off
- Generates detailed report showing status before and after activation
- Automatically invoked by pipeline when post-deploy hooks execute
- Uses standard post-deploy hook parameter signature for seamless integration

**Artifact Naming Convention**:
- Solution ZIP files: `{SolutionName}_managed_{EnvironmentName}.zip`
- Deployment settings: `{SolutionName}_managed_{EnvironmentName}_DeploymentSettings.json`

**Examples**:
- `PipelineDemo_managed_Test.zip`
- `PipelineDemo_managed_Staging.zip` 
- `PipelineDemo_managed_Production.zip`
- `PipelineDemo_managed_Test_DeploymentSettings.json`

### Environment Context in Hooks

Hooks receive environment-specific context through the `targetEnvironmentName` parameter, allowing them to:
- Create environment-specific configurations
- Apply environment-specific validations
- Generate environment-appropriate notifications
- Handle environment-specific deployment logic

### Example Environment-Aware Hook
```powershell
param (
    [Parameter(Mandatory)] [String]$solutionName,
    [Parameter(Mandatory)] [String]$targetEnvironmentName,
    [Parameter()] [String[]]$builtZipFiles = @()
)

Write-Host "Processing $solutionName for $targetEnvironmentName environment"

# Environment-specific logic
switch ($targetEnvironmentName) {
    "Test" { 
        Write-Host "Applying test environment configurations"
        # Test-specific logic
    }
    "Staging" { 
        Write-Host "Applying staging environment validations"
        # Staging-specific logic
    }
    "Production" { 
        Write-Host "Applying production environment safeguards"
        # Production-specific logic
    }
}

# Process environment-specific artifacts
foreach ($zipFile in $builtZipFiles) {
    $fileName = [System.IO.Path]::GetFileName($zipFile)
    if ($fileName -like "*_${targetEnvironmentName}.zip") {
        Write-Host "Processing environment-specific artifact: $fileName"
        # Process the artifact for this environment
    }
}
```

Hooks are automatically discovered using a file-based naming convention. The system looks for PowerShell scripts in the `scripts/hooks/` directory that match the pattern:

**`{Stage}-{Description}.ps1`**

### Supported Stages
- **pre-export** - Before solution export from development environment
- **post-export** - After solution export from development environment
- **pre-import** - Before solution import to integration environment  
- **post-import** - After solution import to integration environment
- **pre-unpack** - Before solution unpack operations
- **post-unpack** - After solution unpack, before commit  
- **pre-commit** - Before Git commit operations
- **post-commit** - After Git commit operations
- **pre-build** - Before solution build process
- **post-build** - After solution build process
- **pre-deploy** - Before solution deployment (validation)
- **post-deploy** - After solution deployment

### Example Hook Names
- `Pre-Export-Validate.ps1`
- `Post-Export-Cleanup.ps1`
- `Pre-Import-Prepare.ps1`
- `Post-Import-Verify.ps1`
- `Pre-Build-Cleanup.ps1`
- `Pre-Build-Version.ps1`
- `Post-Deploy-Log.ps1`
- `Post-Deploy-EnableFlowsAndProcesses.ps1`
- `Pre-Commit-Modify.ps1`

All discovered hooks for a stage are executed in alphabetical order by filename.

## Creating Custom Hooks

### Basic Hook Template
```powershell
param (
    [Parameter(Mandatory)] [String]$environmentUrl,
    [Parameter(Mandatory)] [String]$solutionName,
    [Parameter()] [String]$targetEnvironmentName = "default",
    [Parameter()] [String]$artifactsPath = "./artifacts",
    # Add other parameters as needed for your specific stage
    [Parameter()] [String]$stage = "your-stage"
)

Write-Host "Executing $stage hook for solution: $solutionName (target: $targetEnvironmentName)"

try {
    # Your custom logic here
    Write-Host "Processing solution for $targetEnvironmentName environment"
    
    # Example: Environment-specific processing
    if ($targetEnvironmentName -eq "Production") {
        Write-Host "Applying production-specific validations"
        # Production-specific logic
    }
    
    Write-Host "Custom hook completed successfully"
} catch {
    Write-Error "Custom hook failed: $($_.Exception.Message)"
    exit 1
}
```

### Best Practices for Hook Development
1. **Always include error handling** with try/catch
2. **Use descriptive output** with Write-Host for progress
3. **Exit with code 1** on failures
4. **Accept all standard parameters** even if not used (parameter filtering is automatic)
5. **Document purpose** in comments at the top
6. **Test independently** before integrating
7. **Use `targetEnvironmentName`** for environment-specific logic
8. **Handle environment-specific artifacts** using the standard naming convention

### Working with Environment-Specific Artifacts

When working with build artifacts in hooks, use the environment-specific naming:

```powershell
# In a post-build hook
param (
    [Parameter()] [String]$solutionName,
    [Parameter()] [String]$targetEnvironmentName,
    [Parameter()] [String[]]$builtZipFiles = @(),
    [Parameter()] [String]$artifactsPath
)

foreach ($zipFile in $builtZipFiles) {
    $fileName = [System.IO.Path]::GetFileName($zipFile)
    # File will be named like: PipelineDemo_managed_Test.zip
    if ($fileName -like "*_managed_${targetEnvironmentName}.zip") {
        Write-Host "Found environment-specific artifact: $fileName"
        
        # Corresponding deployment settings file
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
        $settingsFile = "${baseName}_DeploymentSettings.json"
        $settingsPath = Join-Path $artifactsPath $settingsFile
        
        if (Test-Path $settingsPath) {
            Write-Host "Found deployment settings: $settingsFile"
        }
    }
}
```

## Hook Management

### Enabling/Disabling Hooks
To disable a hook, simply rename it to not match the `{Stage}-*.ps1` pattern (e.g., add `.disabled` to the filename) or move it out of the hooks directory.

### Adding New Hooks
1. Create your hook script in the `scripts/hooks/` directory
2. Follow the naming convention: `{Stage}-{Description}.ps1`
3. Ensure the hook accepts the standard parameters for its stage
4. Test the hook independently

### Debugging Hooks
- Run hooks individually with test parameters
- Use `ShowDetails` parameter for verbose output
- Check exit codes and error messages
- Review hook logs and outputs

## Environment Variables for Hooks

Common environment variables available to hooks (In addition to all standard environment variables available the following are provided to hooks for custom configuration of hook functionality):
- `HOOK_VARIABLES` - JSON payload of plain text variables for consumption by hooks
- `HOOK_SECRETS` - JSON payload of secrets for consumption by hooks

## Benefits

✅ **Modular Design** - Add/remove functionality without touching core scripts
✅ **Easy Maintenance** - Update hooks independently  
✅ **Flexible Configuration** - Enable/disable via JSON config
✅ **Consistent Interface** - Standardized parameters and error handling
✅ **Extensible** - Easy to add new stages and hooks
✅ **Testable** - Hooks can be tested in isolation
