<#
.SYNOPSIS
    Power Platform CLI wrapper with federated and interactive authentication support
    
.DESCRIPTION
    A PowerShell class-based wrapper for Power Platform CLI (pac) operations.
    Supports both federated authentication (OIDC for GitHub Actions) and 
    interactive authentication for local development.
    
.NOTES
    Author: Power Platform Team
    Requires: Power Platform CLI (pac) to be installed
#>

class PowerPlatformClient {
    [string]$EnvironmentUrl
    [string]$TenantId
    [string]$ClientId
    [bool]$UseFederated
    [bool]$UseInteractive
    [bool]$IsAuthenticated
    [string]$AuthProfileName

    # Constructor for interactive authentication (local development)
    PowerPlatformClient([string]$environmentUrl) {
        $this.EnvironmentUrl = $environmentUrl
        $this.UseInteractive = $true
        $this.UseFederated = $false
        $this.IsAuthenticated = $false
        $this.AuthProfileName = "interactive-profile-$(Get-Random)"
        
        Write-Verbose "PowerPlatformClient initialized with interactive authentication"
        Write-Verbose "Environment URL: $environmentUrl"
        
        # Verify pac CLI is available
        $this.VerifyPacCli()
        
        # Authenticate
        $this.Authenticate()
    }

    # Constructor for federated authentication (GitHub Actions / OIDC)
    PowerPlatformClient([string]$tenantId, [string]$clientId, [string]$environmentUrl) {
        $this.EnvironmentUrl = $environmentUrl
        $this.TenantId = $tenantId
        $this.ClientId = $clientId
        $this.UseFederated = $true
        $this.UseInteractive = $false
        $this.IsAuthenticated = $false
        $this.AuthProfileName = "federated-profile-$(Get-Random)"
        
        Write-Verbose "PowerPlatformClient initialized with federated authentication (OIDC)"
        Write-Verbose "Environment URL: $environmentUrl"
        
        # Verify pac CLI is available
        $this.VerifyPacCli()
        
        # Authenticate
        $this.Authenticate()
    }

    # Verify pac CLI is installed, install if not found
    [void] VerifyPacCli() {
        try {
            $null = Get-Command pac -ErrorAction Stop
            $pacVersion = pac --version 2>&1
            Write-Verbose "Power Platform CLI version: $pacVersion"
        }
        catch {
            Write-Host "Power Platform CLI not found. Installing..." -ForegroundColor Yellow
            
            try {
                # Install pac CLI using dotnet tool
                Write-Host "Running: dotnet tool install --global Microsoft.PowerApps.CLI.Tool"
                $installOutput = dotnet tool install --global Microsoft.PowerApps.CLI.Tool 2>&1
                $installExitCode = $LASTEXITCODE
                
                if ($installExitCode -ne 0) {
                    # Check if already installed
                    if ($installOutput -like "*already installed*" -or $installOutput -like "*Tool 'microsoft.powerapps.cli.tool' is already installed*") {
                        Write-Host "Power Platform CLI is already installed, updating PATH..." -ForegroundColor Cyan
                    }
                    else {
                        throw "Failed to install Power Platform CLI with exit code $installExitCode : $installOutput"
                    }
                }
                
                # Refresh PATH to pick up newly installed tool
                # On Linux/Mac, dotnet tools are in ~/.dotnet/tools
                # On Windows, they're in %USERPROFILE%\.dotnet\tools
                $isWindowsOS = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
                
                if ($isWindowsOS) {
                    $dotnetToolsPath = Join-Path $env:USERPROFILE ".dotnet\tools"
                }
                else {
                    $dotnetToolsPath = Join-Path $env:HOME ".dotnet/tools"
                }
                
                # Add to PATH if not already there
                if ($env:PATH -notlike "*$dotnetToolsPath*") {
                    $env:PATH = "$dotnetToolsPath$([System.IO.Path]::PathSeparator)$env:PATH"
                    Write-Host "Added $dotnetToolsPath to PATH" -ForegroundColor Cyan
                }
                
                # Verify installation succeeded
                $pacCheck = Get-Command pac -ErrorAction SilentlyContinue
                if (-not $pacCheck) {
                    throw "pac command not found after installation. PATH: $env:PATH"
                }
                
                $pacVersion = & pac help 2>&1
                Write-Host "✓ Power Platform CLI installed successfully: $pacVersion" -ForegroundColor Green
            }
            catch {
                throw "Failed to install Power Platform CLI: $_. Please install manually with: dotnet tool install --global Microsoft.PowerApps.CLI.Tool"
            }
        }
    }

