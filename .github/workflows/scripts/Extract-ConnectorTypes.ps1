<#
.SYNOPSIS
    Extract all unique connector types from solution Customizations.xml files
    
.DESCRIPTION
    Scans all solution Customizations.xml files to find all connector types
    referenced in connection references and flow definitions.
    
.PARAMETER solutionsPath
    Path to the solutions directory (default: ./src/solutions)
    
.EXAMPLE
    .\Extract-ConnectorTypes.ps1
    
.EXAMPLE
    .\Extract-ConnectorTypes.ps1 -solutionsPath "./src/solutions"
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$solutionsPath = "./src/solutions"
)

Write-Host ""
Write-Host "Extracting connector types from solutions..." -ForegroundColor Cyan
Write-Host ""

$connectorTypes = @{}

# Get all Customizations.xml files
$customizationsFiles = Get-ChildItem -Path $solutionsPath -Recurse -Filter "Customizations.xml" -ErrorAction SilentlyContinue

Write-Host "Found $($customizationsFiles.Count) Customizations.xml file(s)" -ForegroundColor Cyan
Write-Host ""

foreach ($file in $customizationsFiles) {
    $solutionName = Split-Path (Split-Path $file.FullName) -Parent | Split-Path -Leaf
    Write-Host "  Processing: $solutionName" -ForegroundColor Gray
    
    try {
        [xml]$xml = Get-Content -Path $file.FullName -Encoding UTF8
        
        # Extract connector IDs from connection references
        $connectorIdNodes = $xml.SelectNodes("//connectorid")
        foreach ($node in $connectorIdNodes) {
            $connectorIdPath = $node.InnerText
            # Extract connector name from path (e.g., "shared_commondataserviceforapps" from full path)
            $connectorName = $connectorIdPath -replace '.*/apis/', ''
            
            if ($connectorName -and -not $connectorTypes.ContainsKey($connectorName)) {
                $connectorTypes[$connectorName] = @{
                    Name = $connectorName
                    FullPath = $connectorIdPath
                    UsedInSolutions = @($solutionName)
                }
            }
            elseif ($connectorName -and -not $connectorTypes[$connectorName].UsedInSolutions.Contains($solutionName)) {
                $connectorTypes[$connectorName].UsedInSolutions += $solutionName
            }
        }
        
        # Also scan for connectors in workflow/flow definitions (look for connectionName or similar)
        $workflowNodes = $xml.SelectNodes("//Workflow")
        foreach ($workflowNode in $workflowNodes) {
            # Look for connection references in workflow definitions
            $connectionNodes = $workflowNode.SelectNodes(".//ConnectionName | .//ConnectionReference")
            foreach ($connNode in $connectionNodes) {
                $connName = $connNode.InnerText
                if ($connName) {
                    # Try to identify connector type from connection name patterns
                    if ($connName -like "*dataverse*" -or $connName -like "*cds*" -or $connName -like "*dynamics*") {
                        $connectorName = "shared_commondataserviceforapps"
                    }
                    elseif ($connName -like "*office365*" -or $connName -like "*outlook*") {
                        $connectorName = "shared_office365"
                    }
                    elseif ($connName -like "*sharepoint*") {
                        $connectorName = "shared_sharepointonline"
                    }
                    # Add other connector type detections as needed
                    
                    if ($connectorName -and -not $connectorTypes.ContainsKey($connectorName)) {
                        $connectorTypes[$connectorName] = @{
                            Name = $connectorName
                            FullPath = "/providers/Microsoft.PowerApps/apis/$connectorName"
                            UsedInSolutions = @($solutionName)
                        }
                    }
                }
            }
        }
    }
    catch {
        Write-Warning "Failed to parse file: $($file.FullName) - $($_.Exception.Message)"
    }
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Found Connector Types" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

$sortedConnectors = $connectorTypes.Values | Sort-Object -Property Name

foreach ($connector in $sortedConnectors) {
    Write-Host "  • $($connector.Name)" -ForegroundColor Green
    Write-Host "    Path: $($connector.FullPath)" -ForegroundColor Gray
    Write-Host "    Used in: $($connector.UsedInSolutions -join ', ')" -ForegroundColor Gray
}

Write-Host ""
Write-Host "Total unique connectors: $($connectorTypes.Count)" -ForegroundColor Cyan
Write-Host ""

# Output as JSON for easy integration
$output = @{}
foreach ($connector in $sortedConnectors) {
    $output[$connector.Name] = $connector.FullPath
}

Write-Host "Connector mappings (JSON format):" -ForegroundColor Cyan
$output | ConvertTo-Json | Write-Host

exit 0
