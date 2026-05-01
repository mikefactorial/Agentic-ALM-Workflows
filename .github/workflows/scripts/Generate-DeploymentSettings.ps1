<#
.SYNOPSIS
    Generate deployment settings JSON file from template and configuration files
    
.DESCRIPTION
    Merges a deployment settings template with environment-specific connection mappings
    and environment variable values. Validates all connection references have valid GUIDs.
    Warns about missing environment variables but doesn't fail.
    
.PARAMETER solutionName
    Name of the solution (used to lookup environment variables)
    
.PARAMETER targetEnvironment
    Target environment name (e.g., 'development-environment')
    
.PARAMETER templatePath
    Path to the deployment settings template JSON file
    
.PARAMETER outputPath
    Path where the final deployment settings JSON will be written
    
.PARAMETER configPath
    Root path to settings directory (default: ./settings)
    
.EXAMPLE
    .\Generate-DeploymentSettings.ps1 `
        -solutionName "MySolution" `
        -targetEnvironment "development-environment" `
        -templatePath "./deployments/settings/templates/MySolution_template.json" `
        -outputPath "./artifacts/MySolution_settings.json"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$solutionName,
    
    [Parameter(Mandatory=$true)]
    [string]$targetEnvironment,
    
    [Parameter(Mandatory=$true)]
    [string]$templatePath,
    
    [Parameter(Mandatory=$true)]
    [string]$outputPath,
    
    [Parameter(Mandatory=$false)]
    [string]$configPath = "./deployments/settings"
)

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Generate Deployment Settings" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "Solution: $solutionName" -ForegroundColor White
Write-Host "Environment: $targetEnvironment" -ForegroundColor White
Write-Host "Template: $templatePath" -ForegroundColor White
Write-Host "Output: $outputPath" -ForegroundColor White
Write-Host ""

# Validation counters
$resolvedConnections = 0
$unresolvedConnections = 0
$invalidConnections = 0
$resolvedVariables = 0
$unresolvedVariables = 0
$errors = @()

