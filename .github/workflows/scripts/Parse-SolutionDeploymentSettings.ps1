<#
.SYNOPSIS
    Generate deployment settings from solution XML files
    
.DESCRIPTION
    Parses a solution's Customizations.xml and Solution.xml files to extract
    environment variables and connection references, then generates a deployment 
    settings JSON file. Does not require plugin DLLs or pac tool dependencies.
    
.PARAMETER solutionPath
    Path to the solution directory containing src/Other/
    
.PARAMETER outputPath
    Path where the deploymentSettings.json will be written (default: solution directory)
    
.EXAMPLE
    .\Parse-SolutionDeploymentSettings.ps1 -solutionPath "./src/solutions/MySolution"
    
.EXAMPLE
    .\Parse-SolutionDeploymentSettings.ps1 `
        -solutionPath "./src/solutions/MySolution" `
        -outputPath "./artifacts/MySolution_settings.json"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$solutionPath,
    
    [Parameter(Mandatory=$false)]
    [string]$outputPath = ""
)

Write-Host ""
Write-Host "Parsing deployment settings from solution..." -ForegroundColor Cyan

$ErrorActionPreference = "Stop"

# Resolve solution path
$solutionPath = Resolve-Path $solutionPath -ErrorAction Stop
$customizationsPath = Join-Path $solutionPath "src\Other\Customizations.xml"
$solutionXmlPath = Join-Path $solutionPath "src\Other\Solution.xml"

if (-not (Test-Path $customizationsPath)) {
    Write-Error "Customizations.xml not found: $customizationsPath"
    exit 1
}

# Load XML files
[xml]$customizationsXml = Get-Content -Path $customizationsPath -Encoding UTF8
[xml]$solutionXml = Get-Content -Path $solutionXmlPath -Encoding UTF8

$environmentVariables = @()
$connectionReferences = @()
$envVarMetadata = @{}  # Store metadata separately for documentation purposes

# Extract Connection References from customizations.xml
Write-Host "  Scanning connection references..." -ForegroundColor Gray

$connectionRefNodes = $customizationsXml.SelectNodes("//connectionreference")

foreach ($refNode in $connectionRefNodes) {
    $logicalName = $refNode.GetAttribute("connectionreferencelogicalname")
    $connectorIdNode = $refNode.SelectSingleNode("connectorid")
    $connectorIdPath = if ($connectorIdNode) { $connectorIdNode.InnerText } else { "/providers/Microsoft.PowerApps/apis/shared_commondataserviceforapps" }
    
    if ($logicalName -and -not [string]::IsNullOrWhiteSpace($connectorIdPath)) {
        $connectionReferences += @{
            LogicalName = $logicalName
            ConnectionId = ""  # Placeholder - lookup based on ConnectorId, will be populated during deployment
            ConnectorId = $connectorIdPath
        }
    }
}

# Extract Environment Variable schema names from Solution.xml RootComponents
# Environment variable definitions are listed as dependencies with schemaName starting with specific patterns
Write-Host "  Scanning environment variables..." -ForegroundColor Gray

# Function to map environment variable type codes to friendly names
function Get-EnvironmentVariableType {
    param([string]$typeCode)
    
    switch ($typeCode) {
        "100000000" { return "String" }
        "100000001" { return "Number" }
        "100000002" { return "Boolean" }
        "100000003" { return "JSON" }
        "100000004" { return "Secret" }
        default { return "String" }
    }
}

# Look for environment variable definition files in the solution directory
$evDefinitionPath = Join-Path $solutionPath "src\environmentvariabledefinitions"

