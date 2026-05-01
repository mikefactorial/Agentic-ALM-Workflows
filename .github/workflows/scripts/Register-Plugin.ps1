<#
.SYNOPSIS
    Registers plugin packages/assemblies and steps in a Dataverse environment.

.DESCRIPTION
    Replaces the Plugin Registration Tool (PRT) for inner-loop development.
    Pushes plugin packages/assemblies via pac plugin push, registers steps
    and images via Dataverse Web API, registers custom APIs, and optionally
    adds components to a feature solution.

    Uses existing solution metadata XML as the source of truth:
    - SdkMessageProcessingSteps/*.xml for step + image registration
    - pluginpackages/*/pluginpackage.xml for plugin package metadata
    - PluginAssemblies/*/*.data.xml for legacy assembly metadata
    - customapis/**/customapi.xml for custom API registration

    Authentication: interactive (pac auth profile) for local/agent use,
    federated (OIDC) for CI via optional -TenantId/-ClientId.

    Modes:
      A) FromXml  — Push plugin binary + register steps from solution XML
      B) Step     — Register a single step (for new plugins)
      C) CustomApi — Register custom APIs from solution XML

.EXAMPLE
    # Push a plugin package and register all its steps from solution XML
    .\Register-Plugin.ps1 -EnvironmentUrl "https://org.crm.dynamics.com" `
        -SolutionPath "src/solutions/pub_MySolution" `
        -PluginName "pub_Publisher.Plugins.MySolution.Core" `
        -RegisterSteps -SolutionName "my_feature"

.EXAMPLE
    # Push only (no step registration)
    .\Register-Plugin.ps1 -EnvironmentUrl "https://org.crm.dynamics.com" `
        -SolutionPath "src/solutions/pub_MySolution" `
        -PluginName "pub_Publisher.Plugins.MySolution.Core" `
        -PluginFile "src/plugins/pub_MySolution/Publisher.Plugins.Core/bin/Debug/pub_Publisher.Plugins.MySolution.Core.1.0.0.nupkg"

