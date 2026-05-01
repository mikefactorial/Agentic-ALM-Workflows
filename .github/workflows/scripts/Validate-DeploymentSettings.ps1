param(
    [Parameter(Mandatory=$true)]
    [string]$SolutionList,

    [Parameter(Mandatory=$false)]
    [string]$SolutionsRoot = "src/solutions",

    [Parameter(Mandatory=$false)]
    [string]$ConfigPath = "./deployments/settings",

    [Parameter(Mandatory=$true)]
    [string]$TargetEnvironmentList,

    [Parameter(Mandatory=$false)]
    [switch]$StrictMode
)

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Validate Deployment Settings" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

$ErrorActionPreference = "Continue"
$validationErrors = @()

# Load configuration files
$connectionMappingsPath = Join-Path $ConfigPath "connection-mappings.json"
$envVarsPath = Join-Path $ConfigPath "environment-variables.json"

if (-not (Test-Path $connectionMappingsPath)) {
    Write-Error "Connection mappings file not found: $connectionMappingsPath"
    exit 1
}

if (-not (Test-Path $envVarsPath)) {
    Write-Error "Environment variables file not found: $envVarsPath"
    exit 1
}

try {
    $connectionMappings = Get-Content $connectionMappingsPath -Raw | ConvertFrom-Json
    $envVarsConfig = Get-Content $envVarsPath -Raw | ConvertFrom-Json
}
catch {
    Write-Error "Failed to parse configuration files: $($_.Exception.Message)"
    exit 1
}

# Parse and validate target environments
$targetEnvironments = $TargetEnvironmentList -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

if ($targetEnvironments.Count -eq 0) {
    Write-Error "No target environments specified in environment list"
    exit 1
}

# Validate all target environments exist
foreach ($targetEnvironment in $targetEnvironments) {
    if (-not $connectionMappings.environments.PSObject.Properties.Name -contains $targetEnvironment) {
        Write-Error "Target environment '$targetEnvironment' not found in connection-mappings.json"
        exit 1
    }
}

Write-Host "Target Environment(s): $($targetEnvironments -join ', ')" -ForegroundColor White
Write-Host "Solutions to validate: $(($SolutionList -split ',').Count)" -ForegroundColor White
Write-Host ""

# Validate each solution across all target environments
$solutions = $SolutionList -split ',' | ForEach-Object { $_.Trim() }