if (Test-Path $evDefinitionPath) {
    Write-Host "    Found environmentvariabledefinitions folder" -ForegroundColor Gray
    $evDefFolders = Get-ChildItem -Path $evDefinitionPath -Directory -ErrorAction SilentlyContinue
    
    foreach ($evFolder in $evDefFolders) {
        $evFile = Join-Path $evFolder.FullName "environmentvariabledefinition.xml"
        
        if (Test-Path $evFile) {
            try {
                [xml]$evXml = Get-Content -Path $evFile -Encoding UTF8 -ErrorAction Stop
                $evDef = $evXml.environmentvariabledefinition
                
                if ($evDef) {
                    $schemaName = $evDef.schemaname
                    
                    if ($schemaName -and -not ($environmentVariables | Where-Object { $_.SchemaName -eq $schemaName })) {
                        # Extract metadata
                        $displayName = $evDef.displayname.label.description ?? $evDef.displayname.default ?? $schemaName
                        $description = $evDef.description.label.description ?? $evDef.description.default ?? ""
                        $defaultValue = $evDef.defaultvalue ?? ""
                        $typeCode = $evDef.type ?? "100000000"
                        $type = Get-EnvironmentVariableType -typeCode $typeCode
                        
                        # Store metadata separately (used for documentation in environment-variables.json)
                        $envVarMetadata[$schemaName] = @{
                            DisplayName = $displayName
                            Description = $description
                            Type = $type
                            DefaultValue = $defaultValue
                        }
                        
                        # Template only needs SchemaName and Value for deployment
                        $environmentVariables += @{
                            SchemaName = $schemaName
                            Value = ""  # Will be populated during deployment from environment-variables.json
                        }
                        
                        Write-Host "      Found: $schemaName ($displayName)" -ForegroundColor Gray
                    }
                }
            }
            catch {
                Write-Warning "    Failed to parse $($evFile): $($_.Exception.Message)"
                continue
            }
        }
    }
}

# Fallback: Look in other XML files for environment variable references
$allXmlFiles = Get-ChildItem -Path $solutionPath -Recurse -Filter "*.xml" -ErrorAction SilentlyContinue

foreach ($xmlFile in $allXmlFiles) {
    try {
        [xml]$xmlContent = Get-Content -Path $xmlFile.FullName -Encoding UTF8 -ErrorAction SilentlyContinue
        
        # Look for environment variable definitions
        $evNodes = $xmlContent.SelectNodes("//*[contains(local-name(), 'environmentvariable')]")
        
        foreach ($evNode in $evNodes) {
            # Check for schemaname attribute or child element
            $schemaName = $evNode.schemaname ?? $evNode.SelectSingleNode("schemaname")?.InnerText ?? $null
            
            if ($schemaName) {
                # Ensure we don't have duplicates
                if (-not ($environmentVariables | Where-Object { $_.SchemaName -eq $schemaName })) {
                    $environmentVariables += @{
                        SchemaName = $schemaName
                        Value = ""  # Will be populated during deployment from environment-variables.json
                    }
                }
            }
        }
    }
    catch {
        # Skip files that can't be parsed as XML
        continue
    }
}

# Build deployment settings object
$deploymentSettings = @{
    EnvironmentVariables = @()
    ConnectionReferences = @()
}

# Add environment variables
if ($environmentVariables.Count -gt 0) {
    $deploymentSettings.EnvironmentVariables = @($environmentVariables | ForEach-Object {
        [PSCustomObject]@{
            SchemaName = $_.SchemaName
            Value = $_.Value
        }
    })
}

# Add connection references
if ($connectionReferences.Count -gt 0) {
    $deploymentSettings.ConnectionReferences = @($connectionReferences | ForEach-Object {
        [PSCustomObject]@{
            LogicalName = $_.LogicalName
            ConnectionId = $_.ConnectionId
            ConnectorId = $_.ConnectorId
        }
    })
}

# Add environment variable metadata (type, display name, default value, description)
# This is used by Sync-Solution.ps1 to populate environment-variables.json metadata section
if ($envVarMetadata.Count -gt 0) {
    $metaObj = [PSCustomObject]@{}
    foreach ($key in ($envVarMetadata.Keys | Sort-Object)) {
        $m = $envVarMetadata[$key]
        $metaObj | Add-Member -NotePropertyName $key -NotePropertyValue ([PSCustomObject]@{
            displayName  = $m.DisplayName
            schemaName   = $key
            type         = $m.Type
            defaultValue = $m.DefaultValue
            description  = $m.Description
        }) -Force
    }
    $deploymentSettings['Metadata'] = $metaObj
}

# Determine output path
if ([string]::IsNullOrWhiteSpace($outputPath)) {
    $solutionName = Split-Path $solutionPath -Leaf
    $outputPath = Join-Path $solutionPath "deploymentSettings.json"
}

# Ensure output directory exists
$outputDir = Split-Path $outputPath -Parent
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

# Convert to JSON with proper formatting
$json = ConvertTo-Json -InputObject $deploymentSettings -Depth 10

# Write to file
Set-Content -Path $outputPath -Value $json -Encoding UTF8

Write-Host "  Generated: $outputPath (EVs: $($environmentVariables.Count), Connections: $($connectionReferences.Count))" -ForegroundColor Green

exit 0