.EXAMPLE
    # Register a single new step
    .\Register-Plugin.ps1 -EnvironmentUrl "https://org.crm.dynamics.com" `
        -PluginType "Publisher.Plugins.MySolution.Core.MyPlugin" `
        -Message "Create" -PrimaryEntity "pub_sample" `
        -Stage 40 -StepMode 0 -SolutionName "my_feature"

.EXAMPLE
    # Register custom APIs from solution XML
    .\Register-Plugin.ps1 -EnvironmentUrl "https://org.crm.dynamics.com" `
        -CustomApiPath "src/solutions/pub_MySolution/src/customapis/pub_MyCustomApi" `
        -SolutionName "my_feature"
#>
[CmdletBinding(DefaultParameterSetName = 'FromXml')]
param(
    [Parameter(Mandatory)]
    [string]$EnvironmentUrl,

    [string]$TenantId,
    [string]$ClientId,

    # Feature solution to auto-add components to
    [string]$SolutionName,

    # --- Mode A: Push + register from solution XML ---
    [Parameter(ParameterSetName = 'FromXml', Mandatory)]
    [string]$SolutionPath,

    [Parameter(ParameterSetName = 'FromXml', Mandatory)]
    [string]$PluginName,

    [Parameter(ParameterSetName = 'FromXml')]
    [string]$PluginFile,

    [Parameter(ParameterSetName = 'FromXml')]
    [switch]$RegisterSteps,

    [Parameter(ParameterSetName = 'FromXml')]
    [switch]$SkipPush,

    # --- Mode B: Individual step registration ---
    [Parameter(ParameterSetName = 'Step', Mandatory)]
    [string]$PluginType,

    [Parameter(ParameterSetName = 'Step', Mandatory)]
    [string]$Message,

    [Parameter(ParameterSetName = 'Step', Mandatory)]
    [string]$PrimaryEntity,

    [Parameter(ParameterSetName = 'Step', Mandatory)]
    [ValidateSet(10, 20, 40)]
    [int]$Stage,

    [Parameter(ParameterSetName = 'Step')]
    [ValidateSet(0, 1)]
    [int]$StepMode = 0,

    [Parameter(ParameterSetName = 'Step')]
    [int]$Rank = 1,

    [Parameter(ParameterSetName = 'Step')]
    [string]$FilteringAttributes,

    [Parameter(ParameterSetName = 'Step')]
    [switch]$AsyncAutoDelete,

    [Parameter(ParameterSetName = 'Step')]
    [string]$PreImageAttributes,

    [Parameter(ParameterSetName = 'Step')]
    [string]$PostImageAttributes,

    # --- Mode C: Custom API registration ---
    [Parameter(ParameterSetName = 'CustomApi', Mandatory)]
    [string]$CustomApiPath
)

$ErrorActionPreference = 'Stop'

# Source the Dataverse API client
. "$PSScriptRoot/DataverseApiClient.ps1"

# Script-level caches
$script:SdkMessageCache = $null

#region Helper Functions

function Initialize-ApiClient {
    <# Creates a DataverseApiClient using interactive or federated auth.
       If -TenantId is supplied without -ClientId, uses the tenant-scoped interactive
       constructor so guest-account users get a token for the correct tenant. #>
    param([string]$EnvironmentUrl, [string]$TenantId, [string]$ClientId)

    if ($TenantId -and $ClientId) {
        Write-Host "Authenticating with federated credentials..."
        return [DataverseApiClient]::new($TenantId, $ClientId, $EnvironmentUrl)
    }
    elseif ($TenantId) {
        Write-Host "Authenticating interactively (tenant-scoped: $TenantId)..."
        Write-Host "Tip: ensure you ran 'Connect-AzAccount -TenantId $TenantId' first." -ForegroundColor Yellow
        return [DataverseApiClient]::new($EnvironmentUrl, $TenantId)
    }
    else {
        Write-Host "Authenticating with interactive pac auth profile..."
        return [DataverseApiClient]::new($EnvironmentUrl)
    }
}

function New-DataverseRecord {
    <# Creates a record via Dataverse Web API and returns the new record GUID.
       Uses Invoke-WebRequest to capture the OData-EntityId response header. #>
    param(
        [DataverseApiClient]$Client,
        [string]$EntityName,
        [hashtable]$Data
    )

    $Client.EnsureValidToken()
    $url = "https://$($Client.DataverseHost)/api/data/v9.2/$EntityName"
    $headers = @{
        "Authorization"    = "Bearer $($Client.AccessToken)"
        "Content-Type"     = "application/json"
        "OData-MaxVersion" = "4.0"
        "OData-Version"    = "4.0"
    }
    $body = $Data | ConvertTo-Json -Depth 10

    $response = Invoke-WebRequest -Uri $url -Method Post -Headers $headers -Body $body -UseBasicParsing
    # Headers may be IEnumerable<string> in PowerShell 7 — coerce to a single string
    $entityIdHeader = $response.Headers['OData-EntityId']
    if ($entityIdHeader -is [System.Collections.IEnumerable] -and $entityIdHeader -isnot [string]) {
        $entityIdHeader = $entityIdHeader | Select-Object -First 1
    }
    if ([string]$entityIdHeader -match '\(([0-9a-fA-F-]+)\)') {
        return $Matches[1]
    }
    throw "Failed to extract record ID from OData-EntityId header for '$EntityName'"
}

function Initialize-SdkMessageCache {
    <# Builds a bidirectional lookup (name→guid, guid→name) for all SDK messages. #>
    param([DataverseApiClient]$Client)

    if ($script:SdkMessageCache) { return }
    Write-Host "  Building SDK message cache..."
    $messages = $Client.RetrieveMultiple('sdkmessages', "?`$select=sdkmessageid,name")
    $script:SdkMessageCache = @{}
    foreach ($msg in $messages) {
        $script:SdkMessageCache[$msg.name] = $msg.sdkmessageid
        $script:SdkMessageCache[$msg.sdkmessageid] = $msg.name
    }
    Write-Host "  Cached $($messages.Count) SDK messages"
}

function Get-SdkMessageId {
    <# Returns the SDK message GUID for a given message name. #>
    param([DataverseApiClient]$Client, [string]$MessageName)

    Initialize-SdkMessageCache -Client $Client
    $id = $script:SdkMessageCache[$MessageName]
    if (-not $id) { throw "SDK message '$MessageName' not found" }
    return $id
}

function Get-SdkMessageName {
    <# Returns the SDK message name for a given GUID. #>
    param([DataverseApiClient]$Client, [string]$MessageId)

    Initialize-SdkMessageCache -Client $Client
    return $script:SdkMessageCache[$MessageId]
}

function Get-SdkMessageFilterId {
    <# Resolves the SdkMessageFilter by message ID + primary entity. #>
    param([DataverseApiClient]$Client, [string]$SdkMessageId, [string]$PrimaryEntity)

    if (-not $PrimaryEntity -or $PrimaryEntity -eq 'none') { return $null }
    $filter = "_sdkmessageid_value eq $SdkMessageId and primaryobjecttypecode eq '$PrimaryEntity'"
    $results = $Client.RetrieveMultiple('sdkmessagefilters', "?`$filter=$filter&`$select=sdkmessagefilterid")
    if ($results.Count -eq 0) {
        Write-Warning "No SdkMessageFilter for message $SdkMessageId on entity '$PrimaryEntity'"
        return $null
    }
    return $results[0].sdkmessagefilterid
}