foreach ($solutionName in $solutions) {
    $solutionPath = Join-Path $SolutionsRoot $solutionName
    $templatePath = Join-Path $ConfigPath "templates" "${solutionName}_template.json"

    Write-Host "Validating: $solutionName" -ForegroundColor Cyan
    Write-Host "─────────────────────────────────────────────────────" -ForegroundColor Cyan

    # Check if template exists
    if (-not (Test-Path $templatePath)) {
        Write-Host "  ⚠️  No deployment settings template found" -ForegroundColor Yellow
        Write-Host ""
        continue
    }

    try {
        $template = Get-Content $templatePath -Raw | ConvertFrom-Json
    }
    catch {
        $msg = "Invalid JSON in template: $($_.Exception.Message)"
        Write-Host "  ❌ $msg" -ForegroundColor Red
        $validationErrors += $msg
        Write-Host ""
        continue
    }

    # Validate for each target environment
    foreach ($targetEnvironment in $targetEnvironments) {
        Write-Host "  Environment: $targetEnvironment" -ForegroundColor Yellow
        
        # Validate Connection References
        $connErrors = 0
        if ($template.ConnectionReferences -and $template.ConnectionReferences.Count -gt 0) {
            Write-Host "    Connection References:" -ForegroundColor Gray
            $envConnections = $connectionMappings.environments.$targetEnvironment

            foreach ($connRef in $template.ConnectionReferences) {
                $logicalName = $connRef.LogicalName
                $connectorId = $connRef.ConnectorId
                
                Write-Host "      $logicalName..." -NoNewline

                if (-not $envConnections.PSObject.Properties.Name -contains $connectorId) {
                    Write-Host " ❌ NOT FOUND" -ForegroundColor Red
                    $msg = "Connection reference '$logicalName' (connector: $connectorId) not found in connection-mappings.json for $targetEnvironment"
                    $validationErrors += $msg
                    $connErrors++
                }
                else {
                    $connectionId = $envConnections.$connectorId

                    # Check for placeholder values (all zeros)
                    if ($connectionId -match "^0+$") {
                        Write-Host " ⚠️  PLACEHOLDER" -ForegroundColor Yellow
                        $msg = "Connection reference '$logicalName' uses placeholder value. Update connection-mappings.json with actual connection ID for $targetEnvironment"
                        $validationErrors += $msg
                        $connErrors++
                    }
                    else {
                        Write-Host " ✓" -ForegroundColor Green
                    }
                }
            }
        }
        else {
            Write-Host "    Connection References: None" -ForegroundColor Gray
        }

        # Validate Environment Variables
        $envVarErrors = 0
        if ($template.EnvironmentVariables -and $template.EnvironmentVariables.Count -gt 0) {
            Write-Host "    Environment Variables:" -ForegroundColor Gray

            $solutionConfig = $null
            if ($envVarsConfig.solutions.PSObject.Properties.Name -contains $solutionName) {
                $solutionConfig = $envVarsConfig.solutions.$solutionName
            }

            foreach ($envVar in $template.EnvironmentVariables) {
                $schemaName = $envVar.SchemaName
                $isRequired = $envVar.IsRequired -eq $true

                Write-Host "      $schemaName$(if ($isRequired) { " (required)" })..." -NoNewline

                $hasValue = $false
                if ($solutionConfig -and $solutionConfig.environments.PSObject.Properties.Name -contains $targetEnvironment) {
                    $envValues = $solutionConfig.environments.$targetEnvironment
                    if ($envValues.PSObject.Properties.Name -contains $schemaName) {
                        $value = $envValues.$schemaName
                        if ($null -ne $value -and $value -ne "" -and $value -ne "<unset>") {
                            $hasValue = $true
                        }
                    }
                }

                if (-not $hasValue) {
                    if ($isRequired -or $StrictMode) {
                        Write-Host " ❌ MISSING" -ForegroundColor Red
                        $msg = "Environment variable '$schemaName' for solution '$solutionName' has no value for $targetEnvironment"
                        $validationErrors += $msg
                        $envVarErrors++
                    }
                    else {
                        Write-Host " ⚠️  Not configured" -ForegroundColor Yellow
                    }
                }
                else {
                    Write-Host " ✓" -ForegroundColor Green
                }
            }
        }
        else {
            Write-Host "    Environment Variables: None" -ForegroundColor Gray
        }

        if ($connErrors -gt 0 -or $envVarErrors -gt 0) {
            Write-Host "    Status: ❌ $connErrors connection error(s), $envVarErrors env var error(s)" -ForegroundColor Red
        }
        else {
            Write-Host "    Status: ✓ All settings valid" -ForegroundColor Green
        }
        
        Write-Host ""
    }
}

# Summary
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Validation Summary" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

if ($validationErrors.Count -gt 0) {
    Write-Host "❌ Found $($validationErrors.Count) validation error(s):" -ForegroundColor Red
    Write-Host ""
    foreach ($error in $validationErrors) {
        Write-Host "  • $error" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "Please fix these issues before deploying:" -ForegroundColor Yellow
    Write-Host "  1. Update connection-mappings.json with actual connection IDs (use 'pac connection list')" -ForegroundColor Gray
    Write-Host "  2. Configure required environment variables in environment-variables.json" -ForegroundColor Gray
    Write-Host ""
    exit 1
}
else {
    if ($StrictMode) {
        Write-Host "✓ All deployment settings are valid (strict mode)!" -ForegroundColor Green
    } else {
        Write-Host "✓ All deployment settings are valid!" -ForegroundColor Green
    }
    Write-Host ""
}