    # Authenticate to Power Platform
    [void] Authenticate() {
        try {
            Write-Verbose "Authenticating to Power Platform..."
            
            if ($this.UseFederated) {
                # Federated authentication (OIDC for GitHub Actions)
                Write-Verbose "Using federated authentication (GitHub OIDC)"
                
                $result = pac auth create `
                    --name $this.AuthProfileName `
                    --githubFederated `
                    --tenant $this.TenantId `
                    --applicationId $this.ClientId `
                    --environment $this.EnvironmentUrl 2>&1 | Out-String
                
                if ($LASTEXITCODE -ne 0) {
                    throw "Federated authentication failed:`n$result"
                }
            }
            elseif ($this.UseInteractive) {
                # Interactive authentication (local development)
                Write-Verbose "Using interactive authentication"
                Write-Host "You will be prompted to sign in via your browser..." -ForegroundColor Yellow
                
                $result = pac auth create `
                    --name $this.AuthProfileName `
                    --environment $this.EnvironmentUrl 2>&1 | Out-String
                
                if ($LASTEXITCODE -ne 0) {
                    throw "Interactive authentication failed:`n$result"
                }
            }
            else {
                throw "No authentication method configured"
            }
            
            $this.IsAuthenticated = $true
            Write-Verbose "Successfully authenticated to Power Platform"
            Write-Verbose "Auth profile: $($this.AuthProfileName)"
        }
        catch {
            throw "Failed to authenticate: $_"
        }
    }

    # Select this auth profile
    [void] SelectProfile() {
        if (-not $this.IsAuthenticated) {
            throw "Not authenticated. Call Authenticate() first."
        }
        
        $result = pac auth select --name $this.AuthProfileName 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to select auth profile: $result"
        }
    }

    # Get WhoAmI information
    [object] WhoAmI() {
        $this.SelectProfile()
        
        $result = pac org who --json 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw "WhoAmI failed: $result"
        }
        
        return ($result | ConvertFrom-Json)
    }


    # Publish all customizations
    [void] PublishAllCustomizations() {
        $this.SelectProfile()
        
        Write-Verbose "Publishing all customizations..."
        
        $result = pac solution publish 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to publish customizations: $result"
        }
        
        Write-Verbose "Customizations published successfully"
    }

    # Export solution
    [void] ExportSolution([string]$solutionName, [string]$solutionPath) {
        $this.SelectProfile()
        
        Write-Verbose "Exporting solution '$solutionName' to '$solutionPath'..."
        
        # Ensure parent directory exists
        $parentDir = Split-Path -Parent $solutionPath
        if ($parentDir -and -not (Test-Path $parentDir)) {
            New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
        }
        
        # Remove existing file if it exists (pac doesn't support overwrite)
        if (Test-Path $solutionPath) {
            Write-Verbose "Removing existing solution file: $solutionPath"
            Remove-Item $solutionPath -Force
        }
        
        # Run the export command and capture output
        $output = pac solution export `
            --name "$solutionName" `
            --path "$solutionPath" `
            --managed "false" `
            --environment "$($this.EnvironmentUrl)" `
            --async "true" 2>&1
        
        $exitCode = $LASTEXITCODE
        
        Write-Verbose "Export command completed with exit code: $exitCode"
        
        # Always write pac output to console for visibility
        if ($output) {
            Write-Host "pac CLI output:"
            Write-Host ($output | Out-String)
        }
        
        if ($exitCode -ne 0) {
            $errorMessage = "Failed to export solution '$solutionName'. Exit code: $exitCode"
            if ($output) {
                $errorMessage += "`n`npac CLI output:`n" + ($output | Out-String)
            }
            throw $errorMessage
        }
        
        # Verify the file was created
        if (-not (Test-Path $solutionPath)) {
            throw "Export appeared to succeed but solution file was not created at: $solutionPath"
        }
        
        Write-Verbose "Solution exported successfully to: $solutionPath"
    }

    # Import solution
    [void] ImportSolution([string]$solutionPath, [string]$settingsFilePath = "", [bool]$useUpgrade = $false) {
        $this.SelectProfile()
        
        Write-Verbose "Importing solution from '$solutionPath'..."
        if ($settingsFilePath) {
            Write-Verbose "Using deployment settings from '$settingsFilePath'"
        }
        if ($useUpgrade) {
            Write-Verbose "Using single-stage upgrade"
        }
        
        # Verify the file exists before attempting import
        if (-not (Test-Path $solutionPath)) {
            throw "Solution file not found: $solutionPath"
        }
        
        if ($settingsFilePath -and -not (Test-Path $settingsFilePath)) {
            throw "Deployment settings file not found: $settingsFilePath"
        }
        
        # Build import command arguments
        $importArgs = @(
            "solution", "import",
            "--path", $solutionPath,
            "--environment", $this.EnvironmentUrl,
            "--activate-plugins",
            "-a",
            "-wt", "240"  # 4-hour async timeout
        )
        
        if ($settingsFilePath) {
            $importArgs += "--settings-file"
            $importArgs += $settingsFilePath
        }
        
        if ($useUpgrade) {
            $importArgs += "--stage-and-upgrade"
        }
        
        # Run the import command and capture output
        $output = & pac @importArgs 2>&1
        
        $exitCode = $LASTEXITCODE
        
        Write-Verbose "Import command completed with exit code: $exitCode"
        
        # Always write pac output to console for visibility
        if ($output) {
            Write-Host "pac CLI output:"
            Write-Host ($output | Out-String)
        }
        
        if ($exitCode -ne 0) {
            $errorMessage = "Failed to import solution from '$solutionPath'. Exit code: $exitCode"
            if ($output) {
                $errorMessage += "`n`npac CLI output:`n" + ($output | Out-String)
            }
            throw $errorMessage
        }
        
        Write-Verbose "Solution imported successfully"
    }

    # Check if a solution exists in the environment
    [bool] SolutionExists([string]$solutionUniqueName) {
        $this.SelectProfile()
        
        Write-Verbose "Checking if solution '$solutionUniqueName' exists in environment..."
        
        try {
            # List all solutions and look for the unique name
            $output = & pac solution list --environment $this.EnvironmentUrl 2>&1 | Out-String
            $exitCode = $LASTEXITCODE
            
            if ($exitCode -ne 0) {
                Write-Verbose "Failed to list solutions. Exit code: $exitCode"
                Write-Verbose "Output: $output"
                # If we can't determine, assume it doesn't exist (safer to use standard import)
                return $false
            }
            
            # Check if solution unique name appears in the output
            # The list command shows solutions in format with unique names
            $exists = $output -match [regex]::Escape($solutionUniqueName)
            
            Write-Verbose "Solution exists: $exists"
            return $exists
        }
        catch {
            Write-Verbose "Error checking solution existence: $_"
            # If we can't determine, assume it doesn't exist (safer to use standard import)
            return $false
        }
    }

    # Run command with this profile
    [string] RunCommand([string]$command) {
        $this.SelectProfile()
        
        Write-Verbose "Running pac command: $command"
        
        $result = Invoke-Expression "pac $command" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw "Command failed: $result"
        }
        
        return $result
    }

    # Cleanup: Clear auth profile
    [void] ClearAuth() {
        try {
            Write-Verbose "Clearing auth profile: $($this.AuthProfileName)"
            pac auth clear --name $this.AuthProfileName 2>&1 | Out-Null
            $this.IsAuthenticated = $false
        }
        catch {
            Write-Warning "Failed to clear auth profile: $_"
        }
    }

    # Destructor equivalent
    hidden [void] Dispose() {
        $this.ClearAuth()
    }
}