function Resolve-PluginTypeId {
    <# Resolves a plugin type to its GUID by export key or typename. #>
    param(
        [DataverseApiClient]$Client,
        [string]$ExportKey,
        [string]$TypeName
    )

    if ($ExportKey) {
        $results = $Client.RetrieveMultiple('plugintypes',
            "?`$filter=plugintypeexportkey eq '$ExportKey'&`$select=plugintypeid,typename")
    }
    elseif ($TypeName) {
        # Extract just the class name if assembly-qualified (e.g., "Ns.Class, Assembly, ...")
        $cleanName = ($TypeName -split ',')[0].Trim()
        $results = $Client.RetrieveMultiple('plugintypes',
            "?`$filter=typename eq '$cleanName'&`$select=plugintypeid,typename")
    }
    else {
        throw "Either ExportKey or TypeName must be provided"
    }

    if (-not $results -or $results.Count -eq 0) {
        $identifier = if ($ExportKey) { "export key $ExportKey" } else { "typename $TypeName" }
        throw "Plugin type not found for $identifier. Ensure the plugin is deployed to the environment."
    }
    return $results[0].plugintypeid
}

function Find-ExistingStep {
    <# Finds an existing step by plugin type + message + filter + stage. #>
    param(
        [DataverseApiClient]$Client,
        [string]$PluginTypeId,
        [string]$SdkMessageId,
        [string]$SdkMessageFilterId,
        [int]$Stage
    )

    $filter = "_plugintypeid_value eq $PluginTypeId and _sdkmessageid_value eq $SdkMessageId and stage eq $Stage"
    if ($SdkMessageFilterId) {
        $filter += " and _sdkmessagefilterid_value eq $SdkMessageFilterId"
    }
    $results = $Client.RetrieveMultiple('sdkmessageprocessingsteps',
        "?`$filter=$filter&`$select=sdkmessageprocessingstepid,name")
    if ($results.Count -gt 0) { return $results[0] }
    return $null
}