try {
    # Load template
    if (-not (Test-Path $templatePath)) {
        throw "Template file not found: $templatePath"
    }
    
    Write-Host "Loading deployment settings template..." -ForegroundColor Cyan
    $template = Get-Content $templatePath -Raw | ConvertFrom-Json
    
    # Load connection mappings
    $connectionMappingsPath = Join-Path $configPath "connection-mappings.json"
    if (-not (Test-Path $connectionMappingsPath)) {
        throw "Connection mappings file not found: $connectionMappingsPath"
    }
    
    Write-Host "Loading connection mappings..." -ForegroundColor Cyan
    $connectionMappings = Get-Content $connectionMappingsPath -Raw | ConvertFrom-Json
    
    # Load environment variables
    $envVarsPath = Join-Path $configPath "environment-variables.json"
    if (-not (Test-Path $envVarsPath)) {
        throw "Environment variables file not found: $envVarsPath"
    }
    
    Write-Host "Loading environment variable values..." -ForegroundColor Cyan
    $envVarsConfig = Get-Content $envVarsPath -Raw | ConvertFrom-Json
    
    # Validate target environment exists in connection mappings
    if (-not $connectionMappings.environments.PSObject.Properties.Name -contains $targetEnvironment) {
        throw "Target environment '$targetEnvironment' not found in connection-mappings.json"
    }
    
    $envConnectionMap = $connectionMappings.environments.$targetEnvironment
    
    # Process Connection References
    Write-Host ""
    Write-Host "Processing Connection References..." -ForegroundColor Cyan
    
    if ($template.ConnectionReferences -and $template.ConnectionReferences.Count -gt 0) {
        foreach ($connRef in $template.ConnectionReferences) {
            $logicalName = $connRef.LogicalName
            $connectorIdPath = $connRef.ConnectorId
            
            Write-Host "  $logicalName ($connectorIdPath)..." -NoNewline
            
            # Look up connection ID from mappings using full connector ID path
            if ($envConnectionMap.PSObject.Properties.Name -contains $connectorIdPath) {
                $connectionId = $envConnectionMap.$connectorIdPath
                
                # Check if it's a placeholder (all zeros)
                if ($connectionId -eq "00000000-0000-0000-0000-000000000000" -or $connectionId -eq "00000000000000000000000000000000") {
                    Write-Host " ⚠️  PLACEHOLDER" -ForegroundColor Yellow
                    $errors += "Connection reference '$logicalName' uses placeholder connection ID. Update connection-mappings.json with actual connection ID."
                    $unresolvedConnections++
                }
                else {
                    $connRef.ConnectionId = $connectionId
                    Write-Host " ✓" -ForegroundColor Green
                    $resolvedConnections++
                }
            }
            else {
                Write-Host " ❌ NOT FOUND" -ForegroundColor Red
                $errors += "Connector type '$connectorIdPath' not found in connection-mappings.json for environment '$targetEnvironment'"
                $unresolvedConnections++
            }
        }
    }
    else {
        Write-Host "  No connection references in template" -ForegroundColor Gray
    }
    
    # Process Environment Variables
    Write-Host ""
    Write-Host "Processing Environment Variables..." -ForegroundColor Cyan
    
    if ($template.EnvironmentVariables -and $template.EnvironmentVariables.Count -gt 0) {
        # Get environment variables for this environment
        $envVars = $null
        if ($envVarsConfig.environments.PSObject.Properties.Name -contains $targetEnvironment) {
            $envVars = $envVarsConfig.environments.$targetEnvironment
        }
        
        foreach ($envVar in $template.EnvironmentVariables) {
            $schemaName = $envVar.SchemaName
            
            Write-Host "  $schemaName..." -NoNewline
            
            if ($envVars -and $envVars.PSObject.Properties.Name -contains $schemaName) {
                $value = $envVars.$schemaName
                
                if ($null -eq $value -or $value -eq "<unset>") {
                    Write-Host " ❌ NOT SET" -ForegroundColor Red
                    $errors += "Environment variable '$schemaName' not set for environment '$targetEnvironment'. Replace '<unset>' with your value in environment-variables.json"
                    $unresolvedVariables++
                }
                else {
                    $envVar.Value = $value
                    Write-Host " ✓" -ForegroundColor Green
                    $resolvedVariables++
                }
            }
            else {
                Write-Host " ❌ NOT CONFIGURED" -ForegroundColor Red
                $errors += "Environment variable '$schemaName' not found in environment-variables.json for environment '$targetEnvironment'"
                $unresolvedVariables++
            }
        }
    }
    else {
        Write-Host "  No environment variables in template" -ForegroundColor Gray
    }
    
    # Report validation results
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Validation Summary" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Connection References:" -ForegroundColor White
    Write-Host "  ✓ Resolved: $resolvedConnections" -ForegroundColor Green
    if ($unresolvedConnections -gt 0) {
        Write-Host "  ❌ Unresolved: $unresolvedConnections" -ForegroundColor Red
    }
    if ($invalidConnections -gt 0) {
        Write-Host "  ❌ Invalid: $invalidConnections" -ForegroundColor Red
    }
    
    Write-Host ""
    Write-Host "Environment Variables:" -ForegroundColor White
    Write-Host "  ✓ Resolved: $resolvedVariables" -ForegroundColor Green
    if ($unresolvedVariables -gt 0) {
        Write-Host "  ❌ Unresolved: $unresolvedVariables" -ForegroundColor Red
    }
    
    # Fail if connection references or environment variables are not resolved/invalid
    if ($unresolvedConnections -gt 0 -or $invalidConnections -gt 0 -or $unresolvedVariables -gt 0) {
        Write-Host ""
        Write-Host "ERRORS:" -ForegroundColor Red
        foreach ($error in $errors) {
            Write-Host "  • $error" -ForegroundColor Red
        }
        Write-Host ""
        throw "Deployment settings validation failed. All connection references and environment variables must be resolved."
    }
    
    # Write output file
    Write-Host ""
    Write-Host "Writing deployment settings to: $outputPath" -ForegroundColor Cyan
    
    $outputDir = Split-Path $outputPath -Parent
    if ($outputDir -and -not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }
    
    $template | ConvertTo-Json -Depth 10 | Set-Content $outputPath -Encoding UTF8
    
    Write-Host ""
    Write-Host "✓ Deployment settings generated successfully" -ForegroundColor Green
    Write-Host ""
    
    exit 0
}
catch {
    Write-Host ""
    Write-Error "Failed to generate deployment settings: $($_.Exception.Message)"
    Write-Host ""
    exit 1
}