function Register-SingleStep {
    <# Creates or updates a single SDK message processing step. Returns the step GUID. #>
    param(
        [DataverseApiClient]$Client,
        [string]$Name,
        [string]$PluginTypeId,
        [string]$SdkMessageId,
        [string]$SdkMessageFilterId,
        [int]$Stage,
        [int]$Mode,
        [int]$Rank,
        [string]$FilteringAttributes,
        [bool]$AsyncAutoDelete,
        [string]$FeatureSolution
    )

    $existing = Find-ExistingStep -Client $Client -PluginTypeId $PluginTypeId `
        -SdkMessageId $SdkMessageId -SdkMessageFilterId $SdkMessageFilterId -Stage $Stage

    $stepData = @{
        "name"                    = $Name
        "stage"                   = $Stage
        "mode"                    = $Mode
        "rank"                    = $Rank
        "supporteddeployment"     = 0
        "asyncautodelete"         = $AsyncAutoDelete
        "plugintypeid@odata.bind" = "/plugintypes($PluginTypeId)"
        "sdkmessageid@odata.bind" = "/sdkmessages($SdkMessageId)"
    }

    if ($SdkMessageFilterId) {
        $stepData["sdkmessagefilterid@odata.bind"] = "/sdkmessagefilters($SdkMessageFilterId)"
    }

    if ($FilteringAttributes) {
        $stepData["filteringattributes"] = $FilteringAttributes
    }

    if ($existing) {
        Write-Host "    Updating step: $Name"
        # Remove odata.bind fields for update — lookup bindings can't be PATCHed
        $updateData = @{}
        foreach ($key in $stepData.Keys) {
            if ($key -notlike '*@odata.bind') {
                $updateData[$key] = $stepData[$key]
            }
        }
        $Client.Update('sdkmessageprocessingsteps', $existing.sdkmessageprocessingstepid, $updateData)
        $stepId = $existing.sdkmessageprocessingstepid
    }
    else {
        Write-Host "    Creating step: $Name"
        $stepId = New-DataverseRecord -Client $Client -EntityName 'sdkmessageprocessingsteps' -Data $stepData
    }

    if ($FeatureSolution -and $stepId) {
        $Client.AddComponentToSolution($stepId, 92, $FeatureSolution, $false) | Out-Null
    }

    return $stepId
}

function Register-StepImage {
    <# Creates a step image (Pre/Post) for a given step. #>
    param(
        [DataverseApiClient]$Client,
        [string]$StepId,
        [string]$ImageName,
        [string]$EntityAlias,
        [int]$ImageType,  # 0=Pre, 1=Post, 2=Both
        [string]$Attributes,
        [string]$MessagePropertyName = 'Target'
    )

    # Check for existing image
    $filter = "_sdkmessageprocessingstepid_value eq $StepId and entityalias eq '$EntityAlias'"
    $existing = $Client.RetrieveMultiple('sdkmessageprocessingstepimages',
        "?`$filter=$filter&`$select=sdkmessageprocessingstepimageid")

    $imageData = @{
        "name"                = $ImageName
        "entityalias"         = $EntityAlias
        "imagetype"           = $ImageType
        "messagepropertyname" = $MessagePropertyName
        "sdkmessageprocessingstepid@odata.bind" = "/sdkmessageprocessingsteps($StepId)"
    }

    if ($Attributes) {
        $imageData["attributes"] = $Attributes
    }

    if ($existing -and $existing.Count -gt 0) {
        Write-Host "      Updating image: $EntityAlias"
        $updateData = @{}
        foreach ($key in $imageData.Keys) {
            if ($key -notlike '*@odata.bind') {
                $updateData[$key] = $imageData[$key]
            }
        }
        $Client.Update('sdkmessageprocessingstepimages', $existing[0].sdkmessageprocessingstepimageid, $updateData)
    }
    else {
        Write-Host "      Creating image: $EntityAlias"
        New-DataverseRecord -Client $Client -EntityName 'sdkmessageprocessingstepimages' -Data $imageData | Out-Null
    }
}

function Get-PluginRecordId {
    <# Looks up a plugin package or assembly record by name. Returns (type, id) or $null. #>
    param([DataverseApiClient]$Client, [string]$PluginName)

    # Try plugin packages first
    $results = $Client.RetrieveMultiple('pluginpackages',
        "?`$filter=name eq '$PluginName'&`$select=pluginpackageid,name")
    if ($results.Count -gt 0) {
        return @{ Type = 'Nuget'; Id = $results[0].pluginpackageid }
    }

    # Try plugin assemblies
    $results = $Client.RetrieveMultiple('pluginassemblies',
        "?`$filter=name eq '$PluginName'&`$select=pluginassemblyid,name")
    if ($results.Count -gt 0) {
        return @{ Type = 'Assembly'; Id = $results[0].pluginassemblyid }
    }

    return $null
}

function Get-PluginTypes {
    <# Returns all plugin types belonging to a package or assembly. #>
    param(
        [DataverseApiClient]$Client,
        [string]$PluginRecordId,
        [string]$PluginRecordType  # 'Nuget' or 'Assembly'
    )

    if ($PluginRecordType -eq 'Nuget') {
        $filter = "_pluginpackageid_value eq $PluginRecordId"
    }
    else {
        $filter = "_pluginassemblyid_value eq $PluginRecordId"
    }
    return $Client.RetrieveMultiple('plugintypes',
        "?`$filter=$filter&`$select=plugintypeid,typename,plugintypeexportkey")
}

function Push-PluginBinary {
    <# Pushes a plugin binary via pac plugin push. #>
    param(
        [string]$PluginFile,
        [string]$PluginId,
        [string]$PluginType,  # 'Nuget' or 'Assembly'
        [string]$EnvironmentUrl
    )

    if (-not (Test-Path $PluginFile)) {
        throw "Plugin file not found: $PluginFile"
    }

    Write-Host "  Pushing plugin: $PluginFile"
    Write-Host "    Type: $PluginType | ID: $PluginId"

    $pacArgs = @(
        'plugin', 'push',
        '--pluginFile', $PluginFile,
        '--type', $PluginType,
        '--pluginId', $PluginId
    )
    if ($EnvironmentUrl) {
        $pacArgs += '--environment', $EnvironmentUrl
    }

    $output = & pac @pacArgs 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        Write-Error "pac plugin push failed (exit code $exitCode):`n$output"
        throw "pac plugin push failed"
    }
    Write-Host "  Push successful" -ForegroundColor Green
    return $output
}

function Find-PluginMetadata {
    <# Finds plugin metadata (package or assembly) in the solution path by name. #>
    param([string]$SolutionPath, [string]$PluginName)

    # Check plugin packages
    $packagePath = Join-Path $SolutionPath "src/pluginpackages/$PluginName/pluginpackage.xml"
    if (Test-Path $packagePath) {
        [xml]$xml = Get-Content $packagePath -Raw
        $pkg = $xml.pluginpackage
        return @{
            MetadataType = 'Nuget'
            Name         = $pkg.name
            UniqueName   = $pkg.uniquename
            FileName     = $pkg.package.'#text'
            XmlPath      = $packagePath
        }
    }

    # Check plugin assemblies (directory names contain the assembly name)
    $assembliesDir = Join-Path $SolutionPath "src/PluginAssemblies"
    if (Test-Path $assembliesDir) {
        $assemblyDirs = Get-ChildItem -Path $assembliesDir -Directory
        foreach ($dir in $assemblyDirs) {
            $dataXmlFiles = Get-ChildItem -Path $dir.FullName -Filter "*.dll.data.xml"
            foreach ($dataXml in $dataXmlFiles) {
                [xml]$xml = Get-Content $dataXml.FullName -Raw
                $asm = $xml.PluginAssembly
                $asmName = ($asm.FullName -split ',')[0].Trim()
                if ($asmName -eq $PluginName -or $dir.Name -like "$PluginName*") {
                    $types = @()
                    foreach ($pt in $asm.PluginTypes.PluginType) {
                        $types += @{
                            TypeName  = $pt.Name
                            TypeId    = $pt.PluginTypeId
                            FullName  = $pt.AssemblyQualifiedName
                        }
                    }
                    return @{
                        MetadataType = 'Assembly'
                        Name         = $asmName
                        AssemblyId   = $asm.PluginAssemblyId
                        FileName     = $asm.FileName
                        PluginTypes  = $types
                        XmlPath      = $dataXml.FullName
                    }
                }
            }
        }
    }

    throw "Plugin '$PluginName' not found in solution path '$SolutionPath'. Check pluginpackages/ and PluginAssemblies/ directories."
}

function Find-PluginFile {
    <# Locates the built plugin artifact (.nupkg or .dll) by searching plugin project output directories. #>
    param(
        [string]$SolutionPath,
        [string]$PluginName,
        [string]$MetadataType,  # 'Nuget' or 'Assembly'
        [string]$FileName       # Expected filename from metadata
    )

    $repoRoot = (Get-Item $SolutionPath).Parent.Parent.Parent.FullName
    $envConfigPath  = Join-Path $repoRoot "deployments/settings/environment-config.json"
    $platformConfig = Get-Content $envConfigPath -Raw | ConvertFrom-Json
    $searchDirs = @(
        $platformConfig.solutionAreas |
            Where-Object { $_.pluginsPath } |
            ForEach-Object { Join-Path $repoRoot ($_.pluginsPath -replace '/', '\') }
    )

    $extension = if ($MetadataType -eq 'Nuget') { '*.nupkg' } else { '*.dll' }

    foreach ($searchDir in $searchDirs) {
        if (-not (Test-Path $searchDir)) { continue }
        $candidates = Get-ChildItem -Path $searchDir -Recurse -Filter $extension |
            Where-Object { $_.FullName -match '[\\/]bin[\\/](Debug|Release)[\\/]' }

        foreach ($candidate in $candidates) {
            if ($candidate.Name -like "*$PluginName*" -or
                ($FileName -and $candidate.Name -eq $FileName)) {
                return $candidate.FullName
            }
        }
    }

    throw @"
Could not find built artifact for '$PluginName'.
Build the plugin first:
  .\Build-Plugins.ps1 -projectPaths "src/plugins/.../project.csproj"
Then specify -PluginFile explicitly or re-run this script.
"@
}

function Import-StepsFromXml {
    <# Parses SdkMessageProcessingSteps/*.xml files and registers matching steps + images. #>
    param(
        [DataverseApiClient]$Client,
        [string]$SolutionPath,
        [array]$PluginTypeExportKeys,   # Export keys belonging to the pushed plugin
        [array]$PluginTypeNames,         # Type names belonging to the pushed plugin (legacy)
        [string]$FeatureSolution
    )

    $stepsDir = Join-Path $SolutionPath "src/SdkMessageProcessingSteps"
    if (-not (Test-Path $stepsDir)) {
        Write-Warning "No SdkMessageProcessingSteps directory found at $stepsDir"
        return
    }

    $stepFiles = Get-ChildItem -Path $stepsDir -Filter "*.xml"
    $registeredCount = 0
    $skippedCount = 0

    foreach ($file in $stepFiles) {
        [xml]$xml = Get-Content $file.FullName -Raw
        $step = $xml.SdkMessageProcessingStep

        # Determine if this step belongs to the pushed plugin
        $belongsToPlugin = $false
        $pluginTypeId = $null

        if ($step.PluginTypeExportKey) {
            if ($PluginTypeExportKeys -contains $step.PluginTypeExportKey) {
                $belongsToPlugin = $true
                $pluginTypeId = Resolve-PluginTypeId -Client $Client -ExportKey $step.PluginTypeExportKey
            }
        }
        elseif ($step.PluginTypeName) {
            $typeName = ($step.PluginTypeName -split ',')[0].Trim()
            if ($PluginTypeNames -contains $typeName) {
                $belongsToPlugin = $true
                $pluginTypeId = Resolve-PluginTypeId -Client $Client -TypeName $typeName
            }
        }

        if (-not $belongsToPlugin) {
            $skippedCount++
            continue
        }

        # Resolve the SDK message — use the GUID from XML directly (stable across environments)
        $sdkMessageId = $step.SdkMessageId
        $messageName = Get-SdkMessageName -Client $Client -MessageId $sdkMessageId
        Write-Host "  Step: $($step.Name) ($messageName on $($step.PrimaryEntity))"

        # Resolve the message filter
        $messageFilterId = Get-SdkMessageFilterId -Client $Client `
            -SdkMessageId $sdkMessageId -PrimaryEntity $step.PrimaryEntity

        # Register the step
        $stepId = Register-SingleStep -Client $Client `
            -Name $step.Name `
            -PluginTypeId $pluginTypeId `
            -SdkMessageId $sdkMessageId `
            -SdkMessageFilterId $messageFilterId `
            -Stage ([int]$step.Stage) `
            -Mode ([int]$step.Mode) `
            -Rank ([int]$step.Rank) `
            -FilteringAttributes $step.FilteringAttributes `
            -AsyncAutoDelete ([bool][int]$step.AsyncAutoDelete) `
            -FeatureSolution $FeatureSolution

        # Register images
        if ($step.SdkMessageProcessingStepImages -and $step.SdkMessageProcessingStepImages.SdkMessageProcessingStepImage) {
            $images = @($step.SdkMessageProcessingStepImages.SdkMessageProcessingStepImage)
            foreach ($image in $images) {
                Register-StepImage -Client $Client `
                    -StepId $stepId `
                    -ImageName $image.Name `
                    -EntityAlias $image.EntityAlias `
                    -ImageType ([int]$image.ImageType) `
                    -Attributes $image.Attributes `
                    -MessagePropertyName $image.MessagePropertyName
            }
        }

        $registeredCount++
    }

    Write-Host "`n  Steps registered: $registeredCount | Skipped (other plugins): $skippedCount" -ForegroundColor Cyan
}

function Import-CustomApiFromXml {
    <# Parses a customapi directory and registers the custom API, request parameters, and response properties. #>
    param(
        [DataverseApiClient]$Client,
        [string]$CustomApiPath,
        [string]$FeatureSolution
    )

    $apiXmlPath = Join-Path $CustomApiPath "customapi.xml"
    if (-not (Test-Path $apiXmlPath)) {
        throw "customapi.xml not found at: $apiXmlPath"
    }

    [xml]$xml = Get-Content $apiXmlPath -Raw
    $api = $xml.customapi
    $uniqueName = $api.uniquename
    Write-Host "`n  Registering Custom API: $uniqueName"

    # Resolve plugin type
    $pluginTypeId = $null
    if ($api.plugintypeid -and $api.plugintypeid.plugintypeexportkey) {
        $pluginTypeId = Resolve-PluginTypeId -Client $Client -ExportKey $api.plugintypeid.plugintypeexportkey
    }

    # Check for existing API
    $existing = $Client.RetrieveMultiple('customapis',
        "?`$filter=uniquename eq '$uniqueName'&`$select=customapiid")

    $apiData = @{
        "uniquename"                       = $uniqueName
        "name"                             = $api.name
        "displayname"                      = $api.displayname.default
        "description"                      = $api.description.default
        "bindingtype"                      = [int]$api.bindingtype
        "isfunction"                       = [bool][int]$api.isfunction
        "isprivate"                        = [bool][int]$api.isprivate
        "allowedcustomprocessingsteptype"   = [int]$api.allowedcustomprocessingsteptype
        "workflowsdkstepenabled"           = [bool][int]$api.workflowsdkstepenabled
    }

    if ($pluginTypeId) {
        $apiData["plugintypeid@odata.bind"] = "/plugintypes($pluginTypeId)"
    }

    if ($existing -and $existing.Count -gt 0) {
        Write-Host "    Updating existing Custom API"
        $apiId = $existing[0].customapiid
        $updateData = @{}
        foreach ($key in $apiData.Keys) {
            if ($key -notlike '*@odata.bind') {
                $updateData[$key] = $apiData[$key]
            }
        }
        $Client.Update('customapis', $apiId, $updateData)
    }
    else {
        Write-Host "    Creating Custom API"
        $apiId = New-DataverseRecord -Client $Client -EntityName 'customapis' -Data $apiData
    }

    # Add to solution (component type 68 = CustomApi)
    if ($FeatureSolution -and $apiId) {
        $Client.AddComponentToSolution($apiId, 68, $FeatureSolution, $false) | Out-Null
    }

    # Register request parameters
    $requestParamsDir = Join-Path $CustomApiPath "customapirequestparameters"
    if (Test-Path $requestParamsDir) {
        $paramDirs = Get-ChildItem -Path $requestParamsDir -Directory
        foreach ($paramDir in $paramDirs) {
            $paramXml = Join-Path $paramDir.FullName "customapirequestparameter.xml"
            if (-not (Test-Path $paramXml)) { continue }

            [xml]$pXml = Get-Content $paramXml -Raw
            $param = $pXml.customapirequestparameter
            Write-Host "    Request param: $($param.uniquename)"

            $existingParam = $Client.RetrieveMultiple('customapirequestparameters',
                "?`$filter=uniquename eq '$($param.uniquename)' and _customapiid_value eq $apiId&`$select=customapirequestparameterid")

            $paramData = @{
                "uniquename"              = $param.uniquename
                "name"                    = $param.name
                "displayname"             = $param.displayname.default
                "type"                    = [int]$param.type
                "isoptional"              = [bool][int]$param.isoptional
                "customapiid@odata.bind"  = "/customapis($apiId)"
            }

            if ($existingParam -and $existingParam.Count -gt 0) {
                $updateData = @{}
                foreach ($key in $paramData.Keys) {
                    if ($key -notlike '*@odata.bind') {
                        $updateData[$key] = $paramData[$key]
                    }
                }
                $Client.Update('customapirequestparameters', $existingParam[0].customapirequestparameterid, $updateData)
            }
            else {
                New-DataverseRecord -Client $Client -EntityName 'customapirequestparameters' -Data $paramData | Out-Null
            }
        }
    }

    # Register response properties
    $responsePropsDir = Join-Path $CustomApiPath "customapiresponseproperties"
    if (Test-Path $responsePropsDir) {
        $propDirs = Get-ChildItem -Path $responsePropsDir -Directory
        foreach ($propDir in $propDirs) {
            $propXml = Join-Path $propDir.FullName "customapiresponseproperty.xml"
            if (-not (Test-Path $propXml)) { continue }

            [xml]$rXml = Get-Content $propXml -Raw
            $prop = $rXml.customapiresponseproperty
            Write-Host "    Response prop: $($prop.uniquename)"

            $existingProp = $Client.RetrieveMultiple('customapiresponseproperties',
                "?`$filter=uniquename eq '$($prop.uniquename)' and _customapiid_value eq $apiId&`$select=customapiresponsepropertyid")

            $propData = @{
                "uniquename"              = $prop.uniquename
                "name"                    = $prop.name
                "displayname"             = $prop.displayname.default
                "type"                    = [int]$prop.type
                "customapiid@odata.bind"  = "/customapis($apiId)"
            }

            if ($existingProp -and $existingProp.Count -gt 0) {
                $updateData = @{}
                foreach ($key in $propData.Keys) {
                    if ($key -notlike '*@odata.bind') {
                        $updateData[$key] = $propData[$key]
                    }
                }
                $Client.Update('customapiresponseproperties', $existingProp[0].customapiresponsepropertyid, $updateData)
            }
            else {
                New-DataverseRecord -Client $Client -EntityName 'customapiresponseproperties' -Data $propData | Out-Null
            }
        }
    }

    Write-Host "  Custom API '$uniqueName' registered successfully" -ForegroundColor Green
}

#endregion

#region Main Execution

Write-Host "`n=== Register-Plugin ===" -ForegroundColor Cyan
Write-Host "Mode: $($PSCmdlet.ParameterSetName)"
Write-Host "Environment: $EnvironmentUrl"

# Initialize API client
$client = Initialize-ApiClient -EnvironmentUrl $EnvironmentUrl -TenantId $TenantId -ClientId $ClientId

switch ($PSCmdlet.ParameterSetName) {

    'FromXml' {
        # --- Mode A: Push + register from solution XML ---
        Write-Host "`n--- Plugin: $PluginName ---"

        # Find plugin metadata in solution
        $metadata = Find-PluginMetadata -SolutionPath $SolutionPath -PluginName $PluginName
        Write-Host "  Found: $($metadata.MetadataType) plugin at $($metadata.XmlPath)"

        if (-not $SkipPush) {
            # Resolve the plugin file
            if (-not $PluginFile) {
                $PluginFile = Find-PluginFile -SolutionPath $SolutionPath `
                    -PluginName $PluginName -MetadataType $metadata.MetadataType `
                    -FileName $metadata.FileName
            }

            # Look up the plugin record in the environment
            $pluginRecord = Get-PluginRecordId -Client $client -PluginName $metadata.Name
            if (-not $pluginRecord) {
                throw @"
Plugin '$($metadata.Name)' not found in the environment.
Deploy the solution first to create the plugin record:
  .\Deploy-Solutions.ps1 -solutionList "$((Split-Path $SolutionPath -Leaf))" -targetEnvironment "<env>" -environmentUrl "$EnvironmentUrl" ...
Then re-run this script.
"@
            }

            # Push the binary
            Push-PluginBinary -PluginFile $PluginFile `
                -PluginId $pluginRecord.Id `
                -PluginType $pluginRecord.Type `
                -EnvironmentUrl $EnvironmentUrl
        }

        if ($RegisterSteps) {
            Write-Host "`n--- Registering steps from solution XML ---"

            # Get the plugin types in the environment for this plugin
            $pluginRecord = Get-PluginRecordId -Client $client -PluginName $metadata.Name
            if (-not $pluginRecord) {
                throw "Plugin '$($metadata.Name)' not found in environment after push"
            }

            $envTypes = Get-PluginTypes -Client $client `
                -PluginRecordId $pluginRecord.Id `
                -PluginRecordType $pluginRecord.Type

            # Build lists of export keys and type names for matching against step XML
            $exportKeys = @($envTypes | Where-Object { $_.plugintypeexportkey } |
                ForEach-Object { $_.plugintypeexportkey })
            $typeNames = @($envTypes | ForEach-Object { $_.typename })

            Write-Host "  Plugin has $($envTypes.Count) type(s): $($typeNames -join ', ')"

            Import-StepsFromXml -Client $client `
                -SolutionPath $SolutionPath `
                -PluginTypeExportKeys $exportKeys `
                -PluginTypeNames $typeNames `
                -FeatureSolution $SolutionName
        }
    }

    'Step' {
        # --- Mode B: Individual step registration ---
        Write-Host "`n--- Registering individual step ---"

        # Resolve plugin type
        $pluginTypeId = Resolve-PluginTypeId -Client $client -TypeName $PluginType
        Write-Host "  Plugin type: $PluginType (ID: $pluginTypeId)"

        # Resolve SDK message
        $sdkMessageId = Get-SdkMessageId -Client $client -MessageName $Message
        Write-Host "  Message: $Message (ID: $sdkMessageId)"

        # Resolve message filter
        $messageFilterId = Get-SdkMessageFilterId -Client $client `
            -SdkMessageId $sdkMessageId -PrimaryEntity $PrimaryEntity

        # Build step name
        $stepName = "${PluginType}: $Message of $PrimaryEntity"

        # Register
        $stepId = Register-SingleStep -Client $client `
            -Name $stepName `
            -PluginTypeId $pluginTypeId `
            -SdkMessageId $sdkMessageId `
            -SdkMessageFilterId $messageFilterId `
            -Stage $Stage `
            -Mode $StepMode `
            -Rank $Rank `
            -FilteringAttributes $FilteringAttributes `
            -AsyncAutoDelete ([bool]$AsyncAutoDelete.IsPresent) `
            -FeatureSolution $SolutionName

        # Register images if specified
        if ($PreImageAttributes -or $PostImageAttributes) {
            if ($PreImageAttributes) {
                Register-StepImage -Client $client -StepId $stepId `
                    -ImageName 'PreImage' -EntityAlias 'PreImage' -ImageType 0 `
                    -Attributes $PreImageAttributes
            }
            if ($PostImageAttributes) {
                Register-StepImage -Client $client -StepId $stepId `
                    -ImageName 'PostImage' -EntityAlias 'PostImage' -ImageType 1 `
                    -Attributes $PostImageAttributes
            }
        }

        Write-Host "`n  Step registered: $stepName (ID: $stepId)" -ForegroundColor Green
    }

    'CustomApi' {
        # --- Mode C: Custom API registration ---
        Write-Host "`n--- Registering Custom API ---"
        Import-CustomApiFromXml -Client $client -CustomApiPath $CustomApiPath -FeatureSolution $SolutionName
    }
}

Write-Host "`n=== Done ===" -ForegroundColor Green

#endregion
